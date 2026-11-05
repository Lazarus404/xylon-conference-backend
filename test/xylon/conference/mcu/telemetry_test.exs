defmodule Xylon.Conference.Mcu.TelemetryTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.Mcu
  alias Xylon.Conference.Mcu.{Egress, Mixer}
  alias Xylon.Conference.{Plan, Runtime}
  alias Xylon.Participant

  setup do
    plan_ref = Plan.new(make_ref())
    Runtime.ensure_table!()
    on_exit(fn -> Plan.delete(plan_ref) end)
    %{plan_ref: plan_ref}
  end

  defp opus_desc do
    %{
      name: "opus",
      payload_type: 111,
      clock_rate: 48_000,
      channels: 1,
      fmtp: nil,
      mixable?: true,
      sample_rate_hz: 48_000
    }
  end

  defp tone_pcm(amp) do
    samples = Mixer.samples_per_tick([])

    for i <- 1..samples, into: <<>> do
      <<rem(i * amp, 2000)::signed-little-integer-size(16)>>
    end
  end

  defp spawn_peer do
    peer = spawn(fn -> Process.sleep(60_000) end)
    on_exit(fn -> true = Process.exit(peer, :kill) end)
    peer
  end

  @tag :opus
  test "tick emits telemetry with active_contributors", %{plan_ref: plan_ref} do
    parent = self()
    handler_id = {:mcu_telem_tick, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:xylon, :conference, :mcu, :tick],
        fn event, measurements, meta, _ ->
          send(parent, {:telem, event, measurements, meta})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    a = %Participant{id: "a", peer_ref: spawn_peer()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Egress.ensure(plan_ref, "a", opus_desc())

    _ =
      Runtime.put_mcu_contrib(plan_ref, "a", %{
        codec_pid: nil,
        slot: %{pcm: tone_pcm(100), level: 10}
      })

    assert {:ok, [_], _} = Mcu.tick(plan_ref)

    assert_receive {:telem, [:xylon, :conference, :mcu, :tick], measurements, meta}
    assert measurements.active_contributors == 1
    assert is_integer(measurements.duration_us)
    assert measurements.overrun in [0, 1]
    assert meta.plan_ref == plan_ref
  end

  test "encode_groups emits codec_error on bad pcm", %{plan_ref: plan_ref} do
    parent = self()
    handler_id = {:mcu_telem_encode, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:xylon, :conference, :mcu, :codec_error],
        fn event, measurements, meta, _ ->
          send(parent, {:telem, event, measurements, meta})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    gk = {Egress.codec_fp(opus_desc()), :full}
    assert {:error, :bad_pcm} = Egress.encode_groups(plan_ref, [{gk, <<0, 0>>}])

    assert_receive {:telem, [:xylon, :conference, :mcu, :codec_error], %{count: 1}, meta}
    assert meta.op == :encode
    assert meta.reason == :bad_pcm
    assert meta.plan_ref == plan_ref
  end
end
