defmodule Xylon.Conference.TalkingEventsTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{Backend, Plan}
  alias Xylon.Control.{Membership, Presence}
  alias Xylon.{Participant, Session}
  alias XMediaLib.Rtp

  setup do
    start_supervised!(Membership)
    start_supervised!(Presence)
    :ok
  end

  test "handle_rtp emits talking after window of loud audio-level samples" do
    session = %Session{id: "talk1", tenant_id: "t1"}

    assert {:ok, state} =
             Backend.init(session,
               session_pid: self(),
               subscribe_mode: :manual,
               audiolevel_events: true,
               audio_active_packets: 3,
               audio_level_average: 25
             )

    on_exit(fn ->
      Plan.delete(state.plan_ref)
      Xylon.Conference.Runtime.clear_plan(state.plan_ref)
    end)

    a = %Participant{id: "a", peer_ref: self()}
    assert {:ok, state} = Backend.participant_joined(a, state)

    offer = """
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level
    a=ssrc:1001 cname:a
    """

    assert {:ok, state} = Backend.media_ready(a, offer, %{forwarder: nil}, state)
    assert :ok = Presence.subscribe("t1", "talk1", "viewer", self())

    # V=1 level=10
    ext_payload = <<1::4, 0::4, 0x8A>>
    rtp = loud_rtp(1001, ext_payload)

    assert {:ok, state} = Backend.handle_rtp(a, rtp, state)
    assert {:ok, state} = Backend.handle_rtp(a, %{rtp | sequence_number: 2}, state)
    refute_receive {:xylon_control_presence, %{type: :talking}}, 50

    assert {:ok, _state} = Backend.handle_rtp(a, %{rtp | sequence_number: 3}, state)

    assert_receive {:xylon_control_presence,
                    %{type: :talking, participant_id: "a", audio_level_dbov_avg: avg}}

    assert avg <= 25.0
  end

  test "handle_rtp skips talking when audiolevel_events false" do
    session = %Session{id: "talk2", tenant_id: "t1"}

    assert {:ok, state} =
             Backend.init(session,
               session_pid: self(),
               subscribe_mode: :manual,
               audiolevel_events: false,
               audio_active_packets: 1,
               audio_level_average: 25
             )

    on_exit(fn ->
      Plan.delete(state.plan_ref)
      Xylon.Conference.Runtime.clear_plan(state.plan_ref)
    end)

    a = %Participant{id: "a", peer_ref: self()}
    assert {:ok, state} = Backend.participant_joined(a, state)

    offer = """
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level
    a=ssrc:1001 cname:a
    """

    assert {:ok, state} = Backend.media_ready(a, offer, %{forwarder: nil}, state)
    assert :ok = Presence.subscribe("t1", "talk2", "viewer", self())

    rtp = loud_rtp(1001, <<1::4, 0::4, 0x8A>>)
    assert {:ok, _} = Backend.handle_rtp(a, rtp, state)
    refute_receive {:xylon_control_presence, %{type: :talking}}, 50
  end

  defp loud_rtp(ssrc, ext_payload) do
    %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: ssrc,
      csrcs: [],
      extension: %Rtp.Extension{type: 0xBEDE, payload: ext_payload},
      payload: "x"
    }
  end
end
