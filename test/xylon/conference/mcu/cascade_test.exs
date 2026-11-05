defmodule Xylon.Conference.Mcu.CascadeTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.Mcu
  alias Xylon.Conference.Mcu.{Cascade, Contributor, Egress, Mixer, Quota}
  alias Xylon.Conference.{Backend, Plan, Runtime, SessionHooks}
  alias Xylon.Participant
  alias Xylon.Session
  alias XMediaLib.{Codec, Rtp}

  setup do
    Quota.reset()
    plan_ref = Plan.new(make_ref())
    Runtime.ensure_table!()
    assert :ok = Quota.register_mixer(plan_ref)

    on_exit(fn ->
      Quota.reset()
      Plan.delete(plan_ref)
    end)

    %{plan_ref: plan_ref}
  end

  defp tone_pcm(amp) do
    samples = Mixer.samples_per_tick([])

    for i <- 1..samples, into: <<>> do
      <<rem(i * amp, 2000)::signed-little-integer-size(16)>>
    end
  end

  defp spawn_peer do
    peer = spawn(fn -> Process.sleep(60_000) end)
    on_exit(fn -> true = Process.exit(peer, :kill) end)
    peer
  end

  defp state(plan_ref) do
    %{
      plan_ref: plan_ref,
      mcu_jb_target: 1,
      mcu_max_contributors: nil,
      mcu_sr_interval_ms: 1000,
      mcu_opus_bitrate_bps: 32_000,
      bitrate_cap: nil,
      mcu_mix_mid: "0",
      tenant_id: "t1",
      session_id: "cascade-unit"
    }
  end

  @tag :opus
  test "trunk egress gets full-mix packet; local talker gets mix-minus", %{plan_ref: plan_ref} do
    st = state(plan_ref)
    a = %Participant{id: "a", peer_ref: spawn_peer()}
    trunk = %Participant{id: "trunk", peer_ref: spawn_peer(), role: :trunk}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, trunk)

    assert :ok = Egress.ensure(plan_ref, "a", Cascade.opus_desc())
    assert :ok = Cascade.ensure_trunk_egress(plan_ref, "trunk", st)

    _ =
      Runtime.put_mcu_contrib(plan_ref, "a", %{
        codec_pid: nil,
        slot: %{pcm: tone_pcm(100), level: 10}
      })

    assert {:ok, specs, _} = Mcu.tick(plan_ref)
    assert length(specs) == 2

    by_id = Map.new(specs, fn {p, rtp} -> {p.id, rtp} end)
    assert %Rtp{} = by_id["a"]
    assert %Rtp{} = by_id["trunk"]
    # Distinct SSRCs (per-listener egress)
    assert by_id["a"].ssrc != by_id["trunk"].ssrc
    # Sole talker: mix-minus is silence path; trunk full-mix carries energy
    assert by_id["a"].payload != by_id["trunk"].payload
    assert byte_size(by_id["trunk"].payload) > 0
  end

  @tag :opus
  test "spoke mix-minus: trunk excludes attributed contrib; local still hears them", %{
    plan_ref: plan_ref
  } do
    st = state(plan_ref)
    a = %Participant{id: "a", peer_ref: spawn_peer()}
    b = %Participant{id: "b", peer_ref: spawn_peer()}
    trunk = %Participant{id: "trunk", peer_ref: spawn_peer(), role: :trunk}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Plan.put_participant(plan_ref, trunk)

    assert :ok = Egress.ensure(plan_ref, "a", Cascade.opus_desc())
    assert :ok = Cascade.ensure_trunk_egress(plan_ref, "trunk", st)
    assert :ok = Runtime.put_mcu_trunk_attrib(plan_ref, "b", "trunk")

    _ =
      Runtime.put_mcu_contrib(plan_ref, "a", %{
        codec_pid: nil,
        slot: %{pcm: tone_pcm(100), level: 10}
      })

    _ =
      Runtime.put_mcu_contrib(plan_ref, "b", %{
        codec_pid: nil,
        slot: %{pcm: tone_pcm(80), level: 10}
      })

    assert {:ok, full_specs, _} = Mcu.tick(plan_ref, mcu_spoke_mix_minus: false)
    assert {:ok, minus_specs, _} = Mcu.tick(plan_ref, mcu_spoke_mix_minus: true)

    full_by = Map.new(full_specs, fn {p, rtp} -> {p.id, rtp} end)
    minus_by = Map.new(minus_specs, fn {p, rtp} -> {p.id, rtp} end)

    # Local listener still gets mix including b (not trunk exclusion)
    assert byte_size(minus_by["a"].payload) > 0
    # Trunk spoke-minus differs from full trunk (b excluded)
    assert minus_by["trunk"].payload != full_by["trunk"].payload
  end

  test "subscribe trunk to mix publisher is rejected", %{plan_ref: plan_ref} do
    assert {:error, :mcu_mix_trunk_loop} =
             SessionHooks.subscribe(plan_ref, "trunk", Cascade.mix_publisher_id(), "0",
               dest_type: :trunk
             )
  end

  test "mix_announce includes mix publisher and out_ssrc", %{plan_ref: plan_ref} do
    st = state(plan_ref)
    assert :ok = Cascade.ensure_trunk_egress(plan_ref, "trunk", st)
    ssrc = Runtime.get_mcu_egress(plan_ref, "trunk").out_ssrc

    assert {:ok, ann} = Cascade.mix_announce(plan_ref, st, trunk_id: "trunk")
    assert ann.trunk_id == "trunk"

    assert [
             %{
               id: "__mcu_mix__",
               role: :publisher,
               spoke_mix_minus: false,
               trunk_profile: :opus
             }
           ] = ann.participants

    assert [
             %{
               publisher_id: "__mcu_mix__",
               mid: "0",
               ssrc: ^ssrc,
               kind: :audio,
               spoke_mix_minus: false,
               trunk_profile: :opus
             }
           ] = ann.tracks
  end

  test "mix_announce tags spoke_mix_minus when hub opt enabled", %{plan_ref: plan_ref} do
    st = Map.put(state(plan_ref), :mcu_spoke_mix_minus, true)
    assert :ok = Cascade.ensure_trunk_egress(plan_ref, "trunk", st)
    assert {:ok, ann} = Cascade.mix_announce(plan_ref, st, trunk_id: "trunk")
    assert [%{spoke_mix_minus: true}] = ann.participants
    assert [%{spoke_mix_minus: true}] = ann.tracks
  end

  test "mix_announce tags trunk_profile pcm", %{plan_ref: plan_ref} do
    st = Map.put(state(plan_ref), :mcu_cascade_trunk_profile, :pcm)
    assert :ok = Cascade.ensure_trunk_egress(plan_ref, "trunk", st)
    assert {:ok, ann} = Cascade.mix_announce(plan_ref, st, trunk_id: "trunk")
    assert [%{trunk_profile: :pcm}] = ann.participants
    assert [%{trunk_profile: :pcm}] = ann.tracks
  end

  test "agree_trunk_profile mismatch" do
    assert :ok = Cascade.agree_trunk_profile(:opus, :opus)
    assert :ok = Cascade.agree_trunk_profile(:pcm, "pcm")
    assert {:error, :mcu_cascade_profile_mismatch} = Cascade.agree_trunk_profile(:opus, :pcm)
  end

  test "L16 pack/unpack round-trip" do
    pcm = :binary.copy(<<1000::signed-little-integer-size(16)>>, 960)
    assert {:ok, ^pcm} = Cascade.pack_l16_payload(pcm)
    assert {:ok, ^pcm} = Cascade.unpack_l16_payload(pcm)
    assert {:error, :bad_pcm_frame} = Cascade.pack_l16_payload(<<1, 2, 3>>)
    assert {:error, :bad_l16_payload} = Cascade.unpack_l16_payload(<<1, 2, 3>>)
  end

  test "ensure_remote_contributor is idempotent", %{plan_ref: plan_ref} do
    st = state(plan_ref)
    assert :ok = Cascade.ensure_remote_contributor(plan_ref, "remote_b", st)
    assert :ok = Cascade.ensure_remote_contributor(plan_ref, "remote_b", st)
    assert %{codec_pid: pid} = Runtime.get_mcu_contrib(plan_ref, "remote_b")
    assert is_pid(pid)
  end

  test "ensure_remote_contributor pcm uses L16 passthrough", %{plan_ref: plan_ref} do
    st = Map.put(state(plan_ref), :mcu_cascade_trunk_profile, :pcm)
    assert :ok = Cascade.ensure_remote_contributor(plan_ref, "remote_pcm", st)
    assert %{codec_pid: :l16_passthrough, codec_desc: %{name: "l16"}} =
             Runtime.get_mcu_contrib(plan_ref, "remote_pcm")
  end

  @tag :opus
  test "hub remote audio is MCU-only; SFU routes to local are not used" do
    session = %Session{id: "hub-nosfu", tenant_id: "t1"}

    assert {:ok, state} =
             Backend.init(session,
               session_pid: make_ref(),
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :hub,
               mcu_jb_target: 1,
               audio_level_average: 127
             )

    plan_ref = state.plan_ref
    on_exit(fn -> Plan.delete(plan_ref) end)

    remote = %Participant{id: "remote", peer_ref: spawn_peer(), meta: %{remote: true}}
    listen = %Participant{id: "listen", peer_ref: spawn_peer()}
    assert {:ok, state} = Backend.participant_joined(remote, state)
    assert {:ok, state} = Backend.participant_joined(listen, state)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "remote", %{mid: "0", kind: :audio, ssrc: 9001})

    assert :ok = Plan.subscribe(plan_ref, "listen", "remote", "0")
    assert [_] = Plan.routes_for_inbound(plan_ref, "remote", 9001)

    assert :ok = Cascade.ensure_remote_contributor(plan_ref, "remote", state)

    samples = Mixer.samples_per_tick([])
    pcm = :binary.copy(<<10_000::signed-little-integer-size(16)>>, samples)
    {:ok, codec} = Codec.start_link({~c"OPUS", 48_000, 1})
    assert {:ok, opus} = Codec.encode(codec, {pcm, 48_000, 1, 16})
    Codec.close(codec)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 9001,
      csrcs: [],
      extension: nil,
      payload: opus
    }

    result = Backend.handle_rtp(remote, rtp, state)

    case result do
      {:ok, _} ->
        :ok

      {:forward, specs, _} ->
        refute Enum.any?(specs, fn {p, packet} ->
                 p.id == "listen" and packet.payload == opus
               end)

    end

    assert {:ok, %{pcm: slot_pcm}} = Contributor.take_slot(plan_ref, "remote")
    assert byte_size(slot_pcm) == samples * 2
  end
end
