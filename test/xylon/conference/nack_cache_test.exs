defmodule Xylon.Conference.NackCacheTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.NackCache
  alias XMediaLib.Rtp

  setup do
    NackCache.ensure_table!()
    plan_ref = make_ref()
    on_exit(fn -> NackCache.clear_plan(plan_ref) end)
    %{plan_ref: plan_ref}
  end

  test "store and lookup round-trip", %{plan_ref: plan_ref} do
    pkt = %Rtp{sequence_number: 5, ssrc: 9, payload: "x"}
    assert :ok = NackCache.store(plan_ref, 9, 5, pkt)
    assert {:ok, out} = NackCache.lookup(plan_ref, 9, 5)
    assert out.sequence_number == 5
    assert out.ssrc == 9
    assert out.payload == "x"
    assert :error = NackCache.lookup(plan_ref, 9, 6)
  end

  test "store keeps lean emit fields including extension", %{plan_ref: plan_ref} do
    ext = %Rtp.Extension{type: 0xBEDE, payload: <<4, 0, 0>>}
    pkt = %Rtp{
      padding: 0,
      marker: 1,
      payload_type: 111,
      sequence_number: 42,
      timestamp: 9000,
      ssrc: 77,
      csrcs: [1],
      extension: ext,
      payload: "shared"
    }

    assert :ok = NackCache.store(plan_ref, 77, 42, pkt)
    assert {:ok, out} = NackCache.lookup(plan_ref, 77, 42)
    assert out.padding == 0
    assert out.marker == 1
    assert out.payload_type == 111
    assert out.sequence_number == 42
    assert out.timestamp == 9000
    assert out.ssrc == 77
    assert out.csrcs == [1]
    assert out.extension == ext
    assert %Rtp.Extension{type: 0xBEDE} = out.extension
    assert out.payload == "shared"
  end

  test "two legs share equal payload binaries after lean store", %{plan_ref: plan_ref} do
    payload = :binary.copy("audio-frame", 8)
    a = %Rtp{sequence_number: 1, ssrc: 10, payload: payload, payload_type: 111}
    b = %Rtp{sequence_number: 1, ssrc: 20, payload: payload, payload_type: 111}
    assert :ok = NackCache.store(plan_ref, 10, 1, a)
    assert :ok = NackCache.store(plan_ref, 20, 1, b)
    assert {:ok, oa} = NackCache.lookup(plan_ref, 10, 1)
    assert {:ok, ob} = NackCache.lookup(plan_ref, 20, 1)
    assert oa.ssrc == 10
    assert ob.ssrc == 20
    assert oa.payload == ob.payload
    assert oa.payload == payload
  end

  test "eviction keeps at most 1000 packets per out_ssrc", %{plan_ref: plan_ref} do
    out_ssrc = 4242

    for seq <- 1..1005 do
      pkt = %Rtp{sequence_number: seq, ssrc: out_ssrc, payload: <<seq::16>>}
      assert :ok = NackCache.store(plan_ref, out_ssrc, seq, pkt)
    end

    assert NackCache.count(plan_ref, out_ssrc) == 1000
    assert :error = NackCache.lookup(plan_ref, out_ssrc, 1)
    assert {:ok, _} = NackCache.lookup(plan_ref, out_ssrc, 1005)
  end

  test "age eviction drops packets older than max_age_ms", %{plan_ref: plan_ref} do
    out_ssrc = 7
    pkt1 = %Rtp{sequence_number: 1, ssrc: out_ssrc, payload: "a"}
    pkt2 = %Rtp{sequence_number: 2, ssrc: out_ssrc, payload: "b"}

    assert :ok = NackCache.store(plan_ref, out_ssrc, 1, pkt1, now: 0)
    assert :ok = NackCache.store(plan_ref, out_ssrc, 2, pkt2, now: 2000)

    assert :error = NackCache.lookup(plan_ref, out_ssrc, 1, now: 2000)
    assert {:ok, out2} = NackCache.lookup(plan_ref, out_ssrc, 2, now: 2000)
    assert out2.payload == "b"
    assert NackCache.count(plan_ref, out_ssrc) == 1
  end

  test "clear_ssrc removes packets and ring meta", %{plan_ref: plan_ref} do
    out_ssrc = 99
    pkt = %Rtp{sequence_number: 1, ssrc: out_ssrc, payload: "z"}
    assert :ok = NackCache.store(plan_ref, out_ssrc, 1, pkt)
    assert :ok = NackCache.clear_ssrc(plan_ref, out_ssrc)
    assert :error = NackCache.lookup(plan_ref, out_ssrc, 1)
    assert NackCache.count(plan_ref, out_ssrc) == 0
  end

  test "FIFO overflow drops oldest by insertion order", %{plan_ref: plan_ref} do
    out_ssrc = 11

    for seq <- 1..1000 do
      pkt = %Rtp{sequence_number: seq, ssrc: out_ssrc, payload: <<seq::16>>}
      assert :ok = NackCache.store(plan_ref, out_ssrc, seq, pkt, now: seq)
    end

    pkt = %Rtp{sequence_number: 1001, ssrc: out_ssrc, payload: <<1001::16>>}
    assert :ok = NackCache.store(plan_ref, out_ssrc, 1001, pkt, now: 1001)

    assert NackCache.count(plan_ref, out_ssrc) == 1000
    assert :error = NackCache.lookup(plan_ref, out_ssrc, 1, now: 1001)
    assert {:ok, _} = NackCache.lookup(plan_ref, out_ssrc, 2, now: 1001)
    assert {:ok, _} = NackCache.lookup(plan_ref, out_ssrc, 1001, now: 1001)
  end

  test "lookup age-miss updates ring count", %{plan_ref: plan_ref} do
    out_ssrc = 13
    pkt1 = %Rtp{sequence_number: 1, ssrc: out_ssrc, payload: "a"}
    pkt2 = %Rtp{sequence_number: 2, ssrc: out_ssrc, payload: "b"}

    assert :ok = NackCache.store(plan_ref, out_ssrc, 1, pkt1, now: 0)
    assert :ok = NackCache.store(plan_ref, out_ssrc, 2, pkt2, now: 500)
    assert NackCache.count(plan_ref, out_ssrc) == 2

    assert :error = NackCache.lookup(plan_ref, out_ssrc, 1, now: 1001)
    assert NackCache.count(plan_ref, out_ssrc) == 1
    assert {:ok, out2} = NackCache.lookup(plan_ref, out_ssrc, 2, now: 1001)
    assert out2.payload == "b"
  end
end
