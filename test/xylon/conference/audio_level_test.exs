defmodule Xylon.Conference.AudioLevelTest do
  use ExUnit.Case, async: true

  alias Xylon.Conference.AudioLevel

  @opts [audio_active_packets: 3, audio_level_average: 25]

  test "stays silent until window filled with loud levels" do
    state = AudioLevel.new()

    {state, :noop} = AudioLevel.sample(state, 10, @opts)
    {state, :noop} = AudioLevel.sample(state, 10, @opts)
    assert {_state, :talking} = AudioLevel.sample(state, 10, @opts)
  end

  test "does not talk when average above threshold" do
    state = AudioLevel.new()

    {state, :noop} = AudioLevel.sample(state, 80, @opts)
    {state, :noop} = AudioLevel.sample(state, 80, @opts)
    assert {_state, :noop} = AudioLevel.sample(state, 80, @opts)
  end

  test "emits stopped_talking on edge when quiet again" do
    state = AudioLevel.new()

    {state, :noop} = AudioLevel.sample(state, 5, @opts)
    {state, :noop} = AudioLevel.sample(state, 5, @opts)
    {state, :talking} = AudioLevel.sample(state, 5, @opts)

    # Window becomes 5,5,100 -> avg ~36.7 > 25
    assert {_state, :stopped_talking} = AudioLevel.sample(state, 100, @opts)
  end

  test "talking sample returns average in state" do
    state = AudioLevel.new()
    {state, :noop} = AudioLevel.sample(state, 10, @opts)
    {state, :noop} = AudioLevel.sample(state, 20, @opts)
    {state, :talking} = AudioLevel.sample(state, 30, @opts)
    assert state.avg == 20.0
    assert state.talking? == true
  end
end
