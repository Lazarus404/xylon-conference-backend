defmodule Xylon.Conference.FirIntervalTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{Backend, FakePeer, Plan}
  alias Xylon.{Participant, Session}
  alias XMediaLib.Rtp

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    :ok
  end

  test "init defaults fir_interval_ms to 0" do
    session = %Session{id: "fir0", tenant_id: "t1"}
    assert {:ok, state} = Backend.init(session, session_pid: self(), subscribe_mode: :manual)
    assert state.fir_interval_ms == 0
    refute Map.has_key?(state, :last_fir_ms)
  end

  test "fir_interval_ms 0 does not send periodic PLI on video RTP" do
    session = %Session{id: "fir-off", tenant_id: "t1"}

    assert {:ok, state} =
             Backend.init(session, session_pid: self(), subscribe_mode: :manual, fir_interval_ms: 0)

    on_exit(fn -> Plan.delete(state.plan_ref) end)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert {:ok, state} = Backend.participant_joined(a, state)
    assert {:ok, state} = Backend.participant_joined(b, state)
    assert :ok = Plan.put_track(state.plan_ref, "a", %{mid: "0", kind: :video, ssrc: 42})
    assert :ok = Plan.subscribe(state.plan_ref, "b", "a", "0")
    _ = FakePeer.drain(peer_a)

    rtp = video_rtp(42, 1)
    assert {:forward, _, _state2} = Backend.handle_rtp(a, rtp, state)
    assert is_nil(Xylon.Conference.Runtime.get_last_fir(state.plan_ref, "a"))
    assert [] = FakePeer.drain(peer_a)
  end

  test "fir_interval_ms triggers PLI then suppresses until interval elapses" do
    session = %Session{id: "fir-on", tenant_id: "t1"}

    assert {:ok, state} =
             Backend.init(session,
               session_pid: self(),
               subscribe_mode: :manual,
               fir_interval_ms: 60_000
             )

    on_exit(fn -> Plan.delete(state.plan_ref) end)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert {:ok, state} = Backend.participant_joined(a, state)
    assert {:ok, state} = Backend.participant_joined(b, state)
    assert :ok = Plan.put_track(state.plan_ref, "a", %{mid: "0", kind: :video, ssrc: 99})
    assert :ok = Plan.subscribe(state.plan_ref, "b", "a", "0")
    _ = FakePeer.drain(peer_a)

    assert {:forward, _, state2} = Backend.handle_rtp(a, video_rtp(99, 1), state)
    expected = %XMediaLib.Rtcp{payloads: [%XMediaLib.Rtcp.Pli{ssrc_s: 1, ssrc_m: 99}]}
    assert [{:send_rtcp, ^expected}] = FakePeer.drain(peer_a)
    last = Xylon.Conference.Runtime.get_last_fir(state.plan_ref, "a")
    assert is_integer(last)

    assert {:forward, _, _state3} = Backend.handle_rtp(a, video_rtp(99, 2), state2)
    assert [] = FakePeer.drain(peer_a)

    # Force due by setting last far in the past (monotonic can be negative).
    assert :ok = Xylon.Conference.Runtime.put_last_fir(state.plan_ref, "a", last - 120_000)
    assert {:forward, _, _} = Backend.handle_rtp(a, video_rtp(99, 3), state2)
    assert [{:send_rtcp, ^expected}] = FakePeer.drain(peer_a)
  end

  test "no periodic PLI when video has no subscribers" do
    session = %Session{id: "fir-nosub", tenant_id: "t1"}

    assert {:ok, state} =
             Backend.init(session,
               session_pid: self(),
               subscribe_mode: :manual,
               fir_interval_ms: 1
             )

    on_exit(fn -> Plan.delete(state.plan_ref) end)

    assert {:ok, peer_a} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a}
    assert {:ok, state} = Backend.participant_joined(a, state)
    assert :ok = Plan.put_track(state.plan_ref, "a", %{mid: "0", kind: :video, ssrc: 7})

    assert {:ok, _state2} = Backend.handle_rtp(a, video_rtp(7, 1), state)
    assert is_nil(Xylon.Conference.Runtime.get_last_fir(state.plan_ref, "a"))
    assert [] = FakePeer.drain(peer_a)
  end

  defp video_rtp(ssrc, seq) do
    %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: seq,
      timestamp: seq * 3000,
      ssrc: ssrc,
      csrcs: [],
      extension: nil,
      payload: "v"
    }
  end
end
