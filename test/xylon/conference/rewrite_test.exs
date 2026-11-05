defmodule Xylon.Conference.RewriteTest do
  use ExUnit.Case, async: true

  alias Xylon.Conference.Rewrite
  alias XMediaLib.Rtp

  test "rewrites ssrc and strips extensions" do
    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 10,
      timestamp: 1000,
      ssrc: 4242,
      csrcs: [1],
      extension: %{id: 1},
      payload: "hi"
    }

    state = %{
      out_ssrc: 9999,
      last_in_seq: nil,
      last_out_seq: nil,
      last_in_ts: nil,
      last_out_ts: nil
    }

    {out, state2} = Rewrite.apply(rtp, state)
    assert out.ssrc == 9999
    assert out.extension == nil
    assert out.csrcs == []
    assert out.sequence_number == 10
    assert out.timestamp == 1000

    rtp2 = %{rtp | sequence_number: 12, timestamp: 1480}
    {out2, _} = Rewrite.apply(rtp2, state2)
    assert out2.sequence_number == 12
    assert out2.timestamp == 1480
  end
end
