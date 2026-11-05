defmodule Xylon.Conference.Mcu.Mixer do
  @moduledoc """
  PCM mix bus for conference audio MCU (one tick at a time).

  ## What problem this solves

  An audio MCU must sum active contributors into one mix and, for talker-listeners,
  produce mix-minus-self so they do not hear themselves delayed. This module does
  that math only: PCM16 little-endian mono frames in, clamped PCM out. No RTP,
  codecs, GenServers, or network -- callers fill slots and drive the tick clock.

  Defaults match the production bus target: 48 kHz mono, 20 ms tick (960 samples),
  RFC 6464-style levels (0 loud .. 127 quiet) with threshold 25, optional top-N
  loudest, then a soft-knee limiter and hard clip to int16.

  When MCU accel is enabled and `Mcu.Native` is loaded, the sum / soft-knee /
  minus-self path runs in a dirty-CPU NIF. Otherwise (or on NIF error) the same
  algorithm runs in Elixir.

  ## RFCs

  None for pure PCM arithmetic. Contributor levels use the same 0..127 scale as
  [RFC 6464](https://www.rfc-editor.org/rfc/rfc6464) when callers supply them.
  """

  alias Xylon.Conference.Mcu.{Accel, Native}

  @default_sample_rate_hz 48_000
  @default_tick_ms 20
  @default_samples div(@default_sample_rate_hz * @default_tick_ms, 1000)
  @default_threshold 25
  @int16_min -32_768
  @int16_max 32_767
  @soft_knee 30_000

  @typedoc """
  One contributor slot for a mix tick.

  ## Fields

  - `:id` -- participant id (any term used as map key in `minus_self`)
  - `:pcm` -- PCM16LE mono binary; byte size must be `samples * 2`
  - `:level` -- RFC 6464-style level (0 loud .. 127 quiet), or `nil` (inactive)
  - `:active?` -- when `false`, excluded even if level is loud; omit or `true` to allow gate
  """
  @type contributor :: %{
          required(:id) => term(),
          required(:pcm) => binary(),
          required(:level) => non_neg_integer() | nil,
          optional(:active?) => boolean()
        }

  @typedoc """
  Result of one mix tick.

  ## Fields

  - `:full` -- sum of active contributors, clamped to int16 PCM16LE
  - `:minus_self` -- for each input contributor id, mix of active set excluding that id
  """
  @type mix_result :: %{
          full: binary(),
          minus_self: %{optional(term()) => binary()}
        }

  @doc """
  Returns samples per tick from opts (`:samples`) or the 48 kHz / 20 ms default (960).

  ## Examples

      iex> Xylon.Conference.Mcu.Mixer.samples_per_tick([])
      960

      iex> Xylon.Conference.Mcu.Mixer.samples_per_tick(samples: 8)
      8
  """
  @spec samples_per_tick(keyword()) :: pos_integer()
  def samples_per_tick(opts \\ []) when is_list(opts) do
    Keyword.get(opts, :samples, @default_samples)
  end

  @doc """
  Mixes one tick of contributor PCM.

  Opts:

  - `:samples` -- frame length in samples (default 960)
  - `:threshold` -- include when `level <= threshold` (default 25)
  - `:top_n` -- keep N loudest active (lowest levels); `nil` = unlimited
  - `:mcu_nif` -- when boolean, overrides Application `:mcu_accel` for this call

  Returns `{:ok, mix_result}` or `{:error, :bad_pcm}` when any frame byte size
  is not `samples * 2`.

  Soft-limits then hard-clips the int32 sum to int16 (no wrap).
  """
  @spec mix_tick([contributor()], keyword()) :: {:ok, mix_result()} | {:error, :bad_pcm}
  def mix_tick(contributors, opts \\ []) when is_list(contributors) and is_list(opts) do
    samples = samples_per_tick(opts)
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    top_n = Keyword.get(opts, :top_n, nil)
    expect_bytes = samples * 2

    with :ok <- validate_pcm(contributors, expect_bytes) do
      active =
        contributors
        |> Enum.filter(&active_contributor?(&1, threshold))
        |> apply_top_n(top_n)

      if Accel.enabled?(opts) and Native.loaded?() do
        case nif_mix(active, contributors, samples) do
          {:ok, _} = ok -> ok
          _ -> elixir_mix_tick(active, contributors, samples)
        end
      else
        elixir_mix_tick(active, contributors, samples)
      end
    end
  end

  @doc """
  Soft-knee PCM of the active set with `exclude_ids` removed (Elixir path).

  Uses the same gate / `top_n` / soft-knee rules as `mix_tick/2`. Exclude is
  applied after the gate. Returns `{:ok, pcm}` or `{:error, :bad_pcm}`.
  """
  @spec mix_without([contributor()], Enumerable.t(), keyword()) ::
          {:ok, binary()} | {:error, :bad_pcm}
  def mix_without(contributors, exclude_ids, opts \\ [])
      when is_list(contributors) and is_list(opts) do
    samples = samples_per_tick(opts)
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    top_n = Keyword.get(opts, :top_n, nil)
    expect_bytes = samples * 2
    exclude = MapSet.new(exclude_ids)

    with :ok <- validate_pcm(contributors, expect_bytes) do
      active =
        contributors
        |> Enum.filter(&active_contributor?(&1, threshold))
        |> apply_top_n(top_n)
        |> Enum.reject(&MapSet.member?(exclude, &1.id))

      {:ok, encode_pcm(sum_active(active, samples))}
    end
  end

  defp nif_mix(active, contributors, samples) do
    active_pairs = Enum.map(active, fn %{id: id, pcm: pcm} -> {id, pcm} end)
    all_ids = Enum.map(contributors, & &1.id)

    case Native.mix_tick(active_pairs, all_ids, samples) do
      {:ok, {full, minus_list}} when is_binary(full) and is_list(minus_list) ->
        {:ok, %{full: full, minus_self: Map.new(minus_list)}}

      other ->
        other
    end
  rescue
    _ -> {:error, :nif_error}
  end

  defp elixir_mix_tick(active, contributors, samples) do
    full_sums = sum_active(active, samples)
    full = encode_pcm(full_sums)

    minus_self =
      Map.new(contributors, fn %{id: id} ->
        others = Enum.reject(active, &(&1.id == id))
        {id, encode_pcm(sum_active(others, samples))}
      end)

    {:ok, %{full: full, minus_self: minus_self}}
  end

  defp validate_pcm(contributors, expect_bytes) do
    if Enum.any?(contributors, fn c -> byte_size(Map.fetch!(c, :pcm)) != expect_bytes end) do
      {:error, :bad_pcm}
    else
      :ok
    end
  end

  defp active_contributor?(%{active?: false}, _threshold), do: false

  defp active_contributor?(%{level: level}, threshold)
       when is_integer(level) and level >= 0 and level <= 127 do
    level <= threshold
  end

  defp active_contributor?(_contributor, _threshold), do: false

  defp apply_top_n(active, nil), do: active

  defp apply_top_n(active, n) when is_integer(n) and n > 0 do
    active
    |> Enum.sort_by(& &1.level)
    |> Enum.take(n)
  end

  defp apply_top_n(active, _n), do: active

  defp sum_active([], samples), do: List.duplicate(0, samples)

  defp sum_active(active, samples) do
    zeros = List.duplicate(0, samples)

    Enum.reduce(active, zeros, fn %{pcm: pcm}, acc ->
      pcm
      |> decode_pcm()
      |> Enum.zip_with(acc, &(&1 + &2))
    end)
  end

  defp decode_pcm(bin) do
    for <<s::signed-little-integer-size(16) <- bin>>, do: s
  end

  defp encode_pcm(sums) do
    for s <- sums, into: <<>>, do: <<soft_then_hard(s)::signed-little-integer-size(16)>>
  end

  # Soft knee above |x| > knee, then hard int16 ceiling (no wrap).
  defp soft_then_hard(s) when is_integer(s) do
    abs_s = abs(s)

    limited =
      if abs_s <= @soft_knee do
        abs_s
      else
        over = abs_s - @soft_knee
        @soft_knee + div(over, 2)
      end

    signed = if s < 0, do: -limited, else: limited
    clamp_i16(signed)
  end

  defp clamp_i16(s) when s < @int16_min, do: @int16_min
  defp clamp_i16(s) when s > @int16_max, do: @int16_max
  defp clamp_i16(s), do: s
end
