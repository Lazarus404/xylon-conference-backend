defmodule Xylon.Conference.Mcu.NativeTest do
  use ExUnit.Case, async: true

  alias Xylon.Conference.Mcu.{Mixer, Native}

  @samples 8

  defp pcm(samples) when is_list(samples) do
    for s <- samples, into: <<>>, do: <<s::signed-little-integer-size(16)>>
  end

  test "loaded?/0 is boolean" do
    assert is_boolean(Native.loaded?())
  end

  test "non-empty priv .so must load (catches hardlink/truncate build bugs)" do
    so =
      case :code.priv_dir(:xylon_conference_backend) do
        {:error, _} -> Path.expand("../../../../priv/mcu_mix_nif.so", __DIR__)
        dir -> Path.join(dir, "mcu_mix_nif.so")
      end

    if File.exists?(so) and File.stat!(so).size > 0 do
      assert Native.loaded?(),
             "#{so} exists and is non-empty but Native.loaded? is false"
    end
  end

  test "mix_tick still succeeds when accel disabled even if NIF loaded" do
    contributors = [
      %{id: "a", pcm: pcm(List.duplicate(1000, @samples)), level: 5}
    ]

    assert {:ok, %{full: full}} =
             Mixer.mix_tick(contributors, samples: @samples, threshold: 25, mcu_nif: false)

    assert byte_size(full) == @samples * 2
  end
end
