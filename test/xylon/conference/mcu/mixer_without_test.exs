defmodule Xylon.Conference.Mcu.MixerWithoutTest do
  use ExUnit.Case, async: true

  alias Xylon.Conference.Mcu.Mixer

  @samples 8

  defp pcm(samples) when is_list(samples) do
    for s <- samples, into: <<>>, do: <<s::signed-little-integer-size(16)>>
  end

  defp samples_from(bin) when is_binary(bin) do
    for <<s::signed-little-integer-size(16) <- bin>>, do: s
  end

  test "mix_without excludes listed active ids from the sum" do
    a = List.duplicate(1000, @samples)
    b = List.duplicate(200, @samples)
    c = List.duplicate(50, @samples)

    contributors = [
      %{id: "a", pcm: pcm(a), level: 5},
      %{id: "b", pcm: pcm(b), level: 5},
      %{id: "c", pcm: pcm(c), level: 5}
    ]

    assert {:ok, without_a} =
             Mixer.mix_without(contributors, ["a"], samples: @samples, threshold: 25, mcu_nif: false)

    assert samples_from(without_a) == Enum.zip_with(b, c, &(&1 + &2))
  end

  test "mix_without with empty exclude equals full mix" do
    a = List.duplicate(1000, @samples)

    contributors = [%{id: "a", pcm: pcm(a), level: 5}]

    assert {:ok, %{full: full}} =
             Mixer.mix_tick(contributors, samples: @samples, threshold: 25, mcu_nif: false)

    assert {:ok, without} =
             Mixer.mix_without(contributors, [], samples: @samples, threshold: 25, mcu_nif: false)

    assert without == full
  end
end
