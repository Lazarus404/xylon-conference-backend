defmodule Xylon.Conference.Av1Svc do
  @moduledoc """
  AV1 one-SSRC SVC helpers: Dependency Descriptor drop and ADT rewrite.

  ## What problem this solves

  Chrome AV1 `scalabilityMode` publishes one SSRC with a Dependency Descriptor
  extension. The SFU forwards only packets at or below each subscriber's
  `spatial_layer` / `temporal_layer` caps, rewrites the active-decode-target
  bitmask, and drops enhancement after a broken frame chain until a structure
  (key) packet heals it.

  SIM AV1 (multi-SSRC `layers`) stays on the substream path -- this module does
  not filter those tracks. When DD is absent, packets are not dropped (no SVC
  claim).

  Supports Chrome/WebRTC DD bit packing (with a cached structure) and lab
  FakePeer formats (`0xFE` / `0xFD`).

  ## Internal

  Used by `Xylon.Conference.Backend` before `Rewrite.apply/2`.

  ## RFCs

  - [AV1 RTP Dependency Descriptor](https://aomediacodec.github.io/av1-rtp-spec/#dependency-descriptor-rtp-header-extension)
  """

  alias XMediaLib.Rtp
  alias XMediaLib.Rtp.DependencyDescriptor
  alias XMediaLib.Rtp.HeaderExtension

  @accepted_cap 128

  @typedoc """
  Per-route DD chain state.

  ## Fields

  - `:broken?` -- true when enhancement must not be forwarded until structure
  - `:pli_pending?` -- true when a PLI should be sent once for this break
  - `:accepted_frames` -- recent forwarded frame numbers for fdiff checks
  """
  @type chain :: %{
          broken?: boolean(),
          pli_pending?: boolean(),
          accepted_frames: MapSet.t()
        }

  @doc "Fresh chain state (not broken, no PLI pending)."
  @spec new_chain() :: chain()
  def new_chain, do: %{broken?: false, pli_pending?: false, accepted_frames: MapSet.new()}

  @doc "Marks the chain broken and queues a one-shot PLI."
  @spec break_chain(chain()) :: chain()
  def break_chain(chain) when is_map(chain) do
    %{
      broken?: true,
      pli_pending?: true,
      accepted_frames: Map.get(chain, :accepted_frames, MapSet.new())
    }
  end

  @doc "Clears broken / PLI state (e.g. on spatial_layer change before PLI)."
  @spec clear_chain(term()) :: chain()
  def clear_chain(_), do: new_chain()

  @doc "Returns `{pli?, chain}` and clears `:pli_pending?`."
  @spec take_pli?(chain()) :: {boolean(), chain()}
  def take_pli?(%{pli_pending?: pending?} = chain) do
    {pending? == true, %{chain | pli_pending?: false}}
  end

  def take_pli?(_), do: {false, new_chain()}

  @doc """
  True when the published track is AV1 without SIM `layers` (one-SSRC SVC path).
  """
  @spec svc_mode?(map() | String.t() | atom() | nil, term()) :: boolean()
  def svc_mode?(track_or_codec, layers \\ nil)

  def svc_mode?(%{} = track, _) do
    codec = Map.get(track, :codec)
    layers = Map.get(track, :layers)
    av1?(codec) and not sim_layers?(layers)
  end

  def svc_mode?(codec, layers), do: av1?(codec) and not sim_layers?(layers)

  @doc """
  True when this RTP packet should not be forwarded for the given caps.

  Opts: `:dd_ext_id`, `:codec`, `:layers`, `:chain`, `:structure`, `:descriptor`
  (pre-parsed DD map from a publisher-once read; skips re-parse when set).
  """
  @spec drop?(
          Rtp.t(),
          non_neg_integer() | nil,
          non_neg_integer() | nil,
          keyword()
        ) :: boolean()
  def drop?(rtp, max_spatial, max_temporal, opts \\ [])

  def drop?(rtp, nil, nil, opts) do
    chain = Keyword.get(opts, :chain)
    dd_ext_id = Keyword.get(opts, :dd_ext_id)
    structure = Keyword.get(opts, :structure)
    codec = Keyword.get(opts, :codec)
    layers_list = Keyword.get(opts, :layers)
    descriptor = Keyword.get(opts, :descriptor)

    if svc_mode?(codec, layers_list) and
         (broken_enhancement?(rtp, dd_ext_id, chain, structure, descriptor) or
            missing_fdiff_deps?(rtp, dd_ext_id, chain, structure, descriptor)) do
      true
    else
      case resolve_descriptor(rtp, dd_ext_id, structure, descriptor) do
        {:ok, %{dti_not_present?: true}, _} -> true
        {:ok, %{dti_not_present?: true}} -> true
        _ -> false
      end
    end
  end

  def drop?(rtp, max_spatial, max_temporal, opts)
      when (is_nil(max_spatial) or is_integer(max_spatial)) and
             (is_nil(max_temporal) or is_integer(max_temporal)) do
    codec = Keyword.get(opts, :codec)
    layers_list = Keyword.get(opts, :layers)
    dd_ext_id = Keyword.get(opts, :dd_ext_id)
    chain = Keyword.get(opts, :chain)
    structure = Keyword.get(opts, :structure)
    descriptor = Keyword.get(opts, :descriptor)

    if svc_mode?(codec, layers_list) do
      cond do
        broken_enhancement?(rtp, dd_ext_id, chain, structure, descriptor) ->
          true

        missing_fdiff_deps?(rtp, dd_ext_id, chain, structure, descriptor) ->
          true

        true ->
          case resolve_descriptor(rtp, dd_ext_id, structure, descriptor) do
            {:ok, %{dti_not_present?: true}, _} ->
              true

            {:ok, %{dti_not_present?: true}} ->
              true

            {:ok, %{spatial: s, temporal: t}, _} ->
              over_spatial?(s, max_spatial) or over_temporal?(t, max_temporal)

            {:ok, %{spatial: s, temporal: t}} ->
              over_spatial?(s, max_spatial) or over_temporal?(t, max_temporal)

            _ ->
              false
          end
      end
    else
      false
    end
  end

  @doc """
  Updates chain after a forward/drop decision.

  Structure packets heal. Missing fdiff dependencies break the chain.
  Successful forwards record `frame_number` for later fdiff checks.

  Opts: `:dropped?`, `:structure`, `:descriptor` (pre-parsed DD map).
  """
  @spec after_decision(chain(), Rtp.t(), pos_integer() | nil, keyword()) :: chain()
  def after_decision(chain, rtp, dd_ext_id, opts)
      when is_map(chain) and is_list(opts) do
    dropped? = Keyword.get(opts, :dropped?, false)
    structure = Keyword.get(opts, :structure)
    descriptor = Keyword.get(opts, :descriptor)
    chain = normalize_chain(chain)

    case resolve_descriptor(rtp, dd_ext_id, structure, descriptor) do
      {:ok, desc, _struct2} ->
        after_desc(chain, desc, dropped?)

      {:ok, desc} ->
        after_desc(chain, desc, dropped?)

      _ ->
        chain
    end
  end

  @doc """
  Rewrites the DD ADT bitmask on `rtp` for subscriber caps.

  Lab target id = `spatial * 4 + temporal`. Chrome uses the same mask helper
  against the structure's decode-target count when rewriting.
  """
  @spec rewrite_dd(
          Rtp.t(),
          non_neg_integer() | nil,
          non_neg_integer() | nil,
          pos_integer() | nil
        ) :: {Rtp.t(), DependencyDescriptor.structure() | nil}
  def rewrite_dd(rtp, max_spatial, max_temporal, dd_ext_id) do
    rewrite_dd(rtp, max_spatial, max_temporal, dd_ext_id, [])
  end

  @spec rewrite_dd(
          Rtp.t(),
          non_neg_integer() | nil,
          non_neg_integer() | nil,
          pos_integer() | nil,
          keyword()
        ) :: {Rtp.t(), DependencyDescriptor.structure() | nil}
  def rewrite_dd(%Rtp{} = rtp, max_spatial, max_temporal, dd_ext_id, opts)
      when is_integer(dd_ext_id) and dd_ext_id > 0 and is_list(opts) do
    mask = adt_mask(max_spatial, max_temporal)
    structure = Keyword.get(opts, :structure)

    case extension_raw(rtp, dd_ext_id) do
      data when is_binary(data) ->
        case DependencyDescriptor.rewrite_active_decode_targets(data, mask, structure) do
          {:ok, new_data, struct2} ->
            {DependencyDescriptor.put_extension(rtp, dd_ext_id, new_data), struct2}

          :error ->
            case DependencyDescriptor.rewrite_active_decode_targets(data, mask) do
              {:ok, new_data} ->
                {DependencyDescriptor.put_extension(rtp, dd_ext_id, new_data), structure}

              :error ->
                {rtp, structure}
            end
        end

      _ ->
        {rtp, structure}
    end
  end

  def rewrite_dd(rtp, _, _, _, _), do: {rtp, nil}

  @doc """
  ADT bitmask for targets with spatial/temporal at or below caps.

  Target index = `spatial * 4 + temporal` (temporal 0..3).
  """
  @spec adt_mask(non_neg_integer() | nil, non_neg_integer() | nil) :: non_neg_integer()
  def adt_mask(nil, nil), do: 0xFFFFFFFF

  def adt_mask(max_spatial, max_temporal) do
    max_s = max_spatial || 7
    max_t = min(max_temporal || 3, 3)

    Enum.reduce(0..max_s, 0, fn s, acc_s ->
      Enum.reduce(0..max_t, acc_s, fn t, acc ->
        Bitwise.bor(acc, Bitwise.bsl(1, s * 4 + t))
      end)
    end)
  end

  defp after_desc(chain, desc, dropped?) do
    cond do
      not dropped? and desc.structure? ->
        %{
          broken?: false,
          pli_pending?: false,
          accepted_frames: accept_frame(MapSet.new(), desc.frame_number)
        }

      missing_deps_in_desc?(desc, chain) and not desc.structure? ->
        break_chain(chain)

      not dropped? ->
        %{chain | accepted_frames: accept_frame(chain.accepted_frames, desc.frame_number)}

      true ->
        chain
    end
  end

  defp missing_fdiff_deps?(rtp, dd_ext_id, chain, structure, descriptor) do
    case resolve_descriptor(rtp, dd_ext_id, structure, descriptor) do
      {:ok, desc, _} -> missing_deps_in_desc?(desc, normalize_chain(chain || new_chain()))
      {:ok, desc} -> missing_deps_in_desc?(desc, normalize_chain(chain || new_chain()))
      _ -> false
    end
  end

  defp missing_deps_in_desc?(%{fdiffs: fdiffs, frame_number: fn_} = desc, chain)
       when is_list(fdiffs) and fdiffs != [] and is_integer(fn_) do
    if desc.structure? do
      false
    else
      accepted = Map.get(chain, :accepted_frames, MapSet.new())

      Enum.any?(fdiffs, fn d ->
        dep = rem(fn_ - d + 65536, 65536)
        not MapSet.member?(accepted, dep)
      end)
    end
  end

  defp missing_deps_in_desc?(_, _), do: false

  defp accept_frame(set, nil), do: set

  defp accept_frame(set, frame_number) when is_integer(frame_number) do
    set = MapSet.put(set, frame_number)

    if MapSet.size(set) > @accepted_cap do
      set |> Enum.sort() |> Enum.drop(MapSet.size(set) - @accepted_cap) |> MapSet.new()
    else
      set
    end
  end

  defp normalize_chain(%{accepted_frames: _} = chain), do: chain

  defp normalize_chain(chain) when is_map(chain) do
    Map.merge(new_chain(), Map.take(chain, [:broken?, :pli_pending?]))
  end

  defp normalize_chain(_), do: new_chain()

  defp broken_enhancement?(rtp, dd_ext_id, %{broken?: true} = _chain, structure, descriptor) do
    case resolve_descriptor(rtp, dd_ext_id, structure, descriptor) do
      {:ok, %{structure?: true}, _} ->
        false

      {:ok, %{structure?: true}} ->
        false

      {:ok, %{spatial: s, temporal: t}, _} when s > 0 or t > 0 ->
        true

      {:ok, %{spatial: s, temporal: t}} when s > 0 or t > 0 ->
        true

      _ ->
        false
    end
  end

  defp broken_enhancement?(_, _, _, _, _), do: false

  defp resolve_descriptor(_rtp, _dd_ext_id, _structure, %{spatial: _, temporal: _} = desc),
    do: {:ok, desc}

  defp resolve_descriptor(_rtp, _dd_ext_id, _structure, desc) when is_map(desc), do: {:ok, desc}

  defp resolve_descriptor(rtp, dd_ext_id, structure, _)
       when is_integer(dd_ext_id) and dd_ext_id > 0 do
    DependencyDescriptor.read_descriptor(rtp, dd_ext_id, structure)
  end

  defp resolve_descriptor(_, _, _, _), do: :error

  defp extension_raw(%Rtp{extension: %{type: type, payload: payload}}, ext_id)
       when is_binary(payload) do
    type
    |> HeaderExtension.decode_elements(payload)
    |> Enum.find_value(fn
      {^ext_id, data} when is_binary(data) -> data
      _ -> nil
    end)
  end

  defp extension_raw(_, _), do: nil

  defp over_spatial?(_s, nil), do: false
  defp over_spatial?(s, max) when is_integer(max), do: s > max

  defp over_temporal?(_t, nil), do: false
  defp over_temporal?(t, max) when is_integer(max), do: t > max

  defp av1?(codec) when is_binary(codec), do: String.downcase(codec) in ["av1", "av01"]
  defp av1?(codec) when is_atom(codec), do: codec in [:AV1, :av1, :AV01, :av01]
  defp av1?(_), do: false

  defp sim_layers?(layers) when is_list(layers) and layers != [], do: true
  defp sim_layers?(_), do: false
end
