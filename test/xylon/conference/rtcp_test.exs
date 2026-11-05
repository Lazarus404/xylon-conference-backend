defmodule Xylon.Conference.RtcpTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{FakePeer, Plan, Rtcp, Runtime}
  alias Xylon.{Participant, Session}

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    :ok
  end

  test "forward_pli_fir rewrites PLI ssrc_m from out_ssrc to in_ssrc" do
    assert {:ok, session} = Session.create("t1", "rtcp-pli", :conference)
    plan_ref = Session.plan_ref(session)
    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 100})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "1")

    [route] = Plan.routes_for_inbound(plan_ref, "a", 100)
    out_ssrc = route.rewrite.out_ssrc
    pli = %XMediaLib.Rtcp.Pli{ssrc_s: 1, ssrc_m: out_ssrc}
    inbound = %XMediaLib.Rtcp{payloads: [pli]}

    assert :ok = Rtcp.forward_pli_fir(plan_ref, b, inbound)
    expected = %XMediaLib.Rtcp{payloads: [%XMediaLib.Rtcp.Pli{ssrc_s: 1, ssrc_m: 100}]}
    assert [{:send_rtcp, ^expected}] = FakePeer.drain(peer_a)
  end

  test "forward_pli_fir rewrites FIR ssrc from out_ssrc to in_ssrc" do
    assert {:ok, session} = Session.create("t1", "rtcp-fir", :conference)
    plan_ref = Session.plan_ref(session)
    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 200})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "1")

    [route] = Plan.routes_for_inbound(plan_ref, "a", 200)
    out_ssrc = route.rewrite.out_ssrc
    fir = %XMediaLib.Rtcp.Fir{ssrc: out_ssrc}
    inbound = %XMediaLib.Rtcp{payloads: [fir]}

    assert :ok = Rtcp.forward_pli_fir(plan_ref, b, inbound)
    expected = %XMediaLib.Rtcp{payloads: [%XMediaLib.Rtcp.Fir{ssrc: 200}]}
    assert [{:send_rtcp, ^expected}] = FakePeer.drain(peer_a)
  end

  test "forward_pli_fir wraps bare PLI as %Rtcp{} for Peer.send_rtcp" do
    assert {:ok, session} = Session.create("t1", "rtcp-bare", :conference)
    plan_ref = Session.plan_ref(session)
    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 300})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "1")

    [route] = Plan.routes_for_inbound(plan_ref, "a", 300)
    out_ssrc = route.rewrite.out_ssrc
    pli = %XMediaLib.Rtcp.Pli{ssrc_s: 1, ssrc_m: out_ssrc}

    assert :ok = Rtcp.forward_pli_fir(plan_ref, b, pli)
    expected = %XMediaLib.Rtcp{payloads: [%XMediaLib.Rtcp.Pli{ssrc_s: 1, ssrc_m: 300}]}
    assert [{:send_rtcp, ^expected}] = FakePeer.drain(peer_a)
  end

  test "handle_remb sends min of two subscriber rates to publisher" do
    assert {:ok, session} = Session.create("t1", "rtcp-remb-min", :conference)
    plan_ref = Session.plan_ref(session)
    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()
    assert {:ok, peer_c} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    c = %Participant{id: "c", peer_ref: peer_c}
    Enum.each([a, b, c], &Plan.put_participant(plan_ref, &1))
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 400})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "1")
    assert :ok = Plan.subscribe(plan_ref, "c", "a", "1")

    routes = Plan.routes_for_inbound(plan_ref, "a", 400)
    out_b = Enum.find(routes, &(&1.subscriber_id == "b")).rewrite.out_ssrc
    out_c = Enum.find(routes, &(&1.subscriber_id == "c")).rewrite.out_ssrc

    remb_b = %XMediaLib.Rtcp.Remb{ssrc_s: 1, ssrc_m: 0, bitrate: 300_000, ssrcs: [out_b]}
    rates = Rtcp.handle_remb(plan_ref, b, %XMediaLib.Rtcp{payloads: [remb_b]}, %{})
    _ = FakePeer.drain(peer_a)

    remb_c = %XMediaLib.Rtcp.Remb{ssrc_s: 1, ssrc_m: 0, bitrate: 200_000, ssrcs: [out_c]}
    _ = Rtcp.handle_remb(plan_ref, c, %XMediaLib.Rtcp{payloads: [remb_c]}, rates)

    assert [
             {:send_rtcp,
              %XMediaLib.Rtcp{
                payloads: [%XMediaLib.Rtcp.Remb{bitrate: 200_000, ssrcs: [400]}]
              }}
           ] = FakePeer.drain(peer_a)
  end

  test "handle_remb applies bitrate_cap" do
    assert {:ok, session} = Session.create("t1", "rtcp-remb-cap", :conference)
    plan_ref = Session.plan_ref(session)
    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 500})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "1")

    [route] = Plan.routes_for_inbound(plan_ref, "a", 500)
    out_ssrc = route.rewrite.out_ssrc
    remb = %XMediaLib.Rtcp.Remb{ssrc_s: 1, ssrc_m: 0, bitrate: 500_000, ssrcs: [out_ssrc]}

    _ =
      Rtcp.handle_remb(plan_ref, b, %XMediaLib.Rtcp{payloads: [remb]}, %{}, bitrate_cap: 100_000)

    assert [
             {:send_rtcp,
              %XMediaLib.Rtcp{
                payloads: [%XMediaLib.Rtcp.Remb{bitrate: 100_000, ssrcs: [500]}]
              }}
           ] = FakePeer.drain(peer_a)
  end

  test "handle_remb does not send REMB to publisher with transport-cc" do
    assert {:ok, session} = Session.create("t1", "rtcp-remb-twcc", :conference)
    plan_ref = Session.plan_ref(session)
    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Plan.put_track(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 600})
    assert :ok = Plan.subscribe(plan_ref, "b", "a", "1")
    assert :ok = Runtime.put_ext(plan_ref, "a", %{twcc: 4})

    [route] = Plan.routes_for_inbound(plan_ref, "a", 600)
    out_ssrc = route.rewrite.out_ssrc
    remb = %XMediaLib.Rtcp.Remb{ssrc_s: 1, ssrc_m: 0, bitrate: 50_000, ssrcs: [out_ssrc]}

    rates = Rtcp.handle_remb(plan_ref, b, %XMediaLib.Rtcp{payloads: [remb]}, %{})

    assert rates == %{"a" => %{"b" => 50_000}}
    assert [] = FakePeer.drain(peer_a)
  end
end
