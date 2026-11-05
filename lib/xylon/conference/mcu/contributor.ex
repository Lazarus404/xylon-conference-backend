defmodule Xylon.Conference.Mcu.Contributor do
  @moduledoc """
  MCU contributor ingress: decode RTP into 48 kHz mono bus PCM slots.

  ## What problem this solves

  With `audio: :mcu`, each publisher's audio must be decoded and resampled to
  the shared PCM mix bus before mixing. This module owns per-participant decode
  state (codec port, jitter buffer, PCM accumulator, PLC, RTP timestamp
  drift align, startup playout hold) in `Xylon.Conference.Runtime` ETS.
  Supports Opus, PCMU, PCMA, G.722, and L16 (PCM16LE passthrough).

  Short sequence gaps: Opus with `useinbandfec=1` recovers a single missing
  frame via `Codec.decode_fec` on the next packet; multi-frame Opus gaps prefer
  `Codec.decode_plc` with PCM `Plc.conceal` fallback. G.711/G.722 use PCM PLC
  only (up to `mcu_plc_max`). Late packets are dropped; `jb_max` adapts between
  8 and 32. Secondary CN / telephone-event payload types mark the slot inactive
  without decoding. RTP timestamp walk is aligned to bus sample counts with
  bounded pad/trim.

  **Internal:** called from `Xylon.Conference.Backend` on media_ready / handle_rtp /
  leave. Bus format matches `Xylon.Conference.Mcu.Mixer` (48 kHz mono, 20 ms).

  ## RFCs

  - [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) (RTP sequence / payload / timestamp)
  - [RFC 3551](https://www.rfc-editor.org/rfc/rfc3551) (PCMU/PCMA/G.722)
  - [RFC 3389](https://www.rfc-editor.org/rfc/rfc3389) (CN -- inactive path)
  - [RFC 4733](https://www.rfc-editor.org/rfc/rfc4733) (telephone-event -- not mixed)
  - [RFC 6716](https://www.rfc-editor.org/rfc/rfc6716) (Opus)
  """

  alias Xylon.Conference.Mcu.{CodecPort, Mixer, Pcm, Plc, Telemetry}
  alias Xylon.Conference.Runtime
  alias XMediaLib.Codec
  alias XMediaLib.Rtp

  @bus_rate 48_000
  @jb_min 8
  @jb_max_cap 32
  @jb_target_cap 8
  @default_plc_max 5
  @default_jb_target 2
  @default_drift_max_pad 960
  @drift_ahead_threshold 480

  @typedoc "Plan key shared with Plan/Runtime."
  @type plan_ref :: Runtime.plan_ref()

  @doc """
  Ensures a decode port exists for `participant_id`.

  Recreates the port when `codec_desc` fingerprint changes (renegotiation).
  Returns `{:error, :unsupported_codec}` for non-mixable names.

  Opts:

  - `:jb_target` -- startup playout hold depth (0..8, default 2)
  - `:non_mixable_pts` -- CN / telephone-event PTs on this audio mid
  """
  @spec ensure(plan_ref(), term(), map(), keyword()) :: :ok | {:error, term()}
  def ensure(plan_ref, participant_id, %{name: name} = codec_desc, opts \\ [])
      when is_list(opts) do
    Runtime.ensure_table!()

    if CodecPort.supported_name?(name) do
      case Runtime.get_mcu_contrib(plan_ref, participant_id) do
        %{codec_pid: :l16_passthrough, codec_desc: old} = existing ->
          if CodecPort.fingerprint(old) != CodecPort.fingerprint(codec_desc) do
            _ = clear_contrib_only(plan_ref, participant_id)
            start_contrib(plan_ref, participant_id, codec_desc, opts)
          else
            patched = patch_contrib_opts(existing, opts)
            _ = Runtime.put_mcu_contrib(plan_ref, participant_id, patched)
            :ok
          end

        %{codec_pid: pid, codec_desc: old} = existing when is_pid(pid) ->
          cond do
            CodecPort.fingerprint(old) != CodecPort.fingerprint(codec_desc) ->
              _ = clear_contrib_only(plan_ref, participant_id)
              start_contrib(plan_ref, participant_id, codec_desc, opts)

            Process.alive?(pid) ->
              patched = patch_contrib_opts(existing, opts)
              _ = Runtime.put_mcu_contrib(plan_ref, participant_id, patched)
              :ok

            true ->
              start_contrib(plan_ref, participant_id, codec_desc, opts)
          end

        _ ->
          start_contrib(plan_ref, participant_id, codec_desc, opts)
      end
    else
      {:error, :unsupported_codec}
    end
  end

  @doc """
  Pushes one plaintext RTP packet through JB + decode/PLC into the PCM slot.

  Opts:

  - `:level` -- stored on the slot when a full tick is ready (or nil)
  - `:plc_max` -- max consecutive PLC packets (default 5)
  - `:jb_target` -- overrides contrib startup hold depth for this push
  - `:drift_max_pad` -- max PLC/zero pad samples per packet for skew (default 960)
  """
  @spec push(plan_ref(), term(), Rtp.t() | map(), keyword()) :: :ok | {:error, term()}
  def push(plan_ref, participant_id, rtp, opts \\ []) when is_list(opts) do
    Runtime.ensure_table!()
    plc_max = Keyword.get(opts, :plc_max, @default_plc_max)
    drift_max_pad = Keyword.get(opts, :drift_max_pad, @default_drift_max_pad)

    with {:ok, contrib} <- fetch_contrib(plan_ref, participant_id),
         contrib <- maybe_override_jb_target(contrib, opts),
         {:ok, action} <- classify_pt(contrib, rtp) do
      case action do
        :inactive ->
          contrib2 = mark_inactive(contrib)
          _ = Runtime.put_mcu_contrib(plan_ref, participant_id, contrib2)
          :ok

        :mixable ->
          with {:ok, contrib2} <- jb_push(contrib, rtp),
               {:ok, contrib3} <- jb_drain(contrib2, Keyword.get(opts, :level), plc_max, drift_max_pad) do
            _ = Runtime.put_mcu_contrib(plan_ref, participant_id, contrib3)
            :ok
          end
      end
    end
  end

  @doc """
  Returns the latest full bus tick slot, or `{:error, :empty | :not_found}`.
  """
  @spec take_slot(plan_ref(), term()) ::
          {:ok, %{pcm: binary(), level: non_neg_integer() | nil}} | {:error, :empty | :not_found}
  def take_slot(plan_ref, participant_id) do
    Runtime.ensure_table!()

    case Runtime.get_mcu_contrib(plan_ref, participant_id) do
      %{slot: %{pcm: pcm} = slot} when is_binary(pcm) ->
        {:ok, %{pcm: pcm, level: Map.get(slot, :level)}}

      %{slot: nil} ->
        {:error, :empty}

      nil ->
        {:error, :not_found}

      _ ->
        {:error, :empty}
    end
  end

  @doc """
  Closes the codec port and clears MCU contributor + bind rows for the participant.
  """
  @spec clear(plan_ref(), term()) :: :ok
  def clear(plan_ref, participant_id) do
    Runtime.ensure_table!()
    clear_contrib_only(plan_ref, participant_id)
    true = :ets.delete(:xylon_conference_runtime, {plan_ref, :mcu_bind, participant_id})
    :ok
  end

  defp clear_contrib_only(plan_ref, participant_id) do
    case Runtime.get_mcu_contrib(plan_ref, participant_id) do
      %{codec_pid: pid} when is_pid(pid) ->
        _ = Codec.close(pid)

      _ ->
        :ok
    end

    true = :ets.delete(:xylon_conference_runtime, {plan_ref, :mcu_contrib, participant_id})
    :ok
  end

  defp start_contrib(plan_ref, participant_id, codec_desc, opts) do
    channels = Map.get(codec_desc, :channels, 1)
    channels = if is_integer(channels) and channels > 0, do: channels, else: 1
    jb_target = clamp_jb_target(Keyword.get(opts, :jb_target, @default_jb_target))
    non_mixable = Keyword.get(opts, :non_mixable_pts, []) |> List.wrap()

    case CodecPort.start(codec_desc) do
      {:ok, pid} ->
        # Ingress uses decode_fec/decode_plc; encoder FEC ctls are egress-only.
        contrib = %{
          codec_pid: pid,
          codec_desc: codec_desc,
          channels: channels,
          clock_rate: Map.get(codec_desc, :clock_rate) || @bus_rate,
          opus_fec?: CodecPort.opus_fec?(codec_desc),
          last_seq: nil,
          pending: %{},
          pcm_buf: <<>>,
          slot: nil,
          last_bus_frame: nil,
          last_fec_pcm: nil,
          last_rtp_ts: nil,
          drift_err_q: 0,
          jb_max: @jb_max_cap,
          jb_target: jb_target,
          startup_held?: jb_target > 1,
          late_count: 0,
          in_order_streak: 0,
          non_mixable_pts: non_mixable
        }

        _ = Runtime.put_mcu_contrib(plan_ref, participant_id, contrib)
        :ok

      {:error, _} = err ->
        err
    end
  end

  defp patch_contrib_opts(existing, opts) do
    existing
    |> then(fn c ->
      if Keyword.has_key?(opts, :jb_target) do
        t = clamp_jb_target(Keyword.fetch!(opts, :jb_target))
        %{c | jb_target: t, startup_held?: Map.get(c, :startup_held?, false) and t > 1}
      else
        c
      end
    end)
    |> then(fn c ->
      if Keyword.has_key?(opts, :non_mixable_pts) do
        %{c | non_mixable_pts: List.wrap(Keyword.fetch!(opts, :non_mixable_pts))}
      else
        c
      end
    end)
  end

  defp maybe_override_jb_target(contrib, opts) do
    if Keyword.has_key?(opts, :jb_target) do
      t = clamp_jb_target(Keyword.fetch!(opts, :jb_target))
      %{contrib | jb_target: t}
    else
      contrib
    end
  end

  defp clamp_jb_target(n) when is_integer(n) and n >= 0 and n <= @jb_target_cap, do: n
  defp clamp_jb_target(_), do: @default_jb_target

  defp fetch_contrib(plan_ref, participant_id) do
    case Runtime.get_mcu_contrib(plan_ref, participant_id) do
      %{} = c -> {:ok, c}
      nil -> {:error, :not_found}
    end
  end

  defp classify_pt(%{codec_desc: %{payload_type: pt}} = contrib, rtp) do
    case rtp_pt(rtp) do
      ^pt ->
        {:ok, :mixable}

      other when is_integer(other) ->
        non = Map.get(contrib, :non_mixable_pts, [])

        if other in non do
          {:ok, :inactive}
        else
          {:error, :pt_mismatch}
        end

      _ ->
        {:error, :pt_mismatch}
    end
  end

  defp mark_inactive(contrib) do
    samples = Mixer.samples_per_tick([])
    silence = :binary.copy(<<0, 0>>, samples)
    %{contrib | slot: %{pcm: silence, level: 127}}
  end

  defp jb_push(contrib, rtp) do
    seq = rtp_seq(rtp)
    payload = rtp_payload(rtp)
    ts = rtp_ts(rtp)
    jb_max = Map.get(contrib, :jb_max, @jb_max_cap)

    cond do
      not is_integer(seq) or not is_binary(payload) ->
        {:error, :bad_rtp}

      is_integer(contrib.last_seq) and not seq_ahead?(seq, contrib.last_seq) ->
        late = Map.get(contrib, :late_count, 0) + 1
        jb_max = adapt_jb_max_up(jb_max, late)
        jb_target = adapt_jb_target_up(Map.get(contrib, :jb_target, @default_jb_target), late)

        {:ok,
         %{contrib | late_count: late, in_order_streak: 0, jb_max: jb_max, jb_target: jb_target}}

      true ->
        streak = Map.get(contrib, :in_order_streak, 0) + 1
        jb_max = adapt_jb_max_down(jb_max, streak)
        jb_target = adapt_jb_target_down(Map.get(contrib, :jb_target, @default_jb_target), streak)

        pending =
          contrib.pending
          |> Map.put(seq, %{payload: payload, timestamp: ts})
          |> trim_pending(jb_max)

        {:ok,
         %{
           contrib
           | pending: pending,
             jb_max: jb_max,
             jb_target: jb_target,
             in_order_streak: streak,
             late_count: 0
         }}
    end
  end

  defp adapt_jb_max_up(jb_max, late) when late >= 3 and jb_max < @jb_max_cap,
    do: min(@jb_max_cap, jb_max + 4)

  defp adapt_jb_max_up(jb_max, _), do: jb_max

  defp adapt_jb_max_down(jb_max, streak) when streak >= 32 and jb_max > @jb_min,
    do: max(@jb_min, jb_max - 4)

  defp adapt_jb_max_down(jb_max, _), do: jb_max

  defp adapt_jb_target_up(t, late) when late >= 3 and t < @jb_target_cap, do: t + 1
  defp adapt_jb_target_up(t, _), do: t

  defp adapt_jb_target_down(t, streak) when streak >= 32 and t > 1, do: t - 1
  defp adapt_jb_target_down(t, _), do: t

  defp jb_drain(contrib, level, plc_max, drift_max_pad) do
    contrib
    |> deliver_ready(level, plc_max, drift_max_pad)
    |> then(&{:ok, &1})
  end

  defp deliver_ready(%{startup_held?: true} = contrib, level, plc_max, drift_max_pad) do
    if hold_ready?(contrib) do
      deliver_ready(%{contrib | startup_held?: false}, level, plc_max, drift_max_pad)
    else
      contrib
    end
  end

  defp deliver_ready(contrib, level, plc_max, drift_max_pad) do
    samples = Mixer.samples_per_tick([])

    case next_action(contrib, plc_max) do
      :idle ->
        contrib

      {:deliver, seq} ->
        deliver_packet(contrib, seq, level, plc_max, drift_max_pad)

      {:plc, n} ->
        contrib
        |> apply_plc(n, samples, level)
        |> deliver_ready(level, plc_max, drift_max_pad)

      {:skip_to, seq} ->
        deliver_ready(%{contrib | last_seq: seq_prev(seq)}, level, plc_max, drift_max_pad)
    end
  end

  defp hold_ready?(%{pending: pending, jb_target: target}) do
    n = map_size(pending)
    need = max(target, 1)

    n >= need or (n > 0 and seq_span(pending) >= max(target - 1, 0))
  end

  defp hold_ready?(%{pending: pending}) do
    map_size(pending) >= @default_jb_target
  end

  defp seq_span(pending) when map_size(pending) == 0, do: 0

  defp seq_span(pending) do
    keys = Map.keys(pending)
    rem(Enum.max(keys) - Enum.min(keys) + 65_536, 65_536)
  end

  defp next_action(%{last_seq: nil, pending: pending}, _plc_max)
       when map_size(pending) > 0 do
    {:deliver, pending |> Map.keys() |> Enum.min()}
  end

  defp next_action(%{last_seq: last, pending: pending} = contrib, plc_max)
       when is_integer(last) do
    expect = seq_next(last)

    cond do
      Map.has_key?(pending, expect) ->
        {:deliver, expect}

      map_size(pending) == 0 ->
        :idle

      true ->
        ahead =
          pending
          |> Map.keys()
          |> Enum.filter(&seq_ahead?(&1, last))

        case ahead do
          [] ->
            :idle

          keys ->
            next = Enum.min_by(keys, &seq_dist(last, &1))
            gap = seq_dist(last, next) - 1

            cond do
              gap <= 0 ->
                {:deliver, next}

              gap == 1 and Map.get(contrib, :opus_fec?) == true ->
                {:deliver, next}

              gap <= plc_max ->
                {:plc, gap}

              true ->
                {:skip_to, next}
            end
        end
    end
  end

  defp next_action(_, _), do: :idle

  defp apply_plc(contrib, n, samples, level) when n > 0 do
    Enum.reduce(1..n, contrib, fn _, c ->
      apply_one_plc(c, samples, level)
    end)
  end

  defp apply_one_plc(c, samples, level) do
    frame = plc_bus_frame(c, samples)
    tick_bytes = samples * 2
    buf = c.pcm_buf <> frame

    {slot, buf, last_frame} =
      if byte_size(buf) >= tick_bytes do
        <<out::binary-size(^tick_bytes), rest::binary>> = buf
        {%{pcm: out, level: level}, rest, out}
      else
        {c.slot, buf, Map.get(c, :last_bus_frame)}
      end

    %{
      c
      | last_seq: seq_next(c.last_seq || -1),
        pcm_buf: buf,
        slot: slot || c.slot,
        last_bus_frame: last_frame
    }
  end

  defp plc_bus_frame(c, samples) do
    if opus_codec?(c) do
      case Codec.decode_plc(c.codec_pid) do
        {:ok, {pcm, rate, ch, _}} ->
          mono = to_mono(pcm, ch || c.channels)

          case to_bus(mono, rate) do
            {:ok, bus} when byte_size(bus) == samples * 2 ->
              bus

            {:ok, bus} when byte_size(bus) > samples * 2 ->
              binary_part(bus, 0, samples * 2)

            _ ->
              Plc.conceal(Map.get(c, :last_bus_frame), samples)
          end

        _ ->
          Plc.conceal(Map.get(c, :last_bus_frame), samples)
      end
    else
      Plc.conceal(Map.get(c, :last_bus_frame), samples)
    end
  end

  defp opus_codec?(%{codec_desc: %{name: name}}) do
    name |> to_string() |> String.downcase() == "opus"
  end

  defp opus_codec?(_), do: false

  defp deliver_packet(contrib, seq, level, plc_max, drift_max_pad) do
    %{payload: payload, timestamp: rtp_ts} = Map.fetch!(contrib.pending, seq)
    contrib = %{contrib | pending: Map.delete(contrib.pending, seq)}
    contrib = maybe_recover_fec_gap(contrib, seq, payload, level, drift_max_pad)

    case decode_payload(contrib, payload) do
      {:ok, {pcm, rate, ch, _bits}} ->
        case ingest_decoded_pcm(
               contrib,
               pcm,
               rate,
               ch || contrib.channels,
               rtp_ts,
               seq,
               level,
               drift_max_pad
             ) do
          {:ok, contrib2} ->
            deliver_ready(contrib2, level, plc_max, drift_max_pad)

          {:error, reason} ->
            _ = Telemetry.emit(:codec_error, %{count: 1}, %{op: :decode, reason: reason})
            %{contrib | last_seq: seq}
        end

      {:error, reason} ->
        _ = Telemetry.emit(:codec_error, %{count: 1}, %{op: :decode, reason: reason})
        %{contrib | last_seq: seq}
    end
  end

  defp decode_payload(%{codec_pid: :l16_passthrough}, payload) do
    alias Xylon.Conference.Mcu.Cascade

    case Cascade.unpack_l16_payload(payload) do
      {:ok, pcm} -> {:ok, {pcm, 48_000, 1, 16}}
      {:error, _} = err -> err
    end
  end

  defp decode_payload(%{codec_pid: pid}, payload) when is_pid(pid) do
    Codec.decode(pid, payload)
  end

  defp maybe_recover_fec_gap(contrib, seq, payload, level, drift_max_pad) do
    last = contrib.last_seq

    if Map.get(contrib, :opus_fec?) == true and is_integer(last) and seq_dist(last, seq) == 2 do
      recovered_seq = seq_next(last)
      samples = Mixer.samples_per_tick([])

      case Codec.decode_fec(contrib.codec_pid, payload) do
        {:ok, {pcm, rate, ch, _}} ->
          case ingest_decoded_pcm(
                 contrib,
                 pcm,
                 rate,
                 ch || contrib.channels,
                 recovered_rtp_ts(contrib),
                 recovered_seq,
                 level,
                 drift_max_pad
               ) do
            {:ok, c2} ->
              # Preserve recovered frame across the following current-packet ingest.
              %{c2 | last_fec_pcm: Map.get(c2, :last_bus_frame)}

            {:error, _} ->
              apply_one_plc(contrib, samples, level)
          end

        _ ->
          apply_one_plc(contrib, samples, level)
      end
    else
      contrib
    end
  end

  defp recovered_rtp_ts(%{last_rtp_ts: last, clock_rate: clock}) when is_integer(last) do
    clock = if is_integer(clock) and clock > 0, do: clock, else: @bus_rate
    rem(last + div(clock * 20, 1000), 4_294_967_296)
  end

  defp recovered_rtp_ts(_), do: nil

  defp ingest_decoded_pcm(contrib, pcm, rate, channels, rtp_ts, seq, level, drift_max_pad) do
    mono = to_mono(pcm, channels)

    case to_bus(mono, rate) do
      {:ok, bus_pcm} ->
        {bus_pcm, contrib} = align_to_rtp_ts(contrib, rtp_ts, bus_pcm, drift_max_pad)
        buf = contrib.pcm_buf <> bus_pcm
        tick_bytes = Mixer.samples_per_tick([]) * 2

        {slot, buf, last_frame} =
          if byte_size(buf) >= tick_bytes do
            <<frame::binary-size(^tick_bytes), rest::binary>> = buf
            {%{pcm: frame, level: level}, rest, frame}
          else
            {contrib.slot, buf, Map.get(contrib, :last_bus_frame)}
          end

        last_frame =
          cond do
            is_binary(last_frame) ->
              last_frame

            byte_size(bus_pcm) == tick_bytes ->
              bus_pcm

            true ->
              Map.get(contrib, :last_bus_frame)
          end

        {:ok,
         %{
           contrib
           | last_seq: seq,
             pcm_buf: buf,
             slot: slot || contrib.slot,
             last_bus_frame: last_frame
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp align_to_rtp_ts(contrib, rtp_ts, bus_pcm, max_pad)
       when is_integer(rtp_ts) and is_binary(bus_pcm) do
    clock = Map.get(contrib, :clock_rate) || Map.get(contrib.codec_desc, :clock_rate) || @bus_rate
    clock = if is_integer(clock) and clock > 0, do: clock, else: @bus_rate
    got = div(byte_size(bus_pcm), 2)

    case Map.get(contrib, :last_rtp_ts) do
      nil ->
        {bus_pcm, %{contrib | last_rtp_ts: rtp_ts, drift_err_q: 0}}

      last when is_integer(last) ->
        delta = unwrap32(rtp_ts - last)
        err = Map.get(contrib, :drift_err_q, 0)
        num = delta * @bus_rate + err
        expected = div(num, clock)
        new_err = rem(num, clock)

        bus2 =
          adjust_bus_samples(
            bus_pcm,
            got,
            expected,
            max_pad,
            Map.get(contrib, :last_bus_frame)
          )

        {bus2, %{contrib | last_rtp_ts: rtp_ts, drift_err_q: new_err}}

      _ ->
        {bus_pcm, %{contrib | last_rtp_ts: rtp_ts}}
    end
  end

  defp align_to_rtp_ts(contrib, _rtp_ts, bus_pcm, _max_pad), do: {bus_pcm, contrib}

  defp unwrap32(d) when is_integer(d) and d < 0, do: d + 4_294_967_296
  defp unwrap32(d) when is_integer(d), do: rem(d, 4_294_967_296)

  defp adjust_bus_samples(pcm, got, expected, max_pad, last_frame) do
    cond do
      got > expected + @drift_ahead_threshold ->
        keep = max(expected, 0) * 2
        if keep <= 0, do: <<>>, else: binary_part(pcm, 0, min(keep, byte_size(pcm)))

      got < expected ->
        need = min(expected - got, max_pad)
        pcm <> pad_samples(need, last_frame)

      true ->
        pcm
    end
  end

  defp pad_samples(n, _last) when n <= 0, do: <<>>

  defp pad_samples(n, last_frame) when is_binary(last_frame) and byte_size(last_frame) >= 2 do
    # ponytail: take prefix of last frame when sizes differ; else zeros via Plc
    expect = n * 2

    cond do
      byte_size(last_frame) == expect ->
        Plc.conceal(last_frame, n)

      byte_size(last_frame) > expect ->
        Plc.conceal(binary_part(last_frame, 0, expect), n)

      true ->
        :binary.copy(<<0, 0>>, n)
    end
  end

  defp pad_samples(n, _), do: :binary.copy(<<0, 0>>, n)

  defp to_bus(pcm, rate) when is_integer(rate) and rate > 0 do
    if rate == @bus_rate, do: {:ok, pcm}, else: Pcm.resample_to_bus(pcm, rate)
  end

  defp to_bus(pcm, _), do: {:ok, pcm}

  defp trim_pending(pending, max) when map_size(pending) <= max, do: pending

  defp trim_pending(pending, max) do
    pending
    |> Enum.sort_by(fn {seq, _} -> seq end)
    |> Enum.take(-max)
    |> Map.new()
  end

  defp to_mono(pcm, 1), do: pcm

  defp to_mono(pcm, channels) when is_integer(channels) and channels > 1 do
    sample_bytes = 2 * channels

    for <<frame::binary-size(^sample_bytes) <- pcm>>, into: <<>> do
      samples =
        for <<s::signed-little-integer-size(16) <- frame>>, do: s

      avg = div(Enum.sum(samples), length(samples))
      <<avg::signed-little-integer-size(16)>>
    end
  end

  defp to_mono(pcm, _), do: pcm

  defp rtp_pt(%Rtp{payload_type: pt}), do: pt
  defp rtp_pt(%{payload_type: pt}), do: pt
  defp rtp_pt(_), do: nil

  defp rtp_seq(%Rtp{sequence_number: seq}), do: seq
  defp rtp_seq(%{sequence_number: seq}), do: seq
  defp rtp_seq(_), do: nil

  defp rtp_ts(%Rtp{timestamp: ts}), do: ts
  defp rtp_ts(%{timestamp: ts}), do: ts
  defp rtp_ts(_), do: nil

  defp rtp_payload(%Rtp{payload: p}), do: p
  defp rtp_payload(%{payload: p}), do: p
  defp rtp_payload(_), do: nil

  defp seq_next(s) when is_integer(s) and s < 0, do: 0
  defp seq_next(s), do: rem(s + 1, 65_536)

  defp seq_prev(s), do: rem(s - 1 + 65_536, 65_536)

  defp seq_ahead?(seq, last) do
    d = rem(seq - last + 65_536, 65_536)
    d > 0 and d < 32_768
  end

  defp seq_dist(from, to), do: rem(to - from + 65_536, 65_536)
end
