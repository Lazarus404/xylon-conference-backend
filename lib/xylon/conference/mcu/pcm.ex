defmodule Xylon.Conference.Mcu.Pcm do
  @moduledoc """
  PCM helpers for the MCU mix bus (resample to 48 kHz mono).

  ## What problem this solves

  G.711 and G.722 decode to native rates (8 kHz / 16 kHz). The mix bus is fixed
  at 48 kHz mono / 20 ms. This module upsamples decoded PCM16LE into bus format
  before contributor slots are written.

  # ponytail: uses xmedialib `resampler_drv` the same way `XMediaLib.Codec`
  # does on encode. Ceiling: duplicate of private Codec resample wiring;
  # upgrade path is a public `XMediaLib.Codec.resample/5`.

  **Internal.**

  ## RFCs

  None for pure PCM resample arithmetic.
  """

  @bus_rate 48_000

  @doc """
  Resamples PCM16LE to the 48 kHz mix bus.

  When `from_rate_hz` is already 48_000, returns `pcm` unchanged.
  `channels` defaults to 1 (mono).
  """
  @spec resample_to_bus(binary(), pos_integer(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def resample_to_bus(pcm, from_rate_hz, channels \\ 1)
      when is_binary(pcm) and is_integer(from_rate_hz) and is_integer(channels) do
    cond do
      from_rate_hz == @bus_rate and channels == 1 ->
        {:ok, pcm}

      byte_size(pcm) == 0 ->
        {:ok, pcm}

      true ->
        do_resample(pcm, from_rate_hz, channels, @bus_rate, 1)
    end
  end

  defp do_resample(pcm, from_sr, from_ch, to_sr, to_ch) do
    with :ok <- load_resampler() do
      port = :erlang.open_port({:spawn, :resampler_drv}, [:binary])

      try do
        cmd = cmd_resample(from_sr, from_ch, to_sr, to_ch)

        case :erlang.port_control(port, cmd, pcm) do
          out when is_binary(out) -> {:ok, out}
          _ -> {:error, :resample_error}
        end
      after
        try do
          :erlang.port_close(port)
        catch
          _, _ -> :ok
        end
      end
    end
  end

  # Same packing as XMediaLib.Codec
  defp cmd_resample(from_sr, from_ch, to_sr, to_ch),
    do: div(from_sr, 1000) * 16_777_216 + from_ch * 65_536 + div(to_sr, 1000) * 256 + to_ch

  defp load_resampler do
    case :erl_ddll.load_driver(priv_dir(), :resampler_drv) do
      :ok -> :ok
      {:error, :already_loaded} -> :ok
      {:error, :permanent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp priv_dir do
    case :code.priv_dir(:xmedialib) do
      path when is_list(path) -> List.to_string(path)
      {:error, _} -> "./priv"
    end
  end
end
