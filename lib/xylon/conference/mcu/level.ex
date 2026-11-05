defmodule Xylon.Conference.Mcu.Level do
  @moduledoc """
  MCU activity levels: PCM energy and hysteresis for the mix gate.

  ## What problem this solves

  The mixer includes contributors when `level <= threshold` (RFC 6464 scale:
  0 loud .. 127 quiet). When the audio-level header extension is missing, this
  module estimates level from PCM energy. Hysteresis stops flapping around the
  threshold.

  **Internal.**

  ## RFCs

  - [RFC 6464](https://www.rfc-editor.org/rfc/rfc6464) (level scale 0..127)
  """

  @typedoc """
  Hysteresis gate state.

  ## Fields

  - `:active?` -- whether the contributor is currently treated as in the mix
  """
  @type state :: %{active?: boolean()}

  @doc "Initial hysteresis state (inactive)."
  @spec new() :: state()
  def new, do: %{active?: false}

  @doc """
  Maps PCM16LE mono energy to an RFC 6464-style level (0 loud .. 127 quiet).
  """
  @spec energy_level(binary()) :: 0..127
  def energy_level(pcm) when is_binary(pcm) do
    if byte_size(pcm) < 2 do
      127
    else
      peak =
        for(<<s::signed-little-integer-size(16) <- pcm>>, do: abs(s))
        |> Enum.max(fn -> 0 end)

      cond do
        peak <= 0 -> 127
        peak >= 32_767 -> 0
        true -> 127 - div(peak * 127, 32_767)
      end
    end
  end

  @doc """
  Applies enter/leave hysteresis around `threshold`.

  Enter active when `raw <= threshold`. Leave when `raw > threshold + hyst`.
  While active but in the hysteresis band, returns a level that still passes
  the mixer gate (`min(raw, threshold)`).
  """
  @spec apply_hysteresis(0..127, state(), non_neg_integer(), non_neg_integer()) ::
          {0..127, state()}
  def apply_hysteresis(raw, state, threshold, hyst)
      when is_integer(raw) and raw >= 0 and raw <= 127 and is_map(state) do
    threshold = clamp127(threshold)
    hyst = max(0, hyst)

    if state.active? do
      if raw > threshold + hyst do
        {raw, %{active?: false}}
      else
        {min(raw, threshold), %{active?: true}}
      end
    else
      if raw <= threshold do
        {raw, %{active?: true}}
      else
        {raw, %{active?: false}}
      end
    end
  end

  defp clamp127(n) when is_integer(n) and n < 0, do: 0
  defp clamp127(n) when is_integer(n) and n > 127, do: 127
  defp clamp127(n) when is_integer(n), do: n
  defp clamp127(_), do: 25
end
