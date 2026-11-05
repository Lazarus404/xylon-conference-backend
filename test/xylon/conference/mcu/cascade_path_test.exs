defmodule Xylon.Conference.Mcu.CascadePathTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{FakePeer, Plan, Runtime}
  alias Xylon.Conference.Mcu.{Cascade, Quota}
  alias Xylon.Trunk.Manager
  alias Xylon.{Forwarder, Participant, Session}
  alias XMediaLib.Rtp

  @master_key <<0xE1F97A0D3E018BE0D64FA32C06DE4139::size(128)>>
  @master_salt <<0x0EC675AD498AFEEBB6960B3AABE6::size(112)>>

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    Quota.reset()

    on_exit(fn -> Quota.reset() end)
    :ok
  end

  defp encode_opus_tone do
    samples = Xylon.Conference.Mcu.Mixer.samples_per_tick([])

    pcm =
      for _i <- 1..samples, into: <<>> do
        <<10_000::signed-little-integer-size(16)>>
      end

    {:ok, codec} = XMediaLib.Codec.start_link({~c"OPUS", 48_000, 1})
    assert {:ok, opus} = XMediaLib.Codec.encode(codec, {pcm, 48_000, 1, 16})
    XMediaLib.Codec.close(codec)
    opus
  end

  @tag :opus
  test "connect_pair auto-announces hub mix onto spoke" do
    assert {:ok, hub} =
             Session.create("t1", "mcu-hub-ann", :conference,
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :hub,
               subscribe_mode: :manual
             )

    assert {:ok, spoke} =
             Session.create("t1", "mcu-spoke-ann", :conference,
               audio: :sfu,
               video: :sfu,
               mcu_cascade: :spoke,
               subscribe_mode: :manual
             )

    assert {:ok, %{a: trunk_hub, b: _trunk_spoke}} =
             Manager.connect_pair(hub, spoke,
               id_a: "trunk",
               id_b: "trunk",
               master_key: @master_key,
               master_salt: @master_salt
             )

    mix_id = Cascade.mix_publisher_id()
    plan_spoke = Session.plan_ref(spoke)
    assert Enum.any?(1..50, fn _ ->
             Process.sleep(10)
             match?(%Participant{}, Plan.get_participant(plan_spoke, mix_id))
           end)

    mix_ssrc = Runtime.get_mcu_egress(Session.plan_ref(hub), trunk_hub.id).out_ssrc
    assert [%{ssrc: ^mix_ssrc, kind: :audio}] = Plan.tracks_for(plan_spoke, mix_id)

    _ = Session.hangup(hub)
    _ = Session.hangup(spoke)
  end

  @tag :opus
  test "hub-mix: Opus RTP from spoke talker mixes and fans out on spoke" do
    assert {:ok, hub} =
             Session.create("t1", "mcu-hub", :conference,
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :hub,
               subscribe_mode: :manual,
               mcu_jb_target: 1,
               audio_level_average: 127
             )

    assert {:ok, spoke} =
             Session.create("t1", "mcu-spoke", :conference,
               audio: :sfu,
               video: :sfu,
               mcu_cascade: :spoke,
               subscribe_mode: :manual
             )

    fwd_hub = Session.forwarder(hub)
    fwd_spoke = Session.forwarder(spoke)
    plan_hub = Session.plan_ref(hub)
    plan_spoke = Session.plan_ref(spoke)

    assert {:ok, %{a: trunk_hub, b: trunk_spoke}} =
             Manager.connect_pair(hub, spoke,
               id_a: "trunk",
               id_b: "trunk",
               master_key: @master_key,
               master_salt: @master_salt
             )

    # Manager.connect already wires Bridge; wait for auto mix announce
    mix_id = Cascade.mix_publisher_id()

    assert Enum.any?(1..50, fn _ ->
             Process.sleep(10)
             match?(%Participant{}, Plan.get_participant(plan_spoke, mix_id))
           end)

    assert {:ok, peer_b} = FakePeer.start_link()
    assert {:ok, peer_listen} = FakePeer.start_link()
    b = %Participant{id: "b", peer_ref: peer_b, role: :publisher}
    listen = %Participant{id: "listen", peer_ref: peer_listen, role: :subscriber}

    assert :ok = Session.attach_participant(spoke, b)
    assert :ok = Session.attach_participant(spoke, listen)
    assert :ok = Forwarder.put_plan(fwd_spoke, peer_b, %{mode: :sfu, participant: b})
    assert :ok = Forwarder.put_plan(fwd_spoke, peer_listen, %{mode: :sfu, participant: listen})

    assert :ok = Xylon.Conference.publish(plan_spoke, "b", %{mid: "0", kind: :audio, ssrc: 700})

    assert :ok =
             Xylon.Conference.subscribe(plan_spoke, trunk_spoke.id, "b", "0",
               dest_type: :trunk,
               forwarder: fwd_spoke
             )

    [up_route] = Plan.routes_for_inbound(plan_spoke, "b", 700)
    up_ssrc = up_route.rewrite.out_ssrc

    remote_b = %{
      trunk_hub
      | id: "b",
        role: :publisher,
        peer_ref: trunk_hub.peer_ref,
        meta: %{remote: true}
    }

    assert :ok = Plan.put_participant(plan_hub, remote_b)
    assert :ok = Xylon.Conference.publish(plan_hub, "b", %{mid: "0", kind: :audio, ssrc: up_ssrc})
    hub_state = :sys.get_state(hub).backend_state
    assert :ok = Cascade.ensure_remote_contributor(plan_hub, "b", hub_state)
    assert :ok = Forwarder.put_plan(fwd_hub, trunk_hub.peer_ref, %{mode: :sfu, participant: remote_b})

    mix_ssrc = Runtime.get_mcu_egress(plan_hub, trunk_hub.id).out_ssrc

    assert :ok =
             Xylon.Conference.subscribe(plan_spoke, "listen", mix_id, "0", forwarder: fwd_spoke)

    assert [%{ssrc: ^mix_ssrc}] = Plan.tracks_for(plan_spoke, mix_id)

    # Loop guard
    assert {:error, :mcu_mix_trunk_loop} =
             Xylon.Conference.subscribe(plan_spoke, trunk_spoke.id, mix_id, "0",
               dest_type: :trunk,
               forwarder: fwd_spoke
             )

    opus = encode_opus_tone()

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

    # Full up-leg: spoke peer -> SFU -> trunk Pipe -> hub Bridge -> MCU
    before_hub = XGW.Trunk.Pipe.stats(trunk_hub.peer_ref)
    send(fwd_spoke, {:xgw, :rtp, peer_b, rtp_in, %{}})

    assert Enum.any?(1..50, fn _ ->
             Process.sleep(20)
             drained = FakePeer.drain(peer_listen)

             Enum.any?(drained, fn
               {:send_rtp, _ssrc, %Rtp{payload: payload}} -> byte_size(payload) > 0
               _ -> false
             end)
           end)

    assert XGW.Trunk.Pipe.stats(trunk_hub.peer_ref).udp_in > before_hub.udp_in

    _ = Session.hangup(hub)
    _ = Session.hangup(spoke)
  end

  @tag :opus
  test "spoke mix-minus: sole spoke talker does not hear self on mix" do
    assert {:ok, hub} =
             Session.create("t1", "mcu-hub-smm", :conference,
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :hub,
               mcu_spoke_mix_minus: true,
               subscribe_mode: :manual,
               mcu_jb_target: 1,
               audio_level_average: 127
             )

    assert {:ok, spoke} =
             Session.create("t1", "mcu-spoke-smm", :conference,
               audio: :sfu,
               video: :sfu,
               mcu_cascade: :spoke,
               subscribe_mode: :manual
             )

    fwd_hub = Session.forwarder(hub)
    fwd_spoke = Session.forwarder(spoke)
    plan_hub = Session.plan_ref(hub)
    plan_spoke = Session.plan_ref(spoke)

    assert {:ok, %{a: trunk_hub, b: trunk_spoke}} =
             Manager.connect_pair(hub, spoke,
               id_a: "trunk",
               id_b: "trunk",
               master_key: @master_key,
               master_salt: @master_salt
             )

    mix_id = Cascade.mix_publisher_id()

    assert Enum.any?(1..50, fn _ ->
             Process.sleep(10)
             match?(%Participant{}, Plan.get_participant(plan_spoke, mix_id))
           end)

    assert {:ok, peer_b} = FakePeer.start_link()
    assert {:ok, peer_hub_listen} = FakePeer.start_link()
    b = %Participant{id: "b", peer_ref: peer_b, role: :publisher}
    hub_listen = %Participant{id: "hub_listen", peer_ref: peer_hub_listen, role: :subscriber}

    assert :ok = Session.attach_participant(spoke, b)
    assert :ok = Session.attach_participant(hub, hub_listen)
    assert :ok = Forwarder.put_plan(fwd_spoke, peer_b, %{mode: :sfu, participant: b})
    assert :ok = Forwarder.put_plan(fwd_hub, peer_hub_listen, %{mode: :sfu, participant: hub_listen})

    assert :ok = Xylon.Conference.publish(plan_spoke, "b", %{mid: "0", kind: :audio, ssrc: 701})

    assert :ok =
             Xylon.Conference.subscribe(plan_spoke, trunk_spoke.id, "b", "0",
               dest_type: :trunk,
               forwarder: fwd_spoke
             )

    [up_route] = Plan.routes_for_inbound(plan_spoke, "b", 701)
    up_ssrc = up_route.rewrite.out_ssrc

    remote_b = %{
      trunk_hub
      | id: "b",
        role: :publisher,
        peer_ref: trunk_hub.peer_ref,
        meta: %{remote: true}
    }

    assert :ok = Plan.put_participant(plan_hub, remote_b)
    assert :ok = Xylon.Conference.publish(plan_hub, "b", %{mid: "0", kind: :audio, ssrc: up_ssrc})
    hub_state = :sys.get_state(hub).backend_state
    assert :ok = Cascade.ensure_remote_contributor(plan_hub, "b", hub_state)
    assert :ok = Forwarder.put_plan(fwd_hub, trunk_hub.peer_ref, %{mode: :sfu, participant: remote_b})

    # Hub local listener gets mix-minus of b? No - local gets minus_self only if they're a contrib.
    # hub_listen is not a contrib so gets full mix including b.
    assert :ok =
             Xylon.Conference.Mcu.Egress.ensure(plan_hub, "hub_listen", Cascade.opus_desc())

    mix_ssrc = Runtime.get_mcu_egress(plan_hub, trunk_hub.id).out_ssrc

    assert :ok =
             Xylon.Conference.subscribe(plan_spoke, "b", mix_id, "0", forwarder: fwd_spoke)

    assert [%{ssrc: ^mix_ssrc}] = Plan.tracks_for(plan_spoke, mix_id)

    opus = encode_opus_tone()

    rtp_in = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 701,
      csrcs: [],
      extension: nil,
      payload: opus
    }

    send(fwd_spoke, {:xgw, :rtp, peer_b, rtp_in, %{}})

    # Hub must attribute b to trunk via shared Pipe peer_ref
    assert Enum.any?(1..50, fn _ ->
             Process.sleep(20)
             Cascade.trunk_exclude_ids(plan_hub, trunk_hub.id) |> MapSet.member?("b")
           end)

    Process.sleep(100)
    drained_b = FakePeer.drain(peer_b)

    mix_payloads =
      for {:send_rtp, _ssrc, %Rtp{payload: payload}} <- drained_b,
          byte_size(payload) > 0,
          do: payload

    # Encoded silence is still non-empty Opus; decode and require quiet energy.
    if mix_payloads != [] do
      {:ok, dec} = XMediaLib.Codec.start_link({~c"OPUS", 48_000, 1})

      energies =
        Enum.map(mix_payloads, fn payload ->
          case XMediaLib.Codec.decode(dec, payload) do
            {:ok, {pcm, _, _, _}} when is_binary(pcm) ->
              Xylon.Conference.Mcu.Level.energy_level(pcm)

            _ ->
              0
          end
        end)

      XMediaLib.Codec.close(dec)
      # 0 = loud on RFC 6464 scale; quiet self-hear should stay high (near 127)
      assert Enum.all?(energies, &(&1 >= 100)),
             "spoke talker mix energy too loud (self-hear): #{inspect(energies)}"
    end

    _ = Session.hangup(hub)
    _ = Session.hangup(spoke)
  end

  defp l16_tone_pcm do
    samples = Xylon.Conference.Mcu.Mixer.samples_per_tick([])
    :binary.copy(<<10_000::signed-little-integer-size(16)>>, samples)
  end

  @tag :opus
  test "PCM trunk: L16 on Pipe; SFU spoke edge-transcodes mix to Opus for locals" do
    assert {:ok, hub} =
             Session.create("t1", "mcu-hub-pcm", :conference,
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :hub,
               mcu_cascade_trunk_profile: :pcm,
               subscribe_mode: :manual,
               mcu_jb_target: 1,
               audio_level_average: 127
             )

    assert {:ok, spoke} =
             Session.create("t1", "mcu-spoke-pcm", :conference,
               audio: :sfu,
               video: :sfu,
               mcu_cascade: :spoke,
               mcu_cascade_trunk_profile: :pcm,
               subscribe_mode: :manual,
               mcu_jb_target: 1,
               audio_level_average: 127
             )

    fwd_hub = Session.forwarder(hub)
    fwd_spoke = Session.forwarder(spoke)
    plan_hub = Session.plan_ref(hub)
    plan_spoke = Session.plan_ref(spoke)

    assert {:ok, %{a: trunk_hub, b: trunk_spoke}} =
             Manager.connect_pair(hub, spoke,
               id_a: "trunk",
               id_b: "trunk",
               master_key: @master_key,
               master_salt: @master_salt
             )

    mix_id = Cascade.mix_publisher_id()

    assert Enum.any?(1..50, fn _ ->
             Process.sleep(10)
             match?(%Participant{}, Plan.get_participant(plan_spoke, mix_id))
           end)

    assert %{codec_desc: %{name: "l16"}} = Runtime.get_mcu_egress(plan_hub, trunk_hub.id)

    assert Enum.any?(1..40, fn _ ->
             Process.sleep(10)

             match?(
               %{codec_pid: :l16_passthrough},
               Runtime.get_mcu_contrib(plan_spoke, mix_id)
             )
           end)

    assert {:ok, peer_b} = FakePeer.start_link()
    assert {:ok, peer_listen} = FakePeer.start_link()
    b = %Participant{id: "b", peer_ref: peer_b, role: :publisher}
    listen = %Participant{id: "listen", peer_ref: peer_listen, role: :subscriber}

    assert :ok = Session.attach_participant(spoke, b)
    assert :ok = Session.attach_participant(spoke, listen)
    assert :ok = Forwarder.put_plan(fwd_spoke, peer_b, %{mode: :sfu, participant: b})
    assert :ok = Forwarder.put_plan(fwd_spoke, peer_listen, %{mode: :sfu, participant: listen})

    assert :ok =
             Forwarder.put_plan(fwd_spoke, trunk_spoke.peer_ref, %{
               mode: :sfu,
               participant: trunk_spoke
             })

    assert %{codec_desc: %{name: "opus"}} = Runtime.get_mcu_egress(plan_spoke, "listen")

    assert :ok = Xylon.Conference.publish(plan_spoke, "b", %{mid: "0", kind: :audio, ssrc: 710})

    assert :ok =
             Xylon.Conference.subscribe(plan_spoke, trunk_spoke.id, "b", "0",
               dest_type: :trunk,
               forwarder: fwd_spoke
             )

    [up_route] = Plan.routes_for_inbound(plan_spoke, "b", 710)
    up_ssrc = up_route.rewrite.out_ssrc

    remote_b = %{
      trunk_hub
      | id: "b",
        role: :publisher,
        peer_ref: trunk_hub.peer_ref,
        meta: %{remote: true}
    }

    assert :ok = Plan.put_participant(plan_hub, remote_b)
    assert :ok = Xylon.Conference.publish(plan_hub, "b", %{mid: "0", kind: :audio, ssrc: up_ssrc})
    hub_state = :sys.get_state(hub).backend_state
    assert :ok = Cascade.ensure_remote_contributor(plan_hub, "b", hub_state)
    assert :ok = Forwarder.put_plan(fwd_hub, trunk_hub.peer_ref, %{mode: :sfu, participant: remote_b})

    mix_ssrc = Runtime.get_mcu_egress(plan_hub, trunk_hub.id).out_ssrc

    refute Enum.any?(Plan.routes_for_inbound(plan_spoke, mix_id, mix_ssrc), fn r ->
             r.destination.participant.id == "listen"
           end)

    pcm = l16_tone_pcm()

    rtp_in = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 710,
      csrcs: [],
      extension: nil,
      payload: pcm
    }

    before_hub = XGW.Trunk.Pipe.stats(trunk_hub.peer_ref)
    send(fwd_spoke, {:xgw, :rtp, peer_b, rtp_in, %{}})

    assert Enum.any?(1..50, fn _ ->
             Process.sleep(20)
             XGW.Trunk.Pipe.stats(trunk_hub.peer_ref).udp_in > before_hub.udp_in
           end)

    # Drive SFU+PCM edge-transcode: L16 mix RTP on the trunk peer (as hub egress).
    mix_rtp = %{rtp_in | ssrc: mix_ssrc, sequence_number: 2}
    send(fwd_spoke, {:xgw, :rtp, trunk_spoke.peer_ref, mix_rtp, %{}})

    assert Enum.any?(1..50, fn _ ->
             Process.sleep(20)
             drained = FakePeer.drain(peer_listen)

             Enum.any?(drained, fn
               {:send_rtp, _ssrc, %Rtp{payload_type: 111, payload: payload}} ->
                 byte_size(payload) > 0

               _ ->
                 false
             end)
           end)

    _ = Session.hangup(hub)
    _ = Session.hangup(spoke)
  end

  @tag :opus
  test "PCM profile mismatch fails connect_pair" do
    assert {:ok, hub} =
             Session.create("t1", "mcu-hub-mm", :conference,
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :hub,
               mcu_cascade_trunk_profile: :pcm,
               subscribe_mode: :manual
             )

    assert {:ok, spoke} =
             Session.create("t1", "mcu-spoke-mm", :conference,
               audio: :sfu,
               video: :sfu,
               mcu_cascade: :spoke,
               mcu_cascade_trunk_profile: :opus,
               subscribe_mode: :manual
             )

    assert {:error, :mcu_cascade_profile_mismatch} =
             Manager.connect_pair(hub, spoke,
               id_a: "trunk",
               id_b: "trunk",
               master_key: @master_key,
               master_salt: @master_salt
             )

    _ = Session.hangup(hub)
    _ = Session.hangup(spoke)
  end

  @tag :opus
  test "spoke MCU mix-of-mixes: local + remote mix; up-leg still trunks" do
    assert {:ok, hub} =
             Session.create("t1", "mcu-hub-mom", :conference,
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :hub,
               subscribe_mode: :manual,
               mcu_jb_target: 1,
               audio_level_average: 127
             )

    assert {:ok, spoke} =
             Session.create("t1", "mcu-spoke-mom", :conference,
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :spoke,
               subscribe_mode: :manual,
               mcu_jb_target: 1,
               audio_level_average: 127
             )

    fwd_hub = Session.forwarder(hub)
    fwd_spoke = Session.forwarder(spoke)
    plan_hub = Session.plan_ref(hub)
    plan_spoke = Session.plan_ref(spoke)

    assert {:ok, %{a: trunk_hub, b: trunk_spoke}} =
             Manager.connect_pair(hub, spoke,
               id_a: "trunk",
               id_b: "trunk",
               master_key: @master_key,
               master_salt: @master_salt
             )

    mix_id = Cascade.mix_publisher_id()

    assert Enum.any?(1..50, fn _ ->
             Process.sleep(10)
             match?(%Participant{}, Plan.get_participant(plan_spoke, mix_id))
           end)

    assert Enum.any?(1..40, fn _ ->
             Process.sleep(10)
             match?(%{codec_pid: pid} when is_pid(pid), Runtime.get_mcu_contrib(plan_spoke, mix_id))
           end)

    assert {:ok, peer_b} = FakePeer.start_link()
    assert {:ok, peer_listen} = FakePeer.start_link()
    b = %Participant{id: "b", peer_ref: peer_b, role: :publisher}
    listen = %Participant{id: "listen", peer_ref: peer_listen, role: :subscriber}

    assert :ok = Session.attach_participant(spoke, b)
    assert :ok = Session.attach_participant(spoke, listen)
    assert :ok = Forwarder.put_plan(fwd_spoke, peer_b, %{mode: :sfu, participant: b})
    assert :ok = Forwarder.put_plan(fwd_spoke, peer_listen, %{mode: :sfu, participant: listen})

    assert :ok = Xylon.Conference.publish(plan_spoke, "b", %{mid: "0", kind: :audio, ssrc: 730})

    assert :ok =
             Xylon.Conference.subscribe(plan_spoke, trunk_spoke.id, "b", "0",
               dest_type: :trunk,
               forwarder: fwd_spoke
             )

    # Spoke MCU: local egress, not SFU of hub mix
    assert :ok =
             Xylon.Conference.Mcu.Egress.ensure(plan_spoke, "listen", Cascade.opus_desc())

    assert :ok =
             Xylon.Conference.Mcu.Contributor.ensure(plan_spoke, "b", Cascade.opus_desc(),
               jb_target: 1
             )

    [up_route] = Plan.routes_for_inbound(plan_spoke, "b", 730)
    up_ssrc = up_route.rewrite.out_ssrc

    remote_b = %{
      trunk_hub
      | id: "b",
        role: :publisher,
        peer_ref: trunk_hub.peer_ref,
        meta: %{remote: true}
    }

    assert :ok = Plan.put_participant(plan_hub, remote_b)
    assert :ok = Xylon.Conference.publish(plan_hub, "b", %{mid: "0", kind: :audio, ssrc: up_ssrc})
    hub_state = :sys.get_state(hub).backend_state
    assert :ok = Cascade.ensure_remote_contributor(plan_hub, "b", hub_state)
    assert :ok = Forwarder.put_plan(fwd_hub, trunk_hub.peer_ref, %{mode: :sfu, participant: remote_b})

    mix_ssrc = Runtime.get_mcu_egress(plan_hub, trunk_hub.id).out_ssrc
    assert :ok = Forwarder.put_plan(fwd_spoke, trunk_spoke.peer_ref, %{mode: :sfu, participant: trunk_spoke})

    # No SFU subscribe to mix (would double audio)
    refute Enum.any?(Plan.routes_for_inbound(plan_spoke, mix_id, mix_ssrc), fn r ->
             r.destination.participant.id == "listen"
           end)

    opus = encode_opus_tone()

    rtp_in = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 730,
      csrcs: [],
      extension: nil,
      payload: opus
    }

    before_hub = XGW.Trunk.Pipe.stats(trunk_hub.peer_ref)
    send(fwd_spoke, {:xgw, :rtp, peer_b, rtp_in, %{}})

    assert Enum.any?(1..50, fn _ ->
             Process.sleep(20)
             drained = FakePeer.drain(peer_listen)

             Enum.any?(drained, fn
               {:send_rtp, _ssrc, %Rtp{payload: payload}} -> byte_size(payload) > 0
               _ -> false
             end)
           end)

    assert XGW.Trunk.Pipe.stats(trunk_hub.peer_ref).udp_in > before_hub.udp_in

    _ = Session.hangup(hub)
    _ = Session.hangup(spoke)
  end
end
