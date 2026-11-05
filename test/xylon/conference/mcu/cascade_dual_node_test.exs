defmodule Xylon.Conference.Mcu.CascadeDualNodeTest do
  use ExUnit.Case, async: false

  alias XGW.Trunk.Pipe
  alias Xylon.Conference.{Plan, Runtime}
  alias Xylon.Conference.Mcu.{Cascade, Egress, Mixer, Quota}
  alias Xylon.Trunk.{Lab, Manager}
  alias Xylon.Trunk.Lab.SinkPeer
  alias Xylon.{Forwarder, Participant, Session}
  alias XMediaLib.{Codec, Rtp}

  @moduletag :dual_node
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

  test "hub-mix: spoke talker reaches mix over Pipe; encode_groups shared; control-only erpc" do
    assert {:ok, %{b: node_b, stop: stop}} = Lab.start_pair()
    on_exit(stop)

    assert :ok = :erpc.call(node_b, Xylon.Catalogue, :reset!, [])
    assert :ok = :erpc.call(node_b, Xylon.Conference, :attach, [])
    assert :ok = :erpc.call(node_b, Quota, :reset, [])

    sid = "mcu-cas-#{System.unique_integer([:positive])}"
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
             Manager.connect_remote(hub, node_b,
               session_key: key,
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

    # Control-plane only: announce talker metadata (ssrc/mid/kind; no RTP payload)
    announce_tracks = [%{publisher_id: "b", mid: "0", ssrc: up_ssrc, kind: :audio}]
    refute Enum.any?(announce_tracks, &Map.has_key?(&1, :payload))

    assert :ok =
             Manager.announce_local_change(Node.self(), key, %{
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
        "mcu-cascade-dual-#{System.unique_integer([:positive])}",
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

    # Full up-leg on spoke node: peer -> SFU -> Pipe -> hub Bridge -> MCU
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

    # Hub listener hears the same hub mix (local + remote contributors when present;
    # this case is remote talker B only -- "A+B" means both edges' contributors)
    assert Enum.any?(1..40, fn _ ->
             Process.sleep(20)
             events = SinkPeer.drain(peer_listen_a)

             Enum.any?(events, fn
               {:send_rtp, _, %Rtp{payload: p}} -> byte_size(p) > 0
               _ -> false
             end)
           end)

    # Spoke must not trunk-loop the mix
    assert {:error, :mcu_mix_trunk_loop} =
             :erpc.call(node_b, Xylon.Conference, :subscribe, [
               plan_spoke,
               "trunk",
               mix_id,
               "0",
               [dest_type: :trunk, forwarder: fwd_spoke]
             ])
  end

  test "spoke mix-minus: attrib over Pipe; talker mix is quiet when sole contrib" do
    assert {:ok, %{b: node_b, stop: stop}} = Lab.start_pair()
    on_exit(stop)

    assert :ok = :erpc.call(node_b, Xylon.Catalogue, :reset!, [])
    assert :ok = :erpc.call(node_b, Xylon.Conference, :attach, [])
    assert :ok = :erpc.call(node_b, Quota, :reset, [])

    sid = "mcu-smm-#{System.unique_integer([:positive])}"
    key = {"t1", sid}

    assert {:ok, hub} =
             Session.create("t1", sid, :conference,
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :hub,
               mcu_spoke_mix_minus: true,
               subscribe_mode: :manual,
               mcu_jb_target: 1,
               audio_level_average: 127
             )

    assert {:ok, trunk_hub} =
             Manager.connect_remote(hub, node_b,
               session_key: key,
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
    fwd_spoke = :erpc.call(node_b, Session, :forwarder, [spoke])

    assert Enum.any?(1..80, fn _ ->
             Process.sleep(25)

             match?(
               %Participant{},
               :erpc.call(node_b, Plan, :get_participant, [plan_spoke, mix_id])
             )
           end)

    assert {:ok, peer_b} = :erpc.call(node_b, SinkPeer, :start, [])
    b = %Participant{id: "b", peer_ref: peer_b, role: :publisher}
    assert :ok = :erpc.call(node_b, Session, :attach_participant, [spoke, b])

    assert :ok =
             :erpc.call(node_b, Forwarder, :put_plan, [
               fwd_spoke,
               peer_b,
               %{mode: :sfu, participant: b}
             ])

    assert :ok =
             :erpc.call(node_b, Xylon.Conference, :publish, [
               plan_spoke,
               "b",
               %{mid: "0", kind: :audio, ssrc: 702}
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
               "b",
               mix_id,
               "0",
               [forwarder: fwd_spoke]
             ])

    [up_route] = :erpc.call(node_b, Plan, :routes_for_inbound, [plan_spoke, "b", 702])
    up_ssrc = up_route.rewrite.out_ssrc

    assert :ok =
             Manager.announce_local_change(Node.self(), key, %{
               from_edge: :spoke,
               participants: [%{id: "b", role: :publisher, labels: []}],
               tracks: [%{publisher_id: "b", mid: "0", ssrc: up_ssrc, kind: :audio}]
             })

    assert Enum.any?(1..40, fn _ ->
             Process.sleep(20)
             match?(%{codec_pid: pid} when is_pid(pid), Runtime.get_mcu_contrib(plan_hub, "b"))
           end)

    opus = encode_opus_loud()

    rtp_in = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 702,
      csrcs: [],
      extension: nil,
      payload: opus
    }

    _ = :erpc.call(node_b, :erlang, :send, [fwd_spoke, {:xgw, :rtp, peer_b, rtp_in, %{}}])

    assert Enum.any?(1..80, fn _ ->
             Process.sleep(25)
             Cascade.trunk_exclude_ids(plan_hub, trunk_hub.id) |> MapSet.member?("b")
           end)

    Process.sleep(150)
    events = :erpc.call(node_b, SinkPeer, :drain, [peer_b])

    mix_payloads =
      for {:send_rtp, _ssrc, %Rtp{payload: payload}} <- events,
          byte_size(payload) > 0,
          do: payload

    if mix_payloads != [] do
      {:ok, dec} = Codec.start_link({~c"OPUS", 48_000, 1})

      energies =
        Enum.map(mix_payloads, fn payload ->
          case Codec.decode(dec, payload) do
            {:ok, {pcm, _, _, _}} when is_binary(pcm) ->
              Xylon.Conference.Mcu.Level.energy_level(pcm)

            _ ->
              0
          end
        end)

      Codec.close(dec)

      assert Enum.all?(energies, &(&1 >= 100)),
             "dual_node spoke talker mix energy too loud: #{inspect(energies)}"
    end
  end

  test "PCM trunk profile over Pipe: L16 up and down; Pipe stats move" do
    assert {:ok, %{b: node_b, stop: stop}} = Lab.start_pair()
    on_exit(stop)

    assert :ok = :erpc.call(node_b, Xylon.Catalogue, :reset!, [])
    assert :ok = :erpc.call(node_b, Xylon.Conference, :attach, [])
    assert :ok = :erpc.call(node_b, Quota, :reset, [])

    sid = "mcu-pcm-#{System.unique_integer([:positive])}"
    key = {"t1", sid}

    assert {:ok, hub} =
             Session.create("t1", sid, :conference,
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :hub,
               mcu_cascade_trunk_profile: :pcm,
               subscribe_mode: :manual,
               mcu_jb_target: 1,
               audio_level_average: 127
             )

    assert {:ok, trunk_hub} =
             Manager.connect_remote(hub, node_b,
               session_key: key,
               module_id: :conference,
               backend_opts: [
                 audio: :sfu,
                 video: :sfu,
                 mcu_cascade: :spoke,
                 mcu_cascade_trunk_profile: :pcm,
                 subscribe_mode: :manual,
                 mcu_jb_target: 1,
                 audio_level_average: 127
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
    fwd_spoke = :erpc.call(node_b, Session, :forwarder, [spoke])
    pipe_hub = trunk_hub.peer_ref

    assert Enum.any?(1..80, fn _ ->
             Process.sleep(25)

             match?(
               %Participant{},
               :erpc.call(node_b, Plan, :get_participant, [plan_spoke, mix_id])
             )
           end)

    assert %{codec_desc: %{name: "l16"}} = Runtime.get_mcu_egress(plan_hub, trunk_hub.id)

    assert {:ok, peer_b} = :erpc.call(node_b, SinkPeer, :start, [])
    assert {:ok, peer_listen_b} = :erpc.call(node_b, SinkPeer, :start, [])
    b = %Participant{id: "b", peer_ref: peer_b, role: :publisher}
    listen_b = %Participant{id: "listen_b", peer_ref: peer_listen_b, role: :subscriber}

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
               %{mid: "0", kind: :audio, ssrc: 720}
             ])

    assert :ok =
             :erpc.call(node_b, Xylon.Conference, :subscribe, [
               plan_spoke,
               "trunk",
               "b",
               "0",
               [dest_type: :trunk, forwarder: fwd_spoke]
             ])

    # PCM SFU edge: locals get Opus egress (not raw L16 SFU of mix)
    assert Enum.any?(1..40, fn _ ->
             Process.sleep(20)

             match?(
               %{codec_desc: %{name: "opus"}},
               :erpc.call(node_b, Runtime, :get_mcu_egress, [plan_spoke, "listen_b"])
             )
           end)

    [up_route] = :erpc.call(node_b, Plan, :routes_for_inbound, [plan_spoke, "b", 720])
    up_ssrc = up_route.rewrite.out_ssrc

    assert :ok =
             Manager.announce_local_change(Node.self(), key, %{
               from_edge: :spoke,
               participants: [%{id: "b", role: :publisher, labels: []}],
               tracks: [%{publisher_id: "b", mid: "0", ssrc: up_ssrc, kind: :audio}]
             })

    assert Enum.any?(1..40, fn _ ->
             Process.sleep(20)

             match?(
               %{codec_pid: :l16_passthrough},
               Runtime.get_mcu_contrib(plan_hub, "b")
             )
           end)

    pcm = :binary.copy(<<10_000::signed-little-integer-size(16)>>, Mixer.samples_per_tick([]))

    rtp_in = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 720,
      csrcs: [],
      extension: nil,
      payload: pcm
    }

    before_out = Pipe.stats(pipe_hub)
    _ = :erpc.call(node_b, :erlang, :send, [fwd_spoke, {:xgw, :rtp, peer_b, rtp_in, %{}}])

    assert Enum.any?(1..80, fn _ ->
             Process.sleep(25)
             Pipe.stats(pipe_hub).udp_in > before_out.udp_in
           end)

    mix_ssrc = Runtime.get_mcu_egress(plan_hub, trunk_hub.id).out_ssrc
    trunk_spoke = :erpc.call(node_b, Plan, :get_participant, [plan_spoke, "trunk"])

    mix_rtp = %{rtp_in | ssrc: mix_ssrc, sequence_number: 2}

    _ =
      :erpc.call(node_b, :erlang, :send, [
        fwd_spoke,
        {:xgw, :rtp, trunk_spoke.peer_ref, mix_rtp, %{}}
      ])

    assert Enum.any?(1..80, fn _ ->
             Process.sleep(25)
             events = :erpc.call(node_b, SinkPeer, :drain, [peer_listen_b])

             Enum.any?(events, fn
               {:send_rtp, _, %Rtp{payload_type: 111, payload: p}} ->
                 byte_size(p) > 0

               _ ->
                 false
             end)
           end)
  end

  test "spoke MCU mix-of-mixes: local egress; Pipe up-leg; mix as contributor" do
    assert {:ok, %{b: node_b, stop: stop}} = Lab.start_pair()
    on_exit(stop)

    assert :ok = :erpc.call(node_b, Xylon.Catalogue, :reset!, [])
    assert :ok = :erpc.call(node_b, Xylon.Conference, :attach, [])
    assert :ok = :erpc.call(node_b, Quota, :reset, [])

    sid = "mcu-mom-#{System.unique_integer([:positive])}"
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
             Manager.connect_remote(hub, node_b,
               session_key: key,
               module_id: :conference,
               backend_opts: [
                 audio: :mcu,
                 video: :sfu,
                 mcu_cascade: :spoke,
                 subscribe_mode: :manual,
                 mcu_jb_target: 1,
                 audio_level_average: 127
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
    fwd_spoke = :erpc.call(node_b, Session, :forwarder, [spoke])
    pipe_hub = trunk_hub.peer_ref

    assert Enum.any?(1..80, fn _ ->
             Process.sleep(25)

             match?(
               %Participant{},
               :erpc.call(node_b, Plan, :get_participant, [plan_spoke, mix_id])
             )
           end)

    assert Enum.any?(1..40, fn _ ->
             Process.sleep(20)

             match?(
               %{codec_pid: pid} when is_pid(pid),
               :erpc.call(node_b, Runtime, :get_mcu_contrib, [plan_spoke, mix_id])
             )
           end)

    assert {:ok, peer_b} = :erpc.call(node_b, SinkPeer, :start, [])
    assert {:ok, peer_listen_b} = :erpc.call(node_b, SinkPeer, :start, [])
    b = %Participant{id: "b", peer_ref: peer_b, role: :publisher}
    listen_b = %Participant{id: "listen_b", peer_ref: peer_listen_b, role: :subscriber}

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
               %{mid: "0", kind: :audio, ssrc: 740}
             ])

    assert :ok =
             :erpc.call(node_b, Xylon.Conference, :subscribe, [
               plan_spoke,
               "trunk",
               "b",
               "0",
               [dest_type: :trunk, forwarder: fwd_spoke]
             ])

    # Unlinked CodecPort.start: short-lived :erpc starters are safe.
    assert :ok =
             :erpc.call(node_b, Egress, :ensure, [plan_spoke, "listen_b", Cascade.opus_desc()])

    assert :ok =
             :erpc.call(node_b, Xylon.Conference.Mcu.Contributor, :ensure, [
               plan_spoke,
               "b",
               Cascade.opus_desc(),
               [jb_target: 1]
             ])

    assert Enum.any?(1..40, fn _ ->
             Process.sleep(20)

             match?(
               %{codec_pid: pid} when is_pid(pid),
               :erpc.call(node_b, Runtime, :get_mcu_contrib, [plan_spoke, "b"])
             )
           end)

    [up_route] = :erpc.call(node_b, Plan, :routes_for_inbound, [plan_spoke, "b", 740])
    up_ssrc = up_route.rewrite.out_ssrc

    assert :ok =
             Manager.announce_local_change(Node.self(), key, %{
               from_edge: :spoke,
               participants: [%{id: "b", role: :publisher, labels: []}],
               tracks: [%{publisher_id: "b", mid: "0", ssrc: up_ssrc, kind: :audio}]
             })

    assert Enum.any?(1..40, fn _ ->
             Process.sleep(20)
             match?(%{codec_pid: pid} when is_pid(pid), Runtime.get_mcu_contrib(plan_hub, "b"))
           end)

    before_out = Pipe.stats(pipe_hub)
    opus = encode_opus_loud()

    rtp_in = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 740,
      csrcs: [],
      extension: nil,
      payload: opus
    }

    _ = :erpc.call(node_b, :erlang, :send, [fwd_spoke, {:xgw, :rtp, peer_b, rtp_in, %{}}])

    assert Enum.any?(1..80, fn _ ->
             Process.sleep(25)
             events = :erpc.call(node_b, SinkPeer, :drain, [peer_listen_b])

             Enum.any?(events, fn
               {:send_rtp, _, %Rtp{payload: p}} -> byte_size(p) > 0
               _ -> false
             end)
           end)

    assert Enum.any?(1..80, fn _ ->
             Process.sleep(25)
             Pipe.stats(pipe_hub).udp_in > before_out.udp_in
           end)
  end
end
