defmodule Xylon.Conference.Allocator do
  @moduledoc """
  Receive-side adaptive layer recommendations from estimated bitrate.

  ## What problem this solves

  When `adaptive_layers` is enabled on a conference Session, subscriber REMB
  bitrates drive automatic SIM `substream` / VP8 `temporal` or SVC
  `spatial_layer` / `temporal_layer` picks via `set_substream`. Manual app
  configure stays sticky and is never overridden.

  Soft spots: none for receive-side REMB/TWCC min. Uplink Dynacast is opt-in
  (`dynacast: true`, SIM + SDK `encodings.active`).

  ## Internal

  Pure helpers used from `Xylon.Conference.Rtcp` after REMB / TWCC fan-in.

  ## RFCs

  - None directly; consumes REMB / TWCC bitrate estimates already fan-in translated
  """

  @typedoc """
  Sticky layer policy for one subscription.

  ## Fields

  - `:source` -- `:manual` (app configure) or `:adaptive`
  - `:pending` -- last non-applied recommendation, or `nil`
  - `:pending_count` -- consecutive REMB updates matching `:pending`
  """
  @type policy :: %{
          source: :manual | :adaptive,
          pending: map() | nil,
          pending_count: non_neg_integer()
        }

  @substream_high 1_500_000
  @substream_mid 600_000
  @temporal_high 900_000
  @temporal_mid 400_000

  @doc "Fresh policy row (`source` is `:manual` or `:adaptive`)."
  @spec new_policy(:manual | :adaptive) :: policy()
  def new_policy(source) when source in [:manual, :adaptive] do
    %{source: source, pending: nil, pending_count: 0}
  end

  @doc """
  Recommends layer opts from bitrate.

  `attrs` keys: `:bitrate_bps`, `:mode` (`:sim` | `:svc`), `:layer_count`,
  `:codec`, optional `:current` (ignored for the recommendation itself).

  Returns a map of opts suitable for `Plan.set_substream/5` (`substream` /
  `temporal` or `spatial_layer` / `temporal_layer`).
  """
  @spec recommend(map()) :: map()
  def recommend(%{bitrate_bps: bps, mode: :sim, layer_count: n, codec: codec})
      when is_integer(bps) and bps >= 0 and is_integer(n) and n >= 1 do
    max_s = n - 1
    sub = min(substream_for(bps), max_s)

    case temporal_for(bps, codec) do
      nil -> %{substream: sub, temporal: nil}
      t -> %{substream: sub, temporal: t}
    end
  end

  def recommend(%{bitrate_bps: bps, mode: :svc, layer_count: n, codec: codec})
      when is_integer(bps) and bps >= 0 and is_integer(n) and n >= 1 do
    max_s = n - 1
    spatial = min(substream_for(bps), max_s)
    temporal = temporal_for(bps, codec) || temporal_for_any(bps)
    %{spatial_layer: spatial, temporal_layer: temporal}
  end

  def recommend(%{bitrate_bps: bps, mode: :svc, codec: codec})
      when is_integer(bps) and bps >= 0 do
    recommend(%{bitrate_bps: bps, mode: :svc, layer_count: 3, codec: codec})
  end

  def recommend(_), do: %{}

  @doc """
  Hysteresis gate: recommendation must match for two consecutive updates and
  differ from `current` before apply. Manual source never applies.

  Returns `{apply?, updated_policy}`. On apply, clears pending state.
  """
  @spec should_apply?(policy(), map(), map()) :: {boolean(), policy()}
  def should_apply?(%{source: :manual} = policy, _rec, _current), do: {false, policy}

  def should_apply?(%{source: :adaptive} = policy, rec, current)
      when is_map(rec) and is_map(current) do
    rec = normalize_rec(rec)
    current = normalize_rec(current)

    cond do
      rec == %{} ->
        {false, %{policy | pending: nil, pending_count: 0}}

      same_layers?(rec, current) ->
        {false, %{policy | pending: nil, pending_count: 0}}

      policy.pending == rec ->
        count = policy.pending_count + 1

        if count >= 2 do
          {true, %{policy | pending: nil, pending_count: 0}}
        else
          {false, %{policy | pending_count: count}}
        end

      true ->
        {false, %{policy | pending: rec, pending_count: 1}}
    end
  end

  def should_apply?(policy, _, _), do: {false, policy}

  @doc "True when `rec` and `current` agree on all keys present in `rec`."
  @spec same_layers?(map(), map()) :: boolean()
  def same_layers?(rec, current) when is_map(rec) and is_map(current) do
    Enum.all?(normalize_rec(rec), fn {k, v} ->
      Map.get(normalize_rec(current), k) == v
    end)
  end

  defp substream_for(bps) when bps >= @substream_high, do: 2
  defp substream_for(bps) when bps >= @substream_mid, do: 1
  defp substream_for(_), do: 0

  defp temporal_for(bps, codec) do
    if vp8?(codec), do: temporal_for_any(bps), else: nil
  end

  defp temporal_for_any(bps) when bps >= @temporal_high, do: 2
  defp temporal_for_any(bps) when bps >= @temporal_mid, do: 1
  defp temporal_for_any(_), do: 0

  defp vp8?(codec) when is_binary(codec), do: String.downcase(codec) == "vp8"
  defp vp8?(codec) when is_atom(codec), do: codec in [:VP8, :vp8]
  defp vp8?(_), do: false

  defp normalize_rec(rec) when is_map(rec) do
    rec
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
