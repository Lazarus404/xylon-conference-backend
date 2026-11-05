defmodule Xylon.Conference.Vp9Svc do
  @moduledoc """
  VP9 scalable-video helpers: payload-descriptor layers and forward drop.

  ## What problem this solves

  One-SSRC VP9 SVC (Chrome `scalabilityMode`) embeds spatial and temporal
  layer ids in the RFC 7798 payload descriptor. The SFU forwards only packets
  at or below each subscriber's `spatial_layer` / `temporal_layer` caps.
  When a Dependency Descriptor extension is present and parseable (lab or
  Chrome with cached structure), those layers win over the payload descriptor.

  SIM VP9 (multi-SSRC `layers`) stays on the existing substream path -- this
  module does not filter those tracks.

  ## Internal

  Used by `Xylon.Conference.Backend` before `Rewrite.apply/2`.

  ## RFCs

  - [RFC 7798](https://www.rfc-editor.org/rfc/rfc7798) (VP9 payload format)
  - Dependency Descriptor URI (AV1 RTP spec); parse via
    `XMediaLib.Rtp.DependencyDescriptor` when the extension is present
  """

  alias XMediaLib.Rtp
  alias XMediaLib.Rtp.DependencyDescriptor

  @doc """
  True when the published track is VP9 without SIM `layers` (one-SSRC SVC path).
  """
  @spec svc_mode?(map() | String.t() | atom() | nil, term()) :: boolean()
  def svc_mode?(track_or_codec, layers \\ nil)

  def svc_mode?(%{} = track, _) do
    codec = Map.get(track, :codec)
    layers = Map.get(track, :layers)
    vp9?(codec) and not sim_layers?(layers)
  end

  def svc_mode?(codec, layers), do: vp9?(codec) and not sim_layers?(layers)

  @doc """
  Reads spatial / temporal layer ids from a VP9 payload descriptor.

  Returns `{:ok, %{spatial: 0..7, temporal: 0..7, e?: boolean()}}` when the L
  bit is set, `:none` when layer indices are absent, or `:error` when truncated.

  ## Examples

      iex> # L=1, no PictureID: first octet 0x20, layer octet TID=1 SID=0
      iex> Xylon.Conference.Vp9Svc.layers(<<0x20, 0x20, 0x00>>)
      {:ok, %{spatial: 0, temporal: 1, e?: false}}

      iex> Xylon.Conference.Vp9Svc.layers(<<0x00, 0x00>>)
      :none
  """
  @spec layers(binary()) ::
          {:ok, %{spatial: non_neg_integer(), temporal: non_neg_integer(), e?: boolean()}}
          | :none
          | :error
  def layers(<<i::1, _p::1, l::1, _f::1, _b::1, e::1, _v::1, _z::1, rest::binary>>) do
    if l == 1 do
      rest
      |> skip_picture_id(i)
      |> read_layer_indices(e == 1)
    else
      :none
    end
  end

  def layers(_), do: :error

  @doc """
  True when this RTP packet should not be forwarded for the given caps.

  `max_spatial` / `max_temporal` of `nil` mean no cap on that axis.
  Non-SVC (wrong codec or SIM layers) never drops.
  When `dd_ext_id` is set and DD layers parse, those win; otherwise PD.
  Opts may include `:descriptor` (`%{spatial: _, temporal: _}`) to skip re-parse.
  """
  @spec drop?(
          Rtp.t(),
          non_neg_integer() | nil,
          non_neg_integer() | nil,
          keyword()
        ) :: boolean()
  def drop?(rtp, max_spatial, max_temporal, opts \\ [])

  def drop?(_rtp, nil, nil, _opts), do: false

  def drop?(rtp, max_spatial, max_temporal, opts)
      when (is_nil(max_spatial) or is_integer(max_spatial)) and
             (is_nil(max_temporal) or is_integer(max_temporal)) do
    codec = Keyword.get(opts, :codec)
    layers_list = Keyword.get(opts, :layers)
    dd_ext_id = Keyword.get(opts, :dd_ext_id)
    structure = Keyword.get(opts, :structure)
    descriptor = Keyword.get(opts, :descriptor)

    if svc_mode?(codec, layers_list) do
      case resolve_layers(rtp, dd_ext_id, structure, descriptor) do
        {:ok, %{spatial: s, temporal: t}} ->
          over_spatial?(s, max_spatial) or over_temporal?(t, max_temporal)

        :none ->
          false

        :error ->
          false
      end
    else
      false
    end
  end

  defp resolve_layers(_rtp, _dd_ext_id, _structure, %{spatial: s, temporal: t})
       when is_integer(s) and is_integer(t) do
    {:ok, %{spatial: s, temporal: t}}
  end

  defp resolve_layers(%Rtp{} = rtp, dd_ext_id, structure, _)
       when is_integer(dd_ext_id) and dd_ext_id > 0 do
    case DependencyDescriptor.read_layers(rtp, dd_ext_id, structure) do
      {:ok, layers} -> {:ok, layers}
      _ -> pd_layers(rtp)
    end
  end

  defp resolve_layers(rtp, _, _, _), do: pd_layers(rtp)

  defp pd_layers(%Rtp{payload: payload}) when is_binary(payload), do: layers(payload)
  defp pd_layers(bin) when is_binary(bin), do: layers(bin)
  defp pd_layers(_), do: :error

  defp over_spatial?(_s, nil), do: false
  defp over_spatial?(s, max) when is_integer(max), do: s > max

  defp over_temporal?(_t, nil), do: false
  defp over_temporal?(t, max) when is_integer(max), do: t > max

  defp vp9?(codec) when is_binary(codec), do: String.downcase(codec) == "vp9"
  defp vp9?(codec) when is_atom(codec), do: codec in [:VP9, :vp9]
  defp vp9?(_), do: false

  defp sim_layers?(layers) when is_list(layers) and layers != [], do: true
  defp sim_layers?(_), do: false

  defp skip_picture_id(rest, 0), do: rest
  defp skip_picture_id(<<0::1, _pid::7, rest::binary>>, 1), do: rest
  defp skip_picture_id(<<1::1, _pid::15, rest::binary>>, 1), do: rest
  defp skip_picture_id(_, 1), do: :error

  defp read_layer_indices(:error, _), do: :error

  defp read_layer_indices(<<tid::3, _u::1, sid::3, _d::1, _::binary>>, e?) do
    {:ok, %{spatial: sid, temporal: tid, e?: e?}}
  end

  defp read_layer_indices(_, _), do: :error
end
