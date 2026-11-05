defmodule Xylon.Conference.SfuForwardTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{FakePeer, Plan}
  alias Xylon.{Forwarder, Participant, Session}
  alias XMediaLib.Rtp
  alias XMediaLib.Rtp.HeaderExtension

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    :ok = Xylon.Recording.Registry.ensure_table!()
    Application.put_env(:xylon, :recording, handler: Xylon.Recording.Null)

    on_exit(fn ->
      Application.delete_env(:xylon, :recording)
      Application.delete_env(:xylon, :recording_spy_pid)
    end)

    :ok
  end

  defmodule RecordingSpy do
    @moduledoc false
    @behaviour Xylon.Recording.Handler

    alias Xylon.Recording.Ctx

    @impl true
    def on_start(%Ctx{}, _opts), do: {:ok, %{n: 0}}

    @impl true
    def on_stop(%Ctx{}, state), do: {:ok, state}

    @impl true
    def on_publisher_rtp(%Ctx{}, state, _meta, _rtp) do
      if pid = Application.get_env(:xylon, :recording_spy_pid), do: send(pid, :publisher_rtp)
      {:ok, Map.update(state, :n, 1, &(&1 + 1))}
    end

    @impl true
    def on_mix_rtp(%Ctx{}, state, _meta, _rtp), do: {:ok, state}
  end

  test "1:1 SFU: subscriber receives rewritten RTP, publisher does not" do
    assert {:ok, session} = Session.create("t1", "sfu-11", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a, role: :publisher}
    b = %Participant{id: "b", peer_ref: peer_b, role: :subscriber}

    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 4242})

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 4242,
      csrcs: [],
      extension: nil,
      payload: "hi"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})
    assert_receive_forwarded(peer_b, 4242)
    assert [] = FakePeer.drain(peer_a)
  end

  test "SFU forward unchanged with Null recording on; Spy sees publisher RTP" do
    Application.put_env(:xylon, :recording_spy_pid, self())
    Application.put_env(:xylon, :recording, handler: RecordingSpy)

    sid = "sfu-rec-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Session.create("t1", sid, :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a, role: :publisher}
    b = %Participant{id: "b", peer_ref: peer_b, role: :subscriber}

    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 4242})

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)

    assert {:ok, _} = Session.start_recording(session)
    assert plan_ref == session

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 4242,
      csrcs: [],
      extension: nil,
      payload: "hi"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})
    assert_receive_forwarded(peer_b, 4242)
    assert [] = FakePeer.drain(peer_a)
    assert_receive :publisher_rtp, 500

    assert {_mod, _ctx, %{n: n}} = Xylon.Recording.Registry.get(session)
    assert n >= 1

    assert {:ok, _} = Session.stop_recording(session)
  end

  test "SFU video fanout stamps transport-cc when subscriber negotiated it" do
    assert {:ok, session} = Session.create("t1", "sfu-twcc-stamp", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Xylon.Conference.Runtime.put_ext(plan_ref, "b", %{twcc: 4})

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 55, codec: "VP8"})

    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "1", forwarder: fwd)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 55,
      csrcs: [],
      extension: nil,
      payload: "v"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})

    Enum.reduce_while(1..50, nil, fn _, _ ->
      case FakePeer.drain(peer_b) do
        [{:send_rtp, out_ssrc, %Rtp{} = out}] ->
          assert out_ssrc != 55
          assert %{type: type, payload: payload} = out.extension
          elements = HeaderExtension.decode_elements(type, payload)
          assert {4, <<0::unsigned-size(16)>>} = List.keyfind(elements, 4, 0)
          assert %{send_map: map} = Xylon.Conference.Runtime.get_sfu_twcc_send(plan_ref, out_ssrc)
          assert Map.has_key?(map, 0)

          # Lean NACK store must keep post-stamp extension (not stripped rewrite).
          assert {:ok, cached} = Xylon.Conference.NackCache.lookup(plan_ref, out_ssrc, out.sequence_number)
          assert cached.ssrc == out_ssrc
          assert cached.sequence_number == out.sequence_number
          assert cached.extension == out.extension
          assert cached.payload == out.payload
          {:halt, :ok}

        [] ->
          Process.sleep(10)
          {:cont, nil}

        other ->
          flunk("unexpected: #{inspect(other)}")
      end
    end)
    |> case do
      :ok -> :ok
      _ -> flunk("timed out waiting for TWCC-stamped RTP")
    end
  end

  test "1:N SFU fanout to two subscribers" do
    assert {:ok, session} = Session.create("t1", "sfu-1n", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()
    assert {:ok, peer_c} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    c = %Participant{id: "c", peer_ref: peer_c}

    Enum.each([a, b, c], &Plan.put_participant(plan_ref, &1))
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 7})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)
    assert :ok = Xylon.Conference.subscribe(plan_ref, "c", "a", "0", forwarder: fwd)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 7,
      csrcs: [],
      extension: nil,
      payload: "n"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})
    assert_receive_forwarded(peer_b, 7)
    assert_receive_forwarded(peer_c, 7)
  end

  test "audio thin fanout stores NACK cache without DD chain rows" do
    assert {:ok, session} = Session.create("t1", "sfu-thin-nack", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()
    assert {:ok, peer_c} = FakePeer.start_link()

    Enum.each(
      [
        %Participant{id: "a", peer_ref: peer_a},
        %Participant{id: "b", peer_ref: peer_b},
        %Participant{id: "c", peer_ref: peer_c}
      ],
      &Plan.put_participant(plan_ref, &1)
    )

    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 88})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)
    assert :ok = Xylon.Conference.subscribe(plan_ref, "c", "a", "0", forwarder: fwd)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 9,
      timestamp: 960,
      ssrc: 88,
      csrcs: [],
      extension: nil,
      payload: "thin"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})
    assert_receive_forwarded(peer_b, 88)
    assert_receive_forwarded(peer_c, 88)

    routes = Plan.routes_for_inbound(plan_ref, "a", 88)
    assert length(routes) == 2

    Enum.each(routes, fn route ->
      out = route.rewrite.out_ssrc
      seq = route.rewrite.last_out_seq
      assert is_integer(seq)
      assert {:ok, cached} = Xylon.Conference.NackCache.lookup(plan_ref, out, seq)
      assert cached.ssrc == out
      assert cached.sequence_number == seq
      assert cached.payload == "thin"

      assert [] =
               :ets.lookup(:xylon_conference_plan, {plan_ref, :dd_chain, "a", "0", route.subscriber_id})
    end)
  end

  test "VP8 SIM layers without caps use thin path (no DD chain)" do
    assert {:ok, session} = Session.create("t1", "sfu-sim-thin", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    assert :ok = Plan.put_participant(plan_ref, %Participant{id: "a", peer_ref: peer_a})
    assert :ok = Plan.put_participant(plan_ref, %Participant{id: "b", peer_ref: peer_b})

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 100,
               codec: "VP8",
               layers: [
                 %{ssrc: 100, substream: 0},
                 %{ssrc: 200, substream: 1}
               ]
             })

    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "1", forwarder: fwd)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 100,
      csrcs: [],
      extension: nil,
      payload: "sim"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})
    assert_receive_forwarded(peer_b, 100)

    assert [] = :ets.lookup(:xylon_conference_plan, {plan_ref, :dd_chain, "a", "1", "b"})
    [route] = Plan.routes_for_inbound(plan_ref, "a", 100)
    assert is_list(route.layers) and route.layers != []
    assert is_nil(route.max_temporal)
  end

  test "unsubscribe stops delivery" do
    assert {:ok, session} = Session.create("t1", "sfu-unsub", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 9})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)
    assert :ok = Xylon.Conference.unsubscribe(plan_ref, "b", "a", "0", forwarder: fwd)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 9,
      csrcs: [],
      extension: nil,
      payload: "x"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})
    Process.sleep(30)
    assert [] = FakePeer.drain(peer_b)
  end

  test "pause drops RTP; resume keeps out_ssrc continuity" do
    assert {:ok, session} = Session.create("t1", "sfu-pause", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 11})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)

    [route] = Plan.routes_for_inbound(plan_ref, "a", 11)
    out = route.rewrite.out_ssrc

    rtp1 = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 11,
      csrcs: [],
      extension: nil,
      payload: "a"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp1, %{}})
    assert_receive_forwarded(peer_b, 11)

    assert :ok = Xylon.Conference.pause(plan_ref, "b", "a", "0", forwarder: fwd)

    rtp2 = %{rtp1 | sequence_number: 2, payload: "b"}
    send(fwd, {:xgw, :rtp, peer_a, rtp2, %{}})
    Process.sleep(30)
    assert [] = FakePeer.drain(peer_b)

    assert :ok = Xylon.Conference.resume(plan_ref, "b", "a", "0", forwarder: fwd)
    [again] = Plan.routes_for_inbound(plan_ref, "a", 11)
    assert again.rewrite.out_ssrc == out

    rtp3 = %{rtp1 | sequence_number: 3, payload: "c"}
    send(fwd, {:xgw, :rtp, peer_a, rtp3, %{}})
    assert_receive_forwarded(peer_b, 11)
  end

  test "switch moves RTP to new publisher" do
    assert {:ok, session} = Session.create("t1", "sfu-switch", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_c} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    Enum.each(
      [
        %Participant{id: "a", peer_ref: peer_a},
        %Participant{id: "c", peer_ref: peer_c},
        %Participant{id: "b", peer_ref: peer_b}
      ],
      &Plan.put_participant(plan_ref, &1)
    )

    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 100})
    assert :ok = Xylon.Conference.publish(plan_ref, "c", %{mid: "0", kind: :audio, ssrc: 200})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)
    assert :ok = Session.switch(session, "b", "c", "0")

    rtp_a = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 100,
      csrcs: [],
      extension: nil,
      payload: "a"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp_a, %{}})
    Process.sleep(30)
    assert [] = FakePeer.drain(peer_b)

    rtp_c = %{rtp_a | ssrc: 200, payload: "c"}
    send(fwd, {:xgw, :rtp, peer_c, rtp_c, %{}})
    assert_receive_forwarded(peer_b, 200)
  end

  test "moderate_av mute pauses publisher outbound RTP" do
    assert {:ok, session} = Session.create("t1", "sfu-mod", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    assert :ok = Plan.put_participant(plan_ref, %Participant{id: "a", peer_ref: peer_a})
    assert :ok = Plan.put_participant(plan_ref, %Participant{id: "b", peer_ref: peer_b})
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 77})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)

    assert :ok = Session.moderate_av(session, "a", :mute, ["0"])

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 77,
      csrcs: [],
      extension: nil,
      payload: "m"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})
    Process.sleep(30)
    assert [] = FakePeer.drain(peer_b)

    assert :ok = Session.moderate_av(session, "a", :unmute, ["0"])
    send(fwd, {:xgw, :rtp, peer_a, %{rtp | sequence_number: 2}, %{}})
    assert_receive_forwarded(peer_b, 77)
  end

  test "moderate_av mute one mid leaves sibling mid flowing" do
    assert {:ok, session} = Session.create("t1", "sfu-mod-mid", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    assert :ok = Plan.put_participant(plan_ref, %Participant{id: "a", peer_ref: peer_a})
    assert :ok = Plan.put_participant(plan_ref, %Participant{id: "b", peer_ref: peer_b})
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 10})
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 20})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "1", forwarder: fwd)

    assert :ok = Session.moderate_av(session, "a", :mute, ["1"])

    rtp_a = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 10,
      csrcs: [],
      extension: nil,
      payload: "a"
    }

    rtp_v = %{rtp_a | payload_type: 96, ssrc: 20, payload: "v"}

    send(fwd, {:xgw, :rtp, peer_a, rtp_a, %{}})
    send(fwd, {:xgw, :rtp, peer_a, rtp_v, %{}})
    assert_receive_forwarded(peer_b, 10)
    Process.sleep(30)
    refute Enum.any?(FakePeer.drain(peer_b), fn
             %{ssrc: 20} -> true
             _ -> false
           end)

    assert :ok = Session.moderate_av(session, "a", :unmute, ["1"])
    send(fwd, {:xgw, :rtp, peer_a, %{rtp_v | sequence_number: 2}, %{}})
    assert_receive_forwarded(peer_b, 20)
  end

  test "Session mailbox stays clear of RTP during Forwarder SFU burst" do
    assert {:ok, session} = Session.create("t1", "sfu-burst", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 1})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 1,
      csrcs: [],
      extension: nil,
      payload: "hi"
    }

    for seq <- 1..20 do
      send(fwd, {:xgw, :rtp, peer_a, %{rtp | sequence_number: seq}, %{}})
    end

    Process.sleep(50)
    assert {:messages, messages} = Process.info(session, :messages)
    refute Enum.any?(messages, &match?({:xgw, :rtp, _, _, _}, &1))
    assert length(FakePeer.drain(peer_b)) == 20
  end

  test "PLI toward rewritten ssrc is rewritten to publisher in_ssrc" do
    assert {:ok, session} = Session.create("t1", "sfu-pli", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 50})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "1", forwarder: fwd)
    _ = FakePeer.drain(peer_a)
    # Subscriber needs a Forwarder plan so inbound RTCP is handled.
    assert :ok = Forwarder.put_plan(fwd, peer_b, %{mode: :sfu, participant: b})

    [route] = Plan.routes_for_inbound(plan_ref, "a", 50)
    out_ssrc = route.rewrite.out_ssrc
    refute out_ssrc == 50
    pli = %XMediaLib.Rtcp.Pli{ssrc_s: 1, ssrc_m: out_ssrc}
    inbound = %XMediaLib.Rtcp{payloads: [pli]}
    expected = %XMediaLib.Rtcp{payloads: [%XMediaLib.Rtcp.Pli{ssrc_s: 1, ssrc_m: 50}]}

    send(fwd, {:xgw, :rtcp, peer_b, inbound, %{}})
    Process.sleep(30)

    assert [{:send_rtcp, ^expected}] = FakePeer.drain(peer_a)
  end

  test "FIR toward rewritten ssrc is rewritten to publisher in_ssrc" do
    assert {:ok, session} = Session.create("t1", "sfu-fir", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 77})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "1", forwarder: fwd)
    _ = FakePeer.drain(peer_a)
    assert :ok = Forwarder.put_plan(fwd, peer_b, %{mode: :sfu, participant: b})

    [route] = Plan.routes_for_inbound(plan_ref, "a", 77)
    out_ssrc = route.rewrite.out_ssrc
    fir = %XMediaLib.Rtcp.Fir{ssrc: out_ssrc}
    inbound = %XMediaLib.Rtcp{payloads: [fir]}
    expected = %XMediaLib.Rtcp{payloads: [%XMediaLib.Rtcp.Fir{ssrc: 77}]}

    send(fwd, {:xgw, :rtcp, peer_b, inbound, %{}})
    Process.sleep(30)

    assert [{:send_rtcp, ^expected}] = FakePeer.drain(peer_a)
  end

  test "video subscribe sends one PLI to publisher with in_ssrc" do
    assert {:ok, session} = Session.create("t1", "sfu-sub-pli", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 99})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "1", forwarder: fwd)

    expected = %XMediaLib.Rtcp{payloads: [%XMediaLib.Rtcp.Pli{ssrc_s: 1, ssrc_m: 99}]}
    assert [{:send_rtcp, ^expected}] = FakePeer.drain(peer_a)
    assert [] = FakePeer.drain(peer_b)
  end

  test "audio subscribe does not send PLI" do
    assert {:ok, session} = Session.create("t1", "sfu-sub-audio", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 11})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)

    assert [] = FakePeer.drain(peer_a)
  end

  test "Gnack retransmits cached packet to NACKing subscriber only" do
    assert {:ok, session} = Session.create("t1", "sfu-nack", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()
    assert {:ok, peer_c} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    c = %Participant{id: "c", peer_ref: peer_c}
    Enum.each([a, b, c], &Plan.put_participant(plan_ref, &1))
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 88})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "1", forwarder: fwd)
    assert :ok = Xylon.Conference.subscribe(plan_ref, "c", "a", "1", forwarder: fwd)
    _ = FakePeer.drain(peer_a)
    assert :ok = Forwarder.put_plan(fwd, peer_b, %{mode: :sfu, participant: b})

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 10,
      timestamp: 1000,
      ssrc: 88,
      csrcs: [],
      extension: nil,
      payload: "lost"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})
    Process.sleep(30)

    [{:send_rtp, out_b, %Rtp{sequence_number: out_seq} = cached}] = FakePeer.drain(peer_b)
    [{:send_rtp, _out_c, _}] = FakePeer.drain(peer_c)

    gnack = %XMediaLib.Rtcp.Gnack{ssrc_s: 1, ssrc_m: out_b, list: [{out_seq, 0}]}
    inbound = %XMediaLib.Rtcp{payloads: [gnack]}
    send(fwd, {:xgw, :rtcp, peer_b, inbound, %{}})
    Process.sleep(30)

    assert [{:send_rtp, ^out_b, ^cached}] = FakePeer.drain(peer_b)
    assert [] = FakePeer.drain(peer_c)
  end

  test "Gnack for unknown sequence is a no-op" do
    assert {:ok, session} = Session.create("t1", "sfu-nack-miss", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 66})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "1", forwarder: fwd)
    _ = FakePeer.drain(peer_a)
    assert :ok = Forwarder.put_plan(fwd, peer_b, %{mode: :sfu, participant: b})

    [route] = Plan.routes_for_inbound(plan_ref, "a", 66)
    out_ssrc = route.rewrite.out_ssrc
    gnack = %XMediaLib.Rtcp.Gnack{ssrc_s: 1, ssrc_m: out_ssrc, list: [{9999, 0}]}
    inbound = %XMediaLib.Rtcp{payloads: [gnack]}
    send(fwd, {:xgw, :rtcp, peer_b, inbound, %{}})
    Process.sleep(30)

    assert [] = FakePeer.drain(peer_b)
  end

  test "unpublish video keeps audio routes and participant" do
    assert {:ok, session} = Session.create("t1", "sfu-unpub-partial", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    assert :ok = Plan.put_participant(plan_ref, %Participant{id: "a", peer_ref: peer_a})
    assert :ok = Plan.put_participant(plan_ref, %Participant{id: "b", peer_ref: peer_b})
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 11})
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 22})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "1", forwarder: fwd)

    assert :ok = Session.unpublish(session, "a", ["1"])

    assert Plan.get_participant(plan_ref, "a")
    assert Plan.get_track(plan_ref, "a", "0")
    refute Plan.get_track(plan_ref, "a", "1")
    assert [] = Plan.routes_for_inbound(plan_ref, "a", 22)
    assert [_] = Plan.routes_for_inbound(plan_ref, "a", 11)

    rtp_v = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 22,
      csrcs: [],
      extension: nil,
      payload: "v"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp_v, %{}})
    Process.sleep(30)
    assert [] = FakePeer.drain(peer_b)

    rtp_a = %{rtp_v | payload_type: 111, ssrc: 11, payload: "a"}
    send(fwd, {:xgw, :rtp, peer_a, rtp_a, %{}})
    assert_receive_forwarded(peer_b, 11)
  end

  test "unpublish both kinds stops fanout; re-publish restores" do
    assert {:ok, session} = Session.create("t1", "sfu-unpub-full", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    assert :ok = Plan.put_participant(plan_ref, %Participant{id: "a", peer_ref: peer_a})
    assert :ok = Plan.put_participant(plan_ref, %Participant{id: "b", peer_ref: peer_b})
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 33})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)

    assert :ok = Session.unpublish(session, "a", :all)
    refute Plan.get_track(plan_ref, "a", "0")
    assert Plan.get_participant(plan_ref, "a")

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 33,
      csrcs: [],
      extension: nil,
      payload: "x"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})
    Process.sleep(30)
    assert [] = FakePeer.drain(peer_b)

    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 44})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)
    send(fwd, {:xgw, :rtp, peer_a, %{rtp | ssrc: 44, sequence_number: 2}, %{}})
    assert_receive_forwarded(peer_b, 44)
  end

  test "selective subscribe to one of two video mids" do
    assert {:ok, session} = Session.create("t1", "sfu-two-video", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 50})
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "2", kind: :video, ssrc: 51})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "1", forwarder: fwd)

    rtp1 = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 50,
      csrcs: [],
      extension: nil,
      payload: "cam"
    }

    rtp2 = %{rtp1 | ssrc: 51, payload: "screen"}

    send(fwd, {:xgw, :rtp, peer_a, rtp1, %{}})
    assert_receive_forwarded(peer_b, 50)

    send(fwd, {:xgw, :rtp, peer_a, rtp2, %{}})
    Process.sleep(30)
    assert [] = FakePeer.drain(peer_b)
  end

  test "update_subscriptions replaces subscribe routes" do
    assert {:ok, session} = Session.create("t1", "sfu-update-subs", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_c} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    Enum.each(
      [
        %Participant{id: "a", peer_ref: peer_a},
        %Participant{id: "c", peer_ref: peer_c},
        %Participant{id: "b", peer_ref: peer_b}
      ],
      &Plan.put_participant(plan_ref, &1)
    )

    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 10})
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 20})
    assert :ok = Xylon.Conference.publish(plan_ref, "c", %{mid: "0", kind: :audio, ssrc: 30})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "1", forwarder: fwd)

    assert :ok =
             Session.update_subscriptions(session, "b", [
               %{publisher_id: "c", mid: "0"}
             ])

    refute MapSet.member?(Plan.subscribers(plan_ref, "a", "0"), "b")
    refute MapSet.member?(Plan.subscribers(plan_ref, "a", "1"), "b")
    assert MapSet.member?(Plan.subscribers(plan_ref, "c", "0"), "b")

    rtp_a = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 10,
      csrcs: [],
      extension: nil,
      payload: "a"
    }

    rtp_c = %{rtp_a | ssrc: 30, payload: "c"}

    send(fwd, {:xgw, :rtp, peer_a, rtp_a, %{}})
    Process.sleep(30)
    assert [] = FakePeer.drain(peer_b)

    send(fwd, {:xgw, :rtp, peer_c, rtp_c, %{}})
    assert_receive_forwarded(peer_b, 30)
  end

  test "unpublish is idempotent; empty mids error" do
    assert {:ok, session} = Session.create("t1", "sfu-unpub-idemp", :conference)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert :ok = Plan.put_participant(plan_ref, %Participant{id: "a", peer_ref: peer_a})
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 55})

    assert :ok = Session.unpublish(session, "a", ["0"])
    assert :ok = Session.unpublish(session, "a", ["0"])
    assert {:error, :invalid_mids} = Session.unpublish(session, "a", [])
  end

  test "trunk destination receives rewritten RTP alongside peer" do
    assert {:ok, session} = Session.create("t1", "sfu-trunk-both", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()
    assert {:ok, peer_t} = FakePeer.start_link()

    assert :ok = Plan.put_participant(plan_ref, %Participant{id: "a", peer_ref: peer_a})
    assert :ok = Plan.put_participant(plan_ref, %Participant{id: "b", peer_ref: peer_b})
    assert :ok = Plan.put_participant(plan_ref, %Participant{id: "trunk1", peer_ref: peer_t})
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 900})
    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "trunk1", "a", "0",
               dest_type: :trunk,
               forwarder: fwd
             )

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 900,
      csrcs: [],
      extension: nil,
      payload: "t"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})
    assert_receive_forwarded(peer_b, 900)
    assert_receive_forwarded(peer_t, 900)
  end

  test "trunk-only path receives RTP; pause stops trunk delivery" do
    assert {:ok, session} = Session.create("t1", "sfu-trunk-only", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_t} = FakePeer.start_link()

    assert :ok = Plan.put_participant(plan_ref, %Participant{id: "a", peer_ref: peer_a})
    assert :ok = Plan.put_participant(plan_ref, %Participant{id: "trunk1", peer_ref: peer_t})
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 901})

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "trunk1", "a", "0",
               dest_type: :trunk,
               forwarder: fwd
             )

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 901,
      csrcs: [],
      extension: nil,
      payload: "x"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})
    assert_receive_forwarded(peer_t, 901)

    assert :ok =
             Xylon.Conference.pause(plan_ref, "trunk1", "a", "0", forwarder: fwd)

    send(fwd, {:xgw, :rtp, peer_a, %{rtp | sequence_number: 2}, %{}})
    Process.sleep(30)
    assert [] = FakePeer.drain(peer_t)
  end

  test "SIM substream filters SSRC; set_substream switches and sends PLI" do
    assert {:ok, session} = Session.create("t1", "sfu-sim", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 100,
               codec: "VP8",
               layers: [
                 %{ssrc: 100, substream: 0},
                 %{ssrc: 200, substream: 1}
               ]
             })

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "b", "a", "1",
               forwarder: fwd,
               substream: 0
             )

    _ = FakePeer.drain(peer_a)

    rtp = fn ssrc, seq ->
      %Rtp{
        padding: 0,
        marker: 0,
        payload_type: 96,
        sequence_number: seq,
        timestamp: 0,
        ssrc: ssrc,
        csrcs: [],
        extension: nil,
        payload: "v"
      }
    end

    send(fwd, {:xgw, :rtp, peer_a, rtp.(100, 1), %{}})
    assert_receive_forwarded(peer_b, 100)

    send(fwd, {:xgw, :rtp, peer_a, rtp.(200, 1), %{}})
    Process.sleep(30)
    assert [] = FakePeer.drain(peer_b)

    assert :ok =
             Xylon.Conference.set_substream(plan_ref, "b", "a", "1",
               forwarder: fwd,
               substream: 1
             )

    expected = %XMediaLib.Rtcp{payloads: [%XMediaLib.Rtcp.Pli{ssrc_s: 1, ssrc_m: 200}]}
    assert [{:send_rtcp, ^expected}] = FakePeer.drain(peer_a)

    send(fwd, {:xgw, :rtp, peer_a, rtp.(200, 2), %{}})
    assert_receive_forwarded(peer_b, 200)

    send(fwd, {:xgw, :rtp, peer_a, rtp.(100, 2), %{}})
    Process.sleep(30)
    assert [] = FakePeer.drain(peer_b)
  end

  defp vp8_tid_payload(tid) when tid in 0..3 do
    # RFC 7741: X=1, T=1, TID in bits 7-6
    <<0x80, 0x20, tid::2, 0::6, 0x00>>
  end

  test "VP8 temporal filter drops higher TID; contiguous out seq" do
    assert {:ok, session} = Session.create("t1", "sfu-tid", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 4242,
               codec: "VP8"
             })

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "b", "a", "1",
               forwarder: fwd,
               temporal: 0
             )

    _ = FakePeer.drain(peer_a)

    rtp = fn tid, seq ->
      %Rtp{
        padding: 0,
        marker: 0,
        payload_type: 96,
        sequence_number: seq,
        timestamp: 0,
        ssrc: 4242,
        csrcs: [],
        extension: nil,
        payload: vp8_tid_payload(tid)
      }
    end

    send(fwd, {:xgw, :rtp, peer_a, rtp.(0, 1), %{}})
    send(fwd, {:xgw, :rtp, peer_a, rtp.(1, 2), %{}})
    send(fwd, {:xgw, :rtp, peer_a, rtp.(2, 3), %{}})
    send(fwd, {:xgw, :rtp, peer_a, rtp.(0, 4), %{}})

    outs =
      Enum.reduce_while(1..50, [], fn _, acc ->
        case FakePeer.drain(peer_b) do
          [] when length(acc) >= 2 ->
            {:halt, Enum.reverse(acc)}

          [] ->
            Process.sleep(10)
            {:cont, acc}

          items ->
            {:cont, Enum.reverse(items) ++ acc}
        end
      end)

    assert length(outs) == 2
    [{:send_rtp, out_ssrc, %Rtp{sequence_number: s1}}, {:send_rtp, out2, %Rtp{sequence_number: s2}}] =
      outs

    assert out2 == out_ssrc
    assert s2 == s1 + 1
  end

  test "temporal-only set_substream does not send PLI; spatial still does" do
    assert {:ok, session} = Session.create("t1", "sfu-tid-pli", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 100,
               codec: "VP8",
               layers: [
                 %{ssrc: 100, substream: 0},
                 %{ssrc: 200, substream: 1}
               ]
             })

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "b", "a", "1",
               forwarder: fwd,
               substream: 0
             )

    _ = FakePeer.drain(peer_a)

    assert :ok =
             Xylon.Conference.set_substream(plan_ref, "b", "a", "1",
               forwarder: fwd,
               temporal: 1
             )

    assert [] = FakePeer.drain(peer_a)

    assert :ok =
             Xylon.Conference.set_substream(plan_ref, "b", "a", "1",
               forwarder: fwd,
               substream: 1
             )

    expected = %XMediaLib.Rtcp{payloads: [%XMediaLib.Rtcp.Pli{ssrc_s: 1, ssrc_m: 200}]}
    assert [{:send_rtcp, ^expected}] = FakePeer.drain(peer_a)
  end

  test "H264 temporal opt is ignored (all packets forward)" do
    assert {:ok, session} = Session.create("t1", "sfu-h264-t", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 55,
               codec: "H264"
             })

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "b", "a", "1",
               forwarder: fwd,
               temporal: 0
             )

    _ = FakePeer.drain(peer_a)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 55,
      csrcs: [],
      extension: nil,
      payload: vp8_tid_payload(2)
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})
    assert_receive_forwarded(peer_b, 55)
  end

  defp vp9_pd_payload(spatial, temporal) do
    <<0::1, 0::1, 1::1, 0::1, 0::1, 0::1, 0::1, 0::1, temporal::3, 0::1, spatial::3, 0::1, 0x00>>
  end

  test "VP9 SVC PD filters spatial/temporal; contiguous out seq" do
    assert {:ok, session} = Session.create("t1", "sfu-vp9", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 9001,
               codec: "VP9"
             })

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "b", "a", "1",
               forwarder: fwd,
               spatial_layer: 0,
               temporal_layer: 0
             )

    _ = FakePeer.drain(peer_a)

    rtp = fn s, t, seq ->
      %Rtp{
        padding: 0,
        marker: 0,
        payload_type: 96,
        sequence_number: seq,
        timestamp: 0,
        ssrc: 9001,
        csrcs: [],
        extension: nil,
        payload: vp9_pd_payload(s, t)
      }
    end

    send(fwd, {:xgw, :rtp, peer_a, rtp.(0, 0, 1), %{}})
    send(fwd, {:xgw, :rtp, peer_a, rtp.(1, 0, 2), %{}})
    send(fwd, {:xgw, :rtp, peer_a, rtp.(0, 1, 3), %{}})
    send(fwd, {:xgw, :rtp, peer_a, rtp.(0, 0, 4), %{}})

    outs =
      Enum.reduce_while(1..50, [], fn _, acc ->
        case FakePeer.drain(peer_b) do
          [] when length(acc) >= 2 ->
            {:halt, Enum.reverse(acc)}

          [] ->
            Process.sleep(10)
            {:cont, acc}

          items ->
            {:cont, Enum.reverse(items) ++ acc}
        end
      end)

    assert length(outs) == 2

    [
      {:send_rtp, out_ssrc, %Rtp{sequence_number: s1}},
      {:send_rtp, out2, %Rtp{sequence_number: s2}}
    ] = outs

    assert out2 == out_ssrc
    assert s2 == s1 + 1
  end

  test "VP9 temporal_layer-only set_substream no PLI; spatial_layer sends PLI" do
    assert {:ok, session} = Session.create("t1", "sfu-vp9-pli", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 44,
               codec: "VP9"
             })

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "b", "a", "1",
               forwarder: fwd,
               spatial_layer: 0,
               temporal_layer: 0
             )

    _ = FakePeer.drain(peer_a)

    assert :ok =
             Xylon.Conference.set_substream(plan_ref, "b", "a", "1",
               forwarder: fwd,
               temporal_layer: 2
             )

    assert [] = FakePeer.drain(peer_a)

    assert :ok =
             Xylon.Conference.set_substream(plan_ref, "b", "a", "1",
               forwarder: fwd,
               spatial_layer: 1
             )

    expected = %XMediaLib.Rtcp{payloads: [%XMediaLib.Rtcp.Pli{ssrc_s: 1, ssrc_m: 44}]}
    assert [{:send_rtcp, ^expected}] = FakePeer.drain(peer_a)
  end

  test "VP9 SIM layers still use substream; PD filter does not run" do
    assert {:ok, session} = Session.create("t1", "sfu-vp9-sim", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 100,
               codec: "VP9",
               layers: [
                 %{ssrc: 100, substream: 0},
                 %{ssrc: 200, substream: 1}
               ]
             })

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "b", "a", "1",
               forwarder: fwd,
               substream: 0,
               spatial_layer: 0,
               temporal_layer: 0
             )

    _ = FakePeer.drain(peer_a)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 100,
      csrcs: [],
      extension: nil,
      payload: vp9_pd_payload(2, 2)
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})
    assert_receive_forwarded(peer_b, 100)

    send(fwd, {:xgw, :rtp, peer_a, %{rtp | ssrc: 200, sequence_number: 2}, %{}})
    Process.sleep(30)
    assert [] = FakePeer.drain(peer_b)
  end

  test "VP9 prefers compact DD layers over PD" do
    assert {:ok, session} = Session.create("t1", "sfu-vp9-dd", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 77,
               codec: "VP9"
             })

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "b", "a", "1",
               forwarder: fwd,
               spatial_layer: 0,
               temporal_layer: 0
             )

    _ = FakePeer.drain(peer_a)
    _ = Xylon.Conference.Runtime.put_ext(plan_ref, "a", %{dependency_descriptor: 5})

    dd_payload =
      XMediaLib.Rtp.HeaderExtension.encode_one_byte_elements([{5, <<0xFE, 0b000_000_00>>}])

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 77,
      csrcs: [],
      extension: %XMediaLib.Rtp.Extension{type: 0xBEDE, payload: dd_payload},
      payload: vp9_pd_payload(2, 2)
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})
    assert_receive_forwarded(peer_b, 77)
  end

  test "AV1 SVC DD filters spatial; contiguous out seq; ADT rewritten" do
    assert {:ok, session} = Session.create("t1", "sfu-av1", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 8001,
               codec: "AV1"
             })

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "b", "a", "1",
               forwarder: fwd,
               spatial_layer: 0,
               temporal_layer: 0
             )

    _ = FakePeer.drain(peer_a)
    _ = Xylon.Conference.Runtime.put_ext(plan_ref, "a", %{dependency_descriptor: 5})

    send(fwd, {:xgw, :rtp, peer_a, av1_dd_rtp(8001, 1, spatial: 0, temporal: 0), %{}})
    send(fwd, {:xgw, :rtp, peer_a, av1_dd_rtp(8001, 2, spatial: 1, temporal: 0), %{}})
    send(fwd, {:xgw, :rtp, peer_a, av1_dd_rtp(8001, 3, spatial: 0, temporal: 1), %{}})
    send(fwd, {:xgw, :rtp, peer_a, av1_dd_rtp(8001, 4, spatial: 0, temporal: 0), %{}})

    outs = drain_send_rtp(peer_b, 2)
    assert length(outs) == 2

    [
      {:send_rtp, out_ssrc, %Rtp{sequence_number: s1} = p1},
      {:send_rtp, out2, %Rtp{sequence_number: s2}}
    ] = outs

    assert out2 == out_ssrc
    assert s2 == s1 + 1

    assert {:ok, desc} = XMediaLib.Rtp.DependencyDescriptor.read_descriptor(p1, 5)
    assert desc.active_decode_targets == 0b0001
  end

  test "AV1 Chrome DD structure cache filters and rewrites ADT" do
    assert {:ok, session} = Session.create("t1", "sfu-av1-chrome", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 8011,
               codec: "AV1"
             })

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "b", "a", "1",
               forwarder: fwd,
               spatial_layer: 0,
               temporal_layer: 0
             )

    _ = FakePeer.drain(peer_a)
    _ = Xylon.Conference.Runtime.put_ext(plan_ref, "a", %{dependency_descriptor: 5})

    structure = XMediaLib.Rtp.DependencyDescriptor.chrome_l1t2_structure(0)

    send(
      fwd,
      {:xgw, :rtp, peer_a, av1_chrome_rtp(8011, 1, structure, spatial: 0, temporal: 0, attach?: true),
       %{}}
    )

    send(
      fwd,
      {:xgw, :rtp, peer_a,
       av1_chrome_rtp(8011, 2, structure, spatial: 0, temporal: 1, attach?: false), %{}}
    )

    send(
      fwd,
      {:xgw, :rtp, peer_a,
       av1_chrome_rtp(8011, 3, structure, spatial: 0, temporal: 0, attach?: false), %{}}
    )

    outs = drain_send_rtp(peer_b, 2)
    assert length(outs) == 2

    [{:send_rtp, _, %Rtp{} = p1}, {:send_rtp, _, %Rtp{}}] = outs
    cached = Plan.get_dd_structure(plan_ref, "a", "1")
    assert is_map(cached)

    assert {:ok, desc, _} =
             XMediaLib.Rtp.DependencyDescriptor.read_descriptor(p1, 5, cached)

    assert desc.format == :chrome
    assert desc.active_decode_targets == 0b01
  end

  test "AV1 multi-sub different caps: ADT per route; shared dd_structure is template" do
    assert {:ok, session} = Session.create("t1", "sfu-av1-multi-adt", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()
    assert {:ok, peer_c} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    c = %Participant{id: "c", peer_ref: peer_c}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Plan.put_participant(plan_ref, c)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 8012,
               codec: "AV1"
             })

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "b", "a", "1",
               forwarder: fwd,
               spatial_layer: 0,
               temporal_layer: 0
             )

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "c", "a", "1",
               forwarder: fwd,
               spatial_layer: 0,
               temporal_layer: 1
             )

    _ = FakePeer.drain(peer_a)
    _ = Xylon.Conference.Runtime.put_ext(plan_ref, "a", %{dependency_descriptor: 5})

    structure = XMediaLib.Rtp.DependencyDescriptor.chrome_l1t2_structure(0)

    send(
      fwd,
      {:xgw, :rtp, peer_a,
       av1_chrome_rtp(8012, 1, structure, spatial: 0, temporal: 0, attach?: true), %{}}
    )

    send(
      fwd,
      {:xgw, :rtp, peer_a,
       av1_chrome_rtp(8012, 2, structure, spatial: 0, temporal: 0, attach?: false), %{}}
    )

    outs_b = drain_send_rtp(peer_b, 2)
    outs_c = drain_send_rtp(peer_c, 2)
    assert length(outs_b) == 2
    assert length(outs_c) == 2

    [{:send_rtp, _, %Rtp{} = b1}, _] = outs_b
    [{:send_rtp, _, %Rtp{} = c1}, _] = outs_c

    cached = Plan.get_dd_structure(plan_ref, "a", "1")
    assert is_map(cached)
    assert cached == structure

    assert {:ok, desc_b, _} =
             XMediaLib.Rtp.DependencyDescriptor.read_descriptor(b1, 5, cached)

    assert {:ok, desc_c, _} =
             XMediaLib.Rtp.DependencyDescriptor.read_descriptor(c1, 5, cached)

    assert desc_b.active_decode_targets == 0b01
    assert desc_c.active_decode_targets == 0b11
  end

  test "AV1 broken chain drops enhancement until structure; PLI once" do
    assert {:ok, session} = Session.create("t1", "sfu-av1-chain", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 8002,
               codec: "AV1"
             })

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "b", "a", "1",
               forwarder: fwd,
               spatial_layer: 2,
               temporal_layer: 2
             )

    _ = FakePeer.drain(peer_a)
    _ = Xylon.Conference.Runtime.put_ext(plan_ref, "a", %{dependency_descriptor: 5})

    _ =
      Plan.put_dd_chain(
        plan_ref,
        "a",
        "1",
        "b",
        Xylon.Conference.Av1Svc.break_chain(Xylon.Conference.Av1Svc.new_chain())
      )

    send(fwd, {:xgw, :rtp, peer_a, av1_dd_rtp(8002, 1, spatial: 1, temporal: 0), %{}})
    Process.sleep(30)
    assert [] = FakePeer.drain(peer_b)

    expected = %XMediaLib.Rtcp{payloads: [%XMediaLib.Rtcp.Pli{ssrc_s: 1, ssrc_m: 8002}]}
    assert [{:send_rtcp, ^expected}] = FakePeer.drain(peer_a)

    send(
      fwd,
      {:xgw, :rtp, peer_a, av1_dd_rtp(8002, 2, spatial: 0, temporal: 0, structure?: true), %{}}
    )

    assert_receive_forwarded(peer_b, 8002)

    send(fwd, {:xgw, :rtp, peer_a, av1_dd_rtp(8002, 3, spatial: 1, temporal: 0), %{}})
    assert_receive_forwarded(peer_b, 8002)
  end

  test "AV1 temporal_layer-only set_substream no PLI; spatial_layer sends PLI" do
    assert {:ok, session} = Session.create("t1", "sfu-av1-pli", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 8003,
               codec: "AV1"
             })

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "b", "a", "1",
               forwarder: fwd,
               spatial_layer: 0,
               temporal_layer: 0
             )

    _ = FakePeer.drain(peer_a)

    assert :ok =
             Xylon.Conference.set_substream(plan_ref, "b", "a", "1",
               forwarder: fwd,
               temporal_layer: 2
             )

    assert [] = FakePeer.drain(peer_a)

    assert :ok =
             Xylon.Conference.set_substream(plan_ref, "b", "a", "1",
               forwarder: fwd,
               spatial_layer: 1
             )

    expected = %XMediaLib.Rtcp{payloads: [%XMediaLib.Rtcp.Pli{ssrc_s: 1, ssrc_m: 8003}]}
    assert [{:send_rtcp, ^expected}] = FakePeer.drain(peer_a)
  end

  test "AV1 SIM layers ignore Av1Svc DD filter" do
    assert {:ok, session} = Session.create("t1", "sfu-av1-sim", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 100,
               codec: "AV1",
               layers: [
                 %{ssrc: 100, substream: 0},
                 %{ssrc: 200, substream: 1}
               ]
             })

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "b", "a", "1",
               forwarder: fwd,
               substream: 0,
               spatial_layer: 0,
               temporal_layer: 0
             )

    _ = FakePeer.drain(peer_a)
    _ = Xylon.Conference.Runtime.put_ext(plan_ref, "a", %{dependency_descriptor: 5})

    # High S/T DD would drop on SVC path; SIM must forward selected SSRC
    send(
      fwd,
      {:xgw, :rtp, peer_a, av1_dd_rtp(100, 1, spatial: 2, temporal: 2), %{}}
    )

    assert_receive_forwarded(peer_b, 100)
  end

  defp av1_dd_rtp(ssrc, seq, opts) do
    data =
      XMediaLib.Rtp.DependencyDescriptor.encode_structured_lab(%{
        spatial: Keyword.get(opts, :spatial, 0),
        temporal: Keyword.get(opts, :temporal, 0),
        end_of_frame?: Keyword.get(opts, :end_of_frame?, true),
        frame_number: Keyword.get(opts, :frame_number, seq),
        active_decode_targets: Keyword.get(opts, :active_decode_targets, 0xFF),
        dti_not_present?: Keyword.get(opts, :dti_not_present?, false),
        structure?: Keyword.get(opts, :structure?, false)
      })

    payload = XMediaLib.Rtp.HeaderExtension.encode_one_byte_elements([{5, data}])

    %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: seq,
      timestamp: 0,
      ssrc: ssrc,
      csrcs: [],
      extension: %XMediaLib.Rtp.Extension{type: 0xBEDE, payload: payload},
      payload: <<0>>
    }
  end

  defp av1_chrome_rtp(ssrc, seq, structure, opts) do
    spatial = Keyword.get(opts, :spatial, 0)
    temporal = Keyword.get(opts, :temporal, 0)
    attach? = Keyword.get(opts, :attach?, false)

    {:ok, data} =
      XMediaLib.Rtp.DependencyDescriptor.encode_chrome(
        %{
          start_of_frame?: true,
          end_of_frame?: true,
          frame_number: seq,
          spatial: spatial,
          temporal: temporal,
          active_decode_targets: 0b11,
          attach_structure?: attach?
        },
        structure
      )

    profile = XMediaLib.Rtp.HeaderExtension.profile_for([{5, data}])
    payload = XMediaLib.Rtp.HeaderExtension.encode_elements(profile, [{5, data}])

    %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: seq,
      timestamp: 0,
      ssrc: ssrc,
      csrcs: [],
      extension: %XMediaLib.Rtp.Extension{type: profile, payload: payload},
      payload: <<0>>
    }
  end

  defp drain_send_rtp(peer, min_count) do
    Enum.reduce_while(1..50, [], fn _, acc ->
      case FakePeer.drain(peer) do
        [] when length(acc) >= min_count ->
          {:halt, Enum.reverse(acc)}

        [] ->
          Process.sleep(10)
          {:cont, acc}

        items ->
          rtp_items = Enum.filter(items, &match?({:send_rtp, _, _}, &1))
          {:cont, Enum.reverse(rtp_items) ++ acc}
      end
    end)
  end

  defp assert_receive_forwarded(peer, inbound_ssrc) do
    Enum.reduce_while(1..50, nil, fn _, _ ->
      case FakePeer.drain(peer) do
        [{:send_rtp, out_ssrc, %Rtp{} = out}] ->
          assert out_ssrc != inbound_ssrc
          assert out.ssrc == out_ssrc
          {:halt, :ok}

        [] ->
          Process.sleep(10)
          {:cont, nil}

        other ->
          flunk("unexpected sends: #{inspect(other)}")
      end
    end)
    |> case do
      :ok -> :ok
      _ -> flunk("timed out waiting for forwarded send_rtp")
    end
  end

  test "unbound RID video track learns SSRC on first RTP and forwards" do
    assert {:ok, session} = Session.create("t1", "sfu-rid-learn", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a, role: :publisher}
    b = %Participant{id: "b", peer_ref: peer_b, role: :subscriber}

    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Xylon.Conference.publish(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 0})

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "b", "a", "1", forwarder: fwd)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 3606849621,
      csrcs: [],
      extension: nil,
      payload: "frame"
    }

    send(fwd, {:xgw, :rtp, peer_a, rtp, %{}})
    assert_receive_forwarded(peer_b, 3606849621)
    assert %{ssrc: 3606849621} = Plan.get_track(plan_ref, "a", "1")
  end

  test "RID extension learn maps layers; set_substream rid switches inbound" do
    assert {:ok, session} = Session.create("t1", "sfu-rid-layers", :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a, role: :publisher}
    b = %Participant{id: "b", peer_ref: peer_b, role: :subscriber}

    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 0,
               layers: [
                 %{ssrc: 0, substream: 0, rid: "q"},
                 %{ssrc: 0, substream: 1, rid: "h"}
               ]
             })

    assert :ok =
             Xylon.Conference.subscribe(plan_ref, "b", "a", "1", forwarder: fwd)

    _ = Xylon.Conference.Runtime.put_ext(plan_ref, "a", %{rid: 4})

    q_ext =
      %Rtp.Extension{
        type: HeaderExtension.one_byte_profile(),
        payload: HeaderExtension.encode_one_byte_elements([{4, "q"}])
      }

    h_ext =
      %Rtp.Extension{
        type: HeaderExtension.one_byte_profile(),
        payload: HeaderExtension.encode_one_byte_elements([{4, "h"}])
      }

    send(
      fwd,
      {:xgw, :rtp, peer_a,
       %Rtp{
         padding: 0,
         marker: 0,
         payload_type: 96,
         sequence_number: 1,
         timestamp: 0,
         ssrc: 100,
         csrcs: [],
         extension: q_ext,
         payload: "q"
       }, %{}}
    )

    assert_receive_forwarded(peer_b, 100)

    send(
      fwd,
      {:xgw, :rtp, peer_a,
       %Rtp{
         padding: 0,
         marker: 0,
         payload_type: 96,
         sequence_number: 2,
         timestamp: 3000,
         ssrc: 200,
         csrcs: [],
         extension: h_ext,
         payload: "h"
       }, %{}}
    )

    # Still subscribed to primary (q); h packet should not fan out yet.
    assert [] = FakePeer.drain(peer_b)

    assert :ok =
             Xylon.Conference.set_substream(plan_ref, "b", "a", "1",
               rid: "h",
               forwarder: fwd
             )

    send(
      fwd,
      {:xgw, :rtp, peer_a,
       %Rtp{
         padding: 0,
         marker: 0,
         payload_type: 96,
         sequence_number: 3,
         timestamp: 6000,
         ssrc: 200,
         csrcs: [],
         extension: h_ext,
         payload: "h2"
       }, %{}}
    )

    assert_receive_forwarded(peer_b, 200)
    track = Plan.get_track(plan_ref, "a", "1")
    assert Enum.find(track.layers, &(&1.rid == "h")).ssrc == 200
  end
end