defmodule Xylon.Conference.Rtcp do
  @moduledoc """
  Conference SFU RTCP: PLI/FIR toward publishers, Generic NACK retransmission.

  ## What problem this solves

  Video decoders need occasional keyframes (full pictures) to start or recover.
  Subscribers send RTCP feedback such as PLI (Picture Loss Indication) or FIR
  (Full Intra Request) toward the SSRC they see in their inbound RTP. In an SFU,
  those SSRC values are the rewritten outbound SSRCs, not the publisher's
  original SSRC. This module maps feedback back to the publisher's inbound SSRC
  and forwards it through [XGW](https://github.com/Lazarus404/xgw) `Peer.send_rtcp/2`.

  When a subscriber reports loss via Generic NACK, this module looks up the
  rewritten packets in `NackCache` by outbound SSRC and sequence and retransmits
  them to the NACKing subscriber Peer only (not to other subscribers).

  Subscriber REMB reports are fan-in translated toward each publisher Peer
  (Janus-style replace): bitrate is the minimum of recent subscriber estimates
  for that publisher (and optional `bitrate_cap`). When the **publisher**
  negotiated `transport-cc` (`Runtime` ext id), that REMB is **not** sent to
  the publisher -- uplink BWE is TWCC-only (`Conference.Twcc`) so panic REMB
  cannot throttle the sender. Rates are still stored for `adaptive_layers`.
  Mix egress SSRCs update MCU REMB/TWCC BWE instead. When `adaptive_layers`
  is enabled, the same REMB rates drive receive-side SIM/SVC layer picks via
  `Allocator` (manual sticky wins). When the subscriber negotiated
  transport-cc and SFU stamped outbound TWCC, adaptive pick uses
  `min(REMB, TWCC-bps)` for that route.

  TWCC feedback toward publishers is generated separately (`Conference.Twcc`).
  Inbound subscriber TWCC about mix SSRCs is handled here for mix encode BWE.
  The SFU can also emit periodic PLI toward video publishers (`fir_interval_ms`)
  when subscribers are present. Unknown packet types are ignored.

  **Internal:** invoked from `Xylon.Conference.Backend.handle_rtcp/3` and
  `handle_rtp/3` (periodic keyframe).

  ## RFCs

  - [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) (RTCP; PLI/FIR as RTCP feedback)
  - [RFC 3711](https://www.rfc-editor.org/rfc/rfc3711) (SRTP-protected RTCP on the wire via XGW)
  - [RFC 4585](https://www.rfc-editor.org/rfc/rfc4585) (Extended RTP profile for RTCP-based feedback; PLI/FIR/NACK)
  - [draft-alvestrand-rmcat-remb](https://datatracker.ietf.org/doc/html/draft-alvestrand-rmcat-remb) (REMB)
  - [draft-holmer-rmcat-transport-wide-cc-extensions](https://datatracker.ietf.org/doc/html/draft-holmer-rmcat-transport-wide-cc-extensions-01)
  """

  import Bitwise

  alias XGW.Peer
  alias Xylon.Conference.Bwe.Twcc, as: TwccBwe
  alias Xylon.Conference.Mcu.Rtcp, as: McuRtcp
  alias Xylon.Conference.{Allocator, NackCache, Plan, Runtime, SessionHooks}
  alias Xylon.Participant
  alias XMediaLib.Rtcp, as: RtcpPacket
  alias XMediaLib.Rtcp.TwccFci

  @sfu_twcc_default_bps 500_000
  @sfu_twcc_floor_bps 50_000
  @sfu_twcc_ceil_bps 5_000_000

  @doc """
  Sends a PLI keyframe request to a video publisher.

  When `subscriber_id` is given, uses that route's inbound layer SSRC (simulcast).
  Otherwise uses the publisher's primary video track SSRC. Returns `:ok`.
  """
  @spec request_keyframe(Plan.plan_ref(), term(), keyword()) :: :ok
  def request_keyframe(plan_ref, publisher_id, opts \\ []) when is_list(opts) do
    subscriber_id = Keyword.get(opts, :subscriber_id)

    with %Participant{peer_ref: peer} when is_pid(peer) <-
           Plan.get_participant(plan_ref, publisher_id),
         in_ssrc when is_integer(in_ssrc) <- keyframe_ssrc(plan_ref, publisher_id, subscriber_id) do
      pli = %XMediaLib.Rtcp.Pli{ssrc_s: 1, ssrc_m: in_ssrc}
      _ = Peer.send_rtcp(peer, %RtcpPacket{payloads: [pli]})
      :ok
    else
      _ -> :ok
    end
  end

  defp keyframe_ssrc(plan_ref, publisher_id, nil) do
    case Plan.find_track_by_kind(plan_ref, publisher_id, :video) do
      %{ssrc: ssrc} when is_integer(ssrc) -> ssrc
      _ -> nil
    end
  end

  defp keyframe_ssrc(plan_ref, publisher_id, subscriber_id) do
    case subscriber_video_mid(plan_ref, publisher_id, subscriber_id) do
      mid when is_binary(mid) ->
        Plan.inbound_ssrc(plan_ref, publisher_id, mid, subscriber_id)

      nil ->
        keyframe_ssrc(plan_ref, publisher_id, nil)
    end
  end

  defp subscriber_video_mid(plan_ref, publisher_id, subscriber_id) do
    plan_ref
    |> Plan.published_mids(publisher_id)
    |> Enum.find(fn mid ->
      case Plan.get_track(plan_ref, publisher_id, mid) do
        %{kind: :video} ->
          MapSet.member?(Plan.subscribers(plan_ref, publisher_id, mid), subscriber_id)

        _ ->
          false
      end
    end)
  end

  @doc """
  Forwards PLI/FIR packets to the publisher that owns the referenced media SSRC.

  Accepts `%XMediaLib.Rtcp{}`, binary RTCP, a single PLI/FIR struct, or a list
  of structs. Media SSRC fields are rewritten from subscriber-facing (outbound)
  values to the publisher's inbound track SSRC before send. Returns `:ok`.
  """
  @spec forward_pli_fir(Plan.plan_ref(), Participant.t(), term()) :: :ok
  def forward_pli_fir(plan_ref, %Participant{} = _from, rtcp) do
    Enum.each(feedback_targets(rtcp), fn media_ssrc ->
      case resolve_publisher(plan_ref, media_ssrc) do
        {:ok, %Participant{peer_ref: peer}, in_ssrc} when is_pid(peer) ->
          wire = rtcp |> rewrite_media_ssrc(media_ssrc, in_ssrc) |> wrap_rtcp()
          _ = Peer.send_rtcp(peer, wire)

        _ ->
          :ok
      end
    end)

    :ok
  end

  @doc """
  Retransmits cached RTP for Generic NACK toward the NACKing subscriber.

  Resolves `ssrc_m` as the subscriber-facing outbound SSRC, expands PID/BLP
  pairs into sequence numbers, looks up each in `NackCache`, and sends matches
  via `Peer.send_rtp/3` to `from.peer_ref` only. Unknown sequences are no-ops.
  """
  @spec handle_nack(Plan.plan_ref(), Participant.t(), term()) :: :ok
  def handle_nack(plan_ref, %Participant{peer_ref: peer} = _from, rtcp) when is_pid(peer) do
    Enum.each(gnack_requests(rtcp), fn {out_ssrc, seqs} ->
      Enum.each(seqs, fn seq ->
        case NackCache.lookup(plan_ref, out_ssrc, seq) do
          {:ok, packet} ->
            _ = Peer.send_rtp(peer, out_ssrc, packet)

          :error ->
            :ok
        end
      end)
    end)

    :ok
  end

  def handle_nack(_plan_ref, _from, _rtcp), do: :ok

  @doc """
  Fan-in translates subscriber REMB toward publishers and returns updated rates.

  `remb_rates` is `%{publisher_id => %{subscriber_id => bitrate_bps}}`. For each
  publisher touched by this compound, sends one `%Remb{}` with that publisher's
  inbound SSRC list and bitrate `min(subscriber rates, bitrate_cap)`, unless
  the publisher registered a transport-cc ext id (then rates are stored only).

  SSRCs that match MCU mix egress (Runtime `mcu_out_ssrc`) update mix REMB and
  Opus encode bitrate instead of the publisher path.
  """
  @spec handle_remb(Plan.plan_ref(), Participant.t(), term(), map(), keyword()) :: map()
  def handle_remb(plan_ref, %Participant{id: subscriber_id}, rtcp, remb_rates, opts \\ [])
      when is_map(remb_rates) do
    bitrate_cap = Keyword.get(opts, :bitrate_cap)

    {remb_rates, publishers} =
      Enum.reduce(remb_packets(rtcp), {remb_rates, MapSet.new()}, fn remb, {rates, pubs} ->
        Enum.reduce(remb.ssrcs || [], {rates, pubs}, fn out_ssrc, {rates_acc, pubs_acc} ->
          case Plan.publisher_for_out_ssrc(plan_ref, out_ssrc) do
            {:ok, publisher_id, _mid} ->
              by_sub = Map.get(rates_acc, publisher_id, %{})
              by_sub = Map.put(by_sub, subscriber_id, remb.bitrate)
              rates_acc = Map.put(rates_acc, publisher_id, by_sub)
              {rates_acc, MapSet.put(pubs_acc, publisher_id)}

            :error ->
              case Runtime.get_mcu_listener_for_out_ssrc(plan_ref, out_ssrc) do
                listener_id when not is_nil(listener_id) ->
                  _ =
                    McuRtcp.note_listener_remb(plan_ref, listener_id, remb.bitrate,
                      bitrate_cap: bitrate_cap
                    )

                  {rates_acc, pubs_acc}

                nil ->
                  {rates_acc, pubs_acc}
              end
          end
        end)
      end)

    Enum.each(publishers, fn publisher_id ->
      send_publisher_remb(plan_ref, publisher_id, remb_rates, bitrate_cap)
    end)

    if Keyword.get(opts, :adaptive_layers, false) do
      apply_adaptive_layers(plan_ref, remb_rates, opts)
    end

    remb_rates
  end

  @doc """
  Applies receive-side Allocator recommendations from `remb_rates`.

  Per subscription uses that subscriber's reported bitrate, optionally
  `min`'d with SFU TWCC-bps when present. Skips manual-sticky routes.
  """
  @spec apply_adaptive_layers(Plan.plan_ref(), map(), keyword()) :: :ok
  def apply_adaptive_layers(plan_ref, remb_rates, opts \\ [])
      when is_map(remb_rates) and is_list(opts) do
    Enum.each(remb_rates, fn {publisher_id, by_sub} when is_map(by_sub) ->
      Enum.each(by_sub, fn {subscriber_id, bps} when is_integer(bps) and bps >= 0 ->
        Enum.each(Plan.published_mids(plan_ref, publisher_id), fn mid ->
          track = Plan.get_track(plan_ref, publisher_id, mid)

          if match?(%{kind: :video}, track) and
               MapSet.member?(Plan.subscribers(plan_ref, publisher_id, mid), subscriber_id) do
            effective = effective_adapt_bps(plan_ref, subscriber_id, publisher_id, mid, bps)
            maybe_adapt_route(plan_ref, publisher_id, mid, subscriber_id, track, effective, opts)
          end
        end)
      end)
    end)

    :ok
  end

  defp effective_adapt_bps(plan_ref, subscriber_id, publisher_id, mid, remb_bps) do
    case Runtime.get_sfu_twcc_bwe(plan_ref, subscriber_id, publisher_id, mid) do
      %{bps: twcc_bps} when is_integer(twcc_bps) and twcc_bps >= 0 ->
        min(remb_bps, twcc_bps)

      _ ->
        remb_bps
    end
  end

  defp maybe_adapt_route(plan_ref, publisher_id, mid, subscriber_id, track, bps, opts) do
    {mode, layer_count} = adapt_mode(track)
    codec = Map.get(track, :codec)

    rec =
      Allocator.recommend(%{
        bitrate_bps: bps,
        mode: mode,
        layer_count: layer_count,
        codec: codec
      })

    layer_opts = rec_to_opts(rec)

    if layer_opts != [] do
      _ =
        SessionHooks.set_substream_adaptive(
          plan_ref,
          subscriber_id,
          publisher_id,
          mid,
          Keyword.merge(layer_opts, Keyword.take(opts, [:forwarder]))
        )
    end

    :ok
  end

  defp adapt_mode(%{layers: layers}) when is_list(layers) and layers != [] do
    {:sim, length(layers)}
  end

  defp adapt_mode(_), do: {:svc, 3}

  defp rec_to_opts(rec) when is_map(rec) do
    []
    |> maybe_kw(:substream, Map.get(rec, :substream))
    |> maybe_kw(:temporal, Map.get(rec, :temporal))
    |> maybe_kw(:spatial_layer, Map.get(rec, :spatial_layer))
    |> maybe_kw(:temporal_layer, Map.get(rec, :temporal_layer))
  end

  defp maybe_kw(acc, _k, nil), do: acc
  defp maybe_kw(acc, k, v), do: Keyword.put(acc, k, v)

  @doc """
  Handles subscriber TWCC feedback about MCU mix egress or SFU rewrite SSRCs.

  Mix SSRCs update MCU encode BWE. Plan rewrite `ssrc_m` updates per-route
  SFU TWCC-bps and, when `adaptive_layers: true`, drives Allocator pick using
  `min(REMB, TWCC)` when REMB is already known for that publisher.
  """
  @spec handle_twcc(Plan.plan_ref(), Participant.t(), term(), keyword()) :: :ok
  def handle_twcc(plan_ref, %Participant{id: subscriber_id}, rtcp, opts \\ [])
      when is_list(opts) do
    bitrate_cap = Keyword.get(opts, :bitrate_cap)
    adaptive? = Keyword.get(opts, :adaptive_layers, false)

    Enum.each(twcc_packets(rtcp), fn twcc ->
      case Runtime.get_mcu_listener_for_out_ssrc(plan_ref, twcc.ssrc_m) do
        listener_id when not is_nil(listener_id) ->
          _ = McuRtcp.note_listener_twcc(plan_ref, listener_id, twcc, bitrate_cap: bitrate_cap)

        nil ->
          case Plan.publisher_for_out_ssrc(plan_ref, twcc.ssrc_m) do
            {:ok, publisher_id, mid} ->
              _ =
                note_sfu_twcc(plan_ref, subscriber_id, publisher_id, mid, twcc.ssrc_m, twcc,
                  bitrate_cap: bitrate_cap,
                  adaptive_layers: adaptive?
                )

            :error ->
              :ok
          end
      end
    end)

    :ok
  end

  defp note_sfu_twcc(plan_ref, subscriber_id, publisher_id, mid, out_ssrc, twcc, opts) do
    bitrate_cap = Keyword.get(opts, :bitrate_cap)

    with %{send_map: send_map} = _send when is_map(send_map) <-
           Runtime.get_sfu_twcc_send(plan_ref, out_ssrc),
         {:ok, packets} <- TwccFci.parse(twcc) do
      prev = Runtime.get_sfu_twcc_bwe(plan_ref, subscriber_id, publisher_id, mid) || %{}
      base = Map.get(prev, :bps) || @sfu_twcc_default_bps

      {bps, state} =
        TwccBwe.estimate_bps(packets, send_map, twcc.ref_time, prev, base,
          bitrate_cap: bitrate_cap,
          floor_bps: @sfu_twcc_floor_bps,
          ceil_bps: @sfu_twcc_ceil_bps
        )

      _ =
        Runtime.put_sfu_twcc_bwe(
          plan_ref,
          subscriber_id,
          publisher_id,
          mid,
          Map.put(state, :bps, bps)
        )

      if Keyword.get(opts, :adaptive_layers, false) do
        remb_bps =
          plan_ref
          |> Runtime.get_remb()
          |> get_in([publisher_id, subscriber_id])

        effective =
          if is_integer(remb_bps) and remb_bps >= 0, do: min(remb_bps, bps), else: bps

        track = Plan.get_track(plan_ref, publisher_id, mid)

        if match?(%{kind: :video}, track) do
          maybe_adapt_route(plan_ref, publisher_id, mid, subscriber_id, track, effective, opts)
        end
      end

      :ok
    else
      _ -> :ok
    end
  end

  defp twcc_packets(%RtcpPacket{payloads: payloads}), do: twcc_packets(payloads)

  defp twcc_packets(list) when is_list(list) do
    Enum.flat_map(list, &twcc_packets/1)
  end

  defp twcc_packets(%XMediaLib.Rtcp.Twcc{} = t), do: [t]
  defp twcc_packets(_), do: []

  defp send_publisher_remb(plan_ref, publisher_id, remb_rates, bitrate_cap) do
    case Runtime.get_ext(plan_ref, publisher_id) do
      %{twcc: id} when is_integer(id) and id >= 1 ->
        :ok

      _ ->
        with %Participant{peer_ref: peer} when is_pid(peer) <-
               Plan.get_participant(plan_ref, publisher_id),
             by_sub when is_map(by_sub) and map_size(by_sub) > 0 <- Map.get(remb_rates, publisher_id),
             bitrate when is_integer(bitrate) and bitrate >= 0 <-
               min_bitrate(Map.values(by_sub), bitrate_cap),
             in_ssrcs when in_ssrcs != [] <- publisher_in_ssrcs(plan_ref, publisher_id) do
          remb = %XMediaLib.Rtcp.Remb{ssrc_s: 1, ssrc_m: 0, bitrate: bitrate, ssrcs: in_ssrcs}
          _ = Peer.send_rtcp(peer, %RtcpPacket{payloads: [remb]})
          :ok
        else
          _ -> :ok
        end
    end
  end

  defp min_bitrate(rates, nil), do: Enum.min(rates)

  defp min_bitrate(rates, cap) when is_integer(cap) and cap > 0 do
    min(Enum.min(rates), cap)
  end

  defp min_bitrate(rates, _), do: Enum.min(rates)

  defp publisher_in_ssrcs(plan_ref, publisher_id) do
    for track <- Plan.tracks_for(plan_ref, publisher_id),
        %{ssrc: ssrc} when is_integer(ssrc) <- [track],
        do: ssrc
  end

  defp remb_packets(%RtcpPacket{payloads: payloads}), do: remb_packets(payloads)

  defp remb_packets(list) when is_list(list) do
    Enum.flat_map(list, &remb_packets/1)
  end

  defp remb_packets(%{__struct__: mod} = pkt) do
    name = mod |> Module.split() |> List.last()

    if name == "Remb" and is_integer(Map.get(pkt, :bitrate)) do
      [pkt]
    else
      []
    end
  end

  defp remb_packets(bin) when is_binary(bin) do
    case safe_decode(bin) do
      {:ok, decoded} -> remb_packets(decoded)
      _ -> []
    end
  end

  defp remb_packets(_), do: []

  defp resolve_publisher(plan_ref, media_ssrc) do
    with {:ok, publisher_id, mid} <- find_publisher(plan_ref, media_ssrc),
         %Participant{} = participant <- Plan.get_participant(plan_ref, publisher_id),
         %{ssrc: in_ssrc} when is_integer(in_ssrc) <- Plan.get_track(plan_ref, publisher_id, mid) do
      {:ok, participant, in_ssrc}
    else
      _ -> :error
    end
  end

  defp find_publisher(plan_ref, media_ssrc) do
    case Plan.publisher_for_out_ssrc(plan_ref, media_ssrc) do
      {:ok, _, _} = ok -> ok
      :error -> Plan.publisher_for_in_ssrc(plan_ref, media_ssrc)
    end
  end

  defp wrap_rtcp(%RtcpPacket{encrypted: nil} = rtcp), do: rtcp
  defp wrap_rtcp(list) when is_list(list), do: %RtcpPacket{payloads: list}

  defp wrap_rtcp(%{__struct__: mod} = pkt) do
    name = mod |> Module.split() |> List.last()

    if name in ["Pli", "Fir"] do
      %RtcpPacket{payloads: [pkt]}
    else
      pkt
    end
  end

  defp wrap_rtcp(other), do: other

  defp rewrite_media_ssrc(%RtcpPacket{payloads: payloads} = rtcp, from_ssrc, to_ssrc) do
    %{rtcp | payloads: Enum.map(payloads, &rewrite_media_ssrc(&1, from_ssrc, to_ssrc))}
  end

  defp rewrite_media_ssrc(list, from_ssrc, to_ssrc) when is_list(list) do
    Enum.map(list, &rewrite_media_ssrc(&1, from_ssrc, to_ssrc))
  end

  defp rewrite_media_ssrc(%{__struct__: mod} = pkt, from_ssrc, to_ssrc) do
    name = mod |> Module.split() |> List.last()

    cond do
      name == "Pli" and Map.get(pkt, :ssrc_m) == from_ssrc ->
        %{pkt | ssrc_m: to_ssrc}

      name == "Fir" and Map.get(pkt, :ssrc) == from_ssrc ->
        %{pkt | ssrc: to_ssrc}

      true ->
        pkt
    end
  end

  defp rewrite_media_ssrc(bin, from_ssrc, to_ssrc) when is_binary(bin) do
    case safe_decode(bin) do
      {:ok, decoded} -> rewrite_media_ssrc(decoded, from_ssrc, to_ssrc)
      _ -> bin
    end
  end

  defp rewrite_media_ssrc(other, _from_ssrc, _to_ssrc), do: other

  defp feedback_targets(%RtcpPacket{payloads: payloads}), do: feedback_targets(payloads)

  defp feedback_targets(rtcp) when is_list(rtcp) do
    rtcp
    |> Enum.flat_map(&feedback_targets/1)
    |> Enum.uniq()
  end

  defp feedback_targets(%{__struct__: mod} = pkt) do
    name = mod |> Module.split() |> List.last()

    cond do
      name in ["Pli"] ->
        case Map.get(pkt, :ssrc_m) do
          ssrc when is_integer(ssrc) -> [ssrc]
          _ -> []
        end

      name in ["Fir"] ->
        case Map.get(pkt, :ssrc) do
          ssrc when is_integer(ssrc) -> [ssrc]
          _ -> []
        end

      true ->
        []
    end
  end

  defp feedback_targets(bin) when is_binary(bin) do
    case safe_decode(bin) do
      {:ok, decoded} -> feedback_targets(decoded)
      _ -> []
    end
  end

  defp feedback_targets(_), do: []

  defp gnack_requests(%RtcpPacket{payloads: payloads}), do: gnack_requests(payloads)

  defp gnack_requests(list) when is_list(list) do
    Enum.flat_map(list, &gnack_requests/1)
  end

  defp gnack_requests(%{__struct__: mod} = pkt) do
    name = mod |> Module.split() |> List.last()

    if name == "Gnack" do
      case {Map.get(pkt, :ssrc_m), Map.get(pkt, :list)} do
        {ssrc, list} when is_integer(ssrc) and is_list(list) ->
          [{ssrc, expand_nack_list(list)}]

        _ ->
          []
      end
    else
      []
    end
  end

  defp gnack_requests(bin) when is_binary(bin) do
    case safe_decode(bin) do
      {:ok, decoded} -> gnack_requests(decoded)
      _ -> []
    end
  end

  defp gnack_requests(_), do: []

  defp expand_nack_list(list) do
    list
    |> Enum.flat_map(fn
      {pid, blp} when is_integer(pid) and is_integer(blp) ->
        lost = for i <- 0..15, band(blp, 1 <<< i) != 0, do: rem(pid + 1 + i, 65_536)
        [pid | lost]

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp safe_decode(bin) do
    try do
      RtcpPacket.decode(bin)
    rescue
      _ -> :error
    catch
      _, _ -> :error
    end
  end
end
