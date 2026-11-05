defmodule Xylon.Conference.Mcu.AdmissionTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{Backend, FakePeer, Plan}
  alias Xylon.Conference.Mcu.Quota
  alias Xylon.Participant
  alias Xylon.Session

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    Quota.reset()
    prev = Application.get_env(:xylon_conference_backend, :mcu_quota)

    on_exit(fn ->
      Quota.reset()
      Application.put_env(:xylon_conference_backend, :mcu_quota, prev)
    end)

    :ok
  end

  test "Session.create with audio mcu registers mixer; SFU does not" do
    assert {:ok, sfu} = Session.create("t1", "adm-sfu", :conference, audio: :sfu)
    assert Quota.totals().mixers == 0
    _ = Session.hangup(sfu)

    assert {:ok, mcu} = Session.create("t1", "adm-mcu", :conference, audio: :mcu, video: :sfu)
    assert Quota.totals().mixers == 1
    _ = Session.hangup(mcu)
    assert Quota.totals().mixers == 0
  end

  test "node max_mixers rejects second MCU Session.create" do
    Application.put_env(:xylon_conference_backend, :mcu_quota, max_mixers: 1)

    assert {:ok, first} = Session.create("t1", "adm-mix-1", :conference, audio: :mcu, video: :sfu)

    assert {:error, :mcu_max_mixers} =
             Session.create("t1", "adm-mix-2", :conference, audio: :mcu, video: :sfu)

    _ = Session.hangup(first)
  end

  test "mcu_max_participants rejects second join" do
    assert {:ok, session} =
             Session.create("t1", "adm-part", :conference,
               audio: :mcu,
               video: :sfu,
               mcu_max_participants: 1
             )

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}

    assert :ok = Session.attach_participant(session, a)

    assert {:error, :mcu_max_participants} = Session.attach_participant(session, b)

    _ = Session.hangup(session)
  end

  test "mcu_max_contributors rejects second media_ready with audio send" do
    assert {:ok, session} =
             Session.create("t1", "adm-contrib", :conference,
               audio: :mcu,
               video: :sfu,
               mcu_max_contributors: 1,
               subscribe_mode: :manual
             )

    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}

    state = :sys.get_state(fwd).backend_state
    assert {:ok, state} = Backend.participant_joined(a, state)
    assert {:ok, state} = Backend.participant_joined(b, state)

    offer =
      """
      v=0
      o=- 0 0 IN IP4 127.0.0.1
      s=-
      t=0 0
      m=audio 9 UDP/TLS/RTP/SAVPF 111
      a=mid:0
      a=sendrecv
      a=rtpmap:111 opus/48000/2
      a=ssrc:1001 cname:a
      """

    offer_b =
      """
      v=0
      o=- 0 0 IN IP4 127.0.0.1
      s=-
      t=0 0
      m=audio 9 UDP/TLS/RTP/SAVPF 111
      a=mid:0
      a=sendrecv
      a=rtpmap:111 opus/48000/2
      a=ssrc:2002 cname:b
      """

    assert {:ok, state} = Backend.media_ready(a, offer, %{forwarder: fwd}, state)

    assert {:error, :mcu_max_contributors} =
             Backend.media_ready(b, offer_b, %{forwarder: fwd}, state)

    assert Plan.get_track(plan_ref, "b", "0") == nil
    _ = Session.hangup(session)
  end
end
