defmodule Xylon.Conference.Rewrite do
  @moduledoc """
  Pure RTP header rewrite for SFU fanout.

  ## What problem this solves

  Each browser expects RTP packets with SSRC, sequence number, and timestamp
  values that belong to *its* negotiated session. When an SFU forwards one
  publisher's packets to many subscribers, it must give each subscriber a
  distinct outbound SSRC and a continuous sequence/timestamp stream. This module
  performs that header rewrite on decrypted RTP (after [XGW](https://github.com/Lazarus404/xgw)
  SRTP termination). Payload bytes are copied unchanged.

  Publisher-specific header extensions (transport-wide congestion control,
  abs-send-time, and similar) are stripped so they do not confuse subscriber
  playout. The Backend may re-stamp subscriber-negotiated transport-cc and
  Dependency Descriptor after rewrite. SRTP encryption on the wire is handled
  by XGW on send; rewrite runs on plaintext `%XMediaLib.Rtp{}` structs only.

  **Internal:** called from `Xylon.Conference.Backend.handle_rtp/3` for each
  fanout route. State is stored in `Xylon.Conference.Plan`.

  ## RFCs

  - [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) (RTP header fields: SSRC, sequence, timestamp)
  - [RFC 3711](https://www.rfc-editor.org/rfc/rfc3711) (SRTP on the wire; rewrite applies before re-encryption)
  """

  alias XMediaLib.Rtp

  @typedoc """
  Per-route rewrite state persisted in `Xylon.Conference.Plan`.

  ## Fields

  - `:out_ssrc` -- SSRC written on packets sent to this subscriber
  - `:last_in_seq` -- last publisher sequence number seen on this route
  - `:last_out_seq` -- last rewritten sequence number sent to the subscriber
  - `:last_in_ts` -- last publisher RTP timestamp seen on this route
  - `:last_out_ts` -- last rewritten timestamp sent to the subscriber
  """
  @type rewrite_state :: Xylon.Conference.Plan.rewrite_state()

  @doc """
  Extracts SSRC from an `%XMediaLib.Rtp{}` struct or map.

  Returns `nil` when the value is missing or not an integer.

  ## Examples

      iex> Xylon.Conference.Rewrite.rtp_ssrc(%{ssrc: 4242})
      4242

      iex> Xylon.Conference.Rewrite.rtp_ssrc(%{})
      nil
  """
  @spec rtp_ssrc(term()) :: non_neg_integer() | nil
  def rtp_ssrc(%Rtp{ssrc: ssrc}) when is_integer(ssrc), do: ssrc
  def rtp_ssrc(%{ssrc: ssrc}) when is_integer(ssrc), do: ssrc
  def rtp_ssrc(_), do: nil

  @doc """
  Extracts RTP sequence number from an `%XMediaLib.Rtp{}` struct or map.

  Returns `nil` when missing or not an integer.
  """
  @spec rtp_seq(term()) :: non_neg_integer() | nil
  def rtp_seq(%Rtp{sequence_number: seq}) when is_integer(seq), do: seq
  def rtp_seq(%{sequence_number: seq}) when is_integer(seq), do: seq
  def rtp_seq(_), do: nil

  @doc """
  Rewrites one RTP packet for a subscriber route.

  Sets outbound SSRC from state, remaps sequence number and timestamp by
  preserving deltas from the previous packet on the route, and strips header
  extensions and CSRC list.

  Returns `{packet, updated_state}`.

  ## Examples

      iex> alias XMediaLib.Rtp
      iex> rtp = %Rtp{sequence_number: 10, timestamp: 1000, ssrc: 4242, payload: "hi"}
      iex> state = %{out_ssrc: 9999, last_in_seq: nil, last_out_seq: nil, last_in_ts: nil, last_out_ts: nil}
      iex> {out, _state} = Xylon.Conference.Rewrite.apply(rtp, state)
      iex> out.ssrc
      9999
      iex> out.sequence_number
      10
  """
  @spec apply(term(), rewrite_state()) :: {term(), rewrite_state()}
  def apply(rtp, %{out_ssrc: out_ssrc} = state) do
    in_seq = seq(rtp)
    in_ts = timestamp(rtp)

    {out_seq, state} = map_seq(state, in_seq)
    {out_ts, state} = map_ts(state, in_ts)

    packet =
      rtp
      |> put_ssrc(out_ssrc)
      |> put_seq(out_seq)
      |> put_ts(out_ts)
      |> strip_extensions()

    {packet, state}
  end

  @doc """
  Advances inbound seq/timestamp tracking without emitting a packet.

  Used when a packet is dropped (e.g. VP8 TID filter) so the next forwarded
  packet keeps a contiguous outbound sequence (delta from last *seen* inbound).
  """
  @spec note_inbound(term(), rewrite_state()) :: rewrite_state()
  def note_inbound(rtp, state) do
    in_seq = seq(rtp)
    in_ts = timestamp(rtp)

    state
    |> maybe_put_last_in_seq(in_seq)
    |> maybe_put_last_in_ts(in_ts)
  end

  defp maybe_put_last_in_seq(state, in_seq) when is_integer(in_seq),
    do: %{state | last_in_seq: in_seq}

  defp maybe_put_last_in_seq(state, _), do: state

  defp maybe_put_last_in_ts(state, in_ts) when is_integer(in_ts),
    do: %{state | last_in_ts: in_ts}

  defp maybe_put_last_in_ts(state, _), do: state

  defp map_seq(%{last_in_seq: nil} = state, in_seq) when is_integer(in_seq) do
    {in_seq, %{state | last_in_seq: in_seq, last_out_seq: in_seq}}
  end

  defp map_seq(%{last_in_seq: last_in, last_out_seq: last_out} = state, in_seq)
       when is_integer(in_seq) and is_integer(last_in) and is_integer(last_out) do
    delta = rem(in_seq - last_in + 65_536, 65_536)
    out = rem(last_out + delta, 65_536)
    {out, %{state | last_in_seq: in_seq, last_out_seq: out}}
  end

  defp map_seq(state, _), do: {0, state}

  defp map_ts(%{last_in_ts: nil} = state, in_ts) when is_integer(in_ts) do
    {in_ts, %{state | last_in_ts: in_ts, last_out_ts: in_ts}}
  end

  defp map_ts(%{last_in_ts: last_in, last_out_ts: last_out} = state, in_ts)
       when is_integer(in_ts) and is_integer(last_in) and is_integer(last_out) do
    delta = in_ts - last_in
    out = last_out + delta
    {out, %{state | last_in_ts: in_ts, last_out_ts: out}}
  end

  defp map_ts(state, _), do: {0, state}

  defp seq(%Rtp{sequence_number: s}) when is_integer(s), do: s
  defp seq(%{sequence_number: s}) when is_integer(s), do: s
  defp seq(_), do: nil

  defp timestamp(%Rtp{timestamp: t}) when is_integer(t), do: t
  defp timestamp(%{timestamp: t}) when is_integer(t), do: t
  defp timestamp(_), do: nil

  defp put_ssrc(%Rtp{} = rtp, ssrc), do: %{rtp | ssrc: ssrc}
  defp put_ssrc(%{} = rtp, ssrc), do: Map.put(rtp, :ssrc, ssrc)
  defp put_ssrc(rtp, _), do: rtp

  defp put_seq(%Rtp{} = rtp, seq), do: %{rtp | sequence_number: seq}
  defp put_seq(%{} = rtp, seq), do: Map.put(rtp, :sequence_number, seq)
  defp put_seq(rtp, _), do: rtp

  defp put_ts(%Rtp{} = rtp, ts), do: %{rtp | timestamp: ts}
  defp put_ts(%{} = rtp, ts), do: Map.put(rtp, :timestamp, ts)
  defp put_ts(rtp, _), do: rtp

  defp strip_extensions(%Rtp{} = rtp), do: %{rtp | extension: nil, csrcs: []}

  defp strip_extensions(%{} = rtp) do
    rtp
    |> Map.put(:extension, nil)
    |> Map.put(:csrcs, [])
  end

  defp strip_extensions(rtp), do: rtp
end
