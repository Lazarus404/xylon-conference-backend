defmodule Xylon.Conference.Mcu.LevelTest do
  use ExUnit.Case, async: true

  alias Xylon.Conference.Mcu.Level

  test "silence is quiet (high level)" do
    pcm = :binary.copy(<<0, 0>>, 64)
    assert Level.energy_level(pcm) == 127
  end

  test "loud tone is lower level than silence" do
    tone =
      for _ <- 1..64, into: <<>> do
        <<20_000::signed-little-integer-size(16)>>
      end

    assert Level.energy_level(tone) <= 50
    assert Level.energy_level(tone) < Level.energy_level(:binary.copy(<<0, 0>>, 64))
  end

  test "hysteresis enter and leave" do
    st = Level.new()
    {l1, st} = Level.apply_hysteresis(80, st, 25, 10)
    assert l1 == 80
    refute st.active?

    {l2, st} = Level.apply_hysteresis(20, st, 25, 10)
    assert l2 == 20
    assert st.active?

    # in band: still active, forced through gate
    {l3, st} = Level.apply_hysteresis(30, st, 25, 10)
    assert l3 == 25
    assert st.active?

    {l4, st} = Level.apply_hysteresis(40, st, 25, 10)
    assert l4 == 40
    refute st.active?
  end
end
