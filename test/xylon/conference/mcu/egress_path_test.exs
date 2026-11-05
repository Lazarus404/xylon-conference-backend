defmodule Xylon.Conference.Mcu.EgressPathTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{Backend, Plan, Runtime}
  alias Xylon.Conference.Mcu.{Contributor, Egress, Mixer}
  alias Xylon.{Participant, Session}
  alias XMediaLib.{Codec, Rtp}

  setup do
    session = %Session{id: "mcu-eg", tenant_id: "t1"}

    assert {:ok, state} =
             Backend.init(session,
               session_pid: self(),
               audio: :mcu,
               video: :sfu,
               mcu_jb_target: 1
             )

    plan_ref = state.plan_ref
    on_exit(fn -> Plan.delete(plan_ref) end)
    %{state: state, plan_ref: plan_ref}
  end

  defp opus_desc(pt \\ 111) do
    %{
      name: "opus",
      payload_type: pt,
      clock_rate: 48_000,
      channels: 1,
      fmtp: nil,
      mixable?: true,
      sample_rate_hz: 48_000
    }
  end

  defp encode_tone_opus(amp) do
    samples = Mixer.samples_per_tick([])

    pcm =
      for i <- 1..samples, into: <<>> do
        <<rem(i * amp, 2000)::signed-little-integer-size(16)>>
      end

    {:ok, codec} = Codec.start_link({~c"OPUS", 48_000, 1})
    assert {:ok, opus} = Codec.encode(codec, {pcm, 48_000, 1, 16})
    Codec.close(codec)
    opus
  end

  @tag :opus
  test "MCU audio handle_rtp returns {:forward, specs} including the other peer", %{
    state: state,
    plan_ref: plan_ref
  } do
    peer_a = spawn(fn -> Process.sleep(60_000) end)
    peer_b = spawn(fn -> Process.sleep(60_000) end)
    on_exit(fn -> true = Process.exit(peer_a, :kill); true = Process.exit(peer_b, :kill) end)

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert {:ok, state} = Backend.participant_joined(a, state)
    assert {:ok, state} = Backend.participant_joined(b, state)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 1001})

    assert :ok =
             Xylon.Conference.publish(plan_ref, "b", %{mid: "0", kind: :audio, ssrc: 2001})

    assert :ok = Contributor.ensure(plan_ref, "a", opus_desc(), jb_target: 1)
    assert :ok = Contributor.ensure(plan_ref, "b", opus_desc(), jb_target: 1)
    assert :ok = Egress.ensure(plan_ref, "a", opus_desc(111))
    assert :ok = Egress.ensure(plan_ref, "b", opus_desc(111))

    # Seed B's slot so A hears someone when A pushes
    samples = Mixer.samples_per_tick([])

    tone_b =
      for i <- 1..samples, into: <<>> do
        <<rem(i * 200, 2000)::signed-little-integer-size(16)>>
      end

    contrib_b = Runtime.get_mcu_contrib(plan_ref, "b")
    _ = Runtime.put_mcu_contrib(plan_ref, "b", %{contrib_b | slot: %{pcm: tone_b, level: 10}})

    opus = encode_tone_opus(100)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 1001,
      csrcs: [],
      extension: nil,
      payload: opus
    }

    assert {:forward, specs, _state} = Backend.handle_rtp(a, rtp, state)
    assert length(specs) >= 1

    assert Enum.any?(specs, fn {%Participant{id: id}, %Rtp{payload_type: pt}} ->
             id == "b" and pt == 111
           end)

    {_, out_b} = Enum.find(specs, fn {p, _} -> p.id == "b" end)
    assert is_integer(out_b.ssrc)
    assert out_b.sequence_number == 0

    # second tick: seq advances, ssrc stable
    rtp2 = %{rtp | sequence_number: 2, timestamp: 960}
    assert {:forward, specs2, _} = Backend.handle_rtp(a, rtp2, state)
    {_, out_b2} = Enum.find(specs2, fn {p, _} -> p.id == "b" end)
    assert out_b2.ssrc == out_b.ssrc
    assert out_b2.sequence_number == out_b.sequence_number + 1
  end

  @tag :opus
  test "participant_left clears egress and encode groups", %{state: state, plan_ref: plan_ref} do
    peer_a = spawn(fn -> Process.sleep(60_000) end)
    peer_b = spawn(fn -> Process.sleep(60_000) end)
    on_exit(fn -> true = Process.exit(peer_a, :kill); true = Process.exit(peer_b, :kill) end)

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert {:ok, state} = Backend.participant_joined(a, state)
    assert {:ok, state} = Backend.participant_joined(b, state)

    assert :ok = Egress.ensure(plan_ref, "a", opus_desc())
    assert :ok = Egress.ensure(plan_ref, "b", opus_desc())

    samples = Mixer.samples_per_tick([])

    tone =
      for i <- 1..samples, into: <<>> do
        <<rem(i * 100, 2000)::signed-little-integer-size(16)>>
      end

    _ =
      Runtime.put_mcu_contrib(plan_ref, "a", %{
        codec_pid: nil,
        slot: %{pcm: tone, level: 10}
      })

    assert {:ok, specs, _} = Xylon.Conference.Mcu.tick(plan_ref)
    assert length(specs) == 2

    fp = Egress.codec_fp(opus_desc())
    minus_gk = {fp, {:minus, "a"}}
    full_gk = {fp, :full}
    assert Runtime.get_mcu_encode_group(plan_ref, minus_gk)
    assert Runtime.get_mcu_encode_group(plan_ref, full_gk)

    assert {:ok, state} = Backend.participant_left(b, state)
    assert Runtime.get_mcu_egress(plan_ref, "b") == nil
    assert Runtime.get_mcu_encode_group(plan_ref, full_gk) == nil
    assert Runtime.get_mcu_encode_group(plan_ref, minus_gk)

    assert {:ok, _state} = Backend.participant_left(a, state)
    assert Runtime.get_mcu_egress(plan_ref, "a") == nil
    assert Runtime.get_mcu_encode_group(plan_ref, minus_gk) == nil
  end

  @tag :opus
  test "ensure fingerprint change on media_ready recreates egress", %{
    state: state,
    plan_ref: plan_ref
  } do
    peer = spawn(fn -> Process.sleep(60_000) end)
    on_exit(fn -> true = Process.exit(peer, :kill) end)
    a = %Participant{id: "a", peer_ref: peer}
    assert {:ok, state} = Backend.participant_joined(a, state)

    opus_offer = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=mid:0
    a=rtpmap:111 opus/48000/2
    """

    assert {:ok, state} = Backend.media_ready(a, opus_offer, %{}, state)
    assert %{codec_desc: %{name: name1}} = Runtime.get_mcu_egress(plan_ref, "a")
    assert String.downcase(to_string(name1)) == "opus"

    pcmu_offer = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    m=audio 9 UDP/TLS/RTP/SAVPF 0
    a=mid:0
    a=rtpmap:0 PCMU/8000
    """

    assert {:ok, _state} = Backend.media_ready(a, pcmu_offer, %{}, state)
    assert %{codec_desc: %{name: name2}, seq: 0} = Runtime.get_mcu_egress(plan_ref, "a")
    assert String.downcase(to_string(name2)) == "pcmu"
  end

  test "MCU video RTP still SFU-forwards", %{state: state, plan_ref: plan_ref} do
    peer_a = spawn(fn -> Process.sleep(60_000) end)
    peer_b = spawn(fn -> Process.sleep(60_000) end)
    on_exit(fn -> true = Process.exit(peer_a, :kill); true = Process.exit(peer_b, :kill) end)

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert {:ok, state} = Backend.participant_joined(a, state)
    assert {:ok, state} = Backend.participant_joined(b, state)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 3001})

    assert :ok = Plan.subscribe(plan_ref, "b", "a", "1")

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 3001,
      csrcs: [],
      extension: nil,
      payload: <<1, 2, 3>>
    }

    assert {:forward, specs, _} = Backend.handle_rtp(a, rtp, state)
    assert Enum.any?(specs, fn {p, _} -> p.id == "b" end)
  end
end
