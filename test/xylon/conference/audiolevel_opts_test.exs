defmodule Xylon.Conference.AudiolevelOptsTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.Backend
  alias Xylon.Session

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    :ok
  end

  test "init stores audiolevel defaults" do
    session = %Session{id: "s1", tenant_id: "t1"}
    assert {:ok, state} = Backend.init(session, session_pid: self())
    assert state.audiolevel_events == false
    assert state.audio_active_packets == 100
    assert state.audio_level_average == 25
    refute Map.has_key?(state, :audio_level_ext_ids)
    refute Map.has_key?(state, :audio_levels)
  end

  test "init accepts audiolevel room opts" do
    session = %Session{id: "s1", tenant_id: "t1"}

    assert {:ok, state} =
             Backend.init(session,
               session_pid: self(),
               audiolevel_events: true,
               audio_active_packets: 40,
               audio_level_average: 20
             )

    assert state.audiolevel_events == true
    assert state.audio_active_packets == 40
    assert state.audio_level_average == 20
  end

  test "init rejects invalid audiolevel knobs" do
    session = %Session{id: "s1", tenant_id: "t1"}

    assert {:error, {:invalid_audio_active_packets, 0}} =
             Backend.init(session, session_pid: self(), audio_active_packets: 0)

    assert {:error, {:invalid_audio_level_average, 200}} =
             Backend.init(session, session_pid: self(), audio_level_average: 200)
  end

  @offer_with_ext """
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
  a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level
  a=rtcp-mux
  a=sendrecv
  a=rtpmap:111 opus/48000/2
  a=ssrc:1001 cname:a
  """
  |> String.replace("\n", "\r\n")

  test "conference answer keeps ssrc-audio-level extmap when offered" do
    assert {:ok, pid} = Session.create("t1", "audiolevel-sdp", :conference)
    assert {:ok, answer} = Session.apply_offer(pid, @offer_with_ext, participant_id: "a")
    assert answer =~ "urn:ietf:params:rtp-hdrext:ssrc-audio-level"
  end

  test "media_ready records audio-level extmap id from offer" do
    session = %Session{id: "s1", tenant_id: "t1"}
    assert {:ok, state} = Backend.init(session, session_pid: self(), subscribe_mode: :manual)
    on_exit(fn -> Xylon.Conference.Plan.delete(state.plan_ref) end)
    a = %Xylon.Participant{id: "a", peer_ref: self()}
    assert {:ok, state} = Backend.participant_joined(a, state)

    offer = """
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=extmap:3 urn:ietf:params:rtp-hdrext:ssrc-audio-level
    a=ssrc:1001 cname:a
    """

    assert {:ok, _state} = Backend.media_ready(a, offer, %{forwarder: nil}, state)
    assert %{audio_level: 3} = Xylon.Conference.Runtime.get_ext(state.plan_ref, "a")
  end
end
