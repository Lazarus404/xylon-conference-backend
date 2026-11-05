defmodule Mix.Tasks.Xylon.Conference.McuSoakTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Xylon.Conference.McuSoak

  test "mcu_soak runs a short tick batch without raising" do
    # Capture shell output; task exits :ok when overrun rate is under default.
    assert :ok ==
             McuSoak.run([
               "--ticks",
               "10",
               "--contributors",
               "2",
               "--warmup",
               "1",
               "--nif",
               "false",
               "--max-overrun-rate",
               "1.0"
             ])
  end
end
