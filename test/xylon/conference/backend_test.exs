defmodule Xylon.Conference.BackendTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{Backend, Plan}
  alias Xylon.{Participant, Session}
  alias XMediaLib.Rtp

  test "handle_rtp fans out to subscribers with rewritten ssrc" do
    session = %Session{id: "s1", tenant_id: "t1"}

    assert {:ok, state} =
             Backend.init(session, session_pid: self(), audio: :sfu, video: :sfu)

    plan_ref = state.plan_ref
    on_exit(fn -> Plan.delete(plan_ref) end)

    a = %Participant{id: "a", peer_ref: self()}
    b = %Participant{id: "b", peer_ref: self()}
    assert {:ok, state} = Backend.participant_joined(a, state)
    assert {:ok, state} = Backend.participant_joined(b, state)
    assert %Participant{id: "b"} = Plan.get_participant(plan_ref, "b")

    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 100})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0")

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 100,
      csrcs: [],
      extension: nil,
      payload: "x"
    }

    assert {:forward, [{^b, out}], _} = Backend.handle_rtp(a, rtp, state)
    assert out.ssrc != 100
    assert out.payload == "x"
  end

  test "accepts audio mcu with video sfu" do
    session = %Session{id: "s1", tenant_id: "t1"}

    assert {:ok, state} =
             Backend.init(session, session_pid: make_ref(), audio: :mcu, video: :sfu)

    assert state.audio == :mcu
    assert state.video == :sfu
  end

  test "rejects video mcu strategy" do
    session = %Session{id: "s1", tenant_id: "t1"}

    assert {:error, {:unsupported_strategy, :video, :mcu}} =
             Backend.init(session, session_pid: make_ref(), audio: :sfu, video: :mcu)
  end
end
