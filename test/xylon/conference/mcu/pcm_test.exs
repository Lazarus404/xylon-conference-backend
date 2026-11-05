defmodule Xylon.Conference.Mcu.PcmTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.Mcu.Pcm

  test "48 kHz mono is identity" do
    pcm = :binary.copy(<<1, 0>>, 960)
    assert {:ok, ^pcm} = Pcm.resample_to_bus(pcm, 48_000)
  end

  @tag :opus
  test "8 kHz silence upsamples to 6x byte size" do
    # 20 ms @ 8 kHz = 160 samples
    pcm8 = :binary.copy(<<0, 0>>, 160)
    assert {:ok, pcm48} = Pcm.resample_to_bus(pcm8, 8000)
    assert byte_size(pcm48) == byte_size(pcm8) * 6
  end

  @tag :opus
  test "16 kHz upsamples to 3x byte size" do
    pcm16 = :binary.copy(<<0, 0>>, 320)
    assert {:ok, pcm48} = Pcm.resample_to_bus(pcm16, 16_000)
    assert byte_size(pcm48) == byte_size(pcm16) * 3
  end
end
