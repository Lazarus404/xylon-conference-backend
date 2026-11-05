defmodule Xylon.Conference.Mcu.MultiCodecMatrixTest do
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

  defp desc(name, pt, clock, sample) do
    %{
      name: name,
      payload_type: pt,
      clock_rate: clock,
      channels: 1,
      fmtp: nil,
      mixable?: true,
      sample_rate_hz: sample
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

  defp put_slot(plan_ref, id, pcm) do
    _ =
      Runtime.put_mcu_contrib(plan_ref, id, %{
        codec_pid: nil,
        slot: %{pcm: pcm, level: 10}
      })

    :ok
  end

  @tag :opus
  test "four-peer matrix: Opus/PCMU/PCMA/G722 forwards with correct PT and G722 ts", %{
    plan_ref: plan_ref
  } do
    peers = %{
      "opus" => desc("opus", 111, 48_000, 48_000),
      "pcmu" => desc("PCMU", 0, 8000, 8000),
      "pcma" => desc("PCMA", 8, 8000, 8000),
      "g722" => desc("G722", 9, 8000, 16_000)
    }

    Enum.each(peers, fn {id, d} ->
      p = %Participant{id: id, peer_ref: spawn_peer()}
      assert :ok = Plan.put_participant(plan_ref, p)
      assert :ok = Egress.ensure(plan_ref, id, d)
      put_slot(plan_ref, id, tone_pcm(100 + String.length(id)))
    end)

    assert {:ok, specs1, _} = Mcu.tick(plan_ref)
    assert length(specs1) == 4

    by_id = Map.new(specs1, fn {p, rtp} -> {p.id, rtp} end)

    assert by_id["opus"].payload_type == 111
    assert by_id["pcmu"].payload_type == 0
    assert by_id["pcma"].payload_type == 8
    assert by_id["g722"].payload_type == 9

    # distinct codec families => distinct payloads for same exclusion sets differ by encode
    assert by_id["opus"].payload != by_id["pcmu"].payload
    assert by_id["pcmu"].payload != by_id["pcma"].payload

    assert {:ok, specs2, _} = Mcu.tick(plan_ref)
    by_id2 = Map.new(specs2, fn {p, rtp} -> {p.id, rtp} end)

    assert by_id2["g722"].sequence_number == by_id["g722"].sequence_number + 1
    assert by_id2["g722"].timestamp == by_id["g722"].timestamp + 160
    assert by_id2["g722"].ssrc == by_id["g722"].ssrc

    assert by_id2["opus"].timestamp == by_id["opus"].timestamp + 960
    assert by_id2["pcmu"].timestamp == by_id["pcmu"].timestamp + 160
  end
end
