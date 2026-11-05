defmodule Xylon.Conference.Mcu.Rtcp do
  @moduledoc """
  MCU mix RTCP: Sender Reports and REMB/TWCC-driven Opus bitrate.

  ## What problem this solves

  The mix is a synthetic RTP source with its own per-listener egress SSRC.
  Clients need RFC 3550 Sender Reports for those SSRCs so jitter buffers stay
  honest. Subscriber REMB naming mix SSRCs, and subscriber transport-cc
  feedback about mix SSRCs, adjust shared Opus encode bitrate. Plan rewrite
  REMB lookup does not see mix SSRCs.

  When both REMB and TWCC estimates exist for bound listeners, the encode
  group target is `min` of those rates (then optional `bitrate_cap`).
  TWCC alone or REMB alone is enough; missing TWCC keeps REMB-only behavior.

  **Internal:** called from `Xylon.Conference.Mcu.Egress` (SR) and
  `Xylon.Conference.Rtcp` (mix REMB / mix TWCC).

  ## RFCs

  - [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) (Sender Report)
  - [draft-alvestrand-rmcat-remb](https://datatracker.ietf.org/doc/html/draft-alvestrand-rmcat-remb) (REMB)
  - [draft-holmer-rmcat-transport-wide-cc-extensions](https://datatracker.ietf.org/doc/html/draft-holmer-rmcat-transport-wide-cc-extensions-01)
  """

  import Bitwise

  alias Xylon.Conference.Bwe.Twcc, as: TwccBwe
  alias Xylon.Conference.{Plan, Runtime}
  alias Xylon.Participant
  alias XMediaLib.Codec
  alias XMediaLib.Rtcp, as: RtcpPacket
  alias XMediaLib.Rtcp.TwccFci

  @unix_to_ntp_sec 2_208_988_800
  @default_opus_bps 32_000
  @floor_bps 8_000
  @ceil_bps 128_000

  @doc """
  Maybe sends an SR for the listener's mix egress SSRC.

  Emits when `now_ms - last_sr_ms >= sr_interval_ms` (or never sent). Updates
  egress `last_sr_ms` on send. Returns `:ok`.
  """
  @spec maybe_send_sr(Runtime.plan_ref(), term(), keyword()) :: :ok
  def maybe_send_sr(plan_ref, listener_id, opts \\ []) when is_list(opts) do
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))

    with %{out_ssrc: ssrc, packets: packets, octets: octets, last_rtp_ts: ts} = egress
           when is_integer(ssrc) and packets > 0 <- Runtime.get_mcu_egress(plan_ref, listener_id),
         interval when is_integer(interval) and interval >= 0 <-
           Map.get(egress, :sr_interval_ms) || Keyword.get(opts, :sr_interval_ms, 1000),
         true <- due_sr?(egress, now_ms, interval),
         %Participant{peer_ref: peer} when is_pid(peer) <-
           Plan.get_participant(plan_ref, listener_id),
         true <- Process.alive?(peer) do
      sr = %XMediaLib.Rtcp.Sr{
        ssrc: ssrc,
        ntp: ntp_now(now_ms),
        timestamp: ts || 0,
        packets: packets,
        octets: octets,
        rblocks: []
      }

      _ = safe_send_rtcp(peer, %RtcpPacket{payloads: [sr]})
      _ = Runtime.put_mcu_egress(plan_ref, listener_id, %{egress | last_sr_ms: now_ms})
      :ok
    else
      _ -> :ok
    end
  end

  defp safe_send_rtcp(peer, packet) do
    # Short timeout: lab stub peers are not GenServers; FakePeer/XGW Peer reply fast.
    GenServer.call(peer, {:send_rtcp, packet}, 50)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Records mix REMB for `listener_id` and applies min bitrate to bound Opus groups.
  """
  @spec note_listener_remb(Runtime.plan_ref(), term(), non_neg_integer(), keyword()) :: :ok
  def note_listener_remb(plan_ref, listener_id, bitrate_bps, opts \\ [])
      when is_integer(bitrate_bps) and bitrate_bps >= 0 and is_list(opts) do
    rates = Map.put(Runtime.get_mcu_remb(plan_ref), listener_id, bitrate_bps)
    _ = Runtime.put_mcu_remb(plan_ref, rates)
    apply_bitrates(plan_ref, Keyword.get(opts, :bitrate_cap))
  end

  @doc """
  Updates mix TWCC BWE for `listener_id` from one feedback packet and applies bitrates.

  Correlates parsed FCI rows with the egress `twcc_send_map`. Steps `twcc_bps`
  from loss fraction and inter-packet delay gradient (clock-offset canceling).
  """
  @spec note_listener_twcc(Runtime.plan_ref(), term(), XMediaLib.Rtcp.Twcc.t(), keyword()) :: :ok
  def note_listener_twcc(plan_ref, listener_id, twcc, opts \\ []) when is_list(opts) do
    bitrate_cap = Keyword.get(opts, :bitrate_cap)

    with %{twcc_send_map: send_map} = _egress when is_map(send_map) <-
           Runtime.get_mcu_egress(plan_ref, listener_id),
         {:ok, packets} <- TwccFci.parse(twcc) do
      prev = Map.get(Runtime.get_mcu_twcc(plan_ref), listener_id, %{})
      base = Map.get(prev, :bps) || @default_opus_bps

      {bps, state} =
        TwccBwe.estimate_bps(packets, send_map, twcc.ref_time, prev, base,
          bitrate_cap: bitrate_cap,
          floor_bps: @floor_bps,
          ceil_bps: @ceil_bps
        )

      next = Map.put(Runtime.get_mcu_twcc(plan_ref), listener_id, Map.put(state, :bps, bps))
      _ = Runtime.put_mcu_twcc(plan_ref, next)
      apply_bitrates(plan_ref, bitrate_cap)
    else
      _ -> :ok
    end
  end

  @doc """
  Sets each Opus encode group's `target_bps` from min of TWCC/REMB of bound listeners.

  Per listener: use `twcc.bps` when present, else REMB. Group target is the min
  of those rates (then `bitrate_cap`). Called from REMB/TWCC notes and from
  egress when a listener first binds to a group.
  """
  @spec apply_bitrates(Runtime.plan_ref(), non_neg_integer() | nil) :: :ok
  def apply_bitrates(plan_ref, bitrate_cap) do
    Runtime.ensure_table!()
    remb = Runtime.get_mcu_remb(plan_ref)
    twcc = Runtime.get_mcu_twcc(plan_ref)

    plan_ref
    |> match_encode_groups()
    |> Enum.each(fn {group_key, group} ->
      listeners = listeners_for_group(plan_ref, group_key)

      rates =
        listeners
        |> Enum.map(fn id -> listener_rate(twcc, remb, id) end)
        |> Enum.filter(&(is_integer(&1) and &1 >= 0))

      if rates != [] do
        target = min_bitrate(rates, bitrate_cap)
        apply_group_bitrate(plan_ref, group_key, group, target)
      end
    end)

    :ok
  end

  defp listener_rate(twcc, remb, id) do
    t =
      case Map.get(twcc, id) do
        %{bps: bps} when is_integer(bps) and bps >= 0 -> bps
        _ -> nil
      end

    r = Map.get(remb, id)

    case {t, r} do
      {t, r} when is_integer(t) and is_integer(r) and r >= 0 -> min(t, r)
      {t, _} when is_integer(t) -> t
      {_, r} when is_integer(r) and r >= 0 -> r
      _ -> nil
    end
  end

  defp due_sr?(%{last_sr_ms: nil}, _now, _interval), do: true
  defp due_sr?(%{last_sr_ms: last}, now, interval) when is_integer(last), do: now - last >= interval
  defp due_sr?(_, _, _), do: true

  defp ntp_now(now_ms) when is_integer(now_ms) do
    sec = div(now_ms, 1000) + @unix_to_ntp_sec
    ms = rem(now_ms, 1000)
    frac = div(ms * 0x1_0000_0000, 1000)
    bor(bsl(sec, 32), frac)
  end

  defp min_bitrate(rates, nil), do: Enum.min(rates)

  defp min_bitrate(rates, cap) when is_integer(cap) and cap > 0 do
    min(Enum.min(rates), cap)
  end

  defp min_bitrate(rates, _), do: Enum.min(rates)

  defp listeners_for_group(plan_ref, group_key) do
    :ets.match_object(:xylon_conference_runtime, {{plan_ref, :mcu_egress, :_}, :_})
    |> Enum.flat_map(fn {{_pr, :mcu_egress, id}, egress} ->
      if Map.get(egress, :group_key) == group_key, do: [id], else: []
    end)
  end

  defp match_encode_groups(plan_ref) do
    :ets.match_object(:xylon_conference_runtime, {{plan_ref, :mcu_encode_group, :_}, :_})
    |> Enum.map(fn {{_pr, :mcu_encode_group, key}, group} -> {key, group} end)
  end

  defp apply_group_bitrate(plan_ref, group_key, group, target) do
    {{name, _fmtp, _rate, _ch}, _excl} = group_key

    if String.downcase(to_string(name)) == "opus" and Map.get(group, :target_bps) != target do
      case Map.get(group, :codec_pid) do
        pid when is_pid(pid) ->
          case Codec.set_bitrate(pid, target) do
            :ok ->
              _ =
                Runtime.put_mcu_encode_group(plan_ref, group_key, %{
                  group
                  | target_bps: target,
                    applied_bps: target
                })

              :ok

            _ ->
              _ = Runtime.put_mcu_encode_group(plan_ref, group_key, %{group | target_bps: target})
              :ok
          end

        _ ->
          :ok
      end
    else
      :ok
    end
  end
end
