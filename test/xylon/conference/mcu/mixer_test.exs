defmodule Xylon.Conference.Mcu.MixerTest do
  use ExUnit.Case, async: true

  alias Xylon.Conference.Mcu.{Mixer, Native}

  @samples 8

  defp pcm(samples) when is_list(samples) do
    for s <- samples, into: <<>>, do: <<s::signed-little-integer-size(16)>>
  end

  defp samples_from(bin) when is_binary(bin) do
    for <<s::signed-little-integer-size(16) <- bin>>, do: s
  end

  defp contrib(id, sample_list, opts) do
    level = Keyword.fetch!(opts, :level)

    base = %{
      id: id,
      pcm: pcm(sample_list),
      level: level
    }

    case Keyword.fetch(opts, :active?) do
      {:ok, active?} -> Map.put(base, :active?, active?)
      :error -> base
    end
  end

  test "samples_per_tick defaults to 960 (48kHz, 20ms)" do
    assert Mixer.samples_per_tick([]) == 960
  end

  test "samples_per_tick respects opts" do
    assert Mixer.samples_per_tick(samples: 8) == 8
  end

  test "single active tone: full matches that PCM" do
    tone = [100, 200, 300, 400, 500, 600, 700, 800]
    contributors = [contrib("a", tone, level: 10)]

    assert {:ok, %{full: full, minus_self: minus}} =
             Mixer.mix_tick(contributors, samples: @samples, threshold: 25)

    assert samples_from(full) == tone
    assert samples_from(minus["a"]) == List.duplicate(0, @samples)
  end

  test "two tones: full is sample-wise sum then clamp" do
    a = [1000, 2000, 3000, 4000, 1000, 2000, 3000, 4000]
    b = [500, 500, 500, 500, 500, 500, 500, 500]
    expected = Enum.zip_with(a, b, &(&1 + &2))

    contributors = [
      contrib("a", a, level: 5),
      contrib("b", b, level: 8)
    ]

    assert {:ok, %{full: full}} =
             Mixer.mix_tick(contributors, samples: @samples, threshold: 25)

    assert samples_from(full) == expected
  end

  test "mix-minus-self: A excludes A and equals B-only when both active" do
    a = [1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000]
    b = [200, 200, 200, 200, 200, 200, 200, 200]

    contributors = [
      contrib("a", a, level: 5),
      contrib("b", b, level: 8)
    ]

    assert {:ok, %{minus_self: minus}} =
             Mixer.mix_tick(contributors, samples: @samples, threshold: 25)

    assert samples_from(minus["a"]) == b
    assert samples_from(minus["b"]) == a
  end

  test "silence by level: level above threshold excluded from sum" do
    loud = [1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000]
    quiet = [9000, 9000, 9000, 9000, 9000, 9000, 9000, 9000]

    contributors = [
      contrib("loud", loud, level: 10),
      contrib("quiet", quiet, level: 100)
    ]

    assert {:ok, %{full: full, minus_self: minus}} =
             Mixer.mix_tick(contributors, samples: @samples, threshold: 25)

    assert samples_from(full) == loud
    assert samples_from(minus["quiet"]) == loud
    assert samples_from(minus["loud"]) == List.duplicate(0, @samples)
  end

  test "active?: false excluded even if level loud" do
    a = [1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000]
    b = [2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000]

    contributors = [
      contrib("a", a, level: 5, active?: false),
      contrib("b", b, level: 5)
    ]

    assert {:ok, %{full: full}} =
             Mixer.mix_tick(contributors, samples: @samples, threshold: 25)

    assert samples_from(full) == b
  end

  test "nil level treated as inactive" do
    a = [1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000]
    b = [2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000]

    contributors = [
      %{id: "a", pcm: pcm(a), level: nil},
      contrib("b", b, level: 5)
    ]

    assert {:ok, %{full: full}} =
             Mixer.mix_tick(contributors, samples: @samples, threshold: 25)

    assert samples_from(full) == b
  end

  test "top_n keeps N loudest active only" do
    # levels: lower = louder
    c1 = contrib("c1", List.duplicate(1000, @samples), level: 1)
    c2 = contrib("c2", List.duplicate(2000, @samples), level: 2)
    c3 = contrib("c3", List.duplicate(4000, @samples), level: 3)
    c4 = contrib("c4", List.duplicate(8000, @samples), level: 20)

    assert {:ok, %{full: full}} =
             Mixer.mix_tick([c1, c2, c3, c4], samples: @samples, threshold: 25, top_n: 2)

    # loudest two: c1 + c2
    assert samples_from(full) == List.duplicate(3000, @samples)
  end

  test "clip: two full-scale frames saturate without wrap" do
    hi = List.duplicate(20_000, @samples)

    contributors = [
      contrib("a", hi, level: 5),
      contrib("b", hi, level: 5)
    ]

    assert {:ok, %{full: full}} =
             Mixer.mix_tick(contributors, samples: @samples, threshold: 25)

    assert samples_from(full) == List.duplicate(32_767, @samples)
  end

  test "bad pcm length returns error" do
    bad = pcm([1, 2, 3])

    assert {:error, :bad_pcm} =
             Mixer.mix_tick([%{id: "a", pcm: bad, level: 5}], samples: @samples, threshold: 25)
  end

  test "empty contributors: full is zeros" do
    assert {:ok, %{full: full, minus_self: minus}} =
             Mixer.mix_tick([], samples: @samples, threshold: 25)

    assert samples_from(full) == List.duplicate(0, @samples)
    assert minus == %{}
  end

  test "all silent: full is zeros; minus maps zeros" do
    contributors = [
      contrib("a", List.duplicate(1000, @samples), level: 100),
      contrib("b", List.duplicate(2000, @samples), level: 90)
    ]

    assert {:ok, %{full: full, minus_self: minus}} =
             Mixer.mix_tick(contributors, samples: @samples, threshold: 25)

    zeros = List.duplicate(0, @samples)
    assert samples_from(full) == zeros
    assert samples_from(minus["a"]) == zeros
    assert samples_from(minus["b"]) == zeros
  end

  test "silent listener still gets mix of others" do
    loud = List.duplicate(1500, @samples)
    silent = List.duplicate(9999, @samples)

    contributors = [
      contrib("talker", loud, level: 5),
      contrib("silent", silent, level: 80)
    ]

    assert {:ok, %{minus_self: minus}} =
             Mixer.mix_tick(contributors, samples: @samples, threshold: 25)

    assert samples_from(minus["silent"]) == loud
  end

  test "soft limiter: two loud frames peak below naive sum and stay in int16" do
    a = List.duplicate(16_000, @samples)
    b = List.duplicate(16_000, @samples)
    naive_peak = 32_000

    contributors = [
      contrib("a", a, level: 5),
      contrib("b", b, level: 5)
    ]

    assert {:ok, %{full: full}} =
             Mixer.mix_tick(contributors, samples: @samples, threshold: 25)

    peaks = samples_from(full)
    assert Enum.max(peaks) < naive_peak
    assert Enum.max(peaks) <= 32_767
    assert Enum.min(peaks) >= -32_768
    # soft knee at 30000: 32000 -> 31000
    assert Enum.max(peaks) == 31_000
  end

  test "mcu_nif: false forces Elixir path and matches default when NIF off" do
    tone = [100, 200, 300, 400, 500, 600, 700, 800]
    contributors = [contrib("a", tone, level: 10)]

    assert {:ok, elixir} =
             Mixer.mix_tick(contributors, samples: @samples, threshold: 25, mcu_nif: false)

    assert samples_from(elixir.full) == tone
  end

  @tag :nif
  test "NIF parity: Elixir and NIF produce identical full and minus_self" do
    # Skip when no toolchain / no .so (Elixir path must always pass).
    # If a non-empty .so exists but failed to load, native_test catches that.
    if Native.loaded?() do
      cases = [
        [contrib("a", [100, 200, 300, 400, 500, 600, 700, 800], level: 10)],
        [
          contrib("a", [1000, 2000, 3000, 4000, 1000, 2000, 3000, 4000], level: 5),
          contrib("b", [500, 500, 500, 500, 500, 500, 500, 500], level: 8)
        ],
        [
          contrib("loud", List.duplicate(1000, @samples), level: 10),
          contrib("quiet", List.duplicate(9000, @samples), level: 100)
        ],
        [
          contrib("a", List.duplicate(16_000, @samples), level: 5),
          contrib("b", List.duplicate(16_000, @samples), level: 5)
        ],
        [
          contrib("a", List.duplicate(20_000, @samples), level: 5),
          contrib("b", List.duplicate(20_000, @samples), level: 5)
        ],
        []
      ]

      for contributors <- cases do
        opts = [samples: @samples, threshold: 25]

        assert {:ok, elixir} = Mixer.mix_tick(contributors, Keyword.put(opts, :mcu_nif, false))
        assert {:ok, nif} = Mixer.mix_tick(contributors, Keyword.put(opts, :mcu_nif, true))

        assert nif.full == elixir.full
        assert nif.minus_self == elixir.minus_self
      end
    end
  end

  @tag :nif
  @tag :benchmark
  test "NIF mix_tick is not wildly slower than Elixir (soft check)" do
    if Native.loaded?() do
      samples = 960
      tone = List.duplicate(1000, samples)

      contributors =
        for i <- 1..8 do
          contrib("c#{i}", tone, level: i)
        end

      opts = [samples: samples, threshold: 25]
      warmup = 20
      iters = 80

      for _ <- 1..warmup do
        _ = Mixer.mix_tick(contributors, Keyword.put(opts, :mcu_nif, false))
        _ = Mixer.mix_tick(contributors, Keyword.put(opts, :mcu_nif, true))
      end

      {elixir_us, _} =
        :timer.tc(fn ->
          for _ <- 1..iters do
            assert {:ok, _} = Mixer.mix_tick(contributors, Keyword.put(opts, :mcu_nif, false))
          end
        end)

      {nif_us, _} =
        :timer.tc(fn ->
          for _ <- 1..iters do
            assert {:ok, _} = Mixer.mix_tick(contributors, Keyword.put(opts, :mcu_nif, true))
          end
        end)

      # Soft ceiling: NIF must not be >10x Elixir wall time (catches broken dispatch).
      assert nif_us < elixir_us * 10
    end
  end
end
