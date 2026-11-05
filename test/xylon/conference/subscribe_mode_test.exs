defmodule Xylon.Conference.SubscribeModeTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{Backend, FakePeer, Plan}
  alias Xylon.{Participant, Session}
  alias XMediaLib.Rtp

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    :ok
  end

  test "manual mode does not mesh until subscribe" do
    assert {:ok, session} =
             Session.create("t1", "manual-mode", :conference, subscribe_mode: :manual)

    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}

    state = :sys.get_state(fwd).backend_state
    assert {:ok, state} = Backend.participant_joined(a, state)
    assert {:ok, state} = Backend.participant_joined(b, state)

    offer_a = "m=audio 9 UDP/TLS/RTP/SAVPF 111\na=ssrc:1001 cname:a\n"
    offer_b = "m=audio 9 UDP/TLS/RTP/SAVPF 111\na=ssrc:2002 cname:b\n"

    assert {:ok, state} = Backend.media_ready(a, offer_a, %{forwarder: fwd}, state)
    assert {:ok, _state} = Backend.media_ready(b, offer_b, %{forwarder: fwd}, state)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 1001,
      csrcs: [],
      extension: nil,
      payload: "nomesh"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})
    Process.sleep(50)
    assert [] = FakePeer.drain(peer_b)

    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)
    send(fwd, {:xgw, :rtp, peer_a, %{rtp | sequence_number: 2}, %{}})
    assert_receive_forwarded(peer_b, 1001)
  end

  test "Session.subscribe creates routes in manual mode" do
    assert {:ok, session} =
             Session.create("t1", "session-sub", :conference, subscribe_mode: :manual)

    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)
    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}

    state = :sys.get_state(fwd).backend_state
    assert {:ok, state} = Backend.participant_joined(a, state)
    assert {:ok, state} = Backend.participant_joined(b, state)

    offer_a = "m=audio 9 UDP/TLS/RTP/SAVPF 111\na=ssrc:1001 cname:a\n"
    offer_b = "m=audio 9 UDP/TLS/RTP/SAVPF 111\na=ssrc:2002 cname:b\n"
    assert {:ok, state} = Backend.media_ready(a, offer_a, %{forwarder: fwd}, state)
    assert {:ok, _state} = Backend.media_ready(b, offer_b, %{forwarder: fwd}, state)

    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 1001,
      csrcs: [],
      extension: nil,
      payload: "via-session"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})
    assert_receive_forwarded(peer_b, 1001)

    assert :ok = Xylon.Conference.unsubscribe(plan_ref, "b", "a", "0", forwarder: fwd)
    send(fwd, {:xgw, :rtp, peer_a, %{rtp | sequence_number: 2, payload: "gone"}, %{}})
    Process.sleep(50)
    assert [] = FakePeer.drain(peer_b)
  end

  test "max_publishers rejects second publisher before publish" do
    assert {:ok, session} =
             Session.create("t1", "max-pub", :conference, max_publishers: 1)

    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}

    state = :sys.get_state(fwd).backend_state
    assert {:ok, state} = Backend.participant_joined(a, state)
    assert {:ok, state} = Backend.participant_joined(b, state)

    offer_a = "m=audio 9 UDP/TLS/RTP/SAVPF 111\na=ssrc:1001 cname:a\n"
    offer_b = "m=audio 9 UDP/TLS/RTP/SAVPF 111\na=ssrc:2002 cname:b\n"

    assert {:ok, state} = Backend.media_ready(a, offer_a, %{forwarder: fwd}, state)

    assert {:error, :max_publishers} =
             Backend.media_ready(b, offer_b, %{forwarder: fwd}, state)

    assert Plan.get_track(plan_ref, "a", "0").ssrc == 1001
    assert Plan.get_track(plan_ref, "b", "0") == nil
  end

  test "require_publish_cap denies publish without authorize" do
    deny = fn :publish, _ -> false end

    assert {:ok, session} =
             Session.create("t1", "pub-cap-deny", :conference,
               require_publish_cap: true,
               authorize: deny,
               subscribe_mode: :manual
             )

    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)
    assert {:ok, peer_a} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a, meta: %{capabilities: []}}

    state = :sys.get_state(fwd).backend_state
    assert {:ok, state} = Backend.participant_joined(a, state)

    offer = "m=audio 9 UDP/TLS/RTP/SAVPF 111\na=ssrc:1001 cname:a\n"

    assert {:error, :forbidden} =
             Backend.media_ready(a, offer, %{forwarder: fwd}, state)

    assert Plan.get_track(plan_ref, "a", "0") == nil
  end

  test "require_publish_cap allows publish when authorize and capabilities say so" do
    auth = Xylon.Control.Auth.backend_authorize(["publish"])

    assert {:ok, session} =
             Session.create("t1", "pub-cap-ok", :conference,
               require_publish_cap: true,
               authorize: auth,
               subscribe_mode: :manual
             )

    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)
    assert {:ok, peer_a} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a, meta: %{capabilities: ["publish"]}}

    state = :sys.get_state(fwd).backend_state
    assert {:ok, state} = Backend.participant_joined(a, state)

    offer = "m=audio 9 UDP/TLS/RTP/SAVPF 111\na=ssrc:1001 cname:a\n"
    assert {:ok, _} = Backend.media_ready(a, offer, %{forwarder: fwd}, state)
    assert Plan.get_track(plan_ref, "a", "0").ssrc == 1001
  end

  test "require_publish_cap false ignores authorize deny" do
    deny = fn :publish, _ -> false end

    assert {:ok, session} =
             Session.create("t1", "pub-cap-off", :conference,
               require_publish_cap: false,
               authorize: deny
             )

    fwd = Session.forwarder(session)
    assert {:ok, peer_a} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a}

    state = :sys.get_state(fwd).backend_state
    assert {:ok, state} = Backend.participant_joined(a, state)

    offer = "m=audio 9 UDP/TLS/RTP/SAVPF 111\na=ssrc:1001 cname:a\n"
    assert {:ok, _} = Backend.media_ready(a, offer, %{forwarder: fwd}, state)
  end

  test "Session apply_offer forbidden when require_publish_cap and no publish cap" do
    auth = Xylon.Control.Auth.backend_authorize([])

    assert {:ok, session} =
             Session.create("t1", "pub-cap-session", :conference,
               require_publish_cap: true,
               authorize: auth,
               subscribe_mode: :manual
             )

    offer = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    a=group:BUNDLE 0
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    c=IN IP4 0.0.0.0
    a=ice-ufrag:chromeUfrag
    a=ice-pwd:chromepasswordchromepass
    a=fingerprint:sha-256 11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00
    a=setup:actpass
    a=mid:0
    a=rtcp-mux
    a=sendrecv
    a=rtpmap:111 opus/48000/2
    a=ssrc:1001 cname:a
    """
    |> String.replace("\n", "\r\n")

    assert {:error, :forbidden} =
             Session.apply_offer(session, offer,
               participant_id: "spec",
               control_capabilities: []
             )

    assert {:ok, _} =
             Session.apply_offer(session, offer,
               participant_id: "host",
               control_capabilities: ["publish"]
             )
  end

  test "Session apply_offer max_publishers leaves no Plan ghost" do
    assert {:ok, session} =
             Session.create("t1", "max-pub-session", :conference, max_publishers: 1)

    offer = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    a=group:BUNDLE 0
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    c=IN IP4 0.0.0.0
    a=ice-ufrag:chromeUfrag
    a=ice-pwd:chromepasswordchromepass
    a=fingerprint:sha-256 11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00
    a=setup:actpass
    a=mid:0
    a=rtcp-mux
    a=sendrecv
    a=rtpmap:111 opus/48000/2
    a=ssrc:1001 cname:a
    """
    |> String.replace("\n", "\r\n")

    assert {:ok, _} = Session.apply_offer(session, offer, participant_id: "a")

    offer_b =
      String.replace(offer, "a=ssrc:1001 cname:a", "a=ssrc:2002 cname:b")

    assert {:error, :max_publishers} =
             Session.apply_offer(session, offer_b, participant_id: "b")

    plan_ref = Session.plan_ref(session)
    assert Plan.get_participant(plan_ref, "b") == nil
    assert MapSet.member?(Plan.participant_ids(plan_ref), "a")
  end

  defp assert_receive_forwarded(peer, inbound_ssrc) do
    Enum.reduce_while(1..50, nil, fn _, _ ->
      case FakePeer.drain(peer) do
        [{:send_rtp, out_ssrc, %Rtp{} = out}] ->
          assert out_ssrc != inbound_ssrc
          assert out.ssrc == out_ssrc
          {:halt, :ok}

        [] ->
          Process.sleep(10)
          {:cont, nil}

        other ->
          flunk("unexpected sends: #{inspect(other)}")
      end
    end)
    |> case do
      :ok -> :ok
      _ -> flunk("timed out waiting for forward")
    end
  end
end
