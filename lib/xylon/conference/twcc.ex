defmodule Xylon.Conference.Twcc do
  @moduledoc """
  Transport-wide CC arrival recording and feedback toward publishers.

  ## What problem this solves

  Browsers that negotiate `transport-cc` expect periodic RTPFB fmt-15 feedback
  naming which transport-wide sequence numbers arrived and when. The SFU records
  those sequences from publisher inbound RTP (before rewrite strips extensions)
  and emits `%XMediaLib.Rtcp.Twcc{}` toward the publisher Peer. Arrival times
  prefer `Process.get(:xylon_rtp_arrival_us)` (stamped at Listener demux, then
  carried through `XGW.Peer.deliver/4` and the Forwarder) so Peer/Forwarder
  mailbox delay is not reported as network delay to Chrome BWE. Feedback FCI is
  packed with `XMediaLib.Rtcp.TwccFci.pack/1` over a **uint16 wrap-aware**
  newest window (at most 64 packets) so seq wrap or wide holes cannot report
  massive fake loss to Chrome GCC. The first recv delta is the 64ms remainder of
  the arrival stamp (`Integer.mod(us, 64_000)`), not `us - ref_time*64_000`, so
  BEAM monotonic values outside the 24-bit ref_time range (negative or >~12d)
  cannot clamp every feedback to +/-8.192s. Feedback is not generated toward
  subscribers; outbound fanout keeps extensions stripped.

  **Internal:** driven from `Xylon.Conference.Backend.handle_rtp/3`.

  ## RFCs

  - [draft-holmer-rmcat-transport-wide-cc-extensions](https://datatracker.ietf.org/doc/html/draft-holmer-rmcat-transport-wide-cc-extensions)
  - [RFC 4585](https://www.rfc-editor.org/rfc/rfc4585) (RTPFB container)
  """

  require Logger

  alias XGW.Peer
  alias Xylon.Conference.Plan
  alias Xylon.Participant
  alias XMediaLib.Rtp
  alias XMediaLib.Rtp.HeaderExtension
  alias XMediaLib.Rtcp, as: RtcpPacket
  alias XMediaLib.Rtcp.TwccFci

  @transport_cc_uri "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"
  @delta_us 250
  @small_max_units 255
  @large_max_units 32_767
  @large_min_units -32_768
  @ref_period_us 64_000
  @ref_time_mod 0x1000000
  @seq_mod 0x10000
  @max_status_count 64
  @max_arrival_age_us 500_000
  @loss_warn_ratio 0.05
  @loss_warn_interval_ms 5_000

  @doc "SDP extmap URI for transport-wide congestion control."
  @spec uri() :: String.t()
  def uri, do: @transport_cc_uri

  @doc """
  Reads the transport-wide sequence number from a one-byte RTP extension block.

  Returns `{:ok, seq}` or `:error`.
  """
  @spec read_seq(term(), pos_integer()) :: {:ok, non_neg_integer()} | :error
  def read_seq(rtp, ext_id) when is_integer(ext_id) and ext_id > 0 do
    with %Rtp.Extension{type: 0xBEDE, payload: payload} <- extension(rtp),
         elements <- HeaderExtension.decode_one_byte_elements(payload),
         {^ext_id, <<seq::unsigned-size(16)>>} <-
           Enum.find(elements, fn {id, _} -> id == ext_id end) do
      {:ok, seq}
    else
      _ -> :error
    end
  end

  def read_seq(_, _), do: :error

  @doc """
  Appends an arrival `{twcc_seq, arrival_us}` for `publisher_id`.
  """
  @spec record(map(), term(), non_neg_integer(), integer()) :: map()
  def record(arrivals, publisher_id, seq, arrival_us)
      when is_map(arrivals) and is_integer(seq) and is_integer(arrival_us) do
    list = Map.get(arrivals, publisher_id, [])
    Map.put(arrivals, publisher_id, [{seq, arrival_us} | list])
  end

  @doc """
  Builds and sends Twcc feedback for `publisher_id` when arrivals exist.

  Drops arrivals older than 500 ms before encoding. Returns updated
  `{arrivals, fb_counts}` with that publisher's queue cleared and feedback
  count incremented on send.
  """
  @spec flush(Plan.plan_ref(), term(), map(), map()) :: {map(), map()}
  def flush(plan_ref, publisher_id, arrivals, fb_counts)
      when is_map(arrivals) and is_map(fb_counts) do
    case Map.get(arrivals, publisher_id, []) do
      [] ->
        {arrivals, fb_counts}

      list ->
        now_us = System.monotonic_time(:microsecond)

        samples =
          list
          |> Enum.filter(fn {_seq, us} -> now_us - us <= @max_arrival_age_us end)
          |> Enum.uniq_by(fn {seq, _} -> seq end)

        case samples do
          [] ->
            {Map.delete(arrivals, publisher_id), fb_counts}

          _ ->
            case encode_and_send(plan_ref, publisher_id, samples, fb_counts) do
              {:ok, fb_counts} ->
                {Map.delete(arrivals, publisher_id), fb_counts}

              :error ->
                {arrivals, fb_counts}
            end
        end
    end
  end

  @doc false
  @spec feedback_fields([{non_neg_integer(), integer()}]) ::
          %{
            base_seq: non_neg_integer(),
            status_count: non_neg_integer(),
            ref_time: non_neg_integer(),
            fci: binary(),
            not_received: non_neg_integer()
          }
  def feedback_fields(samples) when is_list(samples) and samples != [] do
    by_seq =
      samples
      |> Enum.uniq_by(fn {seq, _} -> seq end)
      |> Map.new()

    {newest_seq, _newest_us} = Enum.max_by(by_seq, fn {_seq, us} -> us end)

    in_window =
      Enum.filter(by_seq, fn {seq, _} ->
        seq_distance_back(newest_seq, seq) < @max_status_count
      end)

    {base_seq, _} =
      Enum.max_by(in_window, fn {seq, _} -> seq_distance_back(newest_seq, seq) end)

    status_count = seq_distance_back(newest_seq, base_seq) + 1

    first_us =
      Enum.find_value(0..(status_count - 1), fn i ->
        case Map.get(by_seq, seq_add(base_seq, i)) do
          nil -> nil
          us -> us
        end
      end) || Map.fetch!(by_seq, newest_seq)

    # ref_time is only 24 bits of 64ms ticks. Never rebuild the first recv
    # delta as `us - ref_time*64ms` -- that drops high bits of BEAM monotonic
    # time (often largely negative) and clamps to +/-8.192s every feedback.
    ref_time = Integer.mod(Integer.floor_div(first_us, @ref_period_us), @ref_time_mod)
    items = pack_items(base_seq, status_count, by_seq, first_us)
    not_received = Enum.count(items, &(&1 == :not_received))
    fci = TwccFci.pack(items)

    %{
      base_seq: base_seq,
      status_count: status_count,
      ref_time: ref_time,
      fci: fci,
      not_received: not_received
    }
  end

  defp encode_and_send(plan_ref, publisher_id, samples, fb_counts) do
    with %Participant{peer_ref: peer} when is_pid(peer) <-
           Plan.get_participant(plan_ref, publisher_id),
         media_ssrc when is_integer(media_ssrc) <- publisher_media_ssrc(plan_ref, publisher_id),
         true <- samples != [] do
      fb = feedback_fields(samples)
      note_flush_metrics(fb.status_count, fb.not_received)
      fb_count = Map.get(fb_counts, publisher_id, 0)

      twcc = %XMediaLib.Rtcp.Twcc{
        ssrc_s: 1,
        ssrc_m: media_ssrc,
        base_seq: fb.base_seq,
        status_count: fb.status_count,
        ref_time: fb.ref_time,
        fb_count: rem(fb_count, 256),
        fci: fb.fci
      }

      _ = Peer.send_rtcp(peer, %RtcpPacket{payloads: [twcc]})
      {:ok, Map.put(fb_counts, publisher_id, rem(fb_count + 1, 256))}
    else
      _ -> :error
    end
  end

  defp pack_items(base_seq, status_count, by_seq, first_us)
       when is_integer(status_count) and status_count > 0 and is_integer(first_us) do
    # Full-precision 64ms floor; equals first_us - Integer.mod(first_us, 64ms).
    ref_us = first_us - Integer.mod(first_us, @ref_period_us)

    {items, _} =
      Enum.reduce(0..(status_count - 1), {[], :before_first}, fn i, {acc, prev} ->
        seq = seq_add(base_seq, i)

        case Map.get(by_seq, seq) do
          nil ->
            {[:not_received | acc], prev}

          us when prev == :before_first ->
            {[delta_item(us - ref_us) | acc], us}

          us ->
            {[delta_item(us - prev) | acc], us}
        end
      end)

    Enum.reverse(items)
  end

  defp note_flush_metrics(status_count, not_received)
       when is_integer(status_count) and status_count > 0 and is_integer(not_received) do
    packets = Process.get(:xylon_twcc_packets, 0) + status_count
    holes = Process.get(:xylon_twcc_not_received, 0) + not_received
    Process.put(:xylon_twcc_packets, packets)
    Process.put(:xylon_twcc_not_received, holes)

    ratio = not_received / status_count

    if ratio > @loss_warn_ratio do
      now = System.monotonic_time(:millisecond)
      last = Process.get(:xylon_twcc_loss_warn_ms)

      if is_nil(last) or now - last >= @loss_warn_interval_ms do
        Process.put(:xylon_twcc_loss_warn_ms, now)

        Logger.warning(
          "xylon twcc feedback loss_ratio=#{Float.round(ratio * 1.0, 3)} " <>
            "not_received=#{not_received} status_count=#{status_count}"
        )
      end
    end

    :ok
  end

  defp seq_distance_back(newer, older)
       when is_integer(newer) and is_integer(older) do
    rem(newer - older + @seq_mod, @seq_mod)
  end

  defp seq_add(base, offset) when is_integer(base) and is_integer(offset) do
    rem(base + offset, @seq_mod)
  end

  defp delta_item(delta_us) when is_integer(delta_us) do
    units = div(delta_us, @delta_us)

    cond do
      units < 0 ->
        {:received_large, max(units, @large_min_units)}

      units <= @small_max_units ->
        {:received_small, units}

      true ->
        {:received_large, min(units, @large_max_units)}
    end
  end

  defp publisher_media_ssrc(plan_ref, publisher_id) do
    case Plan.find_track_by_kind(plan_ref, publisher_id, :video) do
      %{ssrc: ssrc} when is_integer(ssrc) ->
        ssrc

      _ ->
        case Plan.find_track_by_kind(plan_ref, publisher_id, :audio) do
          %{ssrc: ssrc} when is_integer(ssrc) -> ssrc
          _ -> nil
        end
    end
  end

  defp extension(%Rtp{extension: ext}), do: ext
  defp extension(%{extension: ext}), do: ext
  defp extension(_), do: nil
end
