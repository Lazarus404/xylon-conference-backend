defmodule Xylon.Conference.Bwe.Twcc do
  @moduledoc """
  Shared transport-cc bitrate estimate from loss and delay gradient.

  ## What problem this solves

  MCU mix encode and SFU receive-side adaptive video both need a TWCC-derived
  bitrate. This module holds the estimate math once so MCU and SFU do not
  diverge. Callers supply floor/ceil and optional `bitrate_cap`.

  Also stamps a one-byte transport-cc extension on outbound RTP and trims the
  per-route send map used to correlate feedback FCI rows with send times.

  ## Internal

  Used by `Xylon.Conference.Mcu.Rtcp`, `Xylon.Conference.Rtcp`, and
  `Xylon.Conference.Backend` fanout.

  ## RFCs

  - [draft-holmer-rmcat-transport-wide-cc-extensions](https://datatracker.ietf.org/doc/html/draft-holmer-rmcat-transport-wide-cc-extensions-01)
  """

  alias XMediaLib.Rtp
  alias XMediaLib.Rtp.HeaderExtension

  @one_byte_profile 0xBEDE
  @twcc_send_map_max 512
  @default_cut_factor 85
  @default_grow_factor 105
  @default_grad_up_us 5_000
  @default_loss_cut 0.1

  @typedoc """
  Opaque BWE step state carried between feedback packets.

  ## Fields

  - `:prev_grad_us` -- last median inter-packet delay gradient (us), or `nil`
  """
  @type state :: %{prev_grad_us: integer() | nil}

  @typedoc """
  Per-route TWCC send bookkeeping for correlating feedback.

  ## Fields

  - `:seq` -- next transport-wide sequence to stamp (0..65535)
  - `:send_map` -- `%{twcc_seq => send_us}` for recent outbound packets
  """
  @type send_state :: %{seq: non_neg_integer(), send_map: %{non_neg_integer() => integer()}}

  @doc """
  Steps bitrate from one TWCC feedback window.

  `packets` is the list from `XMediaLib.Rtcp.TwccFci.parse/1`.
  `prev` may include `:prev_grad_us` (and optionally `:bps` ignored here).
  Opts: `:bitrate_cap`, `:floor_bps`, `:ceil_bps`, `:cut_factor`, `:grow_factor`,
  `:grad_up_us`, `:loss_cut`.
  """
  @spec estimate_bps(
          list(),
          map(),
          non_neg_integer() | nil,
          map(),
          pos_integer(),
          keyword()
        ) :: {pos_integer(), state()}
  def estimate_bps(packets, send_map, ref_time, prev, base_bps, opts \\ [])
      when is_list(packets) and is_map(send_map) and is_map(prev) and is_integer(base_bps) and
             base_bps > 0 and is_list(opts) do
    floor_bps = Keyword.get(opts, :floor_bps, 8_000)
    ceil_bps = Keyword.get(opts, :ceil_bps, 128_000)
    cut_factor = Keyword.get(opts, :cut_factor, @default_cut_factor)
    grow_factor = Keyword.get(opts, :grow_factor, @default_grow_factor)
    grad_up_us = Keyword.get(opts, :grad_up_us, @default_grad_up_us)
    loss_cut = Keyword.get(opts, :loss_cut, @default_loss_cut)
    bitrate_cap = Keyword.get(opts, :bitrate_cap)

    total = length(packets)
    lost = Enum.count(packets, fn {_s, st, _} -> st == :not_received end)
    loss = if total > 0, do: lost / total, else: 0.0

    grads = delay_gradients(packets, send_map, ref_time)
    median_grad = median(grads)
    prev_grad = Map.get(prev, :prev_grad_us)

    congested? =
      loss >= loss_cut or
        (is_integer(median_grad) and median_grad >= grad_up_us) or
        (is_integer(median_grad) and is_integer(prev_grad) and
           median_grad - prev_grad >= grad_up_us)

    bps =
      cond do
        congested? ->
          div(base_bps * cut_factor, 100)

        loss == 0.0 and grads != [] and not congested? ->
          div(base_bps * grow_factor, 100)

        true ->
          base_bps
      end

    ceil =
      if is_integer(bitrate_cap) and bitrate_cap > 0,
        do: min(bitrate_cap, ceil_bps),
        else: ceil_bps

    bps = max(floor_bps, min(ceil, bps))
    {bps, %{prev_grad_us: median_grad || prev_grad}}
  end

  @doc """
  Stamps transport-cc on `rtp` and advances `send_state`.

  When `ext_id` is not a one-byte id (1..14), returns `{rtp, send_state}` unchanged.
  Merges with any existing header extension elements.
  """
  @spec stamp_extension(Rtp.t(), pos_integer() | nil, send_state(), integer()) ::
          {Rtp.t(), send_state()}
  def stamp_extension(%Rtp{} = rtp, ext_id, send_state, now_us)
      when is_integer(now_us) and is_map(send_state) do
    case ext_id do
      id when is_integer(id) and id >= 1 and id <= 14 ->
        seq = Map.get(send_state, :seq, 0) || 0

        send_map =
          send_state
          |> Map.get(:send_map, %{})
          |> Map.put(seq, now_us)
          |> trim_send_map()

        next = %{seq: rem(seq + 1, 65_536), send_map: send_map}
        {put_twcc_element(rtp, id, seq), next}

      _ ->
        {rtp, send_state}
    end
  end

  @doc "Empty send bookkeeping for a new route."
  @spec empty_send_state() :: send_state()
  def empty_send_state, do: %{seq: 0, send_map: %{}}

  @doc "Trims send map to the newest #{@twcc_send_map_max} entries by send time."
  @spec trim_send_map(map()) :: map()
  def trim_send_map(map) when is_map(map) and map_size(map) <= @twcc_send_map_max, do: map

  def trim_send_map(map) when is_map(map) do
    drop = map_size(map) - @twcc_send_map_max

    map
    |> Enum.sort_by(fn {_seq, us} -> us end)
    |> Enum.drop(drop)
    |> Map.new()
  end

  defp put_twcc_element(%Rtp{} = rtp, ext_id, seq) do
    data = <<seq::unsigned-size(16)>>

    {profile, elements} =
      case rtp.extension do
        %{type: type, payload: payload} when is_binary(payload) ->
          {type, HeaderExtension.decode_elements(type, payload)}

        _ ->
          {@one_byte_profile, []}
      end

    elements2 = [{ext_id, data} | Enum.reject(elements, fn {id, _} -> id == ext_id end)]

    profile2 =
      case HeaderExtension.profile_for(elements2) do
        0x1000 ->
          0x1000

        _ ->
          if is_integer(profile) and Bitwise.band(profile, 0xFFF0) == 0x1000 do
            profile
          else
            @one_byte_profile
          end
      end

    payload = HeaderExtension.encode_elements(profile2, elements2)
    %{rtp | extension: %Rtp.Extension{type: profile2, payload: payload}}
  end

  defp delay_gradients(packets, send_map, ref_time) do
    ref_us = if is_integer(ref_time), do: ref_time * 64_000, else: 0

    {samples, _} =
      Enum.reduce(packets, {[], ref_us}, fn {seq, status, delta_us}, {acc, cursor} ->
        case {status, delta_us, Map.get(send_map, seq)} do
          {st, d, send_us}
          when st in [:received_small, :received_large] and is_integer(d) and
                 is_integer(send_us) ->
            arrival = cursor + d
            {[{arrival, send_us} | acc], arrival}

          _ ->
            {acc, cursor}
        end
      end)

    samples
    |> Enum.reverse()
    |> pairwise_gradients()
  end

  defp pairwise_gradients([]), do: []
  defp pairwise_gradients([_]), do: []

  defp pairwise_gradients([{a0, s0} | [{a1, s1} | _] = rest]) do
    [(a1 - a0) - (s1 - s0) | pairwise_gradients(rest)]
  end

  defp median([]), do: nil

  defp median(list) do
    sorted = Enum.sort(list)
    mid = div(length(sorted), 2)

    if rem(length(sorted), 2) == 1 do
      Enum.at(sorted, mid)
    else
      div(Enum.at(sorted, mid - 1) + Enum.at(sorted, mid), 2)
    end
  end
end
