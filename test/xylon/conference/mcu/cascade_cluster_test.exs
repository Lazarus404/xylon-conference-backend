defmodule Xylon.Conference.Mcu.CascadeClusterTest do
  use ExUnit.Case, async: false

  alias XGW.Trunk.Pipe
  alias Xylon.Cluster
  alias Xylon.Cluster.Trunk
  alias Xylon.Conference.{Plan, Runtime}
  alias Xylon.Conference.Mcu.{Cascade, Egress, Mixer, Quota}
  alias Xylon.Trunk.Lab
  alias Xylon.Trunk.Lab.SinkPeer
  alias Xylon.{Forwarder, Participant, Session}
  alias XMediaLib.{Codec, Rtp}

  @moduletag :cluster
  @moduletag :opus

  @key_ab <<0xE1F97A0D3E018BE0D64FA32C06DE4139::size(128)>>
  @salt_ab <<0x0EC675AD498AFEEBB6960B3AABE6::size(112)>>
  @key_ba <<0xA1B2C3D4E5F60718293A4B5C6D7E8F90::size(128)>>
  @salt_ba <<0x112233445566778899AABBCCDDEE::size(112)>>

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    Quota.reset()
    on_exit(fn -> Quota.reset() end)
    :ok
  end

  defp encode_opus_loud do
    samples = Mixer.samples_per_tick([])
    pcm = :binary.copy(<<10_000::signed-little-integer-size(16)>>, samples)
    {:ok, codec} = Codec.start_link({~c"OPUS", 48_000, 1})
    assert {:ok, opus} = Codec.encode(codec, {pcm, 48_000, 1, 16})
    Codec.close(codec)
    opus
  end

  test "hub-mix over start_hubs regions: spoke talker, encode_groups, Pipe stats" do
    assert {:ok, %{b: node_b, regions: {ra, rb}, stop: stop}} =
             Lab.start_hubs(["us-west-2", "eu-central-1"])

    on_exit(stop)

    assert Cluster.local_region() == ra
    assert :erpc.call(node_b, Cluster, :local_region, []) == rb
    assert Cluster.hub?()
    assert :erpc.call(node_b, Cluster, :hub?, [])

    assert :ok = :erpc.call(node_b, Xylon.Catalogue, :reset!, [])
    assert :ok = :erpc.call(node_b, Xylon.Conference, :attach, [])
    assert :ok = :erpc.call(node_b, Quota, :reset, [])

    sid = "mcu-cl-#{System.unique_integer([:positive])}"
    key = {"t1", sid}

    assert {:ok, hub} =
             Session.create("t1", sid, :conference,
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :hub,
               subscribe_mode: :manual,
               mcu_jb_target: 1,
               audio_level_average: 127
             )

    assert {:ok, trunk_hub} =
             Trunk.connect_hubs(key, node_b,
               module_id: :conference,
               backend_opts: [
                 audio: :sfu,
                 video: :sfu,
                 mcu_cascade: :spoke,
                 subscribe_mode: :manual
               ],
               key_ab: @key_ab,
               salt_ab: @salt_ab,
               key_ba: @key_ba,
               salt_ba: @salt_ba
             )

    assert [{spoke, _}] = :erpc.call(node_b, Registry, :lookup, [Xylon.Registry, key])
    mix_id = Cascade.mix_publisher_id()
    plan_hub = Session.plan_ref(hub)
    plan_spoke = :erpc.call(node_b, Session, :plan_ref, [spoke])
    fwd_hub = Session.forwarder(hub)
    fwd_spoke = :erpc.call(node_b, Session, :forwarder, [spoke])
    pipe_hub = trunk_hub.peer_ref

    assert Enum.any?(Cluster.Presence.cohosts(key), &(&1.region_id == ra))
    assert Enum.any?(Cluster.Presence.cohosts(key), &(&1.region_id == rb))

    assert Enum.any?(1..80, fn _ ->
             Process.sleep(25)

             match?(
               %Participant{},
               :erpc.call(node_b, Plan, :get_participant, [plan_spoke, mix_id])
             )
           end)

    mix_ssrc = Runtime.get_mcu_egress(plan_hub, "trunk").out_ssrc

    assert {:ok, peer_listen_a} = SinkPeer.start_link()
    assert {:ok, peer_b} = :erpc.call(node_b, SinkPeer, :start, [])
    assert {:ok, peer_listen_b} = :erpc.call(node_b, SinkPeer, :start, [])

    listen_a = %Participant{id: "listen_a", peer_ref: peer_listen_a, role: :subscriber}
    b = %Participant{id: "b", peer_ref: peer_b, role: :publisher}
    listen_b = %Participant{id: "listen_b", peer_ref: peer_listen_b, role: :subscriber}

    assert :ok = Session.attach_participant(hub, listen_a)
    assert :ok = Forwarder.put_plan(fwd_hub, peer_listen_a, %{mode: :sfu, participant: listen_a})
    assert :ok = Egress.ensure(plan_hub, "listen_a", Cascade.opus_desc())

    assert :ok = :erpc.call(node_b, Session, :attach_participant, [spoke, b])
    assert :ok = :erpc.call(node_b, Session, :attach_participant, [spoke, listen_b])

    assert :ok =
             :erpc.call(node_b, Forwarder, :put_plan, [
               fwd_spoke,
               peer_b,
               %{mode: :sfu, participant: b}
             ])

    assert :ok =
             :erpc.call(node_b, Forwarder, :put_plan, [
               fwd_spoke,
               peer_listen_b,
               %{mode: :sfu, participant: listen_b}
             ])

    assert :ok =
             :erpc.call(node_b, Xylon.Conference, :publish, [
               plan_spoke,
               "b",
               %{mid: "0", kind: :audio, ssrc: 700}
             ])

    assert :ok =
             :erpc.call(node_b, Xylon.Conference, :subscribe, [
               plan_spoke,
               "trunk",
               "b",
               "0",
               [dest_type: :trunk, forwarder: fwd_spoke]
             ])

    assert :ok =
             :erpc.call(node_b, Xylon.Conference, :subscribe, [
               plan_spoke,
               "listen_b",
               mix_id,
               "0",
               [forwarder: fwd_spoke]
             ])

    [up_route] = :erpc.call(node_b, Plan, :routes_for_inbound, [plan_spoke, "b", 700])
    up_ssrc = up_route.rewrite.out_ssrc

    announce_tracks = [%{publisher_id: "b", mid: "0", ssrc: up_ssrc, kind: :audio}]
    refute Enum.any?(announce_tracks, &Map.has_key?(&1, :payload))

    assert :ok =
             Xylon.Trunk.Manager.announce_local_change(Node.self(), key, %{
               from_edge: :spoke,
               participants: [%{id: "b", role: :publisher, labels: []}],
               tracks: announce_tracks
             })

    assert Enum.any?(1..40, fn _ ->
             Process.sleep(20)
             match?(%{codec_pid: pid} when is_pid(pid), Runtime.get_mcu_contrib(plan_hub, "b"))
           end)

    parent = self()

    :ok =
      :telemetry.attach(
        "mcu-cascade-cluster-#{System.unique_integer([:positive])}",
        [:xylon, :conference, :mcu, :tick],
        fn _e, measurements, _meta, _ ->
          send(parent, {:mcu_tick, measurements})
        end,
        nil
      )

    before_out = Pipe.stats(pipe_hub)
    before_in = before_out
    opus = encode_opus_loud()

    rtp_in = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 700,
      csrcs: [],
      extension: nil,
      payload: opus
    }

    _ = :erpc.call(node_b, :erlang, :send, [fwd_spoke, {:xgw, :rtp, peer_b, rtp_in, %{}}])

    assert_receive {:mcu_tick, %{encode_groups: n}} when n >= 1, 2_000

    assert Enum.any?(1..80, fn _ ->
             Process.sleep(25)
             events = :erpc.call(node_b, SinkPeer, :drain, [peer_listen_b])

             Enum.any?(events, fn
               {:send_rtp, ^mix_ssrc, %Rtp{payload: p}} -> byte_size(p) > 0
               {:send_rtp, _ssrc, %Rtp{payload: p}} -> byte_size(p) > 0
               _ -> false
             end)
           end)

    after_stats = Pipe.stats(pipe_hub)
    assert after_stats.udp_in > before_in.udp_in
    assert after_stats.udp_out > before_out.udp_out

    assert Enum.any?(1..40, fn _ ->
             Process.sleep(20)
             events = SinkPeer.drain(peer_listen_a)

             Enum.any?(events, fn
               {:send_rtp, _, %Rtp{payload: p}} -> byte_size(p) > 0
               _ -> false
             end)
           end)

    assert {:error, :mcu_mix_trunk_loop} =
             :erpc.call(node_b, Xylon.Conference, :subscribe, [
               plan_spoke,
               "trunk",
               mix_id,
               "0",
               [dest_type: :trunk, forwarder: fwd_spoke]
             ])
  end
end
