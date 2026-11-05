defmodule Xylon.Conference.TrunkCascadeTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{FakePeer, Plan}
  alias Xylon.Trunk.{Bridge, Manager}
  alias Xylon.{Forwarder, Participant, Session}
  alias XMediaLib.Rtp

  @master_key <<0xE1F97A0D3E018BE0D64FA32C06DE4139::size(128)>>
  @master_salt <<0x0EC675AD498AFEEBB6960B3AABE6::size(112)>>

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    :ok
  end

  test "A/V from edge A FakePeer reaches edge B FakePeer through UDP trunk" do
    assert {:ok, session_a} = Session.create("t1", "cascade-a", :conference)
    assert {:ok, session_b} = Session.create("t1", "cascade-b", :conference)
    fwd_a = Session.forwarder(session_a)
    fwd_b = Session.forwarder(session_b)
    plan_a = Session.plan_ref(session_a)
    plan_b = Session.plan_ref(session_b)

    assert {:ok, %{a: trunk_a, b: trunk_b}} =
             Manager.connect_pair(session_a, session_b,
               id_a: "trunk_ab",
               id_b: "trunk_ba",
               master_key: @master_key,
               master_salt: @master_salt
             )

    assert {:ok, bridge_a} = Bridge.start_link(forwarder: fwd_a)
    assert {:ok, bridge_b} = Bridge.start_link(forwarder: fwd_b)
    assert :ok = Bridge.attach_pipe(bridge_a, trunk_a.peer_ref)
    assert :ok = Bridge.attach_pipe(bridge_b, trunk_b.peer_ref)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a, role: :publisher}
    b = %Participant{id: "b", peer_ref: peer_b, role: :subscriber}

    assert :ok = Plan.put_participant(plan_a, a)
    assert :ok = Plan.put_participant(plan_a, trunk_a)
    assert :ok = Plan.put_participant(plan_b, b)

    remote_a = %{trunk_a | id: "a", role: :publisher, peer_ref: trunk_b.peer_ref, meta: %{remote: true}}
    assert :ok = Plan.put_participant(plan_b, remote_a)
    assert :ok = Forwarder.put_plan(fwd_a, peer_a, %{mode: :sfu, participant: a})
    assert :ok = Forwarder.put_plan(fwd_b, trunk_b.peer_ref, %{mode: :sfu, participant: remote_a})

    assert :ok = Xylon.Conference.publish(plan_a, "a", %{mid: "0", kind: :audio, ssrc: 900})

    assert :ok =
             Xylon.Conference.subscribe(plan_a, "trunk_ab", "a", "0",
               dest_type: :trunk,
               forwarder: fwd_a
             )

    [route] = Plan.routes_for_inbound(plan_a, "a", 900)
    out_ssrc = route.rewrite.out_ssrc

    assert :ok =
             Xylon.Conference.publish(plan_b, "a", %{mid: "0", kind: :audio, ssrc: out_ssrc})

    assert :ok =
             Xylon.Conference.subscribe(plan_b, "b", "a", "0", forwarder: fwd_b)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 900,
      csrcs: [],
      extension: nil,
      payload: "cross-edge"
    }

    before = XGW.Trunk.Pipe.stats(trunk_a.peer_ref)
    send(fwd_a, {:xgw, :rtp, peer_a, rtp, %{}})

    assert_receive_forwarded(peer_b, out_ssrc)

    after_stats = XGW.Trunk.Pipe.stats(trunk_a.peer_ref)
    assert after_stats.udp_out > before.udp_out
  end

  defp assert_receive_forwarded(peer, inbound_ssrc) do
    Enum.reduce_while(1..80, nil, fn _, _ ->
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
      _ -> flunk("timed out waiting for forwarded send_rtp")
    end
  end
end
