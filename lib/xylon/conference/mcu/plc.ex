defmodule Xylon.Conference.Mcu.Plc do
  @moduledoc """
  Packet-loss concealment for the MCU mix bus (PCM16LE).

  ## What problem this solves

  When a contributor RTP sequence has a short gap, the mix should not click or
  stall. This module builds a concealment frame from the last good bus PCM
  (repeat with attenuation) or zeros when no history exists.

  **Internal.** Used as the PCM fallback for G.711/G.722 and when Opus
  `Codec.decode_fec` / `Codec.decode_plc` is unavailable. Opus with
  `useinbandfec` prefers codec FEC/PLC in `Mcu.Contributor`.

  ## RFCs

  None for this PCM heuristic. Related: [RFC 6716](https://www.rfc-editor.org/rfc/rfc6716) (Opus PLC conceptually).
  """

  @attenuate_num 9
  @attenuate_den 10

  @doc """
  Builds one concealment frame of `samples` PCM16LE mono samples.

  When `last_pcm` is nil or wrong size, returns zeros. Otherwise copies the
  last frame with ~0.9 amplitude attenuation.
  """
  @spec conceal(binary() | nil, pos_integer()) :: binary()
  def conceal(last_pcm, samples) when is_integer(samples) and samples > 0 do
    expect = samples * 2

    cond do
      is_binary(last_pcm) and byte_size(last_pcm) == expect ->
        attenuate(last_pcm)

      true ->
        :binary.copy(<<0, 0>>, samples)
    end
  end

  defp attenuate(pcm) do
    for <<s::signed-little-integer-size(16) <- pcm>>, into: <<>> do
      <<div(s * @attenuate_num, @attenuate_den)::signed-little-integer-size(16)>>
    end
  end
end
