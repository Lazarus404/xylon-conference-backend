defmodule Xylon.Conference.Mcu.ContinuityTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.Mcu
  alias Xylon.Conference.Mcu.{Contributor, Egress, Level, Mixer}
  alias Xylon.Conference.{Plan, Runtime}
  alias Xylon.Participant
  alias XMediaLib.{Codec, Rtp}

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

  defp encode_opus_frame(amp) do
    samples = Mixer.samples_per_tick([])

    pcm =
      if amp == 0 do
        :binary.copy(<<0, 0>>, samples)
      else
        for i <- 1..samples, into: <<>> do
          <<rem(i * amp, 2000)::signed-little-integer-size(16)>>
        end
      end

    {:ok, codec} = Codec.start_link({~c"OPUS", 48_000, 1})
    assert {:ok, opus} = Codec.encode(codec, {pcm, 48_000, 1, 16})
    Codec.close(codec)
    opus
  end

  defp rtp(seq, payload) do
    %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: seq,
      timestamp: seq * 960,
      ssrc: 1001,
      csrcs: [],
      extension: nil,
      payload: payload
    }
  end

  defp spawn_peer do
    peer = spawn(fn -> Process.sleep(60_000) end)
    on_exit(fn -> true = Process.exit(peer, :kill) end)
    peer
  end

  @tag :opus
  test "gap is concealed with PLC so a later packet still fills a slot", %{plan_ref: plan_ref} do
    # Non-FEC Opus (fmtp nil): PCM / codec PLC path.
    assert :ok = Contributor.ensure(plan_ref, "a", opus_desc(), jb_target: 1)
    opus = encode_opus_frame(100)
    assert :ok = Contributor.push(plan_ref, "a", rtp(1, opus), level: 10)
    assert {:ok, %{pcm: pcm1}} = Contributor.take_slot(plan_ref, "a")
    assert byte_size(pcm1) == Mixer.samples_per_tick([]) * 2

    # skip seq 2 -- PLC then deliver 3
    assert :ok = Contributor.push(plan_ref, "a", rtp(3, opus), level: 10)
    assert {:ok, %{pcm: pcm2}} = Contributor.take_slot(plan_ref, "a")
    assert byte_size(pcm2) == Mixer.samples_per_tick([]) * 2
  end

  @tag :opus
  test "Opus useinbandfec gap recovers via decode_fec", %{plan_ref: plan_ref} do
    desc = %{opus_desc() | fmtp: "minptime=10;useinbandfec=1"}
    assert :ok = Contributor.ensure(plan_ref, "a", desc, jb_target: 1)

    contrib = Runtime.get_mcu_contrib(plan_ref, "a")
    assert contrib.opus_fec? == true

    samples = Mixer.samples_per_tick([])
    frame_a = :binary.copy(<<0, 16>>, samples)
    frame_b = :binary.copy(<<0, 64>>, samples)
    frame_c = :binary.copy(<<0, 120>>, samples)

    {:ok, enc} = Codec.start_link({~c"OPUS", 48_000, 1})
    assert :ok = Codec.set_inband_fec(enc, true)
    assert :ok = Codec.set_packet_loss_perc(enc, 50)
    assert {:ok, pkt_a} = Codec.encode(enc, {frame_a, 48_000, 1, 16})
    assert {:ok, pkt_b} = Codec.encode(enc, {frame_b, 48_000, 1, 16})
    assert {:ok, pkt_c} = Codec.encode(enc, {frame_c, 48_000, 1, 16})
    Codec.close(enc)
    assert is_binary(pkt_b)

    # Reference: B alone, and FEC recover of B from C after A.
    {:ok, ref} = Codec.start_link({~c"OPUS", 48_000, 1})
    assert {:ok, _} = Codec.decode(ref, pkt_a)
    assert {:ok, {pcm_ref_b, _, _, _}} = Codec.decode(ref, pkt_b)
    Codec.close(ref)

    {:ok, fec_ref} = Codec.start_link({~c"OPUS", 48_000, 1})
    assert {:ok, _} = Codec.decode(fec_ref, pkt_a)
    assert {:ok, {pcm_fec_ref, _, _, _}} = Codec.decode_fec(fec_ref, pkt_c)
    Codec.close(fec_ref)

    assert :ok = Contributor.push(plan_ref, "a", rtp(1, pkt_a), level: 10)
    assert {:ok, %{pcm: pcm1}} = Contributor.take_slot(plan_ref, "a")
    assert byte_size(pcm1) == samples * 2

    # Drop seq 2; FEC in pkt_c recovers prior then delivers current.
    assert :ok = Contributor.push(plan_ref, "a", rtp(3, pkt_c), level: 10)
    assert {:ok, %{pcm: pcm_after}} = Contributor.take_slot(plan_ref, "a")
    assert byte_size(pcm_after) == samples * 2

    contrib2 = Runtime.get_mcu_contrib(plan_ref, "a")
    assert is_binary(contrib2.last_fec_pcm)
    assert byte_size(contrib2.last_fec_pcm) == samples * 2
    assert contrib2.last_seq == 3

    mean_ref_b = mean_abs_pcm16(pcm_ref_b)
    mean_fec = mean_abs_pcm16(contrib2.last_fec_pcm)
    mean_c = mean_abs_pcm16(pcm_after)
    mean_fec_ref = mean_abs_pcm16(pcm_fec_ref)

    # Recovered slot is energetic and nearer B than C (same bar as xmedialib).
    assert mean_fec > mean_ref_b * 0.15
    assert abs(mean_fec - mean_ref_b) < abs(mean_fec - mean_c)
    assert abs(mean_fec - mean_fec_ref) < mean_ref_b * 0.5
  end

  defp mean_abs_pcm16(pcm) when is_binary(pcm) and rem(byte_size(pcm), 2) == 0 do
    samples = div(byte_size(pcm), 2)

    sum =
      for <<s::little-signed-integer-size(16) <- pcm>>, reduce: 0 do
        acc -> acc + abs(s)
      end

    sum / samples
  end

  @tag :opus
  test "playout hold does not forward until jb_target filled", %{plan_ref: plan_ref} do
    assert :ok = Contributor.ensure(plan_ref, "a", opus_desc(), jb_target: 2)
    opus = encode_opus_frame(100)
    assert :ok = Contributor.push(plan_ref, "a", rtp(1, opus), level: 10)
    assert {:error, :empty} = Contributor.take_slot(plan_ref, "a")
    assert :ok = Contributor.push(plan_ref, "a", rtp(2, opus), level: 10)
    assert {:ok, _} = Contributor.take_slot(plan_ref, "a")
  end

  @tag :opus
  test "RFC 6464 avg overrides energy for mix gate", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: spawn_peer()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Egress.ensure(plan_ref, "a", opus_desc())

    samples = Mixer.samples_per_tick([])

    loud =
      for _ <- 1..samples, into: <<>> do
        <<32_000::signed-little-integer-size(16)>>
      end

    # Loud PCM but quiet RFC 6464 avg => inactive
    _ = Runtime.put_mcu_contrib(plan_ref, "a", %{slot: %{pcm: loud, level: nil}, codec_pid: nil})
    _ = Runtime.put_audio_level(plan_ref, "a", %{avg: 100.0})
    _ = Runtime.put_mcu_level(plan_ref, "a", Level.new())

    assert {:ok, [], _} = Mcu.tick(plan_ref, threshold: 25, hysteresis: 10)

    _ = Runtime.put_audio_level(plan_ref, "a", %{avg: 5.0})
    _ = Runtime.put_mcu_level(plan_ref, "a", Level.new())
    assert {:ok, specs, _} = Mcu.tick(plan_ref, threshold: 25, hysteresis: 10)
    assert length(specs) >= 1
  end

  @tag :opus
  test "long silence skips encode; CN after dtx hold", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: spawn_peer()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Egress.ensure(plan_ref, "a", opus_desc(), cn_payload_type: 13)

    samples = Mixer.samples_per_tick([])
    quiet = :binary.copy(<<0, 0>>, samples)
    _ = Runtime.put_mcu_contrib(plan_ref, "a", %{slot: %{pcm: quiet, level: 127}, codec_pid: nil})
    _ = Runtime.put_mcu_level(plan_ref, "a", Level.new())

    assert {:ok, [], _} = Mcu.tick(plan_ref, dtx_hold_ticks: 3)
    assert {:ok, [], _} = Mcu.tick(plan_ref, dtx_hold_ticks: 3)
    assert {:ok, [{_p, rtp}], _} = Mcu.tick(plan_ref, dtx_hold_ticks: 3)
    assert rtp.payload_type == 13
    assert {:ok, [], _} = Mcu.tick(plan_ref, dtx_hold_ticks: 3)
  end

  @tag :opus
  test "energy gate keeps quiet slot out of active mix", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: spawn_peer()}
    b = %Participant{id: "b", peer_ref: spawn_peer()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Egress.ensure(plan_ref, "a", opus_desc())
    assert :ok = Egress.ensure(plan_ref, "b", opus_desc())

    samples = Mixer.samples_per_tick([])
    quiet = :binary.copy(<<0, 0>>, samples)

    loud =
      for _ <- 1..samples, into: <<>> do
        <<32_000::signed-little-integer-size(16)>>
      end

    _ = Runtime.put_mcu_contrib(plan_ref, "a", %{slot: %{pcm: quiet, level: nil}, codec_pid: nil})
    _ = Runtime.put_mcu_contrib(plan_ref, "b", %{slot: %{pcm: loud, level: nil}, codec_pid: nil})
    _ = Runtime.put_mcu_level(plan_ref, "a", Level.new())
    _ = Runtime.put_mcu_level(plan_ref, "b", Level.new())

    assert Level.energy_level(loud) <= 25

    assert {:ok, specs, _} = Mcu.tick(plan_ref, threshold: 25, hysteresis: 10)
    # quiet alone would silence; with loud active, mix forwards
    assert length(specs) >= 1

    # only quiet: no forward
    _ = Runtime.put_mcu_contrib(plan_ref, "b", %{slot: %{pcm: quiet, level: nil}, codec_pid: nil})
    # reset hysteresis so quiet stays inactive
    _ = Runtime.put_mcu_level(plan_ref, "a", Level.new())
    _ = Runtime.put_mcu_level(plan_ref, "b", Level.new())
    assert {:ok, [], _} = Mcu.tick(plan_ref, threshold: 25, hysteresis: 10)
  end

  @tag :opus
  test "top_n=1 keeps only the louder contributor in the mix", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: spawn_peer()}
    b = %Participant{id: "b", peer_ref: spawn_peer()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Egress.ensure(plan_ref, "a", opus_desc())
    assert :ok = Egress.ensure(plan_ref, "b", opus_desc())

    samples = Mixer.samples_per_tick([])

    soft =
      for i <- 1..samples, into: <<>> do
        <<rem(i * 50, 500)::signed-little-integer-size(16)>>
      end

    loud =
      for i <- 1..samples, into: <<>> do
        <<rem(i * 300, 5000)::signed-little-integer-size(16)>>
      end

    # Pre-set levels so energy gate is not required
    _ =
      Runtime.put_mcu_contrib(plan_ref, "a", %{
        slot: %{pcm: soft, level: 20},
        codec_pid: nil
      })

    _ =
      Runtime.put_mcu_contrib(plan_ref, "b", %{
        slot: %{pcm: loud, level: 5},
        codec_pid: nil
      })

    # Force hysteresis active with loud levels via Runtime audio avg for both
    _ = Runtime.put_audio_level(plan_ref, "a", %{avg: 20.0})
    _ = Runtime.put_audio_level(plan_ref, "b", %{avg: 5.0})
    _ = Runtime.put_mcu_level(plan_ref, "a", %{active?: true})
    _ = Runtime.put_mcu_level(plan_ref, "b", %{active?: true})

    assert {:ok, %{full: full, minus_self: minus}} =
             Mixer.mix_tick(
               [
                 %{id: "a", pcm: soft, level: 20},
                 %{id: "b", pcm: loud, level: 5}
               ],
               threshold: 25,
               top_n: 1
             )

    # only b in active set => full matches loud; minus_self[b] is silence
    assert full == loud
    assert minus["b"] == :binary.copy(<<0, 0>>, samples)
  end
end
