defmodule Xylon.Conference.Mcu.CodecBindTest do
  use ExUnit.Case, async: true

  alias Xylon.Conference.Mcu.CodecBind

  defp session_wrap(media_body) do
    """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    #{media_body}
    """
  end

  test "opus-only offer: send/recv opus, mix_mid equals mid" do
    offer =
      session_wrap("""
      m=audio 9 UDP/TLS/RTP/SAVPF 111
      a=mid:0
      a=rtpmap:111 opus/48000/2
      a=fmtp:111 minptime=10;useinbandfec=1
      """)

    assert {:ok, [bind]} = CodecBind.from_sdp(offer)
    assert bind.mid == "0"
    assert bind.mix_mid == "0"
    assert bind.kind == :audio
    assert bind.send.name == "opus"
    assert bind.send.payload_type == 111
    assert bind.send.clock_rate == 48_000
    assert bind.send.channels == 2
    assert bind.send.sample_rate_hz == 48_000
    assert bind.send.fmtp == "minptime=10;useinbandfec=1"
    assert bind.send.mixable? == true
    assert bind.recv == bind.send
  end

  test "PCMU offer" do
    offer =
      session_wrap("""
      m=audio 9 UDP/TLS/RTP/SAVPF 0
      a=mid:audio
      a=rtpmap:0 PCMU/8000
      """)

    assert {:ok, [bind]} = CodecBind.from_sdp(offer)
    assert bind.send.name == "PCMU"
    assert bind.send.payload_type == 0
    assert bind.send.clock_rate == 8000
    assert bind.send.sample_rate_hz == 8000
    assert bind.send.channels == 1
    assert bind.send.mixable? == true
  end

  test "PCMA offer" do
    offer =
      session_wrap("""
      m=audio 9 UDP/TLS/RTP/SAVPF 8
      a=mid:a
      a=rtpmap:8 PCMA/8000
      """)

    assert {:ok, [bind]} = CodecBind.from_sdp(offer)
    assert bind.send.name == "PCMA"
    assert bind.send.payload_type == 8
    assert bind.send.sample_rate_hz == 8000
  end

  test "G.722 offer: RTP clock 8000, sample_rate_hz 16000" do
    offer =
      session_wrap("""
      m=audio 9 UDP/TLS/RTP/SAVPF 9
      a=mid:0
      a=rtpmap:9 G722/8000
      """)

    assert {:ok, [bind]} = CodecBind.from_sdp(offer)
    assert bind.send.name == "G722"
    assert bind.send.payload_type == 9
    assert bind.send.clock_rate == 8000
    assert bind.send.sample_rate_hz == 16_000
    assert bind.send.mixable? == true
  end

  test "opus + telephone-event: send is opus" do
    offer =
      session_wrap("""
      m=audio 9 UDP/TLS/RTP/SAVPF 111 126
      a=mid:0
      a=rtpmap:111 opus/48000/2
      a=rtpmap:126 telephone-event/8000
      a=fmtp:126 0-16
      """)

    assert {:ok, [bind]} = CodecBind.from_sdp(offer)
    assert bind.send.name == "opus"
    assert bind.send.payload_type == 111
    assert bind.recv.name == "opus"
    assert bind.non_mixable_pts == [126]
    assert bind.cn_payload_type == nil
  end

  test "opus + CN lists cn_payload_type and non_mixable_pts" do
    offer =
      session_wrap("""
      m=audio 9 UDP/TLS/RTP/SAVPF 111 13
      a=mid:0
      a=rtpmap:111 opus/48000/2
      a=rtpmap:13 CN/8000
      """)

    assert {:ok, [bind]} = CodecBind.from_sdp(offer)
    assert bind.send.name == "opus"
    assert bind.non_mixable_pts == [13]
    assert bind.cn_payload_type == 13
  end

  test "answer CN PT wins over offer for egress cn_payload_type" do
    offer =
      session_wrap("""
      m=audio 9 UDP/TLS/RTP/SAVPF 111 13
      a=mid:0
      a=rtpmap:111 opus/48000/2
      a=rtpmap:13 CN/8000
      """)

    answer =
      session_wrap("""
      m=audio 9 UDP/TLS/RTP/SAVPF 109 105
      a=mid:0
      a=rtpmap:109 opus/48000/2
      a=rtpmap:105 CN/8000
      """)

    assert {:ok, [bind]} = CodecBind.from_sdp(offer, answer: answer)
    assert bind.recv.payload_type == 109
    assert bind.non_mixable_pts == [13]
    assert bind.cn_payload_type == 105
  end

  test "telephone-event only: error" do
    offer =
      session_wrap("""
      m=audio 9 UDP/TLS/RTP/SAVPF 126
      a=mid:dtmf
      a=rtpmap:126 telephone-event/8000
      """)

    assert {:error, {:no_mixable_audio_codec, "dtmf"}} = CodecBind.from_sdp(offer)
  end

  test "offer + answer different PT for recv" do
    offer =
      session_wrap("""
      m=audio 9 UDP/TLS/RTP/SAVPF 111
      a=mid:0
      a=rtpmap:111 opus/48000/2
      """)

    answer =
      session_wrap("""
      m=audio 9 UDP/TLS/RTP/SAVPF 109
      a=mid:0
      a=rtpmap:109 opus/48000/2
      a=fmtp:109 useinbandfec=1
      """)

    assert {:ok, [bind]} = CodecBind.from_sdp(offer, answer: answer)
    assert bind.send.payload_type == 111
    assert bind.send.name == "opus"
    assert bind.recv.payload_type == 109
    assert bind.recv.name == "opus"
    assert bind.recv.fmtp == "useinbandfec=1"
    assert bind.mix_mid == "0"
  end

  test "video-only offer returns empty list" do
    offer =
      session_wrap("""
      m=video 9 UDP/TLS/RTP/SAVPF 96
      a=mid:1
      a=rtpmap:96 VP8/90000
      """)

    assert {:ok, []} = CodecBind.from_sdp(offer)
  end

  test "synthesizes mid when missing" do
    offer =
      session_wrap("""
      m=audio 9 UDP/TLS/RTP/SAVPF 111
      a=rtpmap:111 opus/48000/2
      """)

    assert {:ok, [bind]} = CodecBind.from_sdp(offer)
    assert bind.mid == "0"
    assert bind.mix_mid == "0"
  end

  test "bad SDP returns error" do
    assert {:error, _} = CodecBind.from_sdp("not-sdp")
  end
end
