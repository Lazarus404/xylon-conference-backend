defmodule Xylon.Conference.Backend do
  @moduledoc """
  Xylon media backend: room SFU for audio and video.

  ## What problem this solves

  [Xylon](https://github.com/Lazarus404/xylon) sessions need a backend module that
  decides what to do with decrypted RTP after [XGW](https://github.com/Lazarus404/xgw)
  terminates DTLS-SRTP. This backend implements a conference Selective Forwarding
  Unit: each participant sends audio/video once; the server forwards selected streams
  to other participants with per-subscriber RTP header rewrite.

  Identical-layer routes (no temporal/spatial caps and not VP9/AV1 SVC mode) use a
  thin fanout path: header rewrite, NACK store, and send. SIM layer lists alone do
  not force the full path; capped or true-SVC routes keep SVC/DD filtering. Full-path
  fanout parses Dependency Descriptor structure once per inbound packet (publisher
  + mid) and threads the descriptor through the subscriber loop; ADT rewrite stays
  per route and does not write cap-masked structure back to the shared cache.
  Inbound route lists are cached in `Plan` until the subscribe graph changes.

  Catalogue id: `:conference`. Attach via `Xylon.Conference.attach/0` or
  `config :xylon, :backends`. After the client's offer is applied,
  `media_ready/4` publishes SSRCs from the offer SDP. With `subscribe_mode: :mesh`
  (default), every participant is subscribed to every other participant automatically.
  When a trunk participant is present, mesh also uses `dest_type: :trunk` and
  announces exportable local tracks to cohost hubs (MCU: video only; SFU/spoke: A/V)
  so far-edge listeners can SFU-fanout without a manual `announce_local_change`.
  Optional `require_publish_cap` (default false) asks Control `:authorize` before
  publishing tracks so spectators can join/subscribe without a `"publish"`
  capability. With `subscribe_mode: :manual`, apps drive who receives whom.

  Optional `adaptive_layers` (default false) runs receive-side REMB layer picks
  via `Allocator` for SIM/SVC; app configure with layer opts stays sticky.
  Soft spots: none for receive-side adaptive TWCC/REMB. Uplink Dynacast is
  opt-in via room `dynacast: true` (SIM only; SDK `encodings.active`).

  Optional `audiolevel_events` reads RFC 6464 audio levels and emits Control
  `talking` / `stopped-talking` presence events. Active publishers are listed in
  `Xylon.Control.Feeds` when Control is enabled.

  Session and Forwarder each call `init/2` and hold a separate `backend_state`
  map (room opts + `plan_ref`). Cross-process media fields (ext ids, TWCC
  arrivals, talking detectors, REMB rates, FIR clocks) live in
  `Xylon.Conference.Runtime` ETS, shared via the same `plan_ref` as Plan.

  MCU strategies: `audio: :mcu` with `video: :sfu` is accepted for the MCU
  audio mix (Opus / PCMU / PCMA / G.722, mix-minus-self, shared encode,
  PCM PLC on short gaps, energy/RFC 6464 level gate). Mix sum uses a dirty-CPU
  NIF by default (`mcu_nif` / Application `:mcu_accel`) with Elixir fallback.
  Cascade hub-mix uses `mcu_cascade: :hub` (mix once) with spokes
  `mcu_cascade: :spoke` and `audio: :sfu` (SFU of hub mix) or `audio: :mcu`
  (spoke mix-of-mixes). `video: :mcu` and other unsupported
  combos are rejected at init.

  ## RFCs

  - [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) (RTP and RTCP)
  - [RFC 6464](https://www.rfc-editor.org/rfc/rfc6464) (audio level header extension)
  - [RFC 3264](https://www.rfc-editor.org/rfc/rfc3264) (SDP offer/answer; via [XSDP](https://github.com/Lazarus404/xsdp))
  - [RFC 8829](https://www.rfc-editor.org/rfc/rfc8829) (JSEP signaling through Xylon)
  - [RFC 8445](https://www.rfc-editor.org/rfc/rfc8445) (ICE; via XGW)
  - [RFC 3711](https://www.rfc-editor.org/rfc/rfc3711) (SRTP on the wire; RTP rewrite runs on plaintext after decrypt)
  - [RFC 4585](https://www.rfc-editor.org/rfc/rfc4585) (PLI / NACK RTCP feedback)
  - [draft-alvestrand-rmcat-remb](https://datatracker.ietf.org/doc/html/draft-alvestrand-rmcat-remb) (REMB)
  - [draft-holmer-rmcat-transport-wide-cc-extensions](https://datatracker.ietf.org/doc/html/draft-holmer-rmcat-transport-wide-cc-extensions) (TWCC)
  """

  @behaviour Xylon.Backend

  alias Xylon.Conference.{
    AudioLevel,
    NackCache,
    OfferTracks,
    Plan,
    Rewrite,
    Rtcp,
    Runtime,
    SessionHooks,
    Twcc,
    Av1Svc,
    Vp8Temporal,
    Vp9Svc
  }

  alias Xylon.Conference.Mcu
  alias Xylon.Conference.Mcu.{Cascade, CodecBind, Contributor, Egress, Quota}

  alias Xylon.Control.Presence
  alias Xylon.Forwarder
  alias Xylon.Participant
  alias XMediaLib.Rtp
  alias XMediaLib.Rtp.DependencyDescriptor
  alias XMediaLib.Rtp.HeaderExtension
  alias XMediaLib.Rtp.DependencyDescriptor

  @doc """
  Catalogue id for `Xylon.attach/1` and `Xylon.Session.create/3`.

  Always returns `:conference`.
  """
  @spec id() :: :conference
  def id, do: :conference

  @impl true
  def init(session, opts) do
    audio = Keyword.get(opts, :audio, :sfu)
    video = Keyword.get(opts, :video, :sfu)
    application = Keyword.get(opts, :application, :none)

    with :ok <- validate_strategy(:audio, audio),
         :ok <- validate_strategy(:video, video),
         :ok <- validate_application(application),
         {:ok, subscribe_mode} <-
           validate_subscribe_mode(Keyword.get(opts, :subscribe_mode, :mesh)),
         {:ok, max_publishers} <- validate_max_publishers(Keyword.get(opts, :max_publishers)),
         {:ok, audiolevel_events} <-
           validate_audiolevel_events(Keyword.get(opts, :audiolevel_events, false)),
         {:ok, audio_active_packets} <-
           validate_audio_active_packets(Keyword.get(opts, :audio_active_packets, 100)),
         {:ok, audio_level_average} <-
           validate_audio_level_average(Keyword.get(opts, :audio_level_average, 25)),
         {:ok, bitrate_cap} <- validate_bitrate_cap(Keyword.get(opts, :bitrate_cap)),
         {:ok, adaptive_layers} <-
           validate_adaptive_layers(Keyword.get(opts, :adaptive_layers, false)),
         {:ok, dynacast} <- validate_dynacast(Keyword.get(opts, :dynacast, false)),
         {:ok, twcc_period_ms} <-
           validate_twcc_period_ms(Keyword.get(opts, :twcc_period_ms, 100)),
         {:ok, fir_interval_ms} <-
           validate_fir_interval_ms(Keyword.get(opts, :fir_interval_ms, 0)),
         {:ok, require_publish_cap} <-
           validate_require_publish_cap(Keyword.get(opts, :require_publish_cap, false)),
         {:ok, mcu_top_n} <- validate_mcu_top_n(Keyword.get(opts, :mcu_top_n)),
         {:ok, mcu_level_hysteresis} <-
           validate_mcu_level_hysteresis(Keyword.get(opts, :mcu_level_hysteresis, 10)),
         {:ok, mcu_plc_max} <- validate_mcu_plc_max(Keyword.get(opts, :mcu_plc_max, 5)),
         {:ok, mcu_jb_target} <- validate_mcu_jb_target(Keyword.get(opts, :mcu_jb_target, 2)),
         {:ok, mcu_drift_max_pad} <-
           validate_mcu_drift_max_pad(Keyword.get(opts, :mcu_drift_max_pad, 960)),
         {:ok, mcu_dtx_hold_ticks} <-
           validate_mcu_dtx_hold_ticks(Keyword.get(opts, :mcu_dtx_hold_ticks, 3)),
         {:ok, mcu_sr_interval_ms} <-
           validate_mcu_sr_interval_ms(Keyword.get(opts, :mcu_sr_interval_ms, 1000)),
         {:ok, mcu_opus_bitrate_bps} <-
           validate_mcu_opus_bitrate_bps(Keyword.get(opts, :mcu_opus_bitrate_bps, 32_000)),
         {:ok, mcu_max_participants} <-
           validate_mcu_max_cap(Keyword.get(opts, :mcu_max_participants), :mcu_max_participants),
         {:ok, mcu_max_contributors} <-
           validate_mcu_max_cap(Keyword.get(opts, :mcu_max_contributors), :mcu_max_contributors),
         {:ok, mcu_cascade} <- validate_mcu_cascade(Keyword.get(opts, :mcu_cascade), audio),
         {:ok, mcu_mix_mid} <- validate_mcu_mix_mid(Keyword.get(opts, :mcu_mix_mid, "0")),
         {:ok, mcu_nif} <- validate_mcu_nif(Keyword.get(opts, :mcu_nif)),
         {:ok, mcu_spoke_mix_minus} <-
           validate_mcu_spoke_mix_minus(Keyword.get(opts, :mcu_spoke_mix_minus, false)),
         {:ok, mcu_cascade_trunk_profile} <-
           validate_mcu_cascade_trunk_profile(
             Keyword.get(opts, :mcu_cascade_trunk_profile, :opus)
           ) do
      plan_ref = Plan.new(session_pid(session, opts))
      authorize = Keyword.get(opts, :authorize, fn _action, _meta -> true end)
      Runtime.ensure_table!()
      _ = Runtime.put_dynacast(plan_ref, dynacast)

      with :ok <-
             maybe_register_mcu_mixer(
               audio,
               mcu_cascade,
               mcu_cascade_trunk_profile,
               plan_ref,
               session
             ) do
        {:ok,
         %{
           plan_ref: plan_ref,
           session_id: session.id,
           tenant_id: session.tenant_id,
           audio: audio,
           video: video,
           application: application,
           subscribe_mode: subscribe_mode,
           max_publishers: max_publishers,
           require_publish_cap: require_publish_cap,
           authorize: authorize,
           audiolevel_events: audiolevel_events,
           audio_active_packets: audio_active_packets,
           audio_level_average: audio_level_average,
           bitrate_cap: bitrate_cap,
           adaptive_layers: adaptive_layers,
           dynacast: dynacast,
           twcc_period_ms: twcc_period_ms,
           fir_interval_ms: fir_interval_ms,
           mcu_top_n: mcu_top_n,
           mcu_level_hysteresis: mcu_level_hysteresis,
           mcu_plc_max: mcu_plc_max,
           mcu_jb_target: mcu_jb_target,
           mcu_drift_max_pad: mcu_drift_max_pad,
           mcu_dtx_hold_ticks: mcu_dtx_hold_ticks,
           mcu_sr_interval_ms: mcu_sr_interval_ms,
           mcu_opus_bitrate_bps: mcu_opus_bitrate_bps,
           mcu_max_participants: mcu_max_participants,
           mcu_max_contributors: mcu_max_contributors,
           mcu_cascade: mcu_cascade,
           mcu_mix_mid: mcu_mix_mid,
           mcu_nif: mcu_nif,
           mcu_spoke_mix_minus: mcu_spoke_mix_minus,
           mcu_cascade_trunk_profile: mcu_cascade_trunk_profile
         }}
      end
    end
  end

  @impl true
  def participant_joined(%Participant{} = participant, state) do
    with :ok <- maybe_admit_mcu_participant(state) do
      Plan.put_participant(state.plan_ref, participant)
      _ = maybe_hub_trunk_egress(participant, state)
      _ = maybe_pcm_sfu_local_egress(participant, state)
      {:ok, state}
    end
  end

  @impl true
  def participant_left(%Participant{} = participant, state) do
    maybe_feeds_delete(state, participant.id)
    _ = Contributor.clear(state.plan_ref, participant.id)
    _ = Egress.clear(state.plan_ref, participant.id)

    if state.audio == :mcu do
      _ = Quota.release_contributor(state.plan_ref, participant.id)
      _ = Quota.release_participant(state.plan_ref)
    end

    Plan.delete_participant(state.plan_ref, participant.id)
    Runtime.clear_participant(state.plan_ref, participant.id)
    {:ok, state}
  end

  @doc """
  Builds the Forwarder plan row for this participant (SFU mode).
  """
  @impl true
  @spec forward_plan(Participant.t(), map()) :: {:ok, map(), map()}
  def forward_plan(%Participant{} = participant, state) do
    {:ok, %{mode: :sfu, participant: participant}, state}
  end

  @doc """
  Publishes tracks from the offer; mesh-subscribes when `subscribe_mode` is `:mesh`.
  """
  @impl true
  def media_ready(%Participant{id: self_id} = participant, offer_sdp, ctx, state)
      when is_binary(offer_sdp) and is_map(ctx) do
    plan_ref = state.plan_ref
    fwd = Map.get(ctx, :forwarder)
    tracks = OfferTracks.from_sdp(offer_sdp)

    with :ok <- check_publish_cap(participant, tracks, state),
         :ok <- check_max_publishers(plan_ref, self_id, tracks, state.max_publishers),
         {:ok, state} <- maybe_mcu_media_ready(participant, offer_sdp, ctx, state) do
      Enum.each(tracks, fn track ->
        _ = SessionHooks.publish(plan_ref, self_id, track)
      end)

      mesh_tracks = mesh_tracks_for(state, tracks)

      if state.subscribe_mode == :mesh do
        mesh_subscribe(plan_ref, self_id, mesh_tracks, fwd, state.audio)
        _ = maybe_announce_mesh_exports(plan_ref, self_id, mesh_tracks, state)
      end

      _ = SessionHooks.refresh_publisher_plan(plan_ref, self_id, forwarder: fwd)

      if is_pid(fwd) and is_pid(participant.peer_ref) do
        _ = Forwarder.put_plan(fwd, participant.peer_ref, %{mode: :sfu, participant: participant})
      end

      state =
        case audio_level_ext_id(offer_sdp) do
          nil ->
            state

          id ->
            _ = Runtime.put_ext(state.plan_ref, self_id, %{audio_level: id})
            state
        end

      state =
        case twcc_ext_id(offer_sdp) do
          nil ->
            state

          id ->
            _ = Runtime.put_ext(state.plan_ref, self_id, %{twcc: id})
            state
        end

      state =
        case dependency_descriptor_ext_id(offer_sdp) do
          nil ->
            state

          id ->
            _ = Runtime.put_ext(state.plan_ref, self_id, %{dependency_descriptor: id})
            state
        end

      state =
        case rid_ext_id(offer_sdp) do
          nil ->
            state

          id ->
            _ = Runtime.put_ext(state.plan_ref, self_id, %{rid: id})
            state
        end

      _ = maybe_feeds_put(state, self_id, tracks)

      {:ok, state}
    end
  end

  @impl true
  def handle_rtp(%Participant{} = participant, rtp, state) do
    in_ssrc = Rewrite.rtp_ssrc(rtp)
    # Trunk remotes share one Pipe peer_ref; Forwarder plan is last-writer-wins.
    # Resolve the true publisher by inbound SSRC so mix + SFU video coexist.
    # Capture trunk id before resolve (role: :trunk) or via shared Pipe peer_ref.
    trunk_id_before = if participant.role == :trunk, do: participant.id, else: nil
    participant = resolve_shared_trunk_publisher(participant, in_ssrc, state)
    # Chrome RID SIM: learn layer SSRCs from rtp-stream-id; else bind unbound.
    _ = maybe_learn_rid_or_bind(participant, rtp, in_ssrc, state)
    state = maybe_sample_audio_level(participant, rtp, in_ssrc, state)
    state = maybe_record_twcc(participant, rtp, state)
    state = maybe_periodic_keyframe(participant, in_ssrc, state)
    _ = maybe_recording_publisher(state, participant, in_ssrc, rtp)

    if mcu_audio_path?(state, participant, in_ssrc) do
      _ = maybe_hub_remote_contrib(participant, state)
      _ = maybe_spoke_mix_contrib(participant, state)

      trunk_id =
        trunk_id_before || trunk_id_for_peer(state.plan_ref, participant.peer_ref)

      if trunk_id != nil and Map.get(participant.meta || %{}, :remote, false) and
           Map.get(state, :mcu_cascade) == :hub do
        _ = Runtime.put_mcu_trunk_attrib(state.plan_ref, participant.id, trunk_id)
      end

      level = current_audio_level(state.plan_ref, participant.id)

      _ =
        Contributor.push(state.plan_ref, participant.id, rtp,
          level: level,
          plc_max: state.mcu_plc_max,
          jb_target: state.mcu_jb_target,
          drift_max_pad: state.mcu_drift_max_pad
        )

      state = maybe_flush_twcc(participant, state)

      mcu_result =
        case Mcu.tick(state.plan_ref,
               threshold: state.audio_level_average,
               hysteresis: state.mcu_level_hysteresis,
               top_n: state.mcu_top_n,
               dtx_hold_ticks: state.mcu_dtx_hold_ticks,
               mcu_nif: state.mcu_nif,
               mcu_spoke_mix_minus: Map.get(state, :mcu_spoke_mix_minus, false)
             ) do
          {:ok, specs, mix_rtp} -> {specs, mix_rtp}
          {:error, _} -> {[], nil}
        end

      {specs_mcu, mix_rtp} = mcu_result

      trunk_specs =
        if state.audio == :mcu do
          spoke_trunk_forward_specs(participant, rtp, state)
        else
          []
        end

      specs = specs_mcu ++ trunk_specs
      _ = maybe_recording_mix(state, mix_rtp)

      case specs do
        [] -> {:ok, state}
        list -> {:forward, list, state}
      end
    else
      case Plan.routes_for_inbound(state.plan_ref, participant.id, in_ssrc) do
        [] ->
          {:ok, maybe_flush_twcc(participant, state)}

        routes ->
          specs = fanout_routes(state.plan_ref, rtp, routes)
          {:forward, specs, maybe_flush_twcc(participant, state)}
      end
    end
  end

  defp maybe_recording_publisher(state, %Participant{} = participant, in_ssrc, rtp) do
    if Code.ensure_loaded?(Xylon.Recording.Registry) do
      meta =
        case recording_track_meta(state.plan_ref, participant.id, in_ssrc) do
          {:ok, track_meta} ->
            Map.merge(
              %{
                publisher_id: participant.id,
                ssrc: in_ssrc,
                edge_node: Node.self()
              },
              track_meta
            )

          :unknown ->
            %{
              publisher_id: participant.id,
              ssrc: in_ssrc,
              kind: :unknown,
              edge_node: Node.self()
            }
        end

      meta =
        if Map.get(participant.meta || %{}, :remote, false) do
          Map.put(meta, :via, "trunk")
        else
          meta
        end

      Xylon.Recording.Registry.maybe_publisher_rtp(state.plan_ref, meta, rtp)
    else
      :ok
    end
  end

  defp recording_track_meta(plan_ref, publisher_id, in_ssrc) do
    tracks = Plan.tracks_for(plan_ref, publisher_id)

    case Enum.find(tracks, fn track -> track_matches_ssrc?(track, in_ssrc) end) do
      %{mid: mid, kind: kind} = track when kind in [:audio, :video] and is_binary(mid) ->
        meta = %{mid: mid, kind: kind}

        meta =
          case Map.get(track, :codec) do
            codec when is_binary(codec) and codec != "" -> Map.put(meta, :codec, codec)
            _ -> meta
          end

        meta =
          case Map.get(track, :layers) do
            layers when is_list(layers) and layers != [] ->
              meta = Map.put(meta, :layers, layers)

              case Enum.find(layers, fn
                     %{ssrc: ^in_ssrc} -> true
                     _ -> false
                   end) do
                %{substream: sub} = layer when is_integer(sub) ->
                  meta = Map.put(meta, :substream, sub)

                  case Map.get(layer, :rid) do
                    rid when is_binary(rid) and rid != "" -> Map.put(meta, :rid, rid)
                    _ -> meta
                  end

                _ ->
                  meta
              end

            _ ->
              meta
          end

        {:ok, meta}

      _ ->
        :unknown
    end
  end

  defp track_matches_ssrc?(%{ssrc: ssrc}, in_ssrc) when ssrc == in_ssrc, do: true

  defp track_matches_ssrc?(%{layers: layers}, in_ssrc) when is_list(layers) do
    Enum.any?(layers, fn
      %{ssrc: ^in_ssrc} -> true
      _ -> false
    end)
  end

  defp track_matches_ssrc?(_, _), do: false

  defp maybe_recording_mix(_state, nil), do: :ok

  defp maybe_recording_mix(state, %Rtp{} = mix_rtp) do
    mid = Map.get(state, :mcu_mix_mid, "0")
    ssrc = Rewrite.rtp_ssrc(mix_rtp)

    codec =
      case Runtime.get_mcu_egress(state.plan_ref, "__mcu_mix__") do
        %{codec_desc: %{name: name}} when is_binary(name) or is_atom(name) ->
          name |> to_string() |> String.downcase()

        _ ->
          "opus"
      end

    if Code.ensure_loaded?(Xylon.Recording.Registry) do
      meta = %{
        publisher_id: "__mcu_mix__",
        mid: mid,
        kind: :audio,
        ssrc: ssrc,
        codec: codec,
        edge_node: Node.self()
      }

      Xylon.Recording.Registry.maybe_mix_rtp(state.plan_ref, meta, mix_rtp)
    end

    # Layout recording prefers MCU mix audio over first-publisher audio.
    if Map.get(state, :layout_recording) == true and
         Code.ensure_loaded?(Xylon.Recording.LayoutSink) do
      dest = %{
        type: :record,
        plan_ref: state.plan_ref,
        publisher_id: "__mcu_mix__",
        mid: mid,
        kind: :audio,
        codec: codec
      }

      _ = Xylon.Recording.LayoutSink.ingest(dest, mix_rtp)
    end

    :ok
  end

  defp maybe_recording_mix(_state, _), do: :ok

  defp maybe_spoke_mix_contrib(%Participant{id: id} = participant, %{mcu_cascade: :spoke} = state) do
    if Cascade.mix_publisher?(id) or Map.get(participant.meta || %{}, :mcu_mix, false) do
      _ = Cascade.ensure_remote_contributor(state.plan_ref, id, state)
    end

    :ok
  end

  defp maybe_spoke_mix_contrib(_, _), do: :ok

  defp spoke_trunk_forward_specs(%Participant{} = participant, rtp, %{mcu_cascade: :spoke} = state) do
    if Cascade.mix_publisher?(participant.id) or
         Map.get(participant.meta || %{}, :mcu_mix, false) or
         Map.get(participant.meta || %{}, :remote, false) do
      []
    else
      in_ssrc = Rewrite.rtp_ssrc(rtp)

      state.plan_ref
      |> Plan.routes_for_inbound(participant.id, in_ssrc)
      |> Enum.filter(fn route -> match?(%{type: :trunk}, route.destination) end)
      |> then(&fanout_routes(state.plan_ref, rtp, &1))
    end
  end

  defp spoke_trunk_forward_specs(_, _, _), do: []

  defp fanout_routes(_plan_ref, _rtp, []), do: []

  defp fanout_routes(plan_ref, rtp, routes) do
    {full, thin} = Enum.split_with(routes, &needs_layer_filter?/1)
    prep = fanout_prep(plan_ref, rtp, hd_publisher(full ++ thin), full)

    {specs, dirty} =
      Enum.reduce(thin, {[], %{}}, fn route, {acc, dirty_acc} ->
        {leg, dirty} = forward_route_spec_thin(plan_ref, rtp, route)
        {acc ++ leg, Map.merge(dirty_acc, dirty)}
      end)

    {specs, dirty} =
      Enum.reduce(full, {specs, dirty}, fn route, {acc, dirty_acc} ->
        {leg, dirty} = forward_route_spec_full(plan_ref, rtp, route, prep)
        {acc ++ leg, Map.merge(dirty_acc, dirty)}
      end)

    _ = Plan.put_rewrites(plan_ref, Map.to_list(dirty))
    specs
  end

  defp hd_publisher([%{publisher_id: id} | _]), do: id
  defp hd_publisher([]), do: nil

  defp fanout_prep(_plan_ref, _rtp, _publisher_id, []), do: %{}

  defp fanout_prep(plan_ref, rtp, publisher_id, [%{mid: mid} | _] = _full_routes) do
    dd_ext_id =
      case Runtime.get_ext(plan_ref, publisher_id) do
        %{dependency_descriptor: id} when is_integer(id) and id > 0 -> id
        _ -> nil
      end

    structure0 = Plan.get_dd_structure(plan_ref, publisher_id, mid)

    {structure, descriptor} =
      if is_integer(dd_ext_id) and dd_ext_id > 0 do
        case DependencyDescriptor.read_descriptor(rtp, dd_ext_id, structure0) do
          {:ok, desc, struct2} when is_map(struct2) ->
            _ = Plan.put_dd_structure(plan_ref, publisher_id, mid, struct2)
            {struct2, desc}

          {:ok, desc, _} ->
            {structure0, desc}

          {:ok, desc} ->
            {structure0, desc}

          _ ->
            {structure0, nil}
        end
      else
        {structure0, nil}
      end

    %{dd_ext_id: dd_ext_id, structure: structure, descriptor: descriptor, mid: mid}
  end

  defp needs_layer_filter?(route) do
    codec = Map.get(route, :codec)
    layers = Map.get(route, :layers)

    not is_nil(Map.get(route, :max_temporal)) or
      not is_nil(Map.get(route, :max_spatial)) or
      not is_nil(Map.get(route, :max_temporal_layer)) or
      Av1Svc.svc_mode?(codec, layers) or
      Vp9Svc.svc_mode?(codec, layers)
  end

  defp forward_route_spec_thin(plan_ref, rtp, route) do
    {packet, new_rewrite} = Rewrite.apply(rtp, route.rewrite)
    {packet, out_ssrc} = maybe_stamp_sfu_twcc(plan_ref, route, packet, new_rewrite)

    case Rewrite.rtp_seq(packet) do
      seq when is_integer(seq) and is_integer(out_ssrc) ->
        _ = NackCache.store(plan_ref, out_ssrc, seq, packet)

      _ ->
        :ok
    end

    {[{send_dest(plan_ref, route), packet}], %{route.rewrite_key => new_rewrite}}
  end

  defp forward_route_spec_full(plan_ref, rtp, route, prep) do
    dd_ext_id =
      Map.get(prep, :dd_ext_id) ||
        case Runtime.get_ext(plan_ref, route.publisher_id) do
          %{dependency_descriptor: id} when is_integer(id) and id > 0 -> id
          _ -> nil
        end

    structure = Map.get(prep, :structure)
    descriptor = Map.get(prep, :descriptor)

    chain =
      Plan.get_dd_chain(plan_ref, route.publisher_id, route.mid, route.subscriber_id)

    drop? =
      Vp8Temporal.drop?(rtp, Map.get(route, :max_temporal), Map.get(route, :codec)) or
        Vp9Svc.drop?(rtp, Map.get(route, :max_spatial), Map.get(route, :max_temporal_layer),
          codec: Map.get(route, :codec),
          layers: Map.get(route, :layers),
          dd_ext_id: dd_ext_id,
          structure: structure,
          descriptor: descriptor
        ) or
        Av1Svc.drop?(rtp, Map.get(route, :max_spatial), Map.get(route, :max_temporal_layer),
          codec: Map.get(route, :codec),
          layers: Map.get(route, :layers),
          dd_ext_id: dd_ext_id,
          chain: chain,
          structure: structure,
          descriptor: descriptor
        )

    chain2 =
      Av1Svc.after_decision(chain, rtp, dd_ext_id,
        dropped?: drop?,
        max_spatial: Map.get(route, :max_spatial),
        max_temporal: Map.get(route, :max_temporal_layer),
        structure: structure,
        descriptor: descriptor
      )

    {pli?, chain3} = Av1Svc.take_pli?(chain2)
    _ = Plan.put_dd_chain(plan_ref, route.publisher_id, route.mid, route.subscriber_id, chain3)

    if pli? do
      _ =
        Rtcp.request_keyframe(plan_ref, route.publisher_id,
          subscriber_id: route.subscriber_id
        )
    end

    if drop? do
      new_rewrite = Rewrite.note_inbound(rtp, route.rewrite)
      {[], %{route.rewrite_key => new_rewrite}}
    else
      {rtp2, _struct_local} =
        Av1Svc.rewrite_dd(
          rtp,
          Map.get(route, :max_spatial),
          Map.get(route, :max_temporal_layer),
          dd_ext_id,
          structure: structure
        )

      {packet, new_rewrite} = Rewrite.apply(rtp2, route.rewrite)
      packet = restore_dd_extension(packet, rtp2, dd_ext_id)
      {packet, out_ssrc} = maybe_stamp_sfu_twcc(plan_ref, route, packet, new_rewrite)

      case Rewrite.rtp_seq(packet) do
        seq when is_integer(seq) ->
          _ = NackCache.store(plan_ref, out_ssrc, seq, packet)

        _ ->
          :ok
      end

      {[{send_dest(plan_ref, route), packet}], %{route.rewrite_key => new_rewrite}}
    end
  end

  defp send_dest(plan_ref, %{destination: %{type: :record}} = route) do
    %{
      type: :record,
      plan_ref: plan_ref,
      publisher_id: route.publisher_id,
      mid: route.mid,
      kind: route.kind,
      codec: Map.get(route, :codec)
    }
  end

  defp send_dest(_plan_ref, route), do: route.destination.participant

  defp maybe_hub_remote_contrib(%Participant{meta: meta} = participant, %{mcu_cascade: :hub} = state) do
    if Map.get(meta || %{}, :remote, false) do
      _ = Cascade.ensure_remote_contributor(state.plan_ref, participant.id, state)
    end

    :ok
  end

  defp maybe_hub_remote_contrib(_, _), do: :ok

  defp resolve_shared_trunk_publisher(%Participant{} = participant, in_ssrc, state)
       when is_integer(in_ssrc) do
    meta = participant.meta || %{}

    if Map.get(meta, :remote, false) or participant.role == :trunk do
      case Plan.publisher_for_in_ssrc(state.plan_ref, in_ssrc) do
        {:ok, publisher_id, _mid} when publisher_id != participant.id ->
          case Plan.get_participant(state.plan_ref, publisher_id) do
            %Participant{} = found -> found
            _ -> participant
          end

        _ ->
          participant
      end
    else
      participant
    end
  end

  defp resolve_shared_trunk_publisher(participant, _in_ssrc, _state), do: participant

  defp maybe_bind_unbound_ssrc(_participant, nil, _state), do: :ok

  defp maybe_bind_unbound_ssrc(%Participant{id: publisher_id}, in_ssrc, state)
       when is_integer(in_ssrc) and in_ssrc > 0 do
    plan_ref = state.plan_ref

    case Plan.publisher_for_in_ssrc(plan_ref, in_ssrc) do
      {:ok, _, _} ->
        :ok

      :error ->
        case Plan.find_unbound_track(plan_ref, publisher_id) do
          %{mid: mid} -> Plan.bind_track_ssrc(plan_ref, publisher_id, mid, in_ssrc)
          nil -> :ok
        end
    end
  end

  defp maybe_bind_unbound_ssrc(_, _, _), do: :ok

  defp maybe_learn_rid_or_bind(participant, rtp, in_ssrc, state) do
    case maybe_learn_rid_layer(participant, rtp, in_ssrc, state) do
      :ok -> :ok
      :skip -> maybe_bind_unbound_ssrc(participant, in_ssrc, state)
    end
  end

  defp maybe_learn_rid_layer(_participant, _rtp, nil, _state), do: :skip

  defp maybe_learn_rid_layer(%Participant{id: publisher_id}, rtp, in_ssrc, state)
       when is_integer(in_ssrc) and in_ssrc > 0 do
    rid_ext =
      case Runtime.get_ext(state.plan_ref, publisher_id) do
        %{rid: id} when is_integer(id) and id > 0 -> id
        _ -> nil
      end

    with true <- is_integer(rid_ext),
         {:ok, rid} <- read_rtp_stream_id(rtp, rid_ext),
         track when not is_nil(track) <- find_track_for_rid_learn(state.plan_ref, publisher_id, rid) do
      case Plan.learn_layer_ssrc(state.plan_ref, publisher_id, track.mid, rid, in_ssrc) do
        :ok -> :ok
        {:error, _} -> :skip
      end
    else
      _ -> :skip
    end
  end

  defp maybe_learn_rid_layer(_, _, _, _), do: :skip

  defp find_track_for_rid_learn(plan_ref, publisher_id, rid) do
    Enum.find(Plan.tracks_for(plan_ref, publisher_id), fn track ->
      layers = Map.get(track, :layers, [])
      Enum.any?(layers, &match?(%{rid: ^rid}, &1))
    end)
  end

  defp read_rtp_stream_id(%Rtp{extension: %{type: type, payload: payload}}, ext_id)
       when is_binary(payload) do
    type
    |> HeaderExtension.decode_elements(payload)
    |> HeaderExtension.rtp_stream_id(ext_id)
  end

  defp read_rtp_stream_id(_, _), do: :error

  defp trunk_id_for_peer(plan_ref, peer_ref) when is_pid(peer_ref) do
    Enum.find_value(Plan.participant_ids(plan_ref), fn id ->
      case Plan.get_participant(plan_ref, id) do
        %Participant{role: :trunk, peer_ref: ^peer_ref, id: tid} -> tid
        _ -> nil
      end
    end)
  end

  defp trunk_id_for_peer(_, _), do: nil

  defp maybe_hub_trunk_egress(%Participant{role: :trunk, id: trunk_id}, %{mcu_cascade: :hub} = state) do
    Cascade.ensure_trunk_egress(state.plan_ref, trunk_id, state)
  end

  defp maybe_hub_trunk_egress(_, _), do: :ok

  defp maybe_pcm_sfu_local_egress(%Participant{role: :trunk}, _), do: :ok

  defp maybe_pcm_sfu_local_egress(%Participant{id: id, meta: meta}, state) do
    remote? = is_map(meta) and Map.get(meta, :remote, false) == true
    mix_id = Cascade.mix_publisher_id()

    if not remote? and Cascade.pcm_sfu_edge?(state) and
         match?(%Participant{}, Plan.get_participant(state.plan_ref, mix_id)) do
      Egress.ensure(state.plan_ref, id, Cascade.opus_desc())
    else
      :ok
    end
  end

  defp maybe_periodic_keyframe(_participant, _in_ssrc, %{fir_interval_ms: 0} = state), do: state

  defp maybe_periodic_keyframe(participant, in_ssrc, state) do
    with %{ssrc: track_ssrc} when is_integer(track_ssrc) <-
           Plan.find_track_by_kind(state.plan_ref, participant.id, :video),
         true <- video_ssrc_match?(state.plan_ref, participant.id, in_ssrc, track_ssrc),
         subs <- video_subscribers(state.plan_ref, participant.id),
         true <- MapSet.size(subs) > 0 do
      now = System.monotonic_time(:millisecond)
      last = Runtime.get_last_fir(state.plan_ref, participant.id)
      due? = is_nil(last) or now - last >= state.fir_interval_ms

      if due? do
        _ = Rtcp.request_keyframe(state.plan_ref, participant.id)
        _ = Runtime.put_last_fir(state.plan_ref, participant.id, now)
        state
      else
        state
      end
    else
      _ -> state
    end
  end

  defp video_ssrc_match?(_plan_ref, _publisher_id, in_ssrc, track_ssrc) when in_ssrc == track_ssrc,
    do: true

  defp video_ssrc_match?(plan_ref, publisher_id, in_ssrc, _track_ssrc) do
    # Accept any published video layer SSRC so simulcast still triggers periodic PLI.
    plan_ref
    |> Plan.tracks_for(publisher_id)
    |> Enum.filter(&(&1.kind == :video))
    |> Enum.any?(fn
      %{layers: layers} when is_list(layers) ->
        Enum.any?(layers, fn
          %{ssrc: ^in_ssrc} -> true
          _ -> false
        end)

      _ ->
        false
    end)
  end

  defp video_subscribers(plan_ref, publisher_id) do
    plan_ref
    |> Plan.tracks_for(publisher_id)
    |> Enum.filter(&(&1.kind == :video))
    |> Enum.reduce(MapSet.new(), fn track, acc ->
      MapSet.union(acc, Plan.subscribers(plan_ref, publisher_id, track.mid))
    end)
  end

  defp maybe_record_twcc(participant, rtp, state) do
    with %{twcc: ext_id} when is_integer(ext_id) <- Runtime.get_ext(state.plan_ref, participant.id),
         {:ok, seq} <- Twcc.read_seq(rtp, ext_id) do
      # Prefer Listener/Peer wire stamp (via Forwarder Process.put) so Peer and
      # Forwarder mailbox delay are not reported to Chrome BWE as network delay.
      now_us =
        case Process.get(:xylon_rtp_arrival_us) do
          us when is_integer(us) -> us
          _ -> System.monotonic_time(:microsecond)
        end

      twcc = Runtime.get_twcc(state.plan_ref, participant.id) || empty_twcc()
      arrivals = Twcc.record(%{participant.id => twcc.arrivals}, participant.id, seq, now_us)

      _ =
        Runtime.put_twcc(state.plan_ref, participant.id, %{
          twcc
          | arrivals: Map.get(arrivals, participant.id, [])
        })

      state
    else
      _ -> state
    end
  end

  defp maybe_flush_twcc(participant, state) do
    now = System.monotonic_time(:millisecond)
    twcc = Runtime.get_twcc(state.plan_ref, participant.id)
    last = twcc && twcc.last_ms

    due? = is_nil(last) or now - last >= state.twcc_period_ms

    if due? and is_map(twcc) and twcc.arrivals != [] do
      arrivals_map = %{participant.id => twcc.arrivals}
      fb_counts = %{participant.id => twcc.fb_count}

      {arrivals, fb_counts} =
        Twcc.flush(state.plan_ref, participant.id, arrivals_map, fb_counts)

      _ =
        Runtime.put_twcc(state.plan_ref, participant.id, %{
          arrivals: Map.get(arrivals, participant.id, []),
          last_ms: now,
          fb_count: Map.get(fb_counts, participant.id, twcc.fb_count)
        })

      state
    else
      state
    end
  end

  defp empty_twcc, do: %{arrivals: [], last_ms: nil, fb_count: 0}

  defp maybe_sample_audio_level(participant, rtp, in_ssrc, state) do
    with %{ssrc: ^in_ssrc} <- Plan.find_track_by_kind(state.plan_ref, participant.id, :audio),
         %{audio_level: ext_id} when is_integer(ext_id) <-
           Runtime.get_ext(state.plan_ref, participant.id),
         %Rtp.Extension{type: 0xBEDE, payload: payload} <- rtp.extension,
         elements <- HeaderExtension.decode_one_byte_elements(payload),
         {:ok, %{level: level}} <- HeaderExtension.audio_level(elements, ext_id) do
      det = Runtime.get_audio_level(state.plan_ref, participant.id) || AudioLevel.new()

      opts = [
        audio_active_packets: state.audio_active_packets,
        audio_level_average: state.audio_level_average
      ]

      {det, event} = AudioLevel.sample(det, level, opts)
      _ = Runtime.put_audio_level(state.plan_ref, participant.id, det)

      if state.audiolevel_events do
        case event do
          :noop ->
            state

          edge when edge in [:talking, :stopped_talking] ->
            _ =
              Presence.broadcast_talking(state.tenant_id, state.session_id, %{
                type: edge,
                participant_id: participant.id,
                audio_level_dbov_avg: det.avg
              })

            state
        end
      else
        state
      end
    else
      _ ->
        state
    end
  end

  @impl true
  def handle_rtcp(%Participant{} = participant, rtcp, state) do
    _ = Rtcp.forward_pli_fir(state.plan_ref, participant, rtcp)
    _ = Rtcp.handle_nack(state.plan_ref, participant, rtcp)

    remb_rates =
      Rtcp.handle_remb(state.plan_ref, participant, rtcp, Runtime.get_remb(state.plan_ref),
        bitrate_cap: state.bitrate_cap,
        adaptive_layers: Map.get(state, :adaptive_layers, false)
      )

    _ = Runtime.put_remb(state.plan_ref, remb_rates)

    _ =
      Rtcp.handle_twcc(state.plan_ref, participant, rtcp,
        bitrate_cap: state.bitrate_cap,
        adaptive_layers: Map.get(state, :adaptive_layers, false)
      )

    {:ok, state}
  end

  @impl true
  def handle_datachannel(_participant, _channel_ref, _data, state), do: {:ok, state}

  @doc """
  Attaches the `__layout__` Plan `:record` sink while a layout recording is active.

  Called from Session after `record/start` with `layout: true`.
  """
  @spec attach_layout_recording(keyword(), map()) :: {:ok, map()} | {:error, term()}
  def attach_layout_recording(opts, state) when is_list(opts) do
    opts = Keyword.put_new(opts, :forwarder, nil)

    case SessionHooks.attach_layout(state.plan_ref, opts) do
      :ok -> {:ok, Map.put(state, :layout_recording, true)}
      {:error, _} = err -> err
    end
  end

  @doc "Detaches the layout Plan sink."
  @spec detach_layout_recording(keyword(), map()) :: {:ok, map()}
  def detach_layout_recording(opts, state) when is_list(opts) do
    opts = Keyword.put_new(opts, :forwarder, nil)
    _ = SessionHooks.detach_layout(state.plan_ref, opts)
    {:ok, Map.delete(state, :layout_recording)}
  end

  @impl true
  def subscribe(subscriber_id, publisher_id, mid, opts, state)
      when is_binary(mid) and mid != "" do
    opts = Keyword.put_new(opts, :forwarder, nil)

    case SessionHooks.subscribe(state.plan_ref, subscriber_id, publisher_id, mid, opts) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def subscribe_all(subscriber_id, publisher_id, opts, state) do
    opts = Keyword.put_new(opts, :forwarder, nil)

    case SessionHooks.subscribe_all(state.plan_ref, subscriber_id, publisher_id, opts) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def unsubscribe(subscriber_id, publisher_id, mid, opts, state)
      when is_binary(mid) and mid != "" do
    case SessionHooks.unsubscribe(state.plan_ref, subscriber_id, publisher_id, mid, opts) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stops publishing selected mids without removing the participant from the room.

  Tears down tracks and fanout routes for those mids, updates feeds, and clears
  related detector state. Distinct from `moderate_av/5` (pause only).
  """
  @impl true
  def unpublish(participant_id, mids, opts, state)
      when mids == :all or is_list(mids) do
    opts = Keyword.put_new(opts, :forwarder, nil)
    mids = resolve_unpublish_mids(state.plan_ref, participant_id, mids)

    case SessionHooks.unpublish(state.plan_ref, participant_id, mids, opts) do
      :ok ->
        state = scrub_publisher_media_state(state, participant_id)
        _ = refresh_feeds_after_unpublish(state, participant_id)
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Switches `subscriber_id` to receive `mid` from `to_publisher_id`.

  Looks up the current publisher for `mid` and delegates to `SessionHooks.switch/6`.
  Returns `{:error, :no_route}` when not subscribed, or `{:error, :codec_mismatch}`
  when both tracks have different codecs recorded.
  """
  @impl true
  def switch(subscriber_id, to_publisher_id, mid, opts, state)
      when is_binary(mid) and mid != "" do
    case Plan.subscribed_publisher(state.plan_ref, subscriber_id, mid) do
      {:ok, from_publisher_id} ->
        case SessionHooks.switch(
               state.plan_ref,
               subscriber_id,
               from_publisher_id,
               to_publisher_id,
               mid,
               opts
             ) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, :no_route}
    end
  end

  @doc """
  Pauses or resumes all outbound routes for a publisher (Control A/V mute).

  `action` is `:mute` or `:unmute`. `mids` is a list of SDP mids, or `nil` for all
  published mids on the publisher.
  """
  @impl true
  def moderate_av(publisher_id, action, mids, opts, state)
      when action in [:mute, :unmute] do
    case SessionHooks.moderate_av(state.plan_ref, publisher_id, action, mids, opts) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Changes simulcast / SVC layer opts for a subscription.

  `opts` may include `:substream`, `:rid`, `:temporal`, `:spatial_layer`, and/or
  `:temporal_layer` (see `Plan.set_substream/5`). Temporal-only /
  temporal_layer-only updates need no spatial key.
  """
  @impl true
  def set_substream(subscriber_id, publisher_id, mid, opts, state)
      when is_binary(mid) and mid != "" do
    case SessionHooks.set_substream(
           state.plan_ref,
           subscriber_id,
           publisher_id,
           mid,
           opts
         ) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Replaces all subscribe routes for `subscriber_id` from `streams`.
  """
  @impl true
  def update_subscriptions(subscriber_id, streams, opts, state) when is_list(streams) do
    opts = Keyword.put_new(opts, :forwarder, nil)

    case SessionHooks.update_subscriptions(state.plan_ref, subscriber_id, streams, opts) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_unpublish_mids(plan_ref, participant_id, :all),
    do: Plan.published_mids(plan_ref, participant_id)

  defp resolve_unpublish_mids(_plan_ref, _participant_id, mids), do: mids

  @impl true
  def terminate(_reason, state) do
    if Map.get(state, :audio) == :mcu do
      _ = Quota.unregister_mixer(state.plan_ref)
    end

    Runtime.clear_plan(state.plan_ref)
    Plan.delete(state.plan_ref)
    :ok
  end

  defp mesh_subscribe(plan_ref, self_id, tracks, fwd, audio_mode) do
    others =
      plan_ref
      |> Plan.participant_ids()
      |> MapSet.delete(self_id)
      |> MapSet.to_list()
      |> Enum.reject(fn id ->
        match?(%Participant{role: :record}, Plan.get_participant(plan_ref, id))
      end)

    Enum.each(others, fn other_id ->
      for mid <- mesh_mids_from_publisher(plan_ref, other_id, audio_mode) do
        _ = SessionHooks.subscribe(plan_ref, self_id, other_id, mid, mesh_sub_opts(plan_ref, self_id, fwd))
      end

      for %{mid: mid} <- tracks do
        _ = SessionHooks.subscribe(plan_ref, other_id, self_id, mid, mesh_sub_opts(plan_ref, other_id, fwd))
      end
    end)
  end

  defp mesh_sub_opts(plan_ref, subscriber_id, fwd) do
    opts = [forwarder: fwd]

    case Plan.get_participant(plan_ref, subscriber_id) do
      %Participant{role: :trunk} -> Keyword.put(opts, :dest_type, :trunk)
      _ -> opts
    end
  end

  # Mesh export over trunk: MCU hubs send video only (audio is hub-mix);
  # SFU/spoke edges export published A/V so the far edge can SFU-fanout.
  defp maybe_announce_mesh_exports(_plan_ref, _publisher_id, [], _state), do: :ok

  defp maybe_announce_mesh_exports(plan_ref, publisher_id, tracks, state) do
    export = cascade_export_tracks(tracks, state.audio)
    trunk_ids = trunk_participant_ids(plan_ref)

    if export == [] or trunk_ids == [] do
      :ok
    else
      track_payloads =
        for trunk_id <- trunk_ids,
            %{mid: mid, kind: kind, ssrc: in_ssrc} <- export,
            route <- Plan.routes_for_inbound(plan_ref, publisher_id, in_ssrc),
            route.subscriber_id == trunk_id,
            out_ssrc = route.rewrite.out_ssrc do
          %{publisher_id: publisher_id, mid: mid, ssrc: out_ssrc, kind: kind}
        end

      announce_exports_to_peers(
        {state.tenant_id, state.session_id},
        publisher_id,
        Enum.uniq(track_payloads)
      )
    end
  rescue
    _ -> :ok
  end

  defp cascade_export_tracks(tracks, :mcu), do: Enum.filter(tracks, &(&1.kind == :video))
  defp cascade_export_tracks(tracks, _audio), do: tracks

  defp trunk_participant_ids(plan_ref) do
    plan_ref
    |> Plan.participant_ids()
    |> Enum.filter(fn id ->
      match?(%Participant{role: :trunk}, Plan.get_participant(plan_ref, id))
    end)
  end

  defp announce_exports_to_peers(_key, _publisher_id, []), do: :ok

  defp announce_exports_to_peers(key, publisher_id, track_payloads) do
    peers =
      case Code.ensure_loaded?(Xylon.Cluster.Presence) and
             function_exported?(Xylon.Cluster.Presence, :cohosts, 1) do
        true ->
          Xylon.Cluster.Presence.cohosts(key)
          |> Enum.map(& &1.hub_node)
          |> Enum.reject(&(&1 == Node.self()))

        false ->
          Node.list()
      end

    peers = if peers == [], do: Node.list(), else: peers

    Enum.each(peers, fn peer ->
      _ =
        Xylon.Trunk.Manager.announce_local_change(peer, key, %{
          from_edge: Node.self(),
          participants: [%{id: publisher_id, role: :publisher, labels: []}],
          tracks: track_payloads
        })
    end)

    :ok
  end

  defp mesh_mids_from_publisher(plan_ref, publisher_id, :mcu) do
    plan_ref
    |> Plan.tracks_for(publisher_id)
    |> Enum.filter(&(&1.kind == :video))
    |> Enum.map(& &1.mid)
  end

  defp mesh_mids_from_publisher(plan_ref, publisher_id, _audio) do
    Plan.published_mids(plan_ref, publisher_id)
  end

  defp mesh_tracks_for(%{audio: :mcu}, tracks), do: Enum.filter(tracks, &(&1.kind == :video))
  defp mesh_tracks_for(_state, tracks), do: tracks

  defp maybe_mcu_media_ready(_participant, _offer_sdp, _ctx, %{audio: audio} = state)
       when audio != :mcu,
       do: {:ok, state}

  defp maybe_mcu_media_ready(%Participant{id: self_id}, offer_sdp, ctx, state) do
    opts =
      case Map.get(ctx, :answer_sdp) do
        bin when is_binary(bin) -> [answer: bin]
        _ -> []
      end

    case CodecBind.from_sdp(offer_sdp, opts) do
      {:ok, binds} ->
        with :ok <- admit_mcu_contributor(state, self_id, binds) do
          by_mid = Map.new(binds, fn b -> {b.mid, b} end)
          _ = Runtime.put_mcu_bind(state.plan_ref, self_id, by_mid)

          audio_level_ext_id =
            case Runtime.get_ext(state.plan_ref, self_id) do
              %{audio_level: id} when is_integer(id) -> id
              _ -> nil
            end

          twcc_ext_id =
            case Runtime.get_ext(state.plan_ref, self_id) do
              %{twcc: id} when is_integer(id) -> id
              _ -> nil
            end

          Enum.each(binds, fn bind ->
            _ =
              Contributor.ensure(state.plan_ref, self_id, bind.send,
                jb_target: state.mcu_jb_target,
                non_mixable_pts: Map.get(bind, :non_mixable_pts, [])
              )

            _ =
              Egress.ensure(state.plan_ref, self_id, bind.recv,
                audio_level_ext_id: audio_level_ext_id,
                twcc_ext_id: twcc_ext_id,
                cn_payload_type: Map.get(bind, :cn_payload_type),
                sr_interval_ms: state.mcu_sr_interval_ms,
                opus_bitrate_bps: state.mcu_opus_bitrate_bps,
                bitrate_cap: state.bitrate_cap
              )
          end)

          {:ok, state}
        end

      {:error, _reason} ->
        {:ok, state}
    end
  end

  defp admit_mcu_contributor(_state, _id, []), do: :ok

  defp admit_mcu_contributor(state, self_id, _binds) do
    case Quota.admit_contributor(state.plan_ref, self_id, state.mcu_max_contributors) do
      :ok ->
        :ok

      {:error, reason} = err ->
        _ = Quota.maybe_emit_exceeded(state.tenant_id, state.session_id, reason)
        err
    end
  end

  defp maybe_register_mcu_mixer(:mcu, _cascade, _profile, plan_ref, session) do
    case Quota.register_mixer(plan_ref) do
      :ok ->
        :ok

      {:error, reason} = err ->
        _ = Quota.maybe_emit_exceeded(session.tenant_id, session.id, reason)
        err
    end
  end

  # PCM SFU spoke edge-transcodes hub mix via Mcu.tick; needs a mixer quota row.
  defp maybe_register_mcu_mixer(:sfu, :spoke, :pcm, plan_ref, session) do
    maybe_register_mcu_mixer(:mcu, nil, nil, plan_ref, session)
  end

  defp maybe_register_mcu_mixer(_, _, _, _, _), do: :ok

  defp maybe_admit_mcu_participant(%{audio: :mcu} = state) do
    case Quota.admit_participant(state.plan_ref, state.mcu_max_participants) do
      :ok ->
        :ok

      {:error, reason} = err ->
        _ = Quota.maybe_emit_exceeded(state.tenant_id, state.session_id, reason)
        err
    end
  end

  defp maybe_admit_mcu_participant(_state), do: :ok

  defp mcu_audio_ssrc?(plan_ref, participant_id, ssrc) when is_integer(ssrc) do
    plan_ref
    |> Plan.tracks_for(participant_id)
    |> Enum.any?(fn
      %{kind: :audio, ssrc: ^ssrc} -> true
      %{kind: :audio, layers: layers} when is_list(layers) ->
        Enum.any?(layers, fn
          %{ssrc: ^ssrc} -> true
          _ -> false
        end)

      _ ->
        false
    end)
  end

  defp mcu_audio_ssrc?(_, _, _), do: false

  defp mcu_audio_path?(state, participant, in_ssrc) do
    mcu_audio_ssrc?(state.plan_ref, participant.id, in_ssrc) and
      (state.audio == :mcu or
         (Cascade.pcm_sfu_edge?(state) and Cascade.mix_publisher?(participant.id)))
  end

  defp current_audio_level(plan_ref, participant_id) do
    case Runtime.get_audio_level(plan_ref, participant_id) do
      %{avg: avg} when is_number(avg) -> trunc(avg)
      _ -> nil
    end
  end

  defp check_publish_cap(_participant, [], _state), do: :ok

  defp check_publish_cap(%Participant{id: self_id, meta: meta}, _tracks, %{
         require_publish_cap: true,
         authorize: authorize
       })
       when is_function(authorize, 2) do
    caps_meta =
      case meta do
        %{capabilities: caps} -> %{participant_id: self_id, capabilities: caps}
        _ -> %{participant_id: self_id}
      end

    if authorize.(:publish, caps_meta) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp check_publish_cap(_participant, _tracks, _state), do: :ok

  defp check_max_publishers(_plan_ref, _self_id, [], _cap), do: :ok
  defp check_max_publishers(_plan_ref, _self_id, _tracks, nil), do: :ok

  defp check_max_publishers(plan_ref, self_id, _tracks, cap) when is_integer(cap) and cap > 0 do
    already? = Plan.published_mids(plan_ref, self_id) != []

    if already? do
      :ok
    else
      count = publisher_count(plan_ref)

      if count >= cap do
        {:error, :max_publishers}
      else
        :ok
      end
    end
  end

  defp publisher_count(plan_ref) do
    plan_ref
    |> Plan.participant_ids()
    |> MapSet.to_list()
    |> Enum.count(fn id -> Plan.published_mids(plan_ref, id) != [] end)
  end

  defp validate_strategy(:audio, :sfu), do: :ok
  defp validate_strategy(:audio, :mcu), do: :ok
  defp validate_strategy(:video, :sfu), do: :ok

  defp validate_strategy(kind, other),
    do: {:error, {:unsupported_strategy, kind, other}}

  defp validate_application(:none), do: :ok
  defp validate_application(other), do: {:error, {:unsupported_strategy, :application, other}}

  defp validate_subscribe_mode(:mesh), do: {:ok, :mesh}
  defp validate_subscribe_mode(:manual), do: {:ok, :manual}
  defp validate_subscribe_mode(other), do: {:error, {:invalid_subscribe_mode, other}}

  defp validate_max_publishers(nil), do: {:ok, nil}

  defp validate_max_publishers(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp validate_max_publishers(other), do: {:error, {:invalid_max_publishers, other}}

  defp validate_require_publish_cap(false), do: {:ok, false}
  defp validate_require_publish_cap(true), do: {:ok, true}

  defp validate_require_publish_cap(other),
    do: {:error, {:invalid_require_publish_cap, other}}

  defp validate_mcu_top_n(nil), do: {:ok, nil}
  defp validate_mcu_top_n(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp validate_mcu_top_n(other), do: {:error, {:invalid_mcu_top_n, other}}

  defp validate_mcu_level_hysteresis(n) when is_integer(n) and n >= 0 and n <= 127, do: {:ok, n}

  defp validate_mcu_level_hysteresis(other),
    do: {:error, {:invalid_mcu_level_hysteresis, other}}

  defp validate_mcu_plc_max(n) when is_integer(n) and n >= 0 and n <= 32, do: {:ok, n}
  defp validate_mcu_plc_max(other), do: {:error, {:invalid_mcu_plc_max, other}}

  defp validate_mcu_jb_target(n) when is_integer(n) and n >= 0 and n <= 8, do: {:ok, n}
  defp validate_mcu_jb_target(other), do: {:error, {:invalid_mcu_jb_target, other}}

  defp validate_mcu_drift_max_pad(n) when is_integer(n) and n >= 0 and n <= 4800, do: {:ok, n}

  defp validate_mcu_drift_max_pad(other),
    do: {:error, {:invalid_mcu_drift_max_pad, other}}

  defp validate_mcu_dtx_hold_ticks(n) when is_integer(n) and n >= 0 and n <= 100, do: {:ok, n}

  defp validate_mcu_dtx_hold_ticks(other),
    do: {:error, {:invalid_mcu_dtx_hold_ticks, other}}

  defp validate_mcu_sr_interval_ms(n) when is_integer(n) and n >= 0 and n <= 60_000, do: {:ok, n}

  defp validate_mcu_sr_interval_ms(other),
    do: {:error, {:invalid_mcu_sr_interval_ms, other}}

  defp validate_mcu_opus_bitrate_bps(n) when is_integer(n) and n >= 500 and n <= 512_000,
    do: {:ok, n}

  defp validate_mcu_opus_bitrate_bps(other),
    do: {:error, {:invalid_mcu_opus_bitrate_bps, other}}

  defp validate_mcu_max_cap(nil, _label), do: {:ok, nil}

  defp validate_mcu_max_cap(n, _label) when is_integer(n) and n > 0, do: {:ok, n}

  defp validate_mcu_max_cap(other, label), do: {:error, {:invalid, label, other}}

  defp validate_mcu_cascade(nil, _audio), do: {:ok, nil}
  defp validate_mcu_cascade(:hub, :mcu), do: {:ok, :hub}
  defp validate_mcu_cascade(:spoke, :sfu), do: {:ok, :spoke}
  defp validate_mcu_cascade(:spoke, :mcu), do: {:ok, :spoke}
  defp validate_mcu_cascade(:hub, _), do: {:error, :invalid_mcu_cascade}
  defp validate_mcu_cascade(_, _), do: {:error, :invalid_mcu_cascade}

  defp validate_mcu_mix_mid(mid) when is_binary(mid) and byte_size(mid) > 0, do: {:ok, mid}
  defp validate_mcu_mix_mid(_), do: {:error, :invalid_mcu_mix_mid}

  defp validate_mcu_nif(nil), do: {:ok, nil}
  defp validate_mcu_nif(true), do: {:ok, true}
  defp validate_mcu_nif(false), do: {:ok, false}
  defp validate_mcu_nif(other), do: {:error, {:invalid_mcu_nif, other}}

  defp validate_mcu_spoke_mix_minus(false), do: {:ok, false}
  defp validate_mcu_spoke_mix_minus(true), do: {:ok, true}

  defp validate_mcu_spoke_mix_minus(other),
    do: {:error, {:invalid_mcu_spoke_mix_minus, other}}

  defp validate_mcu_cascade_trunk_profile(:opus), do: {:ok, :opus}
  defp validate_mcu_cascade_trunk_profile(:pcm), do: {:ok, :pcm}
  defp validate_mcu_cascade_trunk_profile("opus"), do: {:ok, :opus}
  defp validate_mcu_cascade_trunk_profile("pcm"), do: {:ok, :pcm}

  defp validate_mcu_cascade_trunk_profile(other),
    do: {:error, {:invalid_mcu_cascade_trunk_profile, other}}

  defp validate_audiolevel_events(v) when is_boolean(v), do: {:ok, v}

  defp validate_audiolevel_events(other), do: {:error, {:invalid_audiolevel_events, other}}

  defp validate_audio_active_packets(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp validate_audio_active_packets(other), do: {:error, {:invalid_audio_active_packets, other}}

  defp validate_audio_level_average(n) when is_integer(n) and n > 0 and n <= 127, do: {:ok, n}

  defp validate_audio_level_average(other), do: {:error, {:invalid_audio_level_average, other}}

  defp validate_bitrate_cap(nil), do: {:ok, nil}
  defp validate_bitrate_cap(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp validate_bitrate_cap(other), do: {:error, {:invalid_bitrate_cap, other}}

  defp validate_adaptive_layers(v) when is_boolean(v), do: {:ok, v}
  defp validate_adaptive_layers(other), do: {:error, {:invalid_adaptive_layers, other}}

  defp validate_dynacast(v) when is_boolean(v), do: {:ok, v}
  defp validate_dynacast(other), do: {:error, {:invalid_dynacast, other}}

  defp validate_twcc_period_ms(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp validate_twcc_period_ms(other), do: {:error, {:invalid_twcc_period_ms, other}}

  defp validate_fir_interval_ms(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp validate_fir_interval_ms(other), do: {:error, {:invalid_fir_interval_ms, other}}

  @audio_level_uri "urn:ietf:params:rtp-hdrext:ssrc-audio-level"

  defp maybe_feeds_put(_state, _self_id, []), do: :ok

  defp maybe_feeds_put(state, self_id, tracks) do
    if Code.ensure_loaded?(Xylon.Control.Feeds) do
      feed = feed_from_tracks(tracks)
      Xylon.Control.Feeds.put(state.tenant_id, state.session_id, self_id, feed)
    else
      :ok
    end
  end

  defp maybe_feeds_delete(state, participant_id) do
    if Code.ensure_loaded?(Xylon.Control.Feeds) do
      Xylon.Control.Feeds.delete(state.tenant_id, state.session_id, participant_id)
    else
      :ok
    end
  end

  defp refresh_feeds_after_unpublish(state, participant_id) do
    if Code.ensure_loaded?(Xylon.Control.Feeds) do
      case feed_from_remaining_tracks(state.plan_ref, participant_id) do
        nil ->
          Xylon.Control.Feeds.delete(state.tenant_id, state.session_id, participant_id)

        feed ->
          Xylon.Control.Feeds.put(state.tenant_id, state.session_id, participant_id, feed)
      end
    else
      :ok
    end
  end

  defp feed_from_remaining_tracks(plan_ref, participant_id) do
    tracks = Plan.tracks_for(plan_ref, participant_id)

    if tracks == [] do
      nil
    else
      feed_from_tracks(tracks)
    end
  end

  defp scrub_publisher_media_state(state, participant_id) do
    plan_ref = state.plan_ref

    if is_nil(Plan.find_track_by_kind(plan_ref, participant_id, :audio)) do
      _ = Runtime.clear_audio(plan_ref, participant_id)
    end

    if is_nil(Plan.find_track_by_kind(plan_ref, participant_id, :video)) do
      _ = Runtime.clear_video(plan_ref, participant_id)
    end

    state
  end

  defp feed_from_tracks(tracks) do
    streams =
      tracks
      |> Enum.map(fn track ->
        stream = %{mid: track.mid, kind: track.kind}

        case Map.get(track, :codec) do
          codec when is_binary(codec) and codec != "" -> Map.put(stream, :codec, codec)
          _ -> stream
        end
      end)
      |> Enum.sort_by(& &1.mid)

    %{streams: streams}
  end

  defp audio_level_ext_id(sdp) when is_binary(sdp) do
    sdp
    |> String.split(["\r\n", "\n"])
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^a=extmap:(\d+)\s+#{Regex.escape(@audio_level_uri)}\s*$/, line) do
        [_, id] -> String.to_integer(id)
        _ -> nil
      end
    end)
  end

  defp twcc_ext_id(sdp) when is_binary(sdp) do
    uri = Twcc.uri()

    sdp
    |> String.split(["\r\n", "\n"])
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^a=extmap:(\d+)\s+#{Regex.escape(uri)}\s*$/, line) do
        [_, id] -> String.to_integer(id)
        _ -> nil
      end
    end)
  end

  defp dependency_descriptor_ext_id(sdp) when is_binary(sdp) do
    uri = XMediaLib.Rtp.DependencyDescriptor.uri()

    sdp
    |> String.split(["\r\n", "\n"])
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^a=extmap:(\d+)\s+#{Regex.escape(uri)}\s*$/, line) do
        [_, id] -> String.to_integer(id)
        _ -> nil
      end
    end)
  end

  defp rid_ext_id(sdp) when is_binary(sdp) do
    uri = HeaderExtension.rtp_stream_id_uri()

    sdp
    |> String.split(["\r\n", "\n"])
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^a=extmap:(\d+)\s+#{Regex.escape(uri)}\s*$/, line) do
        [_, id] -> String.to_integer(id)
        _ -> nil
      end
    end)
  end

  # Rewrite.strip_extensions/1 clears all extensions; restore rewritten DD for
  # subscriber ADT / layer signaling.
  defp restore_dd_extension(packet, source, dd_ext_id)
       when is_integer(dd_ext_id) and dd_ext_id > 0 do
    case dd_extension_raw(source, dd_ext_id) do
      data when is_binary(data) ->
        DependencyDescriptor.put_extension(packet, dd_ext_id, data)

      _ ->
        packet
    end
  end

  defp restore_dd_extension(packet, _, _), do: packet

  # Stamp transport-cc on SFU video fanout when the subscriber negotiated it.
  defp maybe_stamp_sfu_twcc(plan_ref, %{kind: :video} = route, packet, %{out_ssrc: out_ssrc})
       when is_integer(out_ssrc) do
    twcc_ext_id =
      case Runtime.get_ext(plan_ref, route.subscriber_id) do
        %{twcc: id} when is_integer(id) and id >= 1 and id <= 14 -> id
        _ -> nil
      end

    if is_nil(twcc_ext_id) do
      {packet, out_ssrc}
    else
      send_state =
        Runtime.get_sfu_twcc_send(plan_ref, out_ssrc) ||
          Xylon.Conference.Bwe.Twcc.empty_send_state()

      now_us = System.monotonic_time(:microsecond)
      {packet2, next} = Xylon.Conference.Bwe.Twcc.stamp_extension(packet, twcc_ext_id, send_state, now_us)
      _ = Runtime.put_sfu_twcc_send(plan_ref, out_ssrc, next)
      {packet2, out_ssrc}
    end
  end

  defp maybe_stamp_sfu_twcc(_plan_ref, _route, packet, %{out_ssrc: out_ssrc})
       when is_integer(out_ssrc),
       do: {packet, out_ssrc}

  defp maybe_stamp_sfu_twcc(_plan_ref, _route, packet, _), do: {packet, nil}

  defp dd_extension_raw(%Rtp{extension: %{type: type, payload: payload}}, ext_id)
       when is_binary(payload) do
    type
    |> HeaderExtension.decode_elements(payload)
    |> Enum.find_value(fn
      {^ext_id, data} when is_binary(data) -> data
      _ -> nil
    end)
  end

  defp dd_extension_raw(_, _), do: nil

  defp session_pid(%{id: _} = _session, opts) do
    case Keyword.get(opts, :session_pid) do
      pid when is_pid(pid) -> pid
      _ -> make_ref()
    end
  end
end
