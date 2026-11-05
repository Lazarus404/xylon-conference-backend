defmodule Xylon.Conference.MediaReadyTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{Backend, FakePeer, Plan}
  alias Xylon.{Participant, Session}
  alias XMediaLib.Rtp

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    :ok
  end

  test "media_ready meshes two peers from offer SSRCs" do
    assert {:ok, session} = Session.create("t1", "mesh-ready", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}

    state = :sys.get_state(fwd).backend_state
    assert {:ok, state} = Backend.participant_joined(a, state)
    assert {:ok, state} = Backend.participant_joined(b, state)

    offer_a = """
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=ssrc:1001 cname:a
    """

    offer_b = """
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=ssrc:2002 cname:b
    """

    assert {:ok, state} =
             Backend.media_ready(a, offer_a, %{forwarder: fwd}, state)

    assert {:ok, _state} =
             Backend.media_ready(b, offer_b, %{forwarder: fwd}, state)

    assert Plan.get_track(plan_ref, "a", "0").ssrc == 1001
    assert Plan.get_track(plan_ref, "b", "0").ssrc == 2002

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 1001,
      csrcs: [],
      extension: nil,
      payload: "mesh"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})
    assert_receive_forwarded(peer_b, 1001)
    assert [] = FakePeer.drain(peer_a)
  end

  defp assert_receive_forwarded(peer, inbound_ssrc) do
    Enum.reduce_while(1..50, nil, fn _, _ ->
      case FakePeer.drain(peer) do
        [{:send_rtp, out_ssrc, %Rtp{} = out}] ->
          assert out_ssrc != inbound_ssrc
          assert out.ssrc == out_ssrc
          assert out.payload == "mesh"
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
      _ -> flunk("timed out waiting for mesh forward")
    end
  end
end
