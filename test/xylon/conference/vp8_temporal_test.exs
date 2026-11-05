defmodule Xylon.Conference.Vp8TemporalTest do
  use ExUnit.Case, async: true

  doctest Xylon.Conference.Vp8Temporal

  alias Xylon.Conference.Vp8Temporal
  alias XMediaLib.Rtp

  # X=1, T=1, TID in bits 7-6 of third octet
  defp vp8_tid(tid) when tid in 0..3 do
    <<0x80, 0x20, tid::2, 0::6, 0x00>>
  end

  test "tid parses T bit descriptor" do
    assert Vp8Temporal.tid(vp8_tid(0)) == {:ok, 0}
    assert Vp8Temporal.tid(vp8_tid(1)) == {:ok, 1}
    assert Vp8Temporal.tid(vp8_tid(2)) == {:ok, 2}
  end

  test "drop? respects max_temporal and codec" do
    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 1,
      csrcs: [],
      extension: nil,
      payload: vp8_tid(2)
    }

    assert Vp8Temporal.drop?(rtp, nil, "VP8") == false
    assert Vp8Temporal.drop?(rtp, 2, "VP8") == false
    assert Vp8Temporal.drop?(rtp, 1, "VP8") == true
    assert Vp8Temporal.drop?(rtp, 0, "H264") == false
  end
end
