defmodule Xylon.Conference.AllocatorTest do
  use ExUnit.Case, async: true

  doctest Xylon.Conference.Allocator

  alias Xylon.Conference.Allocator

  test "SIM ladder picks substream from bitrate" do
    assert %{substream: 2, temporal: 2} =
             Allocator.recommend(%{
               bitrate_bps: 1_600_000,
               mode: :sim,
               layer_count: 3,
               codec: "VP8",
               current: %{substream: 0, temporal: 0}
             })

    assert %{substream: 1, temporal: 1} =
             Allocator.recommend(%{
               bitrate_bps: 700_000,
               mode: :sim,
               layer_count: 3,
               codec: "VP8",
               current: %{}
             })

    assert %{substream: 0, temporal: 0} =
             Allocator.recommend(%{
               bitrate_bps: 100_000,
               mode: :sim,
               layer_count: 3,
               codec: "VP8",
               current: %{}
             })
  end

  test "SIM clamps substream to layer_count - 1" do
    assert %{substream: 1, temporal: 2} =
             Allocator.recommend(%{
               bitrate_bps: 2_000_000,
               mode: :sim,
               layer_count: 2,
               codec: "VP8",
               current: %{}
             })
  end

  test "SIM H264 ignores temporal" do
    assert %{substream: 1, temporal: nil} =
             Allocator.recommend(%{
               bitrate_bps: 700_000,
               mode: :sim,
               layer_count: 3,
               codec: "H264",
               current: %{}
             })
  end

  test "SVC ladder uses spatial_layer and temporal_layer" do
    assert %{spatial_layer: 2, temporal_layer: 2} =
             Allocator.recommend(%{
               bitrate_bps: 1_600_000,
               mode: :svc,
               layer_count: 3,
               codec: "VP9",
               current: %{}
             })

    assert %{spatial_layer: 0, temporal_layer: 0} =
             Allocator.recommend(%{
               bitrate_bps: 50_000,
               mode: :svc,
               layer_count: 3,
               codec: "AV1",
               current: %{}
             })
  end

  test "should_apply? requires two consecutive matching recommendations" do
    rec = %{substream: 0, temporal: 0}
    policy0 = Allocator.new_policy(:adaptive)

    {false, policy1} = Allocator.should_apply?(policy0, rec, %{substream: 2, temporal: 2})
    assert policy1.pending_count == 1

    {true, policy2} = Allocator.should_apply?(policy1, rec, %{substream: 2, temporal: 2})
    assert policy2.pending_count == 0
    assert policy2.pending == nil

    # Already at target: do not apply
    {false, _} = Allocator.should_apply?(policy2, rec, rec)
  end

  test "should_apply? resets count when recommendation changes" do
    policy0 = Allocator.new_policy(:adaptive)
    {false, p1} = Allocator.should_apply?(policy0, %{substream: 0}, %{substream: 2})
    {false, p2} = Allocator.should_apply?(p1, %{substream: 1}, %{substream: 2})
    assert p2.pending_count == 1
    assert p2.pending == %{substream: 1}
  end

  test "manual policy never applies" do
    policy = Allocator.new_policy(:manual)
    {false, ^policy} = Allocator.should_apply?(policy, %{substream: 0}, %{substream: 2})
  end
end
