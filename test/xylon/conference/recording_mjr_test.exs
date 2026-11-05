defmodule Xylon.Conference.RecordingMjrTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{FakePeer, Plan}
  alias Xylon.{Participant, Session}
  alias XylonRecord.Mjr
  alias XMediaLib.Rtp

  setup do
    unless Code.ensure_loaded?(XylonRecord.Handler) do
      flunk("xylon_record not available; set XTURN_LOCAL_DEPS=1")
    end

    dir = Path.join(System.tmp_dir!(), "conf_mjr_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    :ok = Xylon.Recording.Registry.ensure_table!()

    Application.put_env(:xylon, :recording,
      handler: XylonRecord.Handler,
      dir: dir,
      queue_max: 2000
    )

    on_exit(fn ->
      Application.delete_env(:xylon, :recording)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  defp rtp(ssrc, pt, payload) do
    %Rtp{
      padding: 0,
      marker: 0,
      payload_type: pt,
      sequence_number: 1,
      timestamp: 0,
      ssrc: ssrc,
      csrcs: [],
      extension: nil,
      payload: payload
    }
  end

  # VP8 keyframe so Writer Phase 5 gate accepts video.
  defp vp8_key(ssrc), do: rtp(ssrc, 96, <<0x10, 0x00, 0x01>>)

  test "two publishers: separate audio/video .mjr per publisher track", %{dir: dir} do
    sid = "mjr-2p-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Session.create("t1", sid, :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()
    assert {:ok, peer_c} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a, role: :publisher}
    b = %Participant{id: "b", peer_ref: peer_b, role: :publisher}
    c = %Participant{id: "c", peer_ref: peer_c, role: :subscriber}

    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)
    assert :ok = Plan.put_participant(plan_ref, c)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "0",
               kind: :audio,
               ssrc: 1001,
               codec: "opus"
             })

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 1002,
               codec: "vp8"
             })

    assert :ok =
             Xylon.Conference.publish(plan_ref, "b", %{
               mid: "0",
               kind: :audio,
               ssrc: 2001,
               codec: "opus"
             })

    assert :ok =
             Xylon.Conference.publish(plan_ref, "b", %{
               mid: "1",
               kind: :video,
               ssrc: 2002,
               codec: "vp8"
             })

    assert :ok = Xylon.Conference.subscribe(plan_ref, "c", "a", "0", forwarder: fwd)
    assert :ok = Xylon.Conference.subscribe(plan_ref, "c", "a", "1", forwarder: fwd)
    assert :ok = Xylon.Conference.subscribe(plan_ref, "c", "b", "0", forwarder: fwd)
    assert :ok = Xylon.Conference.subscribe(plan_ref, "c", "b", "1", forwarder: fwd)

    assert {:ok, info} = Session.start_recording(session)

    send(fwd, {:xgw, :rtp, peer_a, rtp(1001, 111, "a0"), %{}})
    send(fwd, {:xgw, :rtp, peer_a, vp8_key(1002), %{}})
    send(fwd, {:xgw, :rtp, peer_b, rtp(2001, 111, "b0"), %{}})
    send(fwd, {:xgw, :rtp, peer_b, vp8_key(2002), %{}})

    rec_dir = Path.join(dir, info.recording_id)
    await_stem_files(rec_dir, 4)

    assert {:ok, _} = Session.stop_recording(session)

    files = File.ls!(rec_dir)
    assert length(files) == 4
    assert Enum.count(files, &String.ends_with?(&1, ".a.mjr")) == 2
    assert Enum.count(files, &String.ends_with?(&1, ".v.mjr")) == 2

    Enum.each(files, fn name ->
      bin = File.read!(Path.join(rec_dir, name))
      assert {:ok, map, rest} = Mjr.parse_header(bin)
      assert map["recording_id"] == info.recording_id
      assert <<"MEET", _::binary>> = rest
    end)
  end

  test "subscriber count does not multiply stem count", %{dir: dir} do
    sid = "mjr-sub-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Session.create("t1", sid, :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()
    assert {:ok, peer_c} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    c = %Participant{id: "c", peer_ref: peer_c}

    Enum.each([a, b, c], &Plan.put_participant(plan_ref, &1))

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "0",
               kind: :audio,
               ssrc: 42,
               codec: "opus"
             })

    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)
    assert :ok = Xylon.Conference.subscribe(plan_ref, "c", "a", "0", forwarder: fwd)

    assert {:ok, info} = Session.start_recording(session)
    send(fwd, {:xgw, :rtp, peer_a, rtp(42, 111, "hi"), %{}})
    rec_dir = Path.join(dir, info.recording_id)
    await_stem_files(rec_dir, 1)
    assert {:ok, _} = Session.stop_recording(session)

    files = File.ls!(rec_dir)
    assert length(files) == 1
  end

  test "backpressure drops while SFU still forwards", %{dir: dir} do
    Application.put_env(:xylon, :recording,
      handler: XylonRecord.Handler,
      dir: dir,
      queue_max: 2
    )

    sid = "mjr-bp-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Session.create("t1", sid, :conference)
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
               mid: "0",
               kind: :audio,
               ssrc: 7,
               codec: "opus"
             })

    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)

    assert {:ok, _} = Session.start_recording(session)

    {_mod, _ctx, state} = Xylon.Recording.Registry.get(session)
    writer = state.writer
    :sys.suspend(writer)

    Enum.each(1..30, fn seq ->
      packet = %{rtp(7, 111, "x") | sequence_number: seq}
      send(fwd, {:xgw, :rtp, peer_a, packet, %{}})
    end)

    assert_receive_forwarded(peer_b, 7)

    {_mod, _ctx, state2} = Xylon.Recording.Registry.get(session)
    assert state2.dropped_backpressure > 0

    :sys.resume(writer)
    assert {:ok, _} = Session.stop_recording(session)
  end

  test "SIM two SSRCs one mid: one .v.mjr for highest substream", %{dir: dir} do
    sid = "mjr-sim-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Session.create("t1", sid, :conference)
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
               codec: "vp8",
               layers: [
                 %{ssrc: 100, substream: 0, rid: "q"},
                 %{ssrc: 200, substream: 1, rid: "h"}
               ]
             })

    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "1", forwarder: fwd)
    assert {:ok, info} = Session.start_recording(session)

    send(fwd, {:xgw, :rtp, peer_a, vp8_key(100), %{}})
    send(fwd, {:xgw, :rtp, peer_a, vp8_key(200), %{}})

    rec_dir = Path.join(dir, info.recording_id)
    await_stem_files(rec_dir, 1)
    assert {:ok, _} = Session.stop_recording(session)

    files = File.ls!(rec_dir)
    assert length(files) == 1
    assert Enum.any?(files, &String.contains?(&1, "_200.v.mjr"))

    bin = File.read!(Path.join(rec_dir, hd(files)))
    assert {:ok, map, _} = Mjr.parse_header(bin)
    assert map["ssrc"] == 200
    assert map["layer"] == 1
  end

  test "SIM video_layer override archives lower layer only", %{dir: dir} do
    sid = "mjr-sim-ov-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Session.create("t1", sid, :conference)
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
               codec: "vp8",
               layers: [
                 %{ssrc: 100, substream: 0},
                 %{ssrc: 200, substream: 1}
               ]
             })

    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "1", forwarder: fwd)
    assert {:ok, info} = Session.start_recording(session, video_layer: 0)

    send(fwd, {:xgw, :rtp, peer_a, vp8_key(100), %{}})
    send(fwd, {:xgw, :rtp, peer_a, vp8_key(200), %{}})

    rec_dir = Path.join(dir, info.recording_id)
    await_stem_files(rec_dir, 1)
    assert {:ok, _} = Session.stop_recording(session)

    files = File.ls!(rec_dir)
    assert length(files) == 1
    assert Enum.any?(files, &String.contains?(&1, "_100.v.mjr"))
  end

  defp await_stem_files(dir, count) do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      case File.ls(dir) do
        {:ok, files} when length(files) >= count ->
          {:halt, :ok}

        _ ->
          Process.sleep(10)
          {:cont, nil}
      end
    end)
    |> case do
      :ok -> :ok
      _ -> flunk("timed out waiting for #{count} stem files in #{dir}")
    end
  end

  defp assert_receive_forwarded(peer, inbound_ssrc) do
    Enum.reduce_while(1..50, nil, fn _, _ ->
      case FakePeer.drain(peer) do
        [{:send_rtp, out_ssrc, %Rtp{}} | _] ->
          assert out_ssrc != inbound_ssrc
          {:halt, :ok}

        [] ->
          Process.sleep(10)
          {:cont, nil}

        other ->
          # May have multiple; accept any send_rtp
          if Enum.any?(List.wrap(other), &match?({:send_rtp, _, %Rtp{}}, &1)) do
            {:halt, :ok}
          else
            flunk("unexpected: #{inspect(other)}")
          end
      end
    end)
    |> case do
      :ok -> :ok
      _ -> flunk("timed out waiting for forwarded RTP")
    end
  end
end
