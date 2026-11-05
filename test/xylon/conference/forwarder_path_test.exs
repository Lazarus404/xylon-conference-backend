defmodule Xylon.Conference.ForwarderPathTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Xylon.Conference.{Backend, FakePeer, Runtime, Twcc}
  alias Xylon.Control.{Membership, Presence}
  alias Xylon.{Participant, Session}
  alias XMediaLib.Rtp

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    :ok
  end

  test "TWCC feedback works when media_ready updates Session state only" do
    assert {:ok, session} =
             Session.create("t1", "fwd-twcc", :conference,
               subscribe_mode: :manual,
               twcc_period_ms: 1
             )

    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}

    assert :ok = Session.attach_participant(session, a)
    assert :ok = Session.attach_participant(session, b)

    # Production path: media_ready mutates Session backend_state only.
    session_state = :sys.get_state(session).backend_state

    offer = """
    m=video 9 UDP/TLS/RTP/SAVPF 96
    a=extmap:4 #{Twcc.uri()}
    a=ssrc:777 cname:a
    """

    assert {:ok, session_state} = Backend.media_ready(a, offer, %{forwarder: fwd}, session_state)

    :sys.replace_state(session, fn s -> %{s | backend_state: session_state} end)

    # Do not patch Forwarder backend_state -- Runtime ETS must carry ext ids.
    refute Map.has_key?(:sys.get_state(fwd).backend_state, :twcc_ext_ids)
    assert %{twcc: 4} = Runtime.get_ext(plan_ref, "a")

    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)
    _ = FakePeer.drain(peer_a)

    payload = <<4::4, 1::4, 0x00, 0x2A>>

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 777,
      csrcs: [],
      extension: %Rtp.Extension{type: 0xBEDE, payload: payload},
      payload: "v"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})

    assert wait_rtcp_twcc(peer_a, 777)
    assert_receive_forwarded(peer_b)
  end

  test "talking events work when media_ready updates Session state only" do
    start_supervised!(Membership)
    start_supervised!(Presence)

    assert {:ok, session} =
             Session.create("t1", "fwd-talk", :conference,
               subscribe_mode: :manual,
               audiolevel_events: true,
               audio_active_packets: 3,
               audio_level_average: 25
             )

    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a}
    assert :ok = Session.attach_participant(session, a)

    session_state = :sys.get_state(session).backend_state

    offer = """
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level
    a=ssrc:1001 cname:a
    """

    assert {:ok, session_state} = Backend.media_ready(a, offer, %{forwarder: fwd}, session_state)
    :sys.replace_state(session, fn s -> %{s | backend_state: session_state} end)

    refute Map.has_key?(:sys.get_state(fwd).backend_state, :audio_level_ext_ids)
    assert %{audio_level: 1} = Runtime.get_ext(plan_ref, "a")

    assert :ok = Presence.subscribe("t1", "fwd-talk", "viewer", self())

    ext_payload = <<1::4, 0::4, 0x8A>>
    rtp = loud_rtp(1001, ext_payload)

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})
    send(fwd, {:xgw, :rtp, peer_a, %{rtp | sequence_number: 2}, %{}})
    refute_receive {:xylon_control_presence, %{type: :talking}}, 50

    send(fwd, {:xgw, :rtp, peer_a, %{rtp | sequence_number: 3}, %{}})

    assert_receive {:xylon_control_presence,
                    %{type: :talking, participant_id: "a", audio_level_dbov_avg: avg}}

    assert avg <= 25.0
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

  defp wait_rtcp_twcc(peer, media_ssrc) do
    Enum.reduce_while(1..50, false, fn _, _ ->
      case FakePeer.drain(peer) do
        [
          {:send_rtcp,
           %XMediaLib.Rtcp{payloads: [%XMediaLib.Rtcp.Twcc{ssrc_m: ^media_ssrc} | _]}}
          | _
        ] ->
          {:halt, true}

        [] ->
          Process.sleep(10)
          {:cont, false}

        other ->
          # Ignore fanout RTP on same peer if any
          if Enum.any?(other, fn
               {:send_rtcp, %XMediaLib.Rtcp{payloads: [%XMediaLib.Rtcp.Twcc{ssrc_m: ^media_ssrc} | _]}} ->
                 true

               _ ->
                 false
             end) do
            {:halt, true}
          else
            Process.sleep(10)
            {:cont, false}
          end
      end
    end)
  end

  defp assert_receive_forwarded(peer) do
    Enum.reduce_while(1..50, nil, fn _, _ ->
      case FakePeer.drain(peer) do
        [{:send_rtp, _ssrc, %Rtp{payload: "v"}} | _] ->
          {:halt, :ok}

        [] ->
          Process.sleep(10)
          {:cont, nil}

        other ->
          flunk("unexpected sends: #{inspect(other)}")
      end
    end)
  end
end
