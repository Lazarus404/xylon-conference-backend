defmodule Xylon.Conference.Mcu.Cascade.TrunkProfileTest do
  use ExUnit.Case, async: true

  alias Xylon.Conference.Mcu.Cascade

  test "trunk_desc :opus matches opus_desc" do
    assert Cascade.trunk_desc(:opus) == Cascade.opus_desc()
  end

  test "trunk_desc :pcm is L16 48k mono PT 96" do
    desc = Cascade.trunk_desc(:pcm)
    assert desc.name == "l16"
    assert desc.payload_type == 96
    assert desc.clock_rate == 48_000
    assert desc.sample_rate_hz == 48_000
    assert desc.channels == 1
    assert desc.mixable? == true
  end

  test "trunk_desc rejects unknown profile" do
    assert_raise ArgumentError, fn -> Cascade.trunk_desc(:g722) end
  end
end
