defmodule Xylon.Conference.Mcu.MixBenchTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.Mcu.{Mixer, Native}

  @moduletag :nif_bench

  @samples 960
  @contributors 8

  defp pcm_tone(amp) do
    for i <- 0..(@samples - 1), into: <<>> do
      s = rem(amp + i, 20_000) - 10_000
      <<s::signed-little-integer-size(16)>>
    end
  end

  defp contributors do
    for n <- 1..@contributors do
      %{id: "c#{n}", pcm: pcm_tone(n * 1000), level: n}
    end
  end

  test "NIF mix_tick is not wildly slower than Elixir on same frame" do
    if not Native.loaded?() do
      :ok
    else
      cs = contributors()
      opts = [samples: @samples, threshold: 25]
      warmup = 5
      rounds = 40

      for _ <- 1..warmup do
        _ = Mixer.mix_tick(cs, Keyword.put(opts, :mcu_nif, false))
        _ = Mixer.mix_tick(cs, Keyword.put(opts, :mcu_nif, true))
      end

      {elixir_us, _} =
        :timer.tc(fn ->
          for _ <- 1..rounds do
            assert {:ok, _} = Mixer.mix_tick(cs, Keyword.put(opts, :mcu_nif, false))
          end
        end)

      {nif_us, _} =
        :timer.tc(fn ->
          for _ <- 1..rounds do
            assert {:ok, _} = Mixer.mix_tick(cs, Keyword.put(opts, :mcu_nif, true))
          end
        end)

      # Soft check: NIF should not be >5x Elixir (noise / CI); usually much faster.
      assert nif_us < elixir_us * 5,
             "nif_us=#{nif_us} elixir_us=#{elixir_us} (expected NIF not much slower)"
    end
  end
end
