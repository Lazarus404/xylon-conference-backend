defmodule Xylon.Conference.RecordingLayoutTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{FakePeer, Plan}
  alias Xylon.{Participant, Session}
  alias XMediaLib.Rtp

  setup do
    unless Code.ensure_loaded?(XylonRecord.Handler) do
      flunk("xylon_record not available; set XTURN_LOCAL_DEPS=1")
    end

    dir = Path.join(System.tmp_dir!(), "layout_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    Xylon.Catalogue.reset!()
    assert :ok = Xylon.Conference.attach()
    :ok = Xylon.Recording.Registry.ensure_table!()
    :ok = Xylon.Recording.LayoutSink.ensure_table!()

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

  defp vp8_key(ssrc), do: rtp(ssrc, 96, <<0x10, 0x00, 0x01>>)

  test "layout true yields layout artifact on stop", %{dir: dir} do
    sid = "lay-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Session.create("t1", sid, :conference)
    fwd = Session.forwarder(session)
    plan_ref = Session.plan_ref(session)

    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a, role: :publisher}
    b = %Participant{id: "b", peer_ref: peer_b, role: :publisher}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{
               mid: "1",
               kind: :video,
               ssrc: 1002,
               codec: "vp8"
             })

    assert :ok =
             Xylon.Conference.publish(plan_ref, "b", %{
               mid: "1",
               kind: :video,
               ssrc: 2002,
               codec: "vp8"
             })

    assert {:ok, info} = Session.start_recording(session, %{layout: true})
    assert is_binary(info.recording_id)

    send(fwd, {:xgw, :rtp, peer_a, vp8_key(1002), %{}})
    send(fwd, {:xgw, :rtp, peer_b, vp8_key(2002), %{}})
    # Keepalive / RTP path needs time for the first MP4 fragment when ffmpeg is present.
    Process.sleep(900)

    assert {:ok, _} = Session.stop_recording(session)

    layout_dir = Path.join([dir, info.recording_id, "layout"])
    assert File.dir?(layout_dir)

    dump = Path.join(layout_dir, "layout.rtp")
    assert File.exists?(dump)
    assert File.stat!(dump).size > 0

    if System.find_executable("ffmpeg") do
      mp4 = Path.join(layout_dir, "layout.mp4")
      assert File.exists?(mp4)
      assert File.stat!(mp4).size > 0
    end
  end

  test "rtmp_url delivers bytes to an ffmpeg listen receiver", %{dir: dir} do
    if is_nil(System.find_executable("ffmpeg")) do
      :ok
    else
      {:ok, listen_sock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, rtmp_port} = :inet.port(listen_sock)
      :ok = :gen_tcp.close(listen_sock)

      flv = Path.join(dir, "recv.flv")
      rtmp_url = "rtmp://127.0.0.1:#{rtmp_port}/live/xylon"
      exe = System.find_executable("ffmpeg")

      listener =
        Port.open(
          {:spawn_executable, exe},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [
              "-hide_banner",
              "-loglevel",
              "error",
              "-listen",
              "1",
              "-i",
              rtmp_url,
              "-c",
              "copy",
              "-f",
              "flv",
              flv
            ]
          ]
        )

      on_exit(fn ->
        try do
          Port.close(listener)
        rescue
          _ -> :ok
        end
      end)

      # Give the RTMP listener time to bind.
      Process.sleep(400)

      sid = "rtmp-#{System.unique_integer([:positive])}"
      assert {:ok, session} = Session.create("t1", sid, :conference)
      plan_ref = Session.plan_ref(session)
      assert {:ok, peer} = FakePeer.start_link()

      assert :ok =
               Plan.put_participant(plan_ref, %Participant{
                 id: "a",
                 peer_ref: peer,
                 role: :publisher
               })

      assert :ok =
               Xylon.Conference.publish(plan_ref, "a", %{
                 mid: "1",
                 kind: :video,
                 ssrc: 1002,
                 codec: "vp8"
               })

      assert {:ok, info} =
               Session.start_recording(session, %{layout: true, rtmp_url: rtmp_url})

      send(Session.forwarder(session), {:xgw, :rtp, peer, vp8_key(1002), %{}})
      Process.sleep(1200)
      assert {:ok, _} = Session.stop_recording(session)
      Process.sleep(500)

      dump = Path.join([dir, info.recording_id, "layout", "layout.rtp"])
      assert File.exists?(dump)

      assert File.exists?(flv)
      assert File.stat!(flv).size > 0
    end
  end

  test "layout omitted leaves no layout participant" do
    sid = "nolay-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Session.create("t1", sid, :conference)
    plan_ref = Session.plan_ref(session)
    assert {:ok, _} = Session.start_recording(session)
    assert is_nil(Plan.get_participant(plan_ref, Xylon.Conference.SessionHooks.layout_subscriber_id()))
    assert {:ok, _} = Session.stop_recording(session)
  end

  test "invalid rtmp_url rejected" do
    sid = "bad-rtmp-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Session.create("t1", sid, :conference)

    assert {:error, :invalid_rtmp_url} =
             Session.start_recording(session, %{layout: true, rtmp_url: "http://example.com"})
  end
end
