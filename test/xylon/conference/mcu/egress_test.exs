defmodule Xylon.Conference.Mcu.EgressTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.Mcu.{Egress, Mixer}
  alias Xylon.Conference.{Runtime, Twcc}
  alias XMediaLib.{Codec, Rtp}

  setup do
    plan_ref = make_ref()
    Runtime.ensure_table!()
    on_exit(fn -> Runtime.clear_plan(plan_ref) end)
    %{plan_ref: plan_ref}
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

  defp pcmu_desc do
    %{
      name: "PCMU",
      payload_type: 0,
      clock_rate: 8000,
      channels: 1,
      fmtp: nil,
      mixable?: true,
      sample_rate_hz: 8000
    }
  end

  defp g722_desc do
    %{
      name: "G722",
      payload_type: 9,
      clock_rate: 8000,
      channels: 1,
      fmtp: nil,
      mixable?: true,
      sample_rate_hz: 16_000
    }
  end

  defp silence_pcm do
    :binary.copy(<<0, 0>>, Mixer.samples_per_tick([]))
  end

  defp full_group(desc) do
    {Egress.codec_fp(desc), :full}
  end

  test "ensure rejects unsupported codec", %{plan_ref: plan_ref} do
    assert {:error, :unsupported_codec} =
             Egress.ensure(plan_ref, "a", Map.put(opus_desc(), :name, "telephone-event"))
  end

  test "ensure creates packetizer without private codec_pid", %{plan_ref: plan_ref} do
    assert :ok = Egress.ensure(plan_ref, "a", opus_desc())
    egress = Runtime.get_mcu_egress(plan_ref, "a")
    assert is_map(egress)
    refute Map.has_key?(egress, :codec_pid)
    assert egress.group_key == nil
  end

  @tag :opus
  test "thin stamp: one encode group, two listeners, distinct ssrc/seq; flush batches", %{
    plan_ref: plan_ref
  } do
    desc = opus_desc(111)
    assert :ok = Egress.ensure(plan_ref, "a", desc)
    assert :ok = Egress.ensure(plan_ref, "b", desc)
    pcm = silence_pcm()
    gk = full_group(desc)

    assert {:ok, %{^gk => opus}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    prep = Egress.prepare_from_payload(opus, gk)

    assert {:ok, %Rtp{} = ra, next_a, true} = Egress.stamp_listener(plan_ref, "a", prep)
    assert {:ok, %Rtp{} = rb, next_b, true} = Egress.stamp_listener(plan_ref, "b", prep)
    assert ra.payload == opus
    assert rb.payload == opus
    assert ra.ssrc != rb.ssrc
    assert ra.sequence_number == 0
    assert rb.sequence_number == 0

    assert :ok = Egress.flush_egresses(plan_ref, [{"a", next_a}, {"b", next_b}])
    assert Runtime.get_mcu_egress(plan_ref, "a").seq == 1
    assert Runtime.get_mcu_egress(plan_ref, "b").seq == 1
    assert :ok = Egress.maybe_send_srs(plan_ref, ["a", "b"])
  end

  @tag :opus
  test "ensure_group_bound + stamp skip_bind advances without double retain path", %{
    plan_ref: plan_ref
  } do
    desc = opus_desc(111)
    assert :ok = Egress.ensure(plan_ref, "a", desc)
    pcm = silence_pcm()
    gk = full_group(desc)
    assert {:ok, %{^gk => opus}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert :ok = Egress.ensure_group_bound(plan_ref, "a", gk)
    prep = Egress.prepare_from_payload(opus, gk)

    assert {:ok, %Rtp{}, next, true} =
             Egress.stamp_listener(plan_ref, "a", prep, skip_bind: true)

    assert :ok = Egress.flush_egresses(plan_ref, [{"a", next}])
    assert Runtime.get_mcu_egress(plan_ref, "a").group_key == gk
  end

  @tag :opus
  test "encode_groups + packetize_payload seq/ts advance; clear drops group", %{
    plan_ref: plan_ref
  } do
    desc = opus_desc(111)
    assert :ok = Egress.ensure(plan_ref, "a", desc)
    pcm = silence_pcm()
    gk = full_group(desc)

    assert {:ok, %{^gk => opus}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert is_binary(opus)
    assert Runtime.get_mcu_encode_group(plan_ref, gk)

    assert {:ok, %Rtp{} = r1} = Egress.packetize_payload(plan_ref, "a", opus, gk)
    assert r1.payload_type == 111
    assert r1.sequence_number == 0
    assert r1.timestamp == 0
    assert r1.marker == 1
    assert r1.payload == opus
    assert r1.extension == nil

    assert {:ok, %{^gk => opus2}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert {:ok, %Rtp{} = r2} = Egress.packetize_payload(plan_ref, "a", opus2, gk)
    assert r2.sequence_number == 1
    assert r2.timestamp == 960
    assert r2.marker == 0
    assert r2.ssrc == r1.ssrc

    assert :ok = Egress.clear(plan_ref, "a")
    assert Runtime.get_mcu_egress(plan_ref, "a") == nil
    assert Runtime.get_mcu_encode_group(plan_ref, gk) == nil
    assert {:error, :not_found} = Egress.packetize_payload(plan_ref, "a", opus, gk)
  end

  @tag :opus
  test "packetize with audio_level_ext_id embeds RFC 6464 extension", %{plan_ref: plan_ref} do
    desc = opus_desc(111)
    assert :ok = Egress.ensure(plan_ref, "a", desc, audio_level_ext_id: 1)
    pcm = silence_pcm()
    gk = full_group(desc)

    assert {:ok, %{^gk => opus}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert {:ok, %Rtp{extension: %Rtp.Extension{} = ext}} =
             Egress.packetize_payload(plan_ref, "a", opus, gk, mix_level: 10)

    assert ext.type == 0xBEDE
    elements = XMediaLib.Rtp.HeaderExtension.decode_one_byte_elements(ext.payload)
    assert {:ok, %{voice?: true, level: 10}} =
             XMediaLib.Rtp.HeaderExtension.audio_level(elements, 1)
  end

  @tag :opus
  test "packetize with ext id and no mix_level defaults level to 127", %{plan_ref: plan_ref} do
    desc = opus_desc(111)
    assert :ok = Egress.ensure(plan_ref, "a", desc, audio_level_ext_id: 2)
    pcm = silence_pcm()
    gk = full_group(desc)
    assert {:ok, %{^gk => opus}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert {:ok, %Rtp{extension: %Rtp.Extension{} = ext}} =
             Egress.packetize_payload(plan_ref, "a", opus, gk)

    elements = XMediaLib.Rtp.HeaderExtension.decode_one_byte_elements(ext.payload)
    assert {:ok, %{voice?: false, level: 127}} =
             XMediaLib.Rtp.HeaderExtension.audio_level(elements, 2)
  end

  @tag :opus
  test "packetize without ext id keeps extension nil", %{plan_ref: plan_ref} do
    desc = opus_desc(111)
    assert :ok = Egress.ensure(plan_ref, "a", desc)
    pcm = silence_pcm()
    gk = full_group(desc)
    assert {:ok, %{^gk => opus}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert {:ok, %Rtp{extension: nil}} =
             Egress.packetize_payload(plan_ref, "a", opus, gk, mix_level: 10)
  end

  @tag :opus
  test "PCMU packetize advances timestamp by 160", %{plan_ref: plan_ref} do
    desc = pcmu_desc()
    assert :ok = Egress.ensure(plan_ref, "a", desc)
    pcm = silence_pcm()
    gk = full_group(desc)

    assert {:ok, %{^gk => p1}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert {:ok, %Rtp{} = r1} = Egress.packetize_payload(plan_ref, "a", p1, gk)
    assert r1.payload_type == 0
    assert r1.timestamp == 0

    assert {:ok, %{^gk => p2}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert {:ok, %Rtp{} = r2} = Egress.packetize_payload(plan_ref, "a", p2, gk)
    assert r2.timestamp == 160
    assert r2.sequence_number == 1
  end

  @tag :opus
  test "G722 packetize advances timestamp by 160", %{plan_ref: plan_ref} do
    desc = g722_desc()
    assert :ok = Egress.ensure(plan_ref, "a", desc)
    pcm = silence_pcm()
    gk = full_group(desc)

    assert {:ok, %{^gk => p1}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert {:ok, %Rtp{} = r1} = Egress.packetize_payload(plan_ref, "a", p1, gk)
    assert r1.payload_type == 9
    assert r1.timestamp == 0

    assert {:ok, %{^gk => p2}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert {:ok, %Rtp{} = r2} = Egress.packetize_payload(plan_ref, "a", p2, gk)
    assert r2.timestamp == 160
  end

  @tag :opus
  test "two PCMU listeners share encode payload", %{plan_ref: plan_ref} do
    desc = pcmu_desc()
    assert :ok = Egress.ensure(plan_ref, "a", desc)
    assert :ok = Egress.ensure(plan_ref, "b", desc)
    pcm = silence_pcm()
    gk = full_group(desc)

    assert {:ok, %{^gk => payload}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert {:ok, ra} = Egress.packetize_payload(plan_ref, "a", payload, gk)
    assert {:ok, rb} = Egress.packetize_payload(plan_ref, "b", payload, gk)
    assert ra.payload == rb.payload
    assert ra.ssrc != rb.ssrc
  end

  @tag :opus
  test "two listeners share encode group; last clear closes it", %{plan_ref: plan_ref} do
    desc = opus_desc(111)
    assert :ok = Egress.ensure(plan_ref, "a", desc)
    assert :ok = Egress.ensure(plan_ref, "b", desc)
    pcm = silence_pcm()
    gk = full_group(desc)

    assert {:ok, %{^gk => opus}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert {:ok, _} = Egress.packetize_payload(plan_ref, "a", opus, gk)
    assert {:ok, _} = Egress.packetize_payload(plan_ref, "b", opus, gk)
    assert %{refcount: 2} = Runtime.get_mcu_encode_group(plan_ref, gk)

    assert :ok = Egress.clear(plan_ref, "a")
    assert %{refcount: 1} = Runtime.get_mcu_encode_group(plan_ref, gk)

    assert :ok = Egress.clear(plan_ref, "b")
    assert Runtime.get_mcu_encode_group(plan_ref, gk) == nil
  end

  @tag :opus
  test "mark_silence restores marker on next packet", %{plan_ref: plan_ref} do
    desc = opus_desc()
    assert :ok = Egress.ensure(plan_ref, "a", desc)
    pcm = silence_pcm()
    gk = full_group(desc)
    assert {:ok, %{^gk => opus}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert {:ok, %{marker: 1}} = Egress.packetize_payload(plan_ref, "a", opus, gk)
    assert {:ok, %{^gk => opus2}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert {:ok, %{marker: 0}} = Egress.packetize_payload(plan_ref, "a", opus2, gk)
    assert :ok = Egress.mark_silence(plan_ref, "a")
    assert {:ok, %{^gk => opus3}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert {:ok, %{marker: 1}} = Egress.packetize_payload(plan_ref, "a", opus3, gk)
  end

  @tag :opus
  test "ensure fingerprint change recreates packetizer", %{plan_ref: plan_ref} do
    assert :ok = Egress.ensure(plan_ref, "a", opus_desc())
    ssrc1 = Runtime.get_mcu_egress(plan_ref, "a").out_ssrc
    assert :ok = Egress.ensure(plan_ref, "a", pcmu_desc())
    egress = Runtime.get_mcu_egress(plan_ref, "a")
    assert egress.codec_desc.name == "PCMU"
    # new row; SSRC may differ
    assert is_integer(egress.out_ssrc)
    assert egress.seq == 0
    _ = ssrc1
  end

  @tag :opus
  test "encode_groups with useinbandfec emits recoverable FEC", %{plan_ref: plan_ref} do
    desc = %{opus_desc(111) | fmtp: "useinbandfec=1"}
    assert :ok = Egress.ensure(plan_ref, "a", desc)
    gk = full_group(desc)
    samples = Mixer.samples_per_tick([])

    frame_a = :binary.copy(<<0, 16>>, samples)
    frame_b = :binary.copy(<<0, 64>>, samples)
    frame_c = :binary.copy(<<0, 120>>, samples)

    assert {:ok, %{^gk => pkt_a}} = Egress.encode_groups(plan_ref, [{gk, frame_a}])
    assert {:ok, %{^gk => pkt_b}} = Egress.encode_groups(plan_ref, [{gk, frame_b}])
    assert {:ok, %{^gk => pkt_c}} = Egress.encode_groups(plan_ref, [{gk, frame_c}])
    assert is_binary(pkt_b)

    {:ok, ref} = Codec.start_link({~c"OPUS", 48_000, 1})
    assert {:ok, _} = Codec.decode(ref, pkt_a)
    assert {:ok, {pcm_ref_b, _, _, _}} = Codec.decode(ref, pkt_b)
    Codec.close(ref)

    {:ok, dec} = Codec.start_link({~c"OPUS", 48_000, 1})
    assert {:ok, _} = Codec.decode(dec, pkt_a)
    # Drop pkt_b; recover via FEC carried in pkt_c.
    assert {:ok, {pcm_fec, _, _, _}} = Codec.decode_fec(dec, pkt_c)
    assert {:ok, {pcm_c, _, _, _}} = Codec.decode(dec, pkt_c)
    Codec.close(dec)

    mean_ref_b = mean_abs_pcm16(pcm_ref_b)
    mean_fec = mean_abs_pcm16(pcm_fec)
    mean_c = mean_abs_pcm16(pcm_c)
    # Default egress loss_perc is 20; require recoverable non-silence FEC.
    assert mean_fec > mean_ref_b * 0.15
    assert mean_fec > 1.0
    assert byte_size(pcm_c) == samples * 2
    _ = mean_c
  end

  @tag :opus
  test "packetize stamps transport-cc and records send map", %{plan_ref: plan_ref} do
    desc = opus_desc(111)
    assert :ok = Egress.ensure(plan_ref, "a", desc, twcc_ext_id: 3)
    pcm = silence_pcm()
    gk = full_group(desc)
    assert {:ok, %{^gk => opus}} = Egress.encode_groups(plan_ref, [{gk, pcm}])

    assert {:ok, rtp} =
             Egress.packetize_payload(plan_ref, "a", opus, gk, now_us: 1_000_000)

    assert {:ok, 0} = Twcc.read_seq(rtp, 3)
    egress = Runtime.get_mcu_egress(plan_ref, "a")
    assert egress.twcc_seq == 1
    assert egress.twcc_send_map[0] == 1_000_000

    assert {:ok, %{^gk => opus2}} = Egress.encode_groups(plan_ref, [{gk, pcm}])

    assert {:ok, rtp2} =
             Egress.packetize_payload(plan_ref, "a", opus2, gk, now_us: 1_020_000)

    assert {:ok, 1} = Twcc.read_seq(rtp2, 3)
    egress2 = Runtime.get_mcu_egress(plan_ref, "a")
    assert egress2.twcc_send_map[1] == 1_020_000
  end

  @tag :opus
  test "packetize transport-cc coexists with audio-level", %{plan_ref: plan_ref} do
    desc = opus_desc(111)
    assert :ok = Egress.ensure(plan_ref, "a", desc, twcc_ext_id: 3, audio_level_ext_id: 1)
    pcm = silence_pcm()
    gk = full_group(desc)
    assert {:ok, %{^gk => opus}} = Egress.encode_groups(plan_ref, [{gk, pcm}])
    assert {:ok, rtp} = Egress.packetize_payload(plan_ref, "a", opus, gk, mix_level: 10)
    assert {:ok, 0} = Twcc.read_seq(rtp, 3)
    elements = XMediaLib.Rtp.HeaderExtension.decode_one_byte_elements(rtp.extension.payload)
    assert {:ok, %{level: 10}} = XMediaLib.Rtp.HeaderExtension.audio_level(elements, 1)
  end

  @tag :opus
  test "twcc send map trims oldest by send time across seq wrap", %{plan_ref: plan_ref} do
    desc = opus_desc(111)
    assert :ok = Egress.ensure(plan_ref, "a", desc, twcc_ext_id: 3)
    pcm = silence_pcm()
    gk = full_group(desc)
    assert {:ok, %{^gk => opus}} = Egress.encode_groups(plan_ref, [{gk, pcm}])

    egress = Runtime.get_mcu_egress(plan_ref, "a")

    # High seqs with old send times, low seqs with new times (post-wrap shape).
    old = Map.new(for i <- 0..300, do: {50_000 + i, 1_000 + i})
    new = Map.new(for i <- 0..300, do: {i, 2_000_000 + i})
    stuffed = Map.merge(old, new)
    assert map_size(stuffed) > 512

    _ =
      Runtime.put_mcu_egress(plan_ref, "a", %{
        egress
        | twcc_send_map: stuffed,
          twcc_seq: 301
      })

    assert {:ok, _} =
             Egress.packetize_payload(plan_ref, "a", opus, gk, now_us: 3_000_000)

    egress2 = Runtime.get_mcu_egress(plan_ref, "a")
    assert map_size(egress2.twcc_send_map) <= 512
    refute Map.has_key?(egress2.twcc_send_map, 50_000)
    assert Map.has_key?(egress2.twcc_send_map, 301)
  end

  defp mean_abs_pcm16(pcm) when is_binary(pcm) and rem(byte_size(pcm), 2) == 0 do
    samples = div(byte_size(pcm), 2)

    sum =
      for <<s::little-signed-integer-size(16) <- pcm>>, reduce: 0 do
        acc -> acc + abs(s)
      end

    sum / samples
  end
end
