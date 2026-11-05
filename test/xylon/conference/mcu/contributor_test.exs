defmodule Xylon.Conference.Mcu.ContributorTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.Mcu.{Contributor, Mixer}
  alias Xylon.Conference.Runtime
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

  defp pcma_desc do
    %{
      name: "PCMA",
      payload_type: 8,
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

  defp encode_opus_frame do
    samples = Mixer.samples_per_tick([])
    pcm = :binary.copy(<<0, 0>>, samples)
    {:ok, codec} = Codec.start_link({~c"OPUS", 48_000, 1})
    assert {:ok, opus} = Codec.encode(codec, {pcm, 48_000, 1, 16})
    Codec.close(codec)
    opus
  end

  defp encode_g711_frame(type) do
    # 20 ms @ 8 kHz
    pcm = :binary.copy(<<0, 0>>, 160)
    {:ok, codec} = Codec.start_link({type, 8000, 1})
    assert {:ok, bin} = Codec.encode(codec, {pcm, 8000, 1, 16})
    Codec.close(codec)
    bin
  end

  defp encode_g722_frame do
    # 20 ms @ 16 kHz
    pcm = :binary.copy(<<0, 0>>, 320)
    {:ok, codec} = Codec.start_link({~c"G722", 16_000, 1})
    assert {:ok, bin} = Codec.encode(codec, {pcm, 16_000, 1, 16})
    Codec.close(codec)
    bin
  end

  defp rtp(seq, payload, pt) do
    %Rtp{
      padding: 0,
      marker: 0,
      payload_type: pt,
      sequence_number: seq,
      timestamp: seq * 160,
      ssrc: 1001,
      csrcs: [],
      extension: nil,
      payload: payload
    }
  end

  @tag :opus
  test "ensure + push fills a PCM slot", %{plan_ref: plan_ref} do
    assert :ok = Contributor.ensure(plan_ref, "a", opus_desc(), jb_target: 1)
    opus = encode_opus_frame()
    assert :ok = Contributor.push(plan_ref, "a", rtp(1, opus, 111), level: 10)

    assert {:ok, %{pcm: pcm, level: 10}} = Contributor.take_slot(plan_ref, "a")
    assert byte_size(pcm) == Mixer.samples_per_tick([]) * 2
  end

  @tag :opus
  test "PCMU ensure + push fills bus slot", %{plan_ref: plan_ref} do
    assert :ok = Contributor.ensure(plan_ref, "a", pcmu_desc(), jb_target: 1)
    payload = encode_g711_frame(~c"PCMU")
    assert :ok = Contributor.push(plan_ref, "a", rtp(1, payload, 0), level: 5)
    assert {:ok, %{pcm: pcm}} = Contributor.take_slot(plan_ref, "a")
    assert byte_size(pcm) == Mixer.samples_per_tick([]) * 2
  end

  test "PCMU sequence gap still fills a slot via PCM PLC", %{plan_ref: plan_ref} do
    assert :ok = Contributor.ensure(plan_ref, "a", pcmu_desc(), jb_target: 1)
    payload = encode_g711_frame(~c"PCMU")
    assert :ok = Contributor.push(plan_ref, "a", rtp(1, payload, 0), level: 5)
    assert {:ok, _} = Contributor.take_slot(plan_ref, "a")
    # skip seq 2
    assert :ok = Contributor.push(plan_ref, "a", rtp(3, payload, 0), level: 5)
    assert {:ok, %{pcm: pcm}} = Contributor.take_slot(plan_ref, "a")
    assert byte_size(pcm) == Mixer.samples_per_tick([]) * 2
  end

  @tag :opus
  test "PCMA ensure + push fills bus slot", %{plan_ref: plan_ref} do
    assert :ok = Contributor.ensure(plan_ref, "a", pcma_desc(), jb_target: 1)
    payload = encode_g711_frame(~c"PCMA")
    assert :ok = Contributor.push(plan_ref, "a", rtp(1, payload, 8))
    assert {:ok, %{pcm: pcm}} = Contributor.take_slot(plan_ref, "a")
    assert byte_size(pcm) == Mixer.samples_per_tick([]) * 2
  end

  @tag :opus
  test "G722 ensure + push fills bus slot", %{plan_ref: plan_ref} do
    assert :ok = Contributor.ensure(plan_ref, "a", g722_desc(), jb_target: 1)
    payload = encode_g722_frame()
    assert :ok = Contributor.push(plan_ref, "a", rtp(1, payload, 9))
    assert {:ok, %{pcm: pcm}} = Contributor.take_slot(plan_ref, "a")
    assert byte_size(pcm) == Mixer.samples_per_tick([]) * 2
  end

  @tag :opus
  test "wrong PT returns pt_mismatch", %{plan_ref: plan_ref} do
    assert :ok = Contributor.ensure(plan_ref, "a", opus_desc(111), jb_target: 1)
    opus = encode_opus_frame()
    assert {:error, :pt_mismatch} = Contributor.push(plan_ref, "a", rtp(1, opus, 96))
  end

  test "ensure rejects unsupported codec", %{plan_ref: plan_ref} do
    assert {:error, :unsupported_codec} =
             Contributor.ensure(plan_ref, "a", Map.put(opus_desc(), :name, "telephone-event"))
  end

  @tag :opus
  test "fingerprint change recreates decode port", %{plan_ref: plan_ref} do
    assert :ok = Contributor.ensure(plan_ref, "a", opus_desc(), jb_target: 1)
    pid1 = Runtime.get_mcu_contrib(plan_ref, "a").codec_pid
    assert :ok = Contributor.ensure(plan_ref, "a", pcmu_desc(), jb_target: 1)
    pid2 = Runtime.get_mcu_contrib(plan_ref, "a").codec_pid
    assert pid1 != pid2
    refute Process.alive?(pid1)
  end

  @tag :opus
  test "late seq is dropped; clear removes state", %{plan_ref: plan_ref} do
    assert :ok = Contributor.ensure(plan_ref, "a", opus_desc(), jb_target: 1)
    opus = encode_opus_frame()
    assert :ok = Contributor.push(plan_ref, "a", rtp(5, opus, 111))
    assert :ok = Contributor.push(plan_ref, "a", rtp(4, opus, 111))
    assert {:ok, _} = Contributor.take_slot(plan_ref, "a")

    assert :ok = Contributor.clear(plan_ref, "a")
    assert {:error, :not_found} = Contributor.take_slot(plan_ref, "a")
  end

  @tag :opus
  test "playout hold does not fill slot until jb_target packets", %{plan_ref: plan_ref} do
    assert :ok = Contributor.ensure(plan_ref, "a", opus_desc(), jb_target: 2)
    opus = encode_opus_frame()
    assert :ok = Contributor.push(plan_ref, "a", rtp(1, opus, 111), level: 10)
    assert {:error, :empty} = Contributor.take_slot(plan_ref, "a")

    assert :ok = Contributor.push(plan_ref, "a", rtp(2, opus, 111), level: 10)
    assert {:ok, %{pcm: pcm}} = Contributor.take_slot(plan_ref, "a")
    assert byte_size(pcm) == Mixer.samples_per_tick([]) * 2
  end

  @tag :opus
  test "CN PT marks slot inactive without decode", %{plan_ref: plan_ref} do
    assert :ok =
             Contributor.ensure(plan_ref, "a", opus_desc(),
               jb_target: 1,
               non_mixable_pts: [13, 126]
             )

    cn = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 13,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 1001,
      csrcs: [],
      extension: nil,
      payload: <<0>>
    }

    assert :ok = Contributor.push(plan_ref, "a", cn)
    assert {:ok, %{pcm: pcm, level: 127}} = Contributor.take_slot(plan_ref, "a")
    assert pcm == :binary.copy(<<0, 0>>, Mixer.samples_per_tick([]))
  end

  @tag :opus
  test "telephone-event PT is ignored (inactive)", %{plan_ref: plan_ref} do
    assert :ok =
             Contributor.ensure(plan_ref, "a", opus_desc(),
               jb_target: 1,
               non_mixable_pts: [126]
             )

    dtmf = rtp(1, <<1, 0, 0, 160>>, 126)
    assert :ok = Contributor.push(plan_ref, "a", dtmf)
    assert {:ok, %{level: 127}} = Contributor.take_slot(plan_ref, "a")
  end

  @tag :opus
  test "RTP ts ahead of decode trims bus pcm_buf", %{plan_ref: plan_ref} do
    assert :ok = Contributor.ensure(plan_ref, "a", pcmu_desc(), jb_target: 1)
    payload = encode_g711_frame(~c"PCMU")

    assert :ok =
             Contributor.push(plan_ref, "a", rtp_ts(1, 0, payload, 0),
               level: 5,
               drift_max_pad: 960
             )

    assert {:ok, _} = Contributor.take_slot(plan_ref, "a")

    # Half RTP delta vs full 20ms frame => expected 480 bus samples; got 960 -> trim
    assert :ok =
             Contributor.push(plan_ref, "a", rtp_ts(2, 40, payload, 0),
               level: 5,
               drift_max_pad: 960
             )

    c = Runtime.get_mcu_contrib(plan_ref, "a")
    # trimmed into pcm_buf remainder or slot; byte size of buf should be bounded
    assert byte_size(c.pcm_buf) <= Mixer.samples_per_tick([]) * 2
  end

  @tag :opus
  test "RTP ts behind decode pads bus samples", %{plan_ref: plan_ref} do
    assert :ok = Contributor.ensure(plan_ref, "a", pcmu_desc(), jb_target: 1)
    payload = encode_g711_frame(~c"PCMU")

    assert :ok =
             Contributor.push(plan_ref, "a", rtp_ts(1, 0, payload, 0), drift_max_pad: 960)

    assert {:ok, _} = Contributor.take_slot(plan_ref, "a")

    # Double RTP delta => expected 1920 bus samples; pad up to max_pad
    assert :ok =
             Contributor.push(plan_ref, "a", rtp_ts(2, 320, payload, 0), drift_max_pad: 960)

    c = Runtime.get_mcu_contrib(plan_ref, "a")
    # slot + buf should reflect pad (at least one full tick available)
    assert {:ok, %{pcm: pcm}} = Contributor.take_slot(plan_ref, "a")
    assert byte_size(pcm) == Mixer.samples_per_tick([]) * 2
    assert is_binary(c.pcm_buf)
  end

  defp rtp_ts(seq, ts, payload, pt) do
    %Rtp{
      padding: 0,
      marker: 0,
      payload_type: pt,
      sequence_number: seq,
      timestamp: ts,
      ssrc: 1001,
      csrcs: [],
      extension: nil,
      payload: payload
    }
  end
end
