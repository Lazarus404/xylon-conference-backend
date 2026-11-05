defmodule Xylon.Conference.Mcu.IngressPathTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.{Backend, Plan}
  alias Xylon.Conference.Mcu.{Contributor, Mixer}
  alias Xylon.{Participant, Session}
  alias XMediaLib.{Codec, Rtp}

  setup do
    session = %Session{id: "mcu-ing", tenant_id: "t1"}

    assert {:ok, state} =
             Backend.init(session,
               session_pid: self(),
               audio: :mcu,
               video: :sfu,
               mcu_jb_target: 1
             )

    plan_ref = state.plan_ref
    on_exit(fn -> Plan.delete(plan_ref) end)
    %{state: state, plan_ref: plan_ref}
  end

  defp encode_opus_frame do
    samples = Mixer.samples_per_tick([])
    pcm = :binary.copy(<<0, 0>>, samples)
    {:ok, codec} = Codec.start_link({~c"OPUS", 48_000, 1})
    assert {:ok, opus} = Codec.encode(codec, {pcm, 48_000, 1, 16})
    Codec.close(codec)
    opus
  end

  @tag :opus
  test "MCU audio RTP fills contributor slot; no SFU forward", %{
    state: state,
    plan_ref: plan_ref
  } do
    a = %Participant{id: "a", peer_ref: self()}
    assert {:ok, state} = Backend.participant_joined(a, state)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{mid: "0", kind: :audio, ssrc: 1001})

    desc = %{
      name: "opus",
      payload_type: 111,
      clock_rate: 48_000,
      channels: 1,
      fmtp: nil,
      mixable?: true,
      sample_rate_hz: 48_000
    }

    assert :ok = Contributor.ensure(plan_ref, "a", desc)

    opus = encode_opus_frame()

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 1001,
      csrcs: [],
      extension: nil,
      payload: opus
    }

    assert {:ok, _state} = Backend.handle_rtp(a, rtp, state)
    assert {:ok, %{pcm: pcm}} = Contributor.take_slot(plan_ref, "a")
    assert byte_size(pcm) == Mixer.samples_per_tick([]) * 2
  end

  test "MCU video RTP still SFU-forwards", %{state: state, plan_ref: plan_ref} do
    peer_a = spawn(fn -> Process.sleep(60_000) end)
    peer_b = spawn(fn -> Process.sleep(60_000) end)
    on_exit(fn -> true = Process.exit(peer_a, :kill); true = Process.exit(peer_b, :kill) end)

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}
    assert {:ok, state} = Backend.participant_joined(a, state)
    assert {:ok, state} = Backend.participant_joined(b, state)

    assert :ok =
             Xylon.Conference.publish(plan_ref, "a", %{mid: "1", kind: :video, ssrc: 2002})

    assert :ok = Plan.subscribe(plan_ref, "b", "a", "1")

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 2002,
      csrcs: [],
      extension: nil,
      payload: "v"
    }

    assert {:forward, [{^b, out}], _} = Backend.handle_rtp(a, rtp, state)
    assert out.payload == "v"
    assert out.ssrc != 2002
  end
end
