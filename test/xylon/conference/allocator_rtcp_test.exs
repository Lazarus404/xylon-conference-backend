defmodule Xylon.Conference.AllocatorRtcpTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{FakePeer, Plan, Rtcp, Runtime, SessionHooks}
  alias Xylon.{Participant, Session}

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    :ok
  end

  test "adaptive_layers REMB upswitches then downswitches SIM substream" do
    assert {:ok, session} =
             Session.create("t1", "alloc-sim", :conference, adaptive_layers: true)

    plan_ref = Session.plan_ref(session)
    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Plan.put_track(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 100,
               codec: "VP8",
               layers: [
                 %{ssrc: 100, substream: 0},
                 %{ssrc: 200, substream: 1},
                 %{ssrc: 300, substream: 2}
               ]
             })

    assert :ok = SessionHooks.subscribe(plan_ref, "b", "a", "1")
    assert %{source: :adaptive} = Plan.get_layer_policy(plan_ref, "a", "1", "b")
    assert %{substream: 0} = Plan.current_layer_opts(plan_ref, "a", "1", "b")

    [route] = Plan.routes_for_inbound(plan_ref, "a", 100)
    out = route.rewrite.out_ssrc

    rates = remb_n(plan_ref, b, %{}, out, 1_600_000, 2)
    assert %{substream: 2} = Plan.current_layer_opts(plan_ref, "a", "1", "b")

    # SIM spatial switch keeps subscriber out_ssrc; REMB can reuse the same SSRC.
    [route2] = Plan.routes_for_inbound(plan_ref, "a", 300)
    assert route2.rewrite.out_ssrc == out

    _ = remb_n(plan_ref, b, rates, out, 100_000, 2)
    assert %{substream: 0} = Plan.current_layer_opts(plan_ref, "a", "1", "b")
  end

  test "manual set_substream is not overridden by REMB" do
    assert {:ok, session} =
             Session.create("t1", "alloc-manual", :conference, adaptive_layers: true)

    plan_ref = Session.plan_ref(session)
    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Plan.put_track(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 100,
               codec: "VP8",
               layers: [
                 %{ssrc: 100, substream: 0},
                 %{ssrc: 200, substream: 1},
                 %{ssrc: 300, substream: 2}
               ]
             })

    assert :ok = SessionHooks.subscribe(plan_ref, "b", "a", "1", substream: 2)
    assert %{source: :manual} = Plan.get_layer_policy(plan_ref, "a", "1", "b")

    [route] = Plan.routes_for_inbound(plan_ref, "a", 300)
    out = route.rewrite.out_ssrc

    _ = remb_n(plan_ref, b, %{}, out, 50_000, 2)
    assert %{substream: 2} = Plan.current_layer_opts(plan_ref, "a", "1", "b")
  end

  test "adaptive_layers false does not change layers" do
    assert {:ok, session} = Session.create("t1", "alloc-off", :conference)
    plan_ref = Session.plan_ref(session)
    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Plan.put_track(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 100,
               codec: "VP8",
               layers: [
                 %{ssrc: 100, substream: 0},
                 %{ssrc: 200, substream: 1}
               ]
             })

    assert :ok = SessionHooks.subscribe(plan_ref, "b", "a", "1")
    [route] = Plan.routes_for_inbound(plan_ref, "a", 100)
    out = route.rewrite.out_ssrc

    _ = remb_n(plan_ref, b, %{}, out, 1_600_000, 2, false)
    assert %{substream: 0} = Plan.current_layer_opts(plan_ref, "a", "1", "b")
  end

  test "adaptive REMB lowers SVC spatial_layer" do
    assert {:ok, session} =
             Session.create("t1", "alloc-svc", :conference, adaptive_layers: true)

    plan_ref = Session.plan_ref(session)
    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Plan.put_track(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 77,
               codec: "VP9"
             })

    assert :ok = SessionHooks.subscribe(plan_ref, "b", "a", "1")
    [route] = Plan.routes_for_inbound(plan_ref, "a", 77)
    out = route.rewrite.out_ssrc

    rates = remb_n(plan_ref, b, %{}, out, 1_600_000, 2)
    assert %{spatial_layer: 2} = Plan.current_layer_opts(plan_ref, "a", "1", "b")

    _ = remb_n(plan_ref, b, rates, out, 80_000, 2)
    assert %{spatial_layer: 0} = Plan.current_layer_opts(plan_ref, "a", "1", "b")
  end

  test "adaptive_layers uses min(REMB, TWCC) to downshift SIM" do
    assert {:ok, session} =
             Session.create("t1", "alloc-twcc", :conference, adaptive_layers: true)

    plan_ref = Session.plan_ref(session)
    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Plan.put_track(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 100,
               codec: "VP8",
               layers: [
                 %{ssrc: 100, substream: 0},
                 %{ssrc: 200, substream: 1},
                 %{ssrc: 300, substream: 2}
               ]
             })

    assert :ok = SessionHooks.subscribe(plan_ref, "b", "a", "1")
    [route] = Plan.routes_for_inbound(plan_ref, "a", 100)
    out = route.rewrite.out_ssrc

    _ = remb_n(plan_ref, b, %{}, out, 1_600_000, 2)
    assert %{substream: 2} = Plan.current_layer_opts(plan_ref, "a", "1", "b")

    send_map =
      Map.new(0..4, fn i -> {i, 1_000_000 + i * 20_000} end)

    assert :ok =
             Runtime.put_sfu_twcc_send(plan_ref, out, %{seq: 5, send_map: send_map})

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
      ssrc_m: out,
      base_seq: 0,
      status_count: 5,
      ref_time: div(1_000_000, 64_000),
      fb_count: 0,
      fci: fci
    }

    # Two TWCC updates for Allocator hysteresis. Cap keeps TWCC-bps at a
    # stable low recommend so pending does not reset between cuts.
    _ = Runtime.put_remb(plan_ref, %{"a" => %{"b" => 1_600_000}})

    assert :ok =
             Rtcp.handle_twcc(plan_ref, b, %XMediaLib.Rtcp{payloads: [twcc]},
               adaptive_layers: true,
               bitrate_cap: 100_000
             )

    assert :ok =
             Rtcp.handle_twcc(plan_ref, b, %XMediaLib.Rtcp{payloads: [%{twcc | fb_count: 1}]},
               adaptive_layers: true,
               bitrate_cap: 100_000
             )

    assert %{substream: 0} = Plan.current_layer_opts(plan_ref, "a", "1", "b")
    assert %{bps: bps} = Runtime.get_sfu_twcc_bwe(plan_ref, "b", "a", "1")
    assert bps <= 100_000
  end

  defp remb_n(plan_ref, subscriber, rates, out_ssrc, bitrate, n, adaptive \\ true) do
    remb = %XMediaLib.Rtcp.Remb{ssrc_s: 1, ssrc_m: 0, bitrate: bitrate, ssrcs: [out_ssrc]}
    opts = [adaptive_layers: adaptive]

    Enum.reduce(1..n, rates, fn _, acc ->
      Rtcp.handle_remb(plan_ref, subscriber, %XMediaLib.Rtcp{payloads: [remb]}, acc, opts)
    end)
  end
end
