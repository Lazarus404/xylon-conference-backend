defmodule Xylon.Conference.RecordingMcuMixTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{Backend, FakePeer, Plan}
  alias Xylon.Conference.Mcu.{Contributor, Egress, Mixer}
  alias Xylon.{Participant, Session}
  alias XMediaLib.{Codec, Rtp}

  setup do
    unless Code.ensure_loaded?(XylonRecord.Handler) do
      flunk("xylon_record not available; set XTURN_LOCAL_DEPS=1")
    end

    dir = Path.join(System.tmp_dir!(), "conf_mcu_mjr_#{System.unique_integer([:positive])}")
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

  defp encode_tone_opus(amp) do
    samples = Mixer.samples_per_tick([])

    pcm =
      for i <- 1..samples, into: <<>> do
        <<rem(i * amp, 2000)::signed-little-integer-size(16)>>
      end

    {:ok, codec} = Codec.start_link({~c"OPUS", 48_000, 1})
    assert {:ok, opus} = Codec.encode(codec, {pcm, 48_000, 1, 16})
    Codec.close(codec)
    opus
  end

  defp rtp(ssrc, seq, opus) do
    %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: seq,
      timestamp: (seq - 1) * 960,
      ssrc: ssrc,
      csrcs: [],
      extension: nil,
      payload: opus
    }
  end

  defp await_stem_files(dir, count) do
    Enum.reduce_while(1..150, nil, fn _, _ ->
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

  defp backend_state(session) do
    :sys.get_state(session).backend_state
  end

  defp put_backend_state(session, state) do
    :sys.replace_state(session, fn s -> %{s | backend_state: state} end)
  end

  @tag :opus
  test "MCU omitted mode: mix stem present and distinct from publisher stems", %{dir: dir} do
    sid = "mcu-mix-#{System.unique_integer([:positive])}"

    assert {:ok, session} =
             Session.create("t1", sid, :conference, audio: :mcu, video: :sfu, mcu_jb_target: 1)

    plan_ref = Session.plan_ref(session)
    assert plan_ref == session

    peer_a = spawn(fn -> Process.sleep(60_000) end)
    peer_b = spawn(fn -> Process.sleep(60_000) end)
    on_exit(fn -> true = Process.exit(peer_a, :kill); true = Process.exit(peer_b, :kill) end)

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    state = backend_state(session)
    assert {:ok, state} = Backend.participant_joined(a, state)
    assert {:ok, state} = Backend.participant_joined(b, state)
    put_backend_state(session, state)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "0",
               kind: :audio,
               ssrc: 1001,
               codec: "opus"
             })

    assert :ok =
             Xylon.Conference.publish(plan_ref, "b", %{
               mid: "0",
               kind: :audio,
               ssrc: 2001,
               codec: "opus"
             })

    assert :ok = Contributor.ensure(plan_ref, "a", opus_desc(), jb_target: 1)
    assert :ok = Contributor.ensure(plan_ref, "b", opus_desc(), jb_target: 1)
    assert :ok = Egress.ensure(plan_ref, "a", opus_desc())
    assert :ok = Egress.ensure(plan_ref, "b", opus_desc())

    assert {:ok, info} = Session.start_recording(session)
    assert info.mode == :tracks_and_mix

    state = backend_state(session)
    opus_a = encode_tone_opus(100)
    opus_b = encode_tone_opus(200)

    # Seed B's PCM so the first tick has a non-silent full mix.
    samples = Mixer.samples_per_tick([])

    tone_b =
      for i <- 1..samples, into: <<>> do
        <<rem(i * 200, 2000)::signed-little-integer-size(16)>>
      end

    contrib_b = Xylon.Conference.Runtime.get_mcu_contrib(plan_ref, "b")
    _ = Xylon.Conference.Runtime.put_mcu_contrib(plan_ref, "b", %{contrib_b | slot: %{pcm: tone_b, level: 10}})

    state =
      Enum.reduce(1..3, state, fn seq, st ->
        case Backend.handle_rtp(a, rtp(1001, seq, opus_a), st) do
          {:forward, _, st2} -> st2
          {:ok, st2} -> st2
        end
      end)

    state =
      case Backend.handle_rtp(b, rtp(2001, 1, opus_b), state) do
        {:forward, _, st2} -> st2
        {:ok, st2} -> st2
      end

    put_backend_state(session, state)

    rec_dir = Path.join(dir, info.recording_id)
    await_stem_files(rec_dir, 2)

    assert {:ok, _} = Session.stop_recording(session)

    files = File.ls!(rec_dir)
    mix = Enum.filter(files, &String.contains?(&1, "__mcu_mix__"))
    pub = Enum.reject(files, &String.contains?(&1, "__mcu_mix__"))
    assert mix != []
    assert pub != []
    assert MapSet.disjoint?(MapSet.new(mix), MapSet.new(pub))
    assert Enum.all?(mix, &String.ends_with?(&1, ".a.mjr"))

    Enum.each(mix, fn name ->
      assert {:ok, map, _} = XylonRecord.Mjr.parse_header(File.read!(Path.join(rec_dir, name)))
      assert map["publisher_id"] == "__mcu_mix__"
    end)

    Enum.each(pub, fn name ->
      assert {:ok, map, _} = XylonRecord.Mjr.parse_header(File.read!(Path.join(rec_dir, name)))
      assert map["publisher_id"] in ["a", "b"]
      refute map["publisher_id"] == "__mcu_mix__"
    end)
  end

  test "SFU omitted mode: no mix stem", %{dir: dir} do
    sid = "sfu-nomix-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Session.create("t1", sid, :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()
    assert :ok = Plan.put_participant(plan_ref, %Participant{id: "a", peer_ref: peer_a})
    assert :ok = Plan.put_participant(plan_ref, %Participant{id: "b", peer_ref: peer_b})

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "0",
               kind: :audio,
               ssrc: 42,
               codec: "opus"
             })

    assert :ok = Xylon.Conference.subscribe(plan_ref, "b", "a", "0", forwarder: fwd)

    assert {:ok, info} = Session.start_recording(session)
    assert info.mode == :tracks

    send(fwd, {:xgw, :rtp, peer_a, rtp(42, 1, <<0, 0>>), %{}})
    rec_dir = Path.join(dir, info.recording_id)
    await_stem_files(rec_dir, 1)
    assert {:ok, _} = Session.stop_recording(session)

    files = File.ls!(rec_dir)
    refute Enum.any?(files, &String.contains?(&1, "__mcu_mix__"))
  end

  @tag :opus
  test "MCU explicit tracks: no mix stem; publisher stem present", %{dir: dir} do
    sid = "mcu-tracks-#{System.unique_integer([:positive])}"

    assert {:ok, session} =
             Session.create("t1", sid, :conference, audio: :mcu, video: :sfu, mcu_jb_target: 1)

    plan_ref = Session.plan_ref(session)

    peer_a = spawn(fn -> Process.sleep(60_000) end)
    peer_b = spawn(fn -> Process.sleep(60_000) end)
    on_exit(fn -> true = Process.exit(peer_a, :kill); true = Process.exit(peer_b, :kill) end)

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    state = backend_state(session)
    assert {:ok, state} = Backend.participant_joined(a, state)
    assert {:ok, state} = Backend.participant_joined(b, state)
    put_backend_state(session, state)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "0",
               kind: :audio,
               ssrc: 1001,
               codec: "opus"
             })

    assert :ok =
             Xylon.Conference.publish(plan_ref, "b", %{
               mid: "0",
               kind: :audio,
               ssrc: 2001,
               codec: "opus"
             })

    assert :ok = Contributor.ensure(plan_ref, "a", opus_desc(), jb_target: 1)
    assert :ok = Contributor.ensure(plan_ref, "b", opus_desc(), jb_target: 1)
    assert :ok = Egress.ensure(plan_ref, "a", opus_desc())
    assert :ok = Egress.ensure(plan_ref, "b", opus_desc())

    assert {:ok, info} = Session.start_recording(session, mode: :tracks)
    assert info.mode == :tracks

    state = backend_state(session)
    opus = encode_tone_opus(100)

    samples = Mixer.samples_per_tick([])

    tone_b =
      for i <- 1..samples, into: <<>> do
        <<rem(i * 150, 2000)::signed-little-integer-size(16)>>
      end

    contrib_b = Xylon.Conference.Runtime.get_mcu_contrib(plan_ref, "b")
    _ = Xylon.Conference.Runtime.put_mcu_contrib(plan_ref, "b", %{contrib_b | slot: %{pcm: tone_b, level: 10}})

    state =
      Enum.reduce(1..3, state, fn seq, st ->
        case Backend.handle_rtp(a, rtp(1001, seq, opus), st) do
          {:forward, _, st2} -> st2
          {:ok, st2} -> st2
        end
      end)

    _ =
      case Backend.handle_rtp(b, rtp(2001, 1, encode_tone_opus(150)), state) do
        {:forward, _, st2} -> st2
        {:ok, st2} -> st2
      end

    rec_dir = Path.join(dir, info.recording_id)
    await_stem_files(rec_dir, 1)
    assert {:ok, _} = Session.stop_recording(session)

    files = File.ls!(rec_dir)
    refute Enum.any?(files, &String.contains?(&1, "__mcu_mix__"))
    assert Enum.any?(files, &String.contains?(&1, "a_0_"))
  end
end
