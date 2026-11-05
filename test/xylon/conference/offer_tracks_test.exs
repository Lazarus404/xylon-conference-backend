defmodule Xylon.Conference.OfferTracksTest do
  use ExUnit.Case, async: true

  alias Xylon.Conference.OfferTracks

  test "extracts first ssrc per audio and video section with synthesized mids" do
    sdp = """
    v=0
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=ssrc:1111 cname:a
    a=ssrc:1111 msid:stream atrack
    a=ssrc:2222 cname:rtx
    m=video 9 UDP/TLS/RTP/SAVPF 96
    a=ssrc:3333 cname:v
    a=ssrc:4444 cname:rtx
    """

    assert OfferTracks.from_sdp(sdp) == [
             %{mid: "0", kind: :audio, ssrc: 1111},
             %{mid: "1", kind: :video, ssrc: 3333}
           ]
  end

  test "uses explicit a=mid when present" do
    sdp = """
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=mid:audio0
    a=ssrc:1111 cname:a
    m=video 9 UDP/TLS/RTP/SAVPF 96
    a=mid:video0
    a=ssrc:3333 cname:v
    """

    assert OfferTracks.from_sdp(sdp) == [
             %{mid: "audio0", kind: :audio, ssrc: 1111},
             %{mid: "video0", kind: :video, ssrc: 3333}
           ]
  end

  test "two video m-lines get distinct mids" do
    sdp = """
    m=video 9 UDP/TLS/RTP/SAVPF 96
    a=mid:cam
    a=ssrc:100 cname:v1
    m=video 9 UDP/TLS/RTP/SAVPF 96
    a=mid:screen
    a=ssrc:200 cname:v2
    """

    assert OfferTracks.from_sdp(sdp) == [
             %{mid: "cam", kind: :video, ssrc: 100},
             %{mid: "screen", kind: :video, ssrc: 200}
           ]
  end

  test "audio-only offer" do
    sdp = """
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=ssrc:42 cname:x
    m=application 9 UDP/DTLS/SCTP webrtc-datachannel
    """

    assert OfferTracks.from_sdp(sdp) == [%{mid: "0", kind: :audio, ssrc: 42}]
  end

  test "includes first rtpmap codec name per kind" do
    sdp = """
    m=audio 9 UDP/TLS/RTP/SAVPF 111 110
    a=rtpmap:111 opus/48000/2
    a=rtpmap:110 telephone-event/48000
    a=ssrc:1111 cname:a
    m=video 9 UDP/TLS/RTP/SAVPF 96 97
    a=rtpmap:96 VP8/90000
    a=rtpmap:97 rtx/90000
    a=ssrc:3333 cname:v
    """

    assert OfferTracks.from_sdp(sdp) == [
             %{mid: "0", kind: :audio, ssrc: 1111, codec: "opus"},
             %{mid: "1", kind: :video, ssrc: 3333, codec: "VP8"}
           ]
  end

  test "omits codec key when rtpmap missing" do
    sdp = """
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=ssrc:7 cname:a
    """

    assert OfferTracks.from_sdp(sdp) == [%{mid: "0", kind: :audio, ssrc: 7}]
  end

  test "SIM group becomes video layers with substream indices" do
    sdp = """
    m=video 9 UDP/TLS/RTP/SAVPF 96
    a=ssrc-group:SIM 100 200 300
    a=ssrc:100 cname:v
    a=ssrc:200 cname:v
    a=ssrc:300 cname:v
    a=rtpmap:96 VP8/90000
    """

    assert OfferTracks.from_sdp(sdp) == [
             %{
               mid: "0",
               kind: :video,
               ssrc: 100,
               codec: "VP8",
               layers: [
                 %{ssrc: 100, substream: 0},
                 %{ssrc: 200, substream: 1},
                 %{ssrc: 300, substream: 2}
               ]
             }
           ]
  end

  test "SIM layers include rid when a=rid lines present" do
    sdp = """
    m=video 9 UDP/TLS/RTP/SAVPF 96
    a=rid:q send
    a=rid:h send
    a=rid:f send
    a=ssrc-group:SIM 100 200 300
    a=ssrc:100 cname:v
    a=ssrc:200 cname:v
    a=ssrc:300 cname:v
    a=rtpmap:96 VP8/90000
    """

    assert OfferTracks.from_sdp(sdp) == [
             %{
               mid: "0",
               kind: :video,
               ssrc: 100,
               codec: "VP8",
               layers: [
                 %{ssrc: 100, substream: 0, rid: "q"},
                 %{ssrc: 200, substream: 1, rid: "h"},
                 %{ssrc: 300, substream: 2, rid: "f"}
               ]
             }
           ]
  end

  test "Chrome RID-only video seeds unbound layers from a=rid order" do
    sdp = """
    m=video 9 UDP/TLS/RTP/SAVPF 96
    a=mid:1
    a=rtpmap:96 VP8/90000
    a=rid:q send
    a=rid:h send
    a=rid:f send
    a=simulcast:send q;h;f
    """

    assert OfferTracks.from_sdp(sdp) == [
             %{
               mid: "1",
               kind: :video,
               ssrc: 0,
               codec: "VP8",
               layers: [
                 %{ssrc: 0, substream: 0, rid: "q"},
                 %{ssrc: 0, substream: 1, rid: "h"},
                 %{ssrc: 0, substream: 2, rid: "f"}
               ]
             }
           ]
  end
end
