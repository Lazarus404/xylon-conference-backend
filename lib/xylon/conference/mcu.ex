defmodule Xylon.Conference.Mcu do
  @moduledoc """
  Conference audio MCU facade: mix tick with shared multi-codec encode groups.

  ## What problem this solves

  After contributors push audio into PCM slots (Opus / PCMU / PCMA / G.722),
  the room needs one event-driven mix tick that gathers slots, applies the
  level gate (RFC 6464 or PCM energy with hysteresis), runs `Mixer.mix_tick/2`,
  encodes once per shared-encode group, and packetizes per-listener RTP
  (thin stamp + batched egress ETS; parallel stamp when listener jobs >= 64).
  Cascade hubs may send trunks a spoke mix-minus (`mcu_spoke_mix_minus`) instead
  of the full mix.

  When the full mix is silence, encoding is skipped. After
  `mcu_dtx_hold_ticks` silent ticks, listeners with a negotiated CN payload
  type may receive one comfort-noise packet.

  **Internal:** called from `Xylon.Conference.Backend.handle_rtp/3` on the MCU
  audio path.

  ## RFCs

  - [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) (RTP)
  - [RFC 3389](https://www.rfc-editor.org/rfc/rfc3389) (CN)
  - [RFC 6464](https://www.rfc-editor.org/rfc/rfc6464) (audio level scale)
  - [RFC 6716](https://www.rfc-editor.org/rfc/rfc6716) (Opus)
  """

  alias Xylon.Conference.Mcu.{Cascade, Egress, Level, Mixer, Rtcp, Telemetry}
  alias Xylon.Conference.{Plan, Runtime}
  alias Xylon.Participant
  alias XMediaLib.Rtp

  @typedoc "Plan key shared with Plan/Runtime."
  @type plan_ref :: Runtime.plan_ref()

  @tick_budget_us 20_000

  @doc """
  Gathers contributor slots, mixes one tick, shared-encodes, and packetizes.

  Opts:

  - `:threshold` -- Mixer silence gate (default 25)
  - `:hysteresis` -- level-gate hysteresis (default 10)
  - `:top_n` -- Mixer top-N loudest (default `nil` = unlimited)
  - `:dtx_hold_ticks` -- silent ticks before optional egress CN (default 3)
  - `:mcu_nif` -- when boolean, force NIF on/off for this tick (default app config)
  - `:mcu_spoke_mix_minus` -- when true, trunk listeners get mix excluding
    contributors attributed to that trunk (default false)

  When the full mix is silence, encoding is skipped. After
  `mcu_dtx_hold_ticks` silent ticks, listeners with a negotiated CN payload
  type may receive one comfort-noise packet.

  Returns `{:ok, specs, mix_rtp}` where `mix_rtp` is a full-mix RTP packet for
  recording (or `nil` on silence / no encode), and `specs` are per-listener
  forward packets.

  Emits `[:xylon, :conference, :mcu, :tick]` with duration and contributor counts.
  """
  @spec tick(plan_ref(), keyword()) ::
          {:ok, [{Participant.t(), Rtp.t()}], Rtp.t() | nil} | {:error, term()}
  def tick(plan_ref, opts \\ []) when is_list(opts) do
    # Bench FakePeer reads this for stamp_plane :mcu_tick_to_egress.
    # Kept until the next tick overwrites it -- egress MFA runs after tick/2
    # returns when Forwarder applies {:forward, specs}.
    _ = Process.put(:xylon_mcu_tick_t0, System.monotonic_time(:nanosecond))

    {us, {result, stats}} = :timer.tc(fn -> do_tick(plan_ref, opts) end)

    _ =
      Telemetry.emit(
        :tick,
        %{
          duration_us: us,
          overrun: if(us > @tick_budget_us, do: 1, else: 0),
          active_contributors: Map.get(stats, :active_contributors, 0),
          encode_groups: Map.get(stats, :encode_groups, 0),
          cpu_millis: div(us, 1000)
        },
        %{plan_ref: plan_ref}
      )

    result
  end

  defp do_tick(plan_ref, opts) do
    Runtime.ensure_table!()
    threshold = Keyword.get(opts, :threshold, 25)
    hyst = Keyword.get(opts, :hysteresis, 10)
    top_n = Keyword.get(opts, :top_n, nil)
    dtx_hold = Keyword.get(opts, :dtx_hold_ticks, 3)
    spoke_mm? = Keyword.get(opts, :mcu_spoke_mix_minus, false) == true
    samples = Mixer.samples_per_tick([])
    silence = :binary.copy(<<0, 0>>, samples)

    contributors = gather_contributors(plan_ref, threshold, hyst)
    active = length(contributors)

    mix_opts =
      [threshold: threshold, top_n: top_n]
      |> then(fn o ->
        case Keyword.fetch(opts, :mcu_nif) do
          {:ok, v} when is_boolean(v) -> Keyword.put(o, :mcu_nif, v)
          _ -> o
        end
      end)

    case Mixer.mix_tick(contributors, mix_opts) do
      {:ok, %{full: full, minus_self: minus_self}} ->
        if full == silence do
          specs = silent_egress(plan_ref, dtx_hold)
          _ = Egress.prune_encode_groups(plan_ref, [])
          {{:ok, specs, nil}, %{active_contributors: active, encode_groups: 0}}
        else
          case forward_listeners(plan_ref, full, minus_self, contributors, mix_opts, spoke_mm?) do
            {:ok, specs, encode_n, mix_rtp} ->
              {{:ok, specs, mix_rtp},
               %{active_contributors: active, encode_groups: encode_n}}

            {:error, _} = err ->
              {err, %{active_contributors: active, encode_groups: 0}}
          end
        end

      {:error, _} = err ->
        {err, %{active_contributors: active, encode_groups: 0}}
    end
  end

  defp gather_contributors(plan_ref, threshold, hyst) do
    plan_ref
    |> Plan.participant_ids()
    |> MapSet.to_list()
    |> Enum.flat_map(fn id ->
      case Runtime.get_mcu_contrib(plan_ref, id) do
        %{slot: %{pcm: pcm} = slot} when is_binary(pcm) ->
          raw = raw_level(plan_ref, id, pcm, slot)
          prev = Runtime.get_mcu_level(plan_ref, id) || Level.new()
          {gated, next_st} = Level.apply_hysteresis(raw, prev, threshold, hyst)
          _ = Runtime.put_mcu_level(plan_ref, id, next_st)

          [
            %{
              id: id,
              pcm: pcm,
              level: gated,
              active?: true
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp raw_level(plan_ref, id, pcm, slot) do
    case Runtime.get_audio_level(plan_ref, id) do
      %{avg: avg} when is_number(avg) ->
        trunc(avg)

      _ ->
        case Map.get(slot, :level) do
          n when is_integer(n) and n >= 0 and n <= 127 -> n
          _ -> Level.energy_level(pcm)
        end
    end
  end

  defp forward_listeners(plan_ref, full, minus_self, contributors, mix_opts, spoke_mm?) do
    jobs =
      plan_ref
      |> Plan.participant_ids()
      |> MapSet.to_list()
      |> Enum.flat_map(fn id ->
        with %Participant{peer_ref: peer} = participant when is_pid(peer) <-
               Plan.get_participant(plan_ref, id),
             true <- Process.alive?(peer),
             %{codec_desc: desc} <- Runtime.get_mcu_egress(plan_ref, id) do
          {pcm, exclusion} =
            cond do
              Cascade.full_mix_listener?(participant) and spoke_mm? ->
                exclude = Cascade.trunk_exclude_ids(plan_ref, id)

                case Mixer.mix_without(contributors, exclude, mix_opts) do
                  {:ok, pcm} -> {pcm, {:minus_trunk, id}}
                  {:error, _} -> {full, :full}
                end

              Cascade.full_mix_listener?(participant) ->
                {full, :full}

              Map.has_key?(minus_self, id) ->
                {Map.fetch!(minus_self, id), {:minus, id}}

              true ->
                {full, :full}
            end

          group_key = {Egress.codec_fp(desc), exclusion}
          mix_level = Level.energy_level(pcm)

          [
            %{
              id: id,
              participant: participant,
              pcm: pcm,
              group_key: group_key,
              mix_level: mix_level
            }
          ]
        else
          _ -> []
        end
      end)

    pairs =
      jobs
      |> Enum.uniq_by(& &1.group_key)
      |> Enum.map(fn %{group_key: gk, pcm: pcm} -> {gk, pcm} end)
      |> ensure_full_encode_pair(jobs, full)

    with {:ok, opus_by_group} <- Egress.encode_groups(plan_ref, pairs) do
      prepared =
        Map.new(opus_by_group, fn {gk, opus} ->
          {gk, Egress.prepare_from_payload(opus, gk)}
        end)

      mix_rtp = stamp_recording_mix(plan_ref, jobs, prepared)

      shard? = length(jobs) >= stamp_shard_threshold()

      if shard? do
        Enum.each(jobs, fn %{id: id, group_key: gk} ->
          _ = Egress.ensure_group_bound(plan_ref, id, gk)
        end)
      end

      {specs, dirty, sr_ids, bound_caps} =
        stamp_listener_jobs(plan_ref, jobs, prepared, skip_bind: shard?)

      _ = Egress.flush_egresses(plan_ref, dirty)

      Enum.each(bound_caps, fn cap ->
        _ = Rtcp.apply_bitrates(plan_ref, cap)
      end)

      _ = Egress.maybe_send_srs(plan_ref, sr_ids)

      active = jobs |> Enum.map(& &1.group_key) |> MapSet.new()
      _ = Egress.prune_encode_groups(plan_ref, active)
      {:ok, specs, map_size(opus_by_group), mix_rtp}
    end
  end

  @record_listener_id "__mcu_mix__"

  defp ensure_full_encode_pair(pairs, jobs, full_pcm) do
    if Enum.any?(pairs, fn {{_fp, excl}, _} -> excl == :full end) do
      pairs
    else
      case pick_record_job(jobs) do
        %{group_key: {fp, _}} -> [{{fp, :full}, full_pcm} | pairs]
        nil -> pairs
      end
    end
  end

  defp pick_record_job(jobs) do
    Enum.find(jobs, fn
      %{group_key: {{"opus", _, _, _}, _}} -> true
      _ -> false
    end) || List.first(jobs)
  end

  defp stamp_recording_mix(plan_ref, jobs, prepared) when map_size(prepared) > 0 do
    full_keys =
      prepared
      |> Map.keys()
      |> Enum.filter(fn {_fp, excl} -> excl == :full end)
      |> Enum.sort_by(fn
        {{"opus", _, _, _}, :full} -> 0
        _ -> 1
      end)

    case full_keys do
      [{fp, :full} = gk | _] ->
        mix_level = recording_mix_level(jobs, gk)

        with %{codec_desc: desc} <- codec_desc_for_fp(plan_ref, jobs, fp),
             :ok <- Egress.ensure(plan_ref, @record_listener_id, desc),
             {:ok, prep} <- Map.fetch(prepared, gk),
             {:ok, rtp, next, _} <-
               Egress.stamp_listener(plan_ref, @record_listener_id, prep,
                 mix_level: mix_level,
                 skip_bind: true
               ) do
          _ = Egress.flush_egresses(plan_ref, [{@record_listener_id, next}])
          rtp
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp stamp_recording_mix(_, _, _), do: nil

  defp recording_mix_level(jobs, {fp, :full}) do
    case Enum.find(jobs, fn
           %{group_key: {^fp, :full}} -> true
           %{group_key: {^fp, _}} -> true
           _ -> false
         end) do
      %{mix_level: lvl} when is_integer(lvl) -> lvl
      _ -> 0
    end
  end

  defp codec_desc_for_fp(plan_ref, jobs, fp) do
    case Enum.find(jobs, fn
           %{group_key: {^fp, _}} -> true
           _ -> false
         end) do
      %{id: id} -> Runtime.get_mcu_egress(plan_ref, id)
      nil -> nil
    end
  end

  # ponytail: Task.async_stream spawn tax; gate via app env (default 64). Upgrade:
  # persistent McuEgressWorker pool if tick budget still trips at high L after thin stamp.
  defp stamp_shard_threshold do
    case Application.get_env(:xylon_conference_backend, :mcu_stamp_shard_threshold, 64) do
      n when is_integer(n) and n > 0 -> n
      _ -> 64
    end
  end

  defp stamp_listener_jobs(plan_ref, jobs, prepared, opts) do
    skip_bind? = Keyword.get(opts, :skip_bind, false)

    if length(jobs) < stamp_shard_threshold() do
      stamp_listener_chunk(plan_ref, jobs, prepared, skip_bind: skip_bind?)
    else
      stamp_listener_jobs_parallel(plan_ref, jobs, prepared)
    end
  end

  defp stamp_listener_jobs_parallel(plan_ref, jobs, prepared) do
    n = min(8, System.schedulers_online())

    jobs
    |> Enum.group_by(fn %{id: id} -> :erlang.phash2(id, n) end)
    |> Map.values()
    |> Task.async_stream(
      fn chunk -> stamp_listener_chunk(plan_ref, chunk, prepared, skip_bind: true) end,
      ordered: false,
      timeout: 20_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce({[], [], [], []}, fn
      {:ok, {specs, dirty, sr_ids, bound}}, {s_acc, d_acc, sr_acc, b_acc} ->
        {specs ++ s_acc, dirty ++ d_acc, sr_ids ++ sr_acc, bound ++ b_acc}

      {:exit, _}, acc ->
        acc
    end)
  end

  defp stamp_listener_chunk(plan_ref, jobs, prepared, stamp_opts) do
    Enum.reduce(jobs, {[], [], [], []}, fn job, {specs_acc, dirty_acc, sr_acc, bound_acc} ->
      %{id: id, participant: participant, group_key: gk, mix_level: lvl} = job

      case Map.fetch(prepared, gk) do
        {:ok, prep} ->
          case Egress.stamp_listener(plan_ref, id, prep, Keyword.put(stamp_opts, :mix_level, lvl)) do
            {:ok, rtp, next, newly_bound?} ->
              bound_acc =
                if newly_bound?, do: [Map.get(next, :bitrate_cap) | bound_acc], else: bound_acc

              {[{participant, rtp} | specs_acc], [{id, next} | dirty_acc], [id | sr_acc], bound_acc}

            {:error, _} ->
              {specs_acc, dirty_acc, sr_acc, bound_acc}
          end

        :error ->
          {specs_acc, dirty_acc, sr_acc, bound_acc}
      end
    end)
    |> then(fn {specs, dirty, sr_ids, bound} ->
      {Enum.reverse(specs), Enum.reverse(dirty), Enum.reverse(sr_ids), Enum.reverse(bound)}
    end)
  end

  defp silent_egress(plan_ref, dtx_hold) do
    plan_ref
    |> Plan.participant_ids()
    |> MapSet.to_list()
    |> Enum.flat_map(fn id ->
      _ = Egress.mark_silence(plan_ref, id)

      with %Participant{peer_ref: peer} = participant when is_pid(peer) <-
             Plan.get_participant(plan_ref, id),
           true <- Process.alive?(peer),
           %{} = egress <- Runtime.get_mcu_egress(plan_ref, id),
           pt when is_integer(pt) <- Map.get(egress, :cn_payload_type),
           true <- Map.get(egress, :silent_ticks, 0) >= dtx_hold,
           true <- Map.get(egress, :cn_sent?, false) != true,
           {:ok, rtp} <- Egress.packetize_cn(plan_ref, id) do
        [{participant, rtp}]
      else
        _ -> []
      end
    end)
  end
end
