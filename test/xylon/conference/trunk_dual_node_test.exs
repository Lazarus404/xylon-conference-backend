defmodule Xylon.Conference.TrunkDualNodeTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.Plan
  alias Xylon.Trunk.{Lab, Manager}
  alias Xylon.Trunk.Lab.SinkPeer
  alias Xylon.{Forwarder, Participant, Session}
  alias XMediaLib.Rtp

  @moduletag :dual_node

  @key_ab <<0xE1F97A0D3E018BE0D64FA32C06DE4139::size(128)>>
  @salt_ab <<0x0EC675AD498AFEEBB6960B3AABE6::size(112)>>
  @key_ba <<0xA1B2C3D4E5F60718293A4B5C6D7E8F90::size(128)>>
  @salt_ba <<0x112233445566778899AABBCCDDEE::size(112)>>

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    :ok
  end

  test "audio and video cross dual-node trunk with auto Bridge" do
    assert {:ok, %{b: node_b, stop: stop}} = Lab.start_pair()
    on_exit(stop)

    assert :ok = :erpc.call(node_b, Xylon.Catalogue, :reset!, [])
    assert :ok = :erpc.call(node_b, Xylon.Conference, :attach, [])

    sid = "av-#{System.unique_integer([:positive])}"
    key = {"t1", sid}

    assert {:ok, session_a} =
             Session.create("t1", sid, :conference, subscribe_mode: :manual)

    assert {:ok, _trunk_a} =
             Manager.connect_remote(session_a, node_b,
               session_key: key,
               module_id: :conference,
               backend_opts: [subscribe_mode: :manual],
               key_ab: @key_ab,
               salt_ab: @salt_ab,
               key_ba: @key_ba,
               salt_ba: @salt_ba
             )

    assert [{session_b, _}] = :erpc.call(node_b, Registry, :lookup, [Xylon.Registry, key])

    fwd_a = Session.forwarder(session_a)
    plan_a = Session.plan_ref(session_a)
    fwd_b = :erpc.call(node_b, Session, :forwarder, [session_b])
    plan_b = :erpc.call(node_b, Session, :plan_ref, [session_b])

    assert {:ok, peer_a} = SinkPeer.start_link()
    assert {:ok, peer_b} = :erpc.call(node_b, SinkPeer, :start, [])

    a = %Participant{id: "a", peer_ref: peer_a, role: :publisher}
    b = %Participant{id: "b", peer_ref: peer_b, role: :subscriber}

    assert :ok = Plan.put_participant(plan_a, a)
    assert :ok = Forwarder.put_plan(fwd_a, peer_a, %{mode: :sfu, participant: a})
    assert :ok = Session.attach_participant(session_a, a)

    assert :ok =
             :erpc.call(node_b, Plan, :put_participant, [plan_b, b])

    assert :ok =
             :erpc.call(node_b, Forwarder, :put_plan, [
               fwd_b,
               peer_b,
               %{mode: :sfu, participant: b}
             ])

    assert :ok = :erpc.call(node_b, Session, :attach_participant, [session_b, b])

    assert :ok = Xylon.Conference.publish(plan_a, "a", %{mid: "0", kind: :audio, ssrc: 100})
    assert :ok = Xylon.Conference.publish(plan_a, "a", %{mid: "1", kind: :video, ssrc: 200})

    assert :ok =
             Xylon.Conference.subscribe(plan_a, "trunk", "a", "0",
               dest_type: :trunk,
               forwarder: fwd_a
             )

    assert :ok =
             Xylon.Conference.subscribe(plan_a, "trunk", "a", "1",
               dest_type: :trunk,
               forwarder: fwd_a
             )

    [audio_route] = Plan.routes_for_inbound(plan_a, "a", 100)
    [video_route] = Plan.routes_for_inbound(plan_a, "a", 200)
    out_audio = audio_route.rewrite.out_ssrc
    out_video = video_route.rewrite.out_ssrc

    assert :ok =
             Manager.announce_local_change(node_b, key, %{
               from_edge: :edge_a,
               participants: [%{id: "a", role: :publisher, labels: []}],
               tracks: [
                 %{publisher_id: "a", mid: "0", ssrc: out_audio, kind: :audio},
                 %{publisher_id: "a", mid: "1", ssrc: out_video, kind: :video}
               ]
             })

    rtp_a = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 100,
      csrcs: [],
      extension: nil,
      payload: "audio"
    }

    rtp_v = %{rtp_a | ssrc: 200, payload_type: 96, payload: "video", sequence_number: 2}

    send(fwd_a, {:xgw, :rtp, peer_a, rtp_a, %{}})
    send(fwd_a, {:xgw, :rtp, peer_a, rtp_v, %{}})

    assert wait_audio_video(peer_b, node_b, out_audio, out_video)
  end

  defp wait_audio_video(peer_b, node_b, _out_audio, _out_video) do
    Enum.reduce_while(1..100, 0, fn _, count ->
      events = :erpc.call(node_b, SinkPeer, :drain, [peer_b])
      n = count + Enum.count(events, &match?({:send_rtp, _, _}, &1))

      if n >= 2 do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, n}
      end
    end)
    |> case do
      true -> true
      n -> flunk("expected >= 2 RTP deliveries on edge B, got #{n}")
    end
  end
end
