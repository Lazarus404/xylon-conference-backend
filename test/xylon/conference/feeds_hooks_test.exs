defmodule Xylon.Conference.FeedsHooksTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{Backend, Plan}
  alias Xylon.Control.{Feeds, Presence}
  alias Xylon.{Participant, Session}

  setup do
    start_supervised!(Presence)
    start_supervised!(Feeds)
    :ok = Feeds.clear("t1", "feeds-hook")
    :ok
  end

  test "media_ready puts feed and broadcasts published" do
    session = %Session{id: "feeds-hook", tenant_id: "t1"}
    assert {:ok, state} = Backend.init(session, session_pid: self(), subscribe_mode: :manual)
    on_exit(fn -> Plan.delete(state.plan_ref) end)

    a = %Participant{id: "a", peer_ref: self()}
    assert {:ok, state} = Backend.participant_joined(a, state)
    assert :ok = Presence.subscribe("t1", "feeds-hook", "viewer", self())

    offer = """
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=rtpmap:111 opus/48000/2
    a=ssrc:1001 cname:a
    """

    assert {:ok, _state} = Backend.media_ready(a, offer, %{forwarder: nil}, state)

    assert_receive {:xylon_control_presence,
                    %{
                      type: :feeds_diff,
                      action: :published,
                      participant_id: "a",
                      streams: [%{mid: "0", kind: "audio", codec: "opus"}]
                    }}

    assert [
             %{
               participant_id: "a",
               streams: [%{mid: "0", kind: "audio", codec: "opus"}]
             }
           ] = Feeds.list("t1", "feeds-hook")
  end

  test "participant_left deletes feed and broadcasts unpublished" do
    session = %Session{id: "feeds-hook", tenant_id: "t1"}
    assert {:ok, state} = Backend.init(session, session_pid: self(), subscribe_mode: :manual)
    on_exit(fn -> Plan.delete(state.plan_ref) end)

    a = %Participant{id: "a", peer_ref: self()}
    assert {:ok, state} = Backend.participant_joined(a, state)

    offer = """
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=ssrc:1001 cname:a
    """

    assert {:ok, state} = Backend.media_ready(a, offer, %{forwarder: nil}, state)
    assert :ok = Presence.subscribe("t1", "feeds-hook", "viewer", self())
    # drain published from media_ready if any still in mailbox from put
    _ = flush_feeds()

    assert {:ok, _state} = Backend.participant_left(a, state)

    assert_receive {:xylon_control_presence,
                    %{type: :feeds_diff, action: :unpublished, participant_id: "a"}}

    assert [] = Feeds.list("t1", "feeds-hook")
  end

  test "unpublish refreshes or deletes feeds while participant stays" do
    session = %Session{id: "feeds-hook", tenant_id: "t1"}
    assert {:ok, state} = Backend.init(session, session_pid: self(), subscribe_mode: :manual)
    on_exit(fn -> Plan.delete(state.plan_ref) end)

    a = %Participant{id: "a", peer_ref: self()}
    assert {:ok, state} = Backend.participant_joined(a, state)
    assert :ok = Presence.subscribe("t1", "feeds-hook", "viewer", self())

    offer = """
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=rtpmap:111 opus/48000/2
    a=ssrc:1001 cname:a
    m=video 9 UDP/TLS/RTP/SAVPF 96
    a=rtpmap:96 VP8/90000
    a=ssrc:2002 cname:a
    """

    assert {:ok, state} = Backend.media_ready(a, offer, %{forwarder: nil}, state)
    _ = flush_feeds()

    assert {:ok, state} = Backend.unpublish("a", ["1"], [], state)

    assert_receive {:xylon_control_presence,
                    %{
                      type: :feeds_diff,
                      action: :published,
                      participant_id: "a",
                      streams: [%{mid: "0", kind: "audio", codec: "opus"}]
                    }}

    assert [
             %{
               participant_id: "a",
               streams: [%{mid: "0", kind: "audio", codec: "opus"}]
             }
           ] = Feeds.list("t1", "feeds-hook")

    assert {:ok, _state} = Backend.unpublish("a", ["0"], [], state)

    assert_receive {:xylon_control_presence,
                    %{type: :feeds_diff, action: :unpublished, participant_id: "a"}}

    assert [] = Feeds.list("t1", "feeds-hook")
    assert Plan.get_participant(state.plan_ref, "a")
  end

  test "unpublish clears remb_rates only when video is unpublished" do
    session = %Session{id: "feeds-hook", tenant_id: "t1"}
    assert {:ok, state} = Backend.init(session, session_pid: self(), subscribe_mode: :manual)
    on_exit(fn -> Plan.delete(state.plan_ref) end)

    a = %Participant{id: "a", peer_ref: self()}
    assert {:ok, state} = Backend.participant_joined(a, state)

    offer = """
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=ssrc:1001 cname:a
    m=video 9 UDP/TLS/RTP/SAVPF 96
    a=ssrc:2002 cname:a
    """

    assert {:ok, state} = Backend.media_ready(a, offer, %{forwarder: nil}, state)
    assert :ok = Xylon.Conference.Runtime.put_remb(state.plan_ref, %{"a" => %{"b" => 250_000}})

    assert {:ok, state} = Backend.unpublish("a", ["0"], [], state)
    assert %{"a" => %{"b" => 250_000}} = Xylon.Conference.Runtime.get_remb(state.plan_ref)

    assert {:ok, _state} = Backend.unpublish("a", ["1"], [], state)
    assert %{} = Xylon.Conference.Runtime.get_remb(state.plan_ref)
  end

  defp flush_feeds do
    receive do
      {:xylon_control_presence, %{type: :feeds_diff}} -> flush_feeds()
    after
      0 -> :ok
    end
  end
end
