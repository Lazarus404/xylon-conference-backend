defmodule Xylon.Conference.TwccTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{Backend, FakePeer, Plan, Runtime, Twcc}
  alias Xylon.{Participant, Session}
  alias XMediaLib.Rtp

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    :ok
  end

  test "read_seq extracts transport-cc from one-byte extension" do
    # id=4, len-1=1 (2 bytes), seq=0x1234
    payload = <<4::4, 1::4, 0x12, 0x34>>
    rtp = %Rtp{extension: %Rtp.Extension{type: 0xBEDE, payload: payload}, ssrc: 1}
    assert {:ok, 0x1234} = Twcc.read_seq(rtp, 4)
    assert :error = Twcc.read_seq(rtp, 5)
  end

  test "handle_rtp emits Twcc to publisher and strips extensions on fanout" do
    session = %Session{id: "twcc1", tenant_id: "t1"}

    assert {:ok, state} =
             Backend.init(session,
               session_pid: self(),
               subscribe_mode: :manual,
               twcc_period_ms: 1
             )

    on_exit(fn -> Plan.delete(state.plan_ref) end)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert {:ok, state} = Backend.participant_joined(a, state)
    assert {:ok, state} = Backend.participant_joined(b, state)

    assert :ok = Plan.put_track(state.plan_ref, "a", %{mid: "0", kind: :video, ssrc: 777})
    assert :ok = Plan.subscribe(state.plan_ref, "b", "a", "0")
    assert :ok = Runtime.put_ext(state.plan_ref, "a", %{twcc: 4})

    payload = <<4::4, 1::4, 0x00, 0x2A>>

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 777,
      csrcs: [],
      extension: %Rtp.Extension{type: 0xBEDE, payload: payload},
      payload: "v"
    }

    assert {:ok, 42} = Twcc.read_seq(rtp, 4)
    assert %{twcc: 4} = Runtime.get_ext(state.plan_ref, a.id)
    assert %{ssrc: 777} = Plan.get_track(state.plan_ref, "a", "0")
    assert %Participant{peer_ref: ^peer_a} = Plan.get_participant(state.plan_ref, "a")

    assert {:forward, [{^b, out}], _state2} = Backend.handle_rtp(a, rtp, state)
    assert is_nil(out.extension)
    assert out.ssrc != 777
    assert Runtime.get_twcc(state.plan_ref, "a").last_ms

    assert [
             {:send_rtcp,
              %XMediaLib.Rtcp{
                payloads: [%XMediaLib.Rtcp.Twcc{base_seq: 42, status_count: 1, ssrc_m: 777}]
              }}
           ] = FakePeer.drain(peer_a)

    assert [] = FakePeer.drain(peer_b)
  end

  test "media_ready records transport-cc extmap id from offer" do
    session = %Session{id: "twcc2", tenant_id: "t1"}
    assert {:ok, state} = Backend.init(session, session_pid: self(), subscribe_mode: :manual)
    on_exit(fn -> Plan.delete(state.plan_ref) end)
    a = %Participant{id: "a", peer_ref: self()}
    assert {:ok, state} = Backend.participant_joined(a, state)

    offer = """
    m=video 9 UDP/TLS/RTP/SAVPF 96
    a=extmap:7 #{Twcc.uri()}
    a=ssrc:1 cname:a
    """

    assert {:ok, _state} = Backend.media_ready(a, offer, %{forwarder: nil}, state)
    assert %{twcc: 7} = Runtime.get_ext(state.plan_ref, "a")
  end

  test "conference answer keeps transport-cc extmap and rtcp-fb when offered" do
    offer = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    a=group:BUNDLE 0
    m=video 9 UDP/TLS/RTP/SAVPF 96
    c=IN IP4 0.0.0.0
    a=ice-ufrag:chromeUfrag
    a=ice-pwd:chromepasswordchromepass
    a=fingerprint:sha-256 11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00
    a=setup:actpass
    a=mid:0
    a=extmap:4 #{Twcc.uri()}
    a=rtcp-mux
    a=sendrecv
    a=rtpmap:96 VP8/90000
    a=rtcp-fb:* transport-cc
    a=ssrc:777 cname:a
    """
    |> String.replace("\n", "\r\n")

    assert {:ok, pid} = Session.create("t1", "twcc-sdp", :conference)
    assert {:ok, answer} = Session.apply_offer(pid, offer, participant_id: "a")
    assert answer =~ Twcc.uri()
    assert answer =~ "transport-cc"
    assert answer =~ "goog-remb"
    assert answer =~ "nack"
  end

  test "handle_rtp records TWCC arrival from Process :xylon_rtp_arrival_us not process time" do
    session = %Session{id: "twcc-arrival", tenant_id: "t1"}

    assert {:ok, state} =
             Backend.init(session,
               session_pid: self(),
               subscribe_mode: :manual,
               twcc_period_ms: 60_000
             )

    on_exit(fn -> Plan.delete(state.plan_ref) end)

    assert {:ok, peer_a} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a}
    assert {:ok, state} = Backend.participant_joined(a, state)

    assert :ok = Plan.put_track(state.plan_ref, "a", %{mid: "0", kind: :video, ssrc: 777})
    assert :ok = Runtime.put_ext(state.plan_ref, "a", %{twcc: 4})

    # Seed last_ms so this packet records without flushing (arrivals stay inspectable).
    now_ms = System.monotonic_time(:millisecond)

    assert :ok =
             Runtime.put_twcc(state.plan_ref, "a", %{
               arrivals: [],
               last_ms: now_ms,
               fb_count: 0
             })

    stamped = 1_234_567
    Process.put(:xylon_rtp_arrival_us, stamped)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 777,
      csrcs: [],
      extension: %Rtp.Extension{type: 0xBEDE, payload: <<4::4, 1::4, 0x00, 0x2A>>},
      payload: "v"
    }

    assert {:ok, _state2} = Backend.handle_rtp(a, rtp, state)
    Process.delete(:xylon_rtp_arrival_us)

    assert [{42, ^stamped}] = Runtime.get_twcc(state.plan_ref, "a").arrivals
  end

  test "feedback_fields fills seq gaps and anchors first delta to ref_time" do
    alias XMediaLib.Rtcp.TwccFci
    alias XMediaLib.Rtcp.Twcc, as: TwccPkt

    # seq 10 then 12 (gap at 11); arrivals with non-zero remainder vs 64ms quanta
    first_us = 64_000 * 5 + 12_500
    second_us = first_us + 5_000

    fb = Twcc.feedback_fields([{12, second_us}, {10, first_us}])
    assert fb.base_seq == 10
    assert fb.status_count == 3
    assert fb.ref_time == 5

    first_delta_us = Integer.mod(first_us, 64_000)
    assert first_delta_us == 12_500

    twcc = %TwccPkt{
      base_seq: fb.base_seq,
      status_count: fb.status_count,
      ref_time: fb.ref_time,
      fb_count: 0,
      fci: fb.fci
    }

    assert {:ok, packets} = TwccFci.parse(twcc)

    assert [
             {10, :received_small, 12_500},
             {11, :not_received, nil},
             {12, :received_small, 5_000}
           ] = packets
  end

  test "feedback_fields first delta stays in 64ms with negative monotonic us" do
    alias XMediaLib.Rtcp.TwccFci
    alias XMediaLib.Rtcp.Twcc, as: TwccPkt

    # BEAM System.monotonic_time(:microsecond) is often largely negative.
    # Reconstructing ref_us as ref_time*64ms drops high bits and yields +/-8s deltas.
    first_us = -576_460_749_962_298
    second_us = first_us + 5_000
    expect_first = Integer.mod(first_us, 64_000)

    fb = Twcc.feedback_fields([{1, first_us}, {2, second_us}])
    assert fb.ref_time == Integer.mod(Integer.floor_div(first_us, 64_000), 0x1000000)

    twcc = %TwccPkt{
      base_seq: fb.base_seq,
      status_count: fb.status_count,
      ref_time: fb.ref_time,
      fb_count: 0,
      fci: fb.fci
    }

    assert {:ok, [{1, _st1, d1}, {2, _st2, d2}]} = TwccFci.parse(twcc)
    # pack stores 250us units
    assert d1 == div(expect_first, 250) * 250
    assert d1 < 64_000
    assert d2 == 5_000
  end

  test "feedback_fields first delta stays in 64ms past 24-bit ref_time wrap" do
    alias XMediaLib.Rtcp.TwccFci
    alias XMediaLib.Rtcp.Twcc, as: TwccPkt

    # 13 days of monotonic us -> floor_div(us, 64ms) exceeds 2^24
    first_us = 13 * 86_400 * 1_000_000 + 12_500
    second_us = first_us + 1_000
    expect_first = Integer.mod(first_us, 64_000)

    fb = Twcc.feedback_fields([{10, first_us}, {11, second_us}])

    twcc = %TwccPkt{
      base_seq: fb.base_seq,
      status_count: fb.status_count,
      ref_time: fb.ref_time,
      fb_count: 0,
      fci: fb.fci
    }

    assert {:ok, [{10, _, d1}, {11, _, d2}]} = TwccFci.parse(twcc)
    assert d1 == div(expect_first, 250) * 250
    assert d1 < 64_000
    assert d2 == 1_000
  end

  test "feedback_fields uses received_large for inter-arrival over 255 small units" do
    alias XMediaLib.Rtcp.TwccFci
    alias XMediaLib.Rtcp.Twcc, as: TwccPkt

    first_us = 64_000 * 2
    # 256 * 250 us = 64_000 us -> needs large delta
    second_us = first_us + 256 * 250

    fb = Twcc.feedback_fields([{1, first_us}, {2, second_us}])
    twcc = %TwccPkt{
      base_seq: fb.base_seq,
      status_count: fb.status_count,
      ref_time: fb.ref_time,
      fb_count: 0,
      fci: fb.fci
    }

    assert {:ok, packets} = TwccFci.parse(twcc)
    assert [{1, st1, d1}, {2, :received_large, 64_000}] = packets
    assert st1 in [:received_small, :received_large]
    assert d1 == 0
  end

  test "feedback_fields wraps uint16 seq without huge fake loss" do
    alias XMediaLib.Rtcp.TwccFci
    alias XMediaLib.Rtcp.Twcc, as: TwccPkt

    t0 = 1_000_000
    samples = [
      {65534, t0},
      {65535, t0 + 1_000},
      {0, t0 + 2_000},
      {1, t0 + 3_000}
    ]

    fb = Twcc.feedback_fields(samples)
    assert fb.base_seq == 65534
    assert fb.status_count == 4

    twcc = %TwccPkt{
      base_seq: fb.base_seq,
      status_count: fb.status_count,
      ref_time: fb.ref_time,
      fb_count: 0,
      fci: fb.fci
    }

    assert {:ok, packets} = TwccFci.parse(twcc)
    assert length(packets) == 4
    assert Enum.all?(packets, fn {_seq, st, _} -> st != :not_received end)
    assert Enum.map(packets, &elem(&1, 0)) == [65534, 65535, 0, 1]
  end

  test "feedback_fields caps status_count to newest 64" do
    alias XMediaLib.Rtcp.TwccFci
    alias XMediaLib.Rtcp.Twcc, as: TwccPkt

    t0 = 2_000_000

    samples =
      for seq <- 0..199 do
        {seq, t0 + seq * 1_000}
      end

    fb = Twcc.feedback_fields(samples)
    assert fb.status_count == 64
    assert fb.base_seq == 136

    twcc = %TwccPkt{
      base_seq: fb.base_seq,
      status_count: fb.status_count,
      ref_time: fb.ref_time,
      fb_count: 0,
      fci: fb.fci
    }

    assert {:ok, packets} = TwccFci.parse(twcc)
    assert length(packets) == 64
    assert Enum.map(packets, &elem(&1, 0)) == Enum.to_list(136..199)
    assert Enum.all?(packets, fn {_seq, st, _} -> st != :not_received end)
  end

  test "feedback_fields marks only in-window holes as not_received" do
    alias XMediaLib.Rtcp.TwccFci
    alias XMediaLib.Rtcp.Twcc, as: TwccPkt

    t0 = 3_000_000
    # seq 10..19 but missing 15
    samples =
      for seq <- 10..19, seq != 15 do
        {seq, t0 + (seq - 10) * 1_000}
      end

    fb = Twcc.feedback_fields(samples)
    assert fb.base_seq == 10
    assert fb.status_count == 10

    twcc = %TwccPkt{
      base_seq: fb.base_seq,
      status_count: fb.status_count,
      ref_time: fb.ref_time,
      fb_count: 0,
      fci: fb.fci
    }

    assert {:ok, packets} = TwccFci.parse(twcc)
    holes = Enum.filter(packets, fn {_s, st, _} -> st == :not_received end)
    assert length(holes) == 1
    assert [{15, :not_received, nil}] = holes
  end

  test "handle_rtp Twcc FCI round-trips through TwccFci.parse" do
    alias XMediaLib.Rtcp.TwccFci

    session = %Session{id: "twcc-parse", tenant_id: "t1"}

    assert {:ok, state} =
             Backend.init(session,
               session_pid: self(),
               subscribe_mode: :manual,
               twcc_period_ms: 1
             )

    on_exit(fn -> Plan.delete(state.plan_ref) end)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()
    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert {:ok, state} = Backend.participant_joined(a, state)
    assert {:ok, state} = Backend.participant_joined(b, state)

    assert :ok = Plan.put_track(state.plan_ref, "a", %{mid: "0", kind: :video, ssrc: 777})
    assert :ok = Plan.subscribe(state.plan_ref, "b", "a", "0")
    assert :ok = Runtime.put_ext(state.plan_ref, "a", %{twcc: 4})

    Process.put(:xylon_rtp_arrival_us, 64_000 * 3 + 2500)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 777,
      csrcs: [],
      extension: %Rtp.Extension{type: 0xBEDE, payload: <<4::4, 1::4, 0x00, 0x2A>>},
      payload: "v"
    }

    assert {:forward, _, _} = Backend.handle_rtp(a, rtp, state)
    Process.delete(:xylon_rtp_arrival_us)

    assert [{:send_rtcp, %XMediaLib.Rtcp{payloads: [%XMediaLib.Rtcp.Twcc{} = twcc]}}] =
             FakePeer.drain(peer_a)

    assert {:ok, [{42, status, delta_us}]} = TwccFci.parse(twcc)
    assert status in [:received_small, :received_large]
    assert delta_us == 2500
  end
end
