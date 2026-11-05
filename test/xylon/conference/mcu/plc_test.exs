defmodule Xylon.Conference.Mcu.PlcTest do
  use ExUnit.Case, async: true

  alias Xylon.Conference.Mcu.Plc

  test "conceal nil yields zeros of requested length" do
    out = Plc.conceal(nil, 8)
    assert out == :binary.copy(<<0, 0>>, 8)
  end

  test "conceal wrong-size yields zeros" do
    out = Plc.conceal(<<1, 0>>, 8)
    assert out == :binary.copy(<<0, 0>>, 8)
  end

  test "conceal attenuates last frame" do
    # one sample value 1000
    last = <<1000::signed-little-integer-size(16)>>
    out = Plc.conceal(last, 1)
    assert <<s::signed-little-integer-size(16)>> = out
    assert s == div(1000 * 9, 10)
  end
end
