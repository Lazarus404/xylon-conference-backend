defmodule Xylon.Conference.Mcu.RtcpTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{FakePeer, Plan, Runtime, Rtcp}
  alias Xylon.Conference.Mcu.Egress
  alias Xylon.Conference.Mcu.Mixer
  alias Xylon.Participant

  setup do
    plan_ref = Plan.new(make_ref())
    Runtime.ensure_table!()
    on_exit(fn -> Plan.delete(plan_ref) end)
    %{plan_ref: plan_ref}
  end

  defp opus_desc do
    %{
      name: "opus",
      payload_type: 111,
      clock_rate: 48_000,
      channels: 1,
      fmtp: nil,
      mixable?: true,
      sample_rate_hz: 48_000
    }
  end

  defp silence_pcm, do: :binary.copy(<<0, 0>>, Mixer.samples_per_tick([]))

  @tag :opus
  test "packetize emits SR after interval with matching counters", %{plan_ref: plan_ref} do
    assert {:ok, peer} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer}
    assert :ok = Plan.put_participant(plan_ref, a)

    assert :ok = Egress.ensure(plan_ref, "a", opus_desc(), sr_interval_ms: 1000)
    pcm = silence_pcm()
    gk = {Egress.codec_fp(opus_desc()), :full}

    assert {:ok, %{^gk => opus}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert {:ok, rtp} = Egress.packetize_payload(plan_ref, "a", opus, gk, now_ms: 1000)

    assert [
             {:send_rtcp,
              %XMediaLib.Rtcp{payloads: [%XMediaLib.Rtcp.Sr{ssrc: ssrc1, packets: 1}]}}
           ] = FakePeer.drain(peer)

    assert ssrc1 == rtp.ssrc

    assert {:ok, %{^gk => opus2}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert {:ok, _} = Egress.packetize_payload(plan_ref, "a", opus2, gk, now_ms: 1500)
    assert [] = FakePeer.drain(peer)

    assert {:ok, %{^gk => opus3}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert {:ok, _} = Egress.packetize_payload(plan_ref, "a", opus3, gk, now_ms: 2500)

    assert [
             {:send_rtcp,
              %XMediaLib.Rtcp{
                payloads: [%XMediaLib.Rtcp.Sr{ssrc: ^ssrc1, packets: 3, octets: octets}]
              }}
           ] = FakePeer.drain(peer)

    assert octets == byte_size(opus) + byte_size(opus2) + byte_size(opus3)
  end

  @tag :opus
  test "REMB on mix out_ssrc updates encode-group target_bps; no publisher REMB", %{
    plan_ref: plan_ref
  } do
    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_pub} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a}
    pub = %Participant{id: "pub", peer_ref: peer_pub}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, pub)

    assert :ok = Egress.ensure(plan_ref, "a", opus_desc())
    pcm = silence_pcm()
    gk = {Egress.codec_fp(opus_desc()), :full}
    assert {:ok, %{^gk => opus}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert {:ok, rtp} = Egress.packetize_payload(plan_ref, "a", opus, gk)

    remb = %XMediaLib.Rtcp.Remb{
      ssrc_s: 1,
      ssrc_m: 0,
      bitrate: 16_000,
      ssrcs: [rtp.ssrc]
    }

    rates = Rtcp.handle_remb(plan_ref, a, %XMediaLib.Rtcp{payloads: [remb]}, %{})
    assert rates == %{}
    assert [] = FakePeer.drain(peer_pub)
    assert Runtime.get_mcu_remb(plan_ref)["a"] == 16_000

    group = Runtime.get_mcu_encode_group(plan_ref, gk)
    assert group.target_bps == 16_000
  end

  @tag :opus
  test "REMB before first packetize applies target_bps when listener binds", %{
    plan_ref: plan_ref
  } do
    assert {:ok, peer_a} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a}
    assert :ok = Plan.put_participant(plan_ref, a)

    assert :ok = Egress.ensure(plan_ref, "a", opus_desc())
    out_ssrc = Runtime.get_mcu_egress(plan_ref, "a").out_ssrc
    pcm = silence_pcm()
    gk = {Egress.codec_fp(opus_desc()), :full}
    assert {:ok, %{^gk => opus}} = Egress.encode_groups(plan_ref, [{gk, pcm}])

    remb = %XMediaLib.Rtcp.Remb{
      ssrc_s: 1,
      ssrc_m: 0,
      bitrate: 16_000,
      ssrcs: [out_ssrc]
    }

    _ = Rtcp.handle_remb(plan_ref, a, %XMediaLib.Rtcp{payloads: [remb]}, %{})
    assert Runtime.get_mcu_remb(plan_ref)["a"] == 16_000
    assert Runtime.get_mcu_encode_group(plan_ref, gk).target_bps == 32_000

    assert {:ok, _} = Egress.packetize_payload(plan_ref, "a", opus, gk)
    assert Runtime.get_mcu_encode_group(plan_ref, gk).target_bps == 16_000
  end

  @tag :opus
  test "TWCC feedback on mix out_ssrc lowers then raises target_bps", %{plan_ref: plan_ref} do
    assert {:ok, peer_a} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a}
    assert :ok = Plan.put_participant(plan_ref, a)

    assert :ok = Egress.ensure(plan_ref, "a", opus_desc(), twcc_ext_id: 3)
    pcm = silence_pcm()
    gk = {Egress.codec_fp(opus_desc()), :full}

    # Seed send map with known send times.
    for i <- 0..4 do
      assert {:ok, %{^gk => opus}} = Egress.encode_groups(plan_ref, [{gk, pcm}])

      assert {:ok, _} =
               Egress.packetize_payload(plan_ref, "a", opus, gk, now_us: 1_000_000 + i * 20_000)
    end

    out_ssrc = Runtime.get_mcu_egress(plan_ref, "a").out_ssrc
    assert Runtime.get_mcu_encode_group(plan_ref, gk).target_bps == 32_000

    # Congestion: high loss fraction in the feedback window.
    fci =
      XMediaLib.Rtcp.TwccFci.pack([
        :not_received,
        :not_received,
        {:received_small, 0},
        {:received_small, 1},
        {:received_small, 1}
      ])

    twcc = %XMediaLib.Rtcp.Twcc{
      ssrc_s: 1,
      ssrc_m: out_ssrc,
      base_seq: 0,
      status_count: 5,
      ref_time: div(1_000_000, 64_000),
      fb_count: 0,
      fci: fci
    }

    assert :ok =
             Rtcp.handle_twcc(plan_ref, a, %XMediaLib.Rtcp{payloads: [twcc]},
               bitrate_cap: 128_000
             )

    bps1 = Runtime.get_mcu_encode_group(plan_ref, gk).target_bps
    assert bps1 < 32_000
    assert Runtime.get_mcu_twcc(plan_ref)["a"].bps == bps1

    # Recovery: small flat deltas, same time base -> delay trend not rising.
    fci2 =
      XMediaLib.Rtcp.TwccFci.pack([
        {:received_small, 0},
        {:received_small, 1},
        {:received_small, 1},
        {:received_small, 1},
        {:received_small, 1}
      ])

    twcc2 = %{twcc | fci: fci2, fb_count: 1, status_count: 5}

    assert :ok =
             Rtcp.handle_twcc(plan_ref, a, %XMediaLib.Rtcp{payloads: [twcc2]},
               bitrate_cap: 128_000
             )

    bps2 = Runtime.get_mcu_encode_group(plan_ref, gk).target_bps
    assert bps2 > bps1
  end

  @tag :opus
  test "combiner uses min of REMB and TWCC", %{plan_ref: plan_ref} do
    assert {:ok, peer_a} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a}
    assert :ok = Plan.put_participant(plan_ref, a)

    assert :ok = Egress.ensure(plan_ref, "a", opus_desc(), twcc_ext_id: 3)
    pcm = silence_pcm()
    gk = {Egress.codec_fp(opus_desc()), :full}

    for i <- 0..2 do
      assert {:ok, %{^gk => opus}} = Egress.encode_groups(plan_ref, [{gk, pcm}])

      assert {:ok, _} =
               Egress.packetize_payload(plan_ref, "a", opus, gk, now_us: 2_000_000 + i * 20_000)
    end

    out_ssrc = Runtime.get_mcu_egress(plan_ref, "a").out_ssrc

    remb = %XMediaLib.Rtcp.Remb{
      ssrc_s: 1,
      ssrc_m: 0,
      bitrate: 24_000,
      ssrcs: [out_ssrc]
    }

    _ = Rtcp.handle_remb(plan_ref, a, %XMediaLib.Rtcp{payloads: [remb]}, %{})

    # Force a TWCC estimate of 16 kbps via Runtime then re-apply.
    _ = Runtime.put_mcu_twcc(plan_ref, %{"a" => %{bps: 16_000, prev_grad_us: 0}})
    _ = Xylon.Conference.Mcu.Rtcp.apply_bitrates(plan_ref, nil)
    assert Runtime.get_mcu_encode_group(plan_ref, gk).target_bps == 16_000
  end

  @tag :opus
  test "TWCC delay gradient congestion cuts bitrate without loss", %{plan_ref: plan_ref} do
    assert {:ok, peer_a} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a}
    assert :ok = Plan.put_participant(plan_ref, a)

    assert :ok = Egress.ensure(plan_ref, "a", opus_desc(), twcc_ext_id: 3)
    pcm = silence_pcm()
    gk = {Egress.codec_fp(opus_desc()), :full}

    # Send every 20 ms.
    for i <- 0..4 do
      assert {:ok, %{^gk => opus}} = Egress.encode_groups(plan_ref, [{gk, pcm}])

      assert {:ok, _} =
               Egress.packetize_payload(plan_ref, "a", opus, gk, now_us: 5_000_000 + i * 20_000)
    end

    out_ssrc = Runtime.get_mcu_egress(plan_ref, "a").out_ssrc

    # Recv spacing 40 ms (160 * 250 us) vs send spacing 20 ms -> +20 ms gradient.
    fci =
      XMediaLib.Rtcp.TwccFci.pack([
        {:received_small, 0},
        {:received_large, 160},
        {:received_large, 160},
        {:received_large, 160},
        {:received_large, 160}
      ])

    twcc = %XMediaLib.Rtcp.Twcc{
      ssrc_s: 1,
      ssrc_m: out_ssrc,
      base_seq: 0,
      status_count: 5,
      ref_time: 0,
      fb_count: 0,
      fci: fci
    }

    assert :ok =
             Rtcp.handle_twcc(plan_ref, a, %XMediaLib.Rtcp{payloads: [twcc]},
               bitrate_cap: 128_000
             )

    assert Runtime.get_mcu_encode_group(plan_ref, gk).target_bps < 32_000
  end
end
