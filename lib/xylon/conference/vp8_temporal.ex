defmodule Xylon.Conference.Vp8Temporal do
  @moduledoc """
  VP8 payload-descriptor temporal layer (TID) helpers for SFU forward filtering.

  ## What problem this solves

  Simulcast VP8 often carries temporal scalability inside one SSRC (TID 0..2).
  Subscribers with a max temporal opt should receive only packets at or below
  that TID. This module parses the RFC 7741 descriptor and decides drop vs
  forward without rewriting the payload.

  ## Internal

  Used by `Xylon.Conference.Backend` before `Rewrite.apply/2`. Non-VP8 codecs
  never drop here.

  ## RFCs

  - [RFC 7741](https://www.rfc-editor.org/rfc/rfc7741) (VP8 payload format)
  """

  alias XMediaLib.Rtp

  @doc """
  Reads temporal layer id from a VP8 RTP payload.

  Returns `{:ok, tid}` when the T bit is set, `:none` when the descriptor has
  no TID octet (treat as base layer / always forward), or `:error` when the
  payload is too short to parse.

  ## Examples

      iex> Xylon.Conference.Vp8Temporal.tid(<<0x80, 0x20, 0x40, 0x00>>)
      {:ok, 1}

      iex> Xylon.Conference.Vp8Temporal.tid(<<0x10, 0x00>>)
      :none
  """
  @spec tid(binary()) :: {:ok, 0..3} | :none | :error
  def tid(<<x::1, _r::1, _n::1, _s::1, _r2::1, _pid::3, rest::binary>>) do
    if x == 1 do
      parse_x_octet(rest)
    else
      :none
    end
  end

  def tid(_), do: :error

  @doc """
  True when this RTP packet should not be forwarded for `max_temporal`.

  `max_temporal` of `nil` means no filter. Non-VP8 `codec` never drops.
  Missing TID (`:none`) is treated as TID 0 (forward when max >= 0).
  """
  @spec drop?(Rtp.t() | binary(), non_neg_integer() | nil, String.t() | atom() | nil) ::
          boolean()
  def drop?(_payload_or_rtp, nil, _codec), do: false

  def drop?(rtp_or_payload, max_temporal, codec)
      when is_integer(max_temporal) and max_temporal >= 0 do
    if vp8?(codec) do
      payload = payload_bin(rtp_or_payload)

      case tid(payload) do
        {:ok, tid} -> tid > max_temporal
        :none -> false
        :error -> false
      end
    else
      false
    end
  end

  defp vp8?(codec) when is_binary(codec), do: String.downcase(codec) == "vp8"
  defp vp8?(codec) when is_atom(codec), do: codec == :VP8 or codec == :vp8
  defp vp8?(_), do: false

  defp payload_bin(%Rtp{payload: p}) when is_binary(p), do: p
  defp payload_bin(bin) when is_binary(bin), do: bin
  defp payload_bin(_), do: <<>>

  defp parse_x_octet(<<i::1, l::1, t::1, k::1, _rsv::4, rest::binary>>) do
    rest
    |> skip_picture_id(i)
    |> skip_tl0(l)
    |> read_tid_octet(t, k)
  end

  defp parse_x_octet(_), do: :error

  defp skip_picture_id(rest, 0), do: rest
  defp skip_picture_id(<<1::1, _pid::15, rest::binary>>, 1), do: rest
  defp skip_picture_id(<<0::1, _pid::7, rest::binary>>, 1), do: rest
  defp skip_picture_id(_, 1), do: :error

  defp skip_tl0(:error, _), do: :error
  defp skip_tl0(rest, 0), do: rest
  defp skip_tl0(<<_tl0, rest::binary>>, 1), do: rest
  defp skip_tl0(_, 1), do: :error

  defp read_tid_octet(:error, _, _), do: :error
  defp read_tid_octet(_rest, 0, 0), do: :none
  defp read_tid_octet(<<tid::2, _y::1, _key::5, _::binary>>, t, k) when t == 1 or k == 1,
    do: {:ok, tid}

  defp read_tid_octet(_, t, k) when t == 1 or k == 1, do: :error
  defp read_tid_octet(_, _, _), do: :none
end
