defmodule Xylon.Conference.Mcu.Egress do
  @moduledoc """
  MCU egress: shared encode groups plus per-listener RTP packetizers.

  ## What problem this solves

  After the mix bus produces PCM16LE for listeners (full mix or mix-minus-self),
  the MCU encodes to each listener's recv codec (Opus, PCMU, PCMA, or G.722)
  and emits RTP. Listeners that share the same recv codec fingerprint and the
  same exclusion set share **one** encode per tick; each listener still gets
  its own SSRC, sequence, timestamp, marker, and PT. Per-tick stamp uses a
  shared payload template, batches egress ETS writes, and defers mix Sender
  Reports to a tick-level sweep.

  When the listener negotiated RFC 6464 audio-level, outbound mix packets carry
  a one-byte header extension with the mix level. When transport-cc is
  negotiated, packets also carry a transport-wide sequence for subscriber TWCC
  BWE. Optional CN payload type supports low-duty comfort noise after sustained
  silence.

  Group key: `{codec_fp, exclusion}` where
  `codec_fp = {name, fmtp, sample_rate_hz, channels}` and
  `exclusion` is `:full` or `{:minus, listener_id}`.

  RTP timestamp advances by `div(clock_rate * 20, 1000)` (Opus 960; G.711/G.722 160).

  **Internal:** used by `Xylon.Conference.Mcu.tick/1` and Backend leave/media_ready.

  ## RFCs

  - [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) (RTP SSRC, sequence, timestamp, marker)
  - [RFC 3551](https://www.rfc-editor.org/rfc/rfc3551) (PCMU/PCMA/G.722 clock)
  - [RFC 3389](https://www.rfc-editor.org/rfc/rfc3389) (CN)
  - [RFC 6464](https://www.rfc-editor.org/rfc/rfc6464) (audio level extension)
  - [draft-holmer-rmcat-transport-wide-cc-extensions](https://datatracker.ietf.org/doc/html/draft-holmer-rmcat-transport-wide-cc-extensions-01)
  - [RFC 6716](https://www.rfc-editor.org/rfc/rfc6716) (Opus)
  - [RFC 8285](https://www.rfc-editor.org/rfc/rfc8285) (one-byte header extensions)
  """

  alias Xylon.Conference.Mcu.{CodecPort, Mixer, Rtcp, Telemetry}
  alias Xylon.Conference.Runtime
  alias XMediaLib.Codec
  alias XMediaLib.Rtp
  alias XMediaLib.Rtp.HeaderExtension

  @bus_rate 48_000
  @tick_ms 20
  @one_byte_profile 0xBEDE
  @default_opus_bitrate 32_000
  @default_sr_interval_ms 1000

  @typedoc "Plan key shared with Plan/Runtime."
  @type plan_ref :: Runtime.plan_ref()

  @typedoc "Recv codec fingerprint for shared-encode grouping."
  @type codec_fp :: {binary(), binary() | nil, pos_integer(), pos_integer()}

  @typedoc "Shared-encode group key (`:full` or minus one contributor id)."
  @type group_key :: {codec_fp(), :full | {:minus, term()}}

  @doc """
  Builds the codec fingerprint used in shared-encode group keys.
  """
  @spec codec_fp(map()) :: codec_fp()
  def codec_fp(%{} = codec_desc) do
    name = codec_desc |> Map.fetch!(:name) |> to_string() |> String.downcase()
    fmtp = Map.get(codec_desc, :fmtp)
    rate = Map.get(codec_desc, :sample_rate_hz) || Map.get(codec_desc, :clock_rate) || @bus_rate
    channels = Map.get(codec_desc, :channels) || 1
    {name, fmtp, rate, channels}
  end

  @doc """
  Ensures a per-listener RTP packetizer row (no private encode port).

  Recreates when `codec_desc` fingerprint changes. Returns
  `{:error, :unsupported_codec}` for unsupported names.

  Opts:

  - `:audio_level_ext_id` -- RFC 6464 one-byte local id, or `nil`
  - `:twcc_ext_id` -- transport-cc one-byte local id, or `nil`
  - `:cn_payload_type` -- comfort-noise PT for silent egress, or `nil`
  - `:sr_interval_ms` -- min interval between mix SRs (default 1000)
  - `:opus_bitrate_bps` -- initial Opus encode bitrate (default 32000)
  - `:bitrate_cap` -- optional ceiling (bps) when applying stored mix REMB on bind
  """
  @spec ensure(plan_ref(), term(), map(), keyword()) :: :ok | {:error, term()}
  def ensure(plan_ref, listener_id, %{name: name} = codec_desc, opts \\ [])
      when is_list(opts) do
    Runtime.ensure_table!()

    if CodecPort.supported_name?(name) do
      case Runtime.get_mcu_egress(plan_ref, listener_id) do
        %{codec_desc: old} = existing ->
          if CodecPort.fingerprint(old) == CodecPort.fingerprint(codec_desc) do
            next =
              existing
              |> Map.put(:codec_desc, codec_desc)
              |> patch_egress_opts(opts)

            _ = Runtime.put_mcu_egress(plan_ref, listener_id, next)
            :ok
          else
            _ = clear(plan_ref, listener_id)
            start_packetizer(plan_ref, listener_id, codec_desc, opts)
          end

        nil ->
          start_packetizer(plan_ref, listener_id, codec_desc, opts)
      end
    else
      {:error, :unsupported_codec}
    end
  end

  @doc """
  Encodes each unique group once. Starts shared encode ports as needed.

  `pairs` is `[{group_key, pcm16le}]`. Bus PCM is passed at 48 kHz so
  `XMediaLib.Codec` resamples down to the encoder native rate.
  """
  @spec encode_groups(plan_ref(), [{group_key(), binary()}]) ::
          {:ok, %{group_key() => binary()}} | {:error, term()}
  def encode_groups(plan_ref, pairs) when is_list(pairs) do
    Runtime.ensure_table!()
    samples = Mixer.samples_per_tick([])
    expect = samples * 2

    Enum.reduce_while(pairs, {:ok, %{}}, fn {group_key, pcm}, {:ok, acc} ->
      with :ok <- check_pcm(pcm, expect),
           {:ok, group} <- ensure_encode_group(plan_ref, group_key),
           {:ok, group} <- maybe_apply_bitrate(plan_ref, group_key, group),
           {:ok, payload} <- encode_group_payload(group, pcm) do
        {:cont, {:ok, Map.put(acc, group_key, payload)}}
      else
        {:error, reason} = err ->
          _ =
            Telemetry.emit(:codec_error, %{count: 1}, %{
              op: :encode,
              reason: reason,
              plan_ref: plan_ref
            })

          {:halt, err}

        other ->
          _ =
            Telemetry.emit(:codec_error, %{count: 1}, %{
              op: :encode,
              reason: other,
              plan_ref: plan_ref
            })

          {:halt, {:error, other}}
      end
    end)
  end

  defp encode_group_payload(%{codec_pid: :l16_passthrough}, pcm) do
    alias Xylon.Conference.Mcu.Cascade
    Cascade.pack_l16_payload(pcm)
  end

  defp encode_group_payload(%{codec_pid: pid}, pcm) when is_pid(pid) do
    Codec.encode(pid, {pcm, @bus_rate, 1, 16})
  end

  defp maybe_apply_bitrate(plan_ref, group_key, %{codec_pid: pid, target_bps: bps} = group)
       when is_pid(pid) and is_integer(bps) do
    if Map.get(group, :applied_bps) == bps do
      {:ok, group}
    else
      case Codec.set_bitrate(pid, bps) do
        :ok ->
          next = %{group | applied_bps: bps}
          _ = Runtime.put_mcu_encode_group(plan_ref, group_key, next)
          {:ok, next}

        {:error, :unsupported} ->
          {:ok, group}

        {:error, _} = err ->
          err
      end
    end
  end

  defp maybe_apply_bitrate(_plan_ref, _key, group), do: {:ok, group}

  @doc """
  Builds one RTP packet from a shared encoded payload for `listener_id`.

  Advances sequence by 1 and timestamp by `div(clock_rate * 20, 1000)`.
  Sets marker on the first packet after silence (`spoke?` was false).

  Thin path: `prepare_from_payload/3` + `stamp_listener/4` + `flush_egresses/2`
  + `maybe_send_srs/3`. This function remains a single-listener convenience
  wrapper (tests and CN-adjacent callers).

  Opts:

  - `:mix_level` -- RFC 6464 level for the outbound audio-level extension (0..127)
  - `:now_ms` -- wall clock for SR interval (tests)
  - `:now_us` -- monotonic us for TWCC send map (tests; default `System.monotonic_time(:microsecond)`)
  """
  @spec packetize_payload(plan_ref(), term(), binary(), group_key(), keyword()) ::
          {:ok, Rtp.t()} | {:error, term()}
  def packetize_payload(plan_ref, listener_id, payload, group_key, opts \\ [])
      when is_binary(payload) and is_list(opts) do
    prepared = prepare_from_payload(payload, group_key)

    with {:ok, rtp, next, newly_bound?} <- stamp_listener(plan_ref, listener_id, prepared, opts) do
      _ = flush_egresses(plan_ref, [{listener_id, next}])

      if newly_bound? do
        _ = Rtcp.apply_bitrates(plan_ref, Map.get(next, :bitrate_cap))
      end

      _ =
        maybe_send_srs(plan_ref, [listener_id],
          now_ms: Keyword.get(opts, :now_ms, System.system_time(:millisecond))
        )

      {:ok, rtp}
    end
  end

  @doc """
  Shared encode-group payload template for thin listener stamp.

  PT, seq, timestamp, and SSRC still come from each listener egress row.
  """
  @spec prepare_from_payload(binary(), group_key(), keyword()) :: map()
  def prepare_from_payload(payload, group_key, _opts \\ [])
      when is_binary(payload) do
    %{payload: payload, group_key: group_key}
  end

  @doc """
  Stamps one listener RTP from a prepared group payload without ETS write.

  Returns `{:ok, rtp, next_egress, newly_bound?}`. Caller batches via
  `flush_egresses/2` and may call `maybe_send_srs/3` once per tick.

  Opts:

  - `:mix_level`, `:now_us` -- same as `packetize_payload/5`
  - `:skip_bind` -- when true, skip encode-group retain (caller pre-bound)
  """
  @spec stamp_listener(plan_ref(), term(), map(), keyword()) ::
          {:ok, Rtp.t(), map(), boolean()} | {:error, term()}
  def stamp_listener(plan_ref, listener_id, %{payload: payload, group_key: group_key}, opts \\ [])
      when is_binary(payload) and is_list(opts) do
    Runtime.ensure_table!()

    with {:ok, egress} <- fetch_egress(plan_ref, listener_id),
         :ok <- maybe_bind(plan_ref, listener_id, egress, group_key, opts) do
      egress = Runtime.get_mcu_egress(plan_ref, listener_id)
      marker = if egress.spoke?, do: 0, else: 1
      seq = egress.seq
      ts = egress.ts
      pt = Map.fetch!(egress.codec_desc, :payload_type)
      step = ts_step(egress.codec_desc)
      mix_level = Keyword.get(opts, :mix_level)
      now_us = Keyword.get(opts, :now_us, System.monotonic_time(:microsecond))
      {extension, egress, twcc_seq} = stamp_extensions(egress, mix_level, now_us)

      rtp = %Rtp{
        padding: 0,
        marker: marker,
        payload_type: pt,
        sequence_number: seq,
        timestamp: ts,
        ssrc: egress.out_ssrc,
        csrcs: [],
        extension: extension,
        payload: payload
      }

      packets = Map.get(egress, :packets, 0) + 1
      octets = Map.get(egress, :octets, 0) + byte_size(payload)
      newly_bound? = Map.get(egress, :group_key) != group_key

      next = %{
        egress
        | seq: rem(seq + 1, 65_536),
          ts: ts + step,
          spoke?: true,
          group_key: group_key,
          silent_ticks: 0,
          cn_sent?: false,
          packets: packets,
          octets: octets,
          last_rtp_ts: ts,
          twcc_seq: twcc_seq
      }

      {:ok, rtp, next, newly_bound?}
    end
  end

  @doc """
  Retains the listener on `group_key` (encode-group refcount).

  Call serially before parallel `stamp_listener(..., skip_bind: true)`.
  """
  @spec ensure_group_bound(plan_ref(), term(), group_key()) :: :ok | {:error, term()}
  def ensure_group_bound(plan_ref, listener_id, group_key) do
    Runtime.ensure_table!()

    with {:ok, egress} <- fetch_egress(plan_ref, listener_id) do
      bind_group(plan_ref, listener_id, egress, group_key)
    end
  end

  defp maybe_bind(plan_ref, listener_id, egress, group_key, opts) do
    if Keyword.get(opts, :skip_bind, false) do
      :ok
    else
      bind_group(plan_ref, listener_id, egress, group_key)
    end
  end

  @doc "Writes many egress rows in one ETS insert."
  @spec flush_egresses(plan_ref(), [{term(), map()}]) :: :ok
  def flush_egresses(plan_ref, pairs) when is_list(pairs) do
    Runtime.put_mcu_egresses(plan_ref, pairs)
  end

  @doc """
  Sends mix Sender Reports for listeners due this tick.

  Defers SR out of the per-listener stamp hot path. Combined with staggered
  `last_sr_ms` anchors on ensure, densify ticks avoid aligned SR storms.
  """
  @spec maybe_send_srs(plan_ref(), [term()], keyword()) :: :ok
  def maybe_send_srs(plan_ref, listener_ids, opts \\ []) when is_list(listener_ids) do
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))

    Enum.each(listener_ids, fn id ->
      _ = Rtcp.maybe_send_sr(plan_ref, id, now_ms: now_ms)
    end)

    :ok
  end

  @doc """
  Emits one comfort-noise RTP packet when `cn_payload_type` is set.

  Advances sequence/timestamp like a normal packet; clears spoke? for marker.
  """
  @spec packetize_cn(plan_ref(), term(), keyword()) :: {:ok, Rtp.t()} | {:error, term()}
  def packetize_cn(plan_ref, listener_id, opts \\ []) when is_list(opts) do
    Runtime.ensure_table!()

    case Runtime.get_mcu_egress(plan_ref, listener_id) do
      %{cn_payload_type: pt} = egress when is_integer(pt) ->
        marker = if egress.spoke?, do: 0, else: 1
        seq = egress.seq
        ts = egress.ts
        step = ts_step(egress.codec_desc)
        now_us = Keyword.get(opts, :now_us, System.monotonic_time(:microsecond))
        {extension, egress, twcc_seq} = stamp_extensions(egress, 127, now_us)
        payload = <<0>>

        rtp = %Rtp{
          padding: 0,
          marker: marker,
          payload_type: pt,
          sequence_number: seq,
          timestamp: ts,
          ssrc: egress.out_ssrc,
          csrcs: [],
          extension: extension,
          payload: payload
        }

        next = %{
          egress
          | seq: rem(seq + 1, 65_536),
            ts: ts + step,
            spoke?: false,
            cn_sent?: true,
            packets: Map.get(egress, :packets, 0) + 1,
            octets: Map.get(egress, :octets, 0) + byte_size(payload),
            last_rtp_ts: ts,
            twcc_seq: twcc_seq
        }

        _ = Runtime.put_mcu_egress(plan_ref, listener_id, next)

        _ =
          Rtcp.maybe_send_sr(plan_ref, listener_id,
            now_ms: Keyword.get(opts, :now_ms, System.system_time(:millisecond))
          )

        {:ok, rtp}

      _ ->
        {:error, :no_cn}
    end
  end

  @doc "Marks listener as silent so the next packetize sets the marker bit."
  @spec mark_silence(plan_ref(), term()) :: :ok
  def mark_silence(plan_ref, listener_id) do
    case Runtime.get_mcu_egress(plan_ref, listener_id) do
      %{} = e ->
        ticks = Map.get(e, :silent_ticks, 0) + 1
        _ = Runtime.put_mcu_egress(plan_ref, listener_id, %{e | spoke?: false, silent_ticks: ticks})
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Clears the listener packetizer and drops encode-group refcount (closes at 0).
  """
  @spec clear(plan_ref(), term()) :: :ok
  def clear(plan_ref, listener_id) do
    Runtime.ensure_table!()

    case Runtime.get_mcu_egress(plan_ref, listener_id) do
      %{group_key: key, out_ssrc: ssrc} = _e when not is_nil(key) ->
        if is_integer(ssrc), do: Runtime.delete_mcu_out_ssrc(plan_ref, ssrc)
        true = :ets.delete(:xylon_conference_runtime, {plan_ref, :mcu_egress, listener_id})
        release_group(plan_ref, key)
        :ok

      %{out_ssrc: ssrc} = _e ->
        if is_integer(ssrc), do: Runtime.delete_mcu_out_ssrc(plan_ref, ssrc)
        true = :ets.delete(:xylon_conference_runtime, {plan_ref, :mcu_egress, listener_id})
        :ok

      nil ->
        :ok
    end
  end

  @doc """
  Closes encode groups whose keys are not in `active_keys` (tick safety net).
  """
  @spec prune_encode_groups(plan_ref(), MapSet.t() | [group_key()]) :: :ok
  def prune_encode_groups(plan_ref, active_keys) do
    Runtime.ensure_table!()
    active = MapSet.new(active_keys)

    plan_ref
    |> match_encode_groups()
    |> Enum.each(fn {key, group} ->
      if MapSet.member?(active, key) do
        :ok
      else
        close_group(plan_ref, key, group)
      end
    end)

    :ok
  end

  defp patch_egress_opts(egress, opts) do
    egress
    |> then(fn e ->
      if Keyword.has_key?(opts, :audio_level_ext_id) do
        Map.put(e, :audio_level_ext_id, Keyword.fetch!(opts, :audio_level_ext_id))
      else
        e
      end
    end)
    |> then(fn e ->
      if Keyword.has_key?(opts, :twcc_ext_id) do
        Map.put(e, :twcc_ext_id, Keyword.fetch!(opts, :twcc_ext_id))
      else
        e
      end
    end)
    |> then(fn e ->
      if Keyword.has_key?(opts, :cn_payload_type) do
        Map.put(e, :cn_payload_type, Keyword.fetch!(opts, :cn_payload_type))
      else
        e
      end
    end)
    |> then(fn e ->
      if Keyword.has_key?(opts, :sr_interval_ms) do
        Map.put(e, :sr_interval_ms, Keyword.fetch!(opts, :sr_interval_ms))
      else
        e
      end
    end)
    |> then(fn e ->
      if Keyword.has_key?(opts, :bitrate_cap) do
        Map.put(e, :bitrate_cap, Keyword.fetch!(opts, :bitrate_cap))
      else
        e
      end
    end)
  end

  # Returns {extension | nil, updated_egress, next_twcc_seq}
  defp stamp_extensions(egress, mix_level, now_us) do
    elements = []

    elements =
      case Map.get(egress, :audio_level_ext_id) do
        id when is_integer(id) and id >= 1 and id <= 14 ->
          level =
            cond do
              is_integer(mix_level) -> max(0, min(127, mix_level))
              true -> 127
            end

          v = if level < 127, do: 1, else: 0
          [{id, <<v::1, level::7>>} | elements]

        _ ->
          elements
      end

    twcc_seq = Map.get(egress, :twcc_seq, 0) || 0

    {elements, egress, next_seq} =
      case Map.get(egress, :twcc_ext_id) do
        id when is_integer(id) and id >= 1 and id <= 14 ->
          send_map =
            egress
            |> Map.get(:twcc_send_map, %{})
            |> Map.put(twcc_seq, now_us)
            |> Xylon.Conference.Bwe.Twcc.trim_send_map()

          {[{id, <<twcc_seq::unsigned-size(16)>>} | elements],
           %{egress | twcc_send_map: send_map}, rem(twcc_seq + 1, 65_536)}

        _ ->
          {elements, egress, twcc_seq}
      end

    extension =
      case elements do
        [] ->
          nil

        _ ->
          %Rtp.Extension{
            type: @one_byte_profile,
            payload: HeaderExtension.encode_one_byte_elements(Enum.reverse(elements))
          }
      end

    {extension, egress, next_seq}
  end

  defp ts_step(%{clock_rate: clock}) when is_integer(clock) and clock > 0,
    do: div(clock * @tick_ms, 1000)

  defp ts_step(_), do: Mixer.samples_per_tick([])

  defp start_packetizer(plan_ref, listener_id, codec_desc, opts) do
    out_ssrc = :erlang.phash2({plan_ref, listener_id, :mcu_egress}, 0xFFFF_FFFF)
    sr_interval_ms = Keyword.get(opts, :sr_interval_ms, @default_sr_interval_ms)

    egress = %{
      codec_desc: codec_desc,
      out_ssrc: out_ssrc,
      seq: 0,
      ts: 0,
      spoke?: false,
      group_key: nil,
      audio_level_ext_id: Keyword.get(opts, :audio_level_ext_id),
      twcc_ext_id: Keyword.get(opts, :twcc_ext_id),
      twcc_seq: 0,
      twcc_send_map: %{},
      cn_payload_type: Keyword.get(opts, :cn_payload_type),
      silent_ticks: 0,
      cn_sent?: false,
      packets: 0,
      octets: 0,
      last_rtp_ts: nil,
      # Stagger first mix SR so densify ticks do not storm GenServer.call for all L.
      last_sr_ms: stagger_sr_anchor(listener_id, sr_interval_ms),
      sr_interval_ms: sr_interval_ms,
      opus_bitrate_bps: Keyword.get(opts, :opus_bitrate_bps, @default_opus_bitrate),
      bitrate_cap: Keyword.get(opts, :bitrate_cap)
    }

    _ = Runtime.put_mcu_egress(plan_ref, listener_id, egress)
    _ = Runtime.put_mcu_out_ssrc(plan_ref, out_ssrc, listener_id)
    :ok
  end

  defp stagger_sr_anchor(listener_id, interval) when is_integer(interval) and interval > 0 do
    now = System.system_time(:millisecond)
    now - rem(:erlang.phash2({listener_id, :mcu_sr}), interval)
  end

  defp stagger_sr_anchor(_listener_id, _interval), do: nil

  defp ensure_encode_group(plan_ref, {{name, fmtp, rate, channels}, _excl} = group_key) do
    case Runtime.get_mcu_encode_group(plan_ref, group_key) do
      %{codec_pid: :l16_passthrough} = group ->
        {:ok, group}

      %{codec_pid: pid} = group when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, group}
        else
          start_encode_group(plan_ref, group_key, name, fmtp, rate, channels)
        end

      _ ->
        start_encode_group(plan_ref, group_key, name, fmtp, rate, channels)
    end
  end

  defp start_encode_group(plan_ref, group_key, name, fmtp, rate, channels) do
    desc = %{
      name: name,
      fmtp: fmtp,
      sample_rate_hz: rate,
      channels: channels,
      payload_type: 0,
      clock_rate: rate,
      mixable?: true
    }

    desc =
      if String.downcase(to_string(name)) == "g722" do
        %{desc | sample_rate_hz: rate, clock_rate: 8000}
      else
        desc
      end

    default_bps = default_opus_bps(plan_ref)

    case CodecPort.start(desc) do
      {:ok, :l16_passthrough} ->
        group = %{
          codec_pid: :l16_passthrough,
          codec_fp: elem(group_key, 0),
          refcount: 0,
          target_bps: default_bps,
          applied_bps: nil
        }

        _ = Runtime.put_mcu_encode_group(plan_ref, group_key, group)
        {:ok, group}

      {:ok, pid} when is_pid(pid) ->
        with :ok <- maybe_configure_opus_encode(pid, name, desc, default_bps) do
          group = %{
            codec_pid: pid,
            codec_fp: elem(group_key, 0),
            refcount: 0,
            target_bps: default_bps,
            applied_bps: if(String.downcase(to_string(name)) == "opus", do: default_bps, else: nil)
          }

          _ = Runtime.put_mcu_encode_group(plan_ref, group_key, group)
          {:ok, group}
        else
          {:error, _} = err ->
            _ = Codec.close(pid)
            err
        end

      {:error, _} = err ->
        err
    end
  end

  defp maybe_configure_opus_encode(pid, name, desc, default_bps) do
    if String.downcase(to_string(name)) == "opus" do
      with :ok <- Codec.set_bitrate(pid, default_bps),
           :ok <- CodecPort.configure_opus!(pid, desc) do
        :ok
      end
    else
      :ok
    end
  end

  defp default_opus_bps(plan_ref) do
    case :ets.match_object(:xylon_conference_runtime, {{plan_ref, :mcu_egress, :_}, :_}) do
      [{_, %{opus_bitrate_bps: n}} | _] when is_integer(n) and n > 0 -> n
      _ -> @default_opus_bitrate
    end
  end

  defp bind_group(_plan_ref, _listener_id, %{group_key: same}, same), do: :ok

  defp bind_group(plan_ref, _listener_id, %{group_key: old}, new_key) do
    if not is_nil(old), do: release_group(plan_ref, old)
    retain_group(plan_ref, new_key)
    :ok
  end

  defp retain_group(plan_ref, group_key) do
    case Runtime.get_mcu_encode_group(plan_ref, group_key) do
      %{refcount: n} = g when is_integer(n) ->
        _ = Runtime.put_mcu_encode_group(plan_ref, group_key, %{g | refcount: n + 1})
        :ok

      _ ->
        :ok
    end
  end

  defp release_group(plan_ref, group_key) do
    case Runtime.get_mcu_encode_group(plan_ref, group_key) do
      %{refcount: n} = g when is_integer(n) and n > 1 ->
        _ = Runtime.put_mcu_encode_group(plan_ref, group_key, %{g | refcount: n - 1})
        :ok

      %{} = g ->
        close_group(plan_ref, group_key, g)

      _ ->
        :ok
    end
  end

  defp close_group(plan_ref, group_key, %{codec_pid: pid}) when is_pid(pid) do
    _ = Codec.close(pid)
    Runtime.delete_mcu_encode_group(plan_ref, group_key)
  end

  defp close_group(plan_ref, group_key, _) do
    Runtime.delete_mcu_encode_group(plan_ref, group_key)
  end

  defp match_encode_groups(plan_ref) do
    :ets.match_object(:xylon_conference_runtime, {{plan_ref, :mcu_encode_group, :_}, :_})
    |> Enum.map(fn {{_pr, :mcu_encode_group, key}, group} -> {key, group} end)
  end

  defp fetch_egress(plan_ref, listener_id) do
    case Runtime.get_mcu_egress(plan_ref, listener_id) do
      %{} = e -> {:ok, e}
      nil -> {:error, :not_found}
    end
  end

  defp check_pcm(pcm, expect) do
    if byte_size(pcm) == expect, do: :ok, else: {:error, :bad_pcm}
  end
end
