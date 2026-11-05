defmodule Xylon.Conference.Mcu.TickTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.Mcu
  alias Xylon.Conference.Mcu.{Egress, Mixer}
  alias Xylon.Conference.{Plan, Runtime}
  alias Xylon.Participant
  alias XMediaLib.Rtp

  setup do
    plan_ref = Plan.new(make_ref())
    Runtime.ensure_table!()
    on_exit(fn -> Plan.delete(plan_ref) end)
    %{plan_ref: plan_ref}
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

  defp tone_pcm(amp) do
    samples = Mixer.samples_per_tick([])

    for i <- 1..samples, into: <<>> do
      <<rem(i * amp, 2000)::signed-little-integer-size(16)>>
    end
  end

  defp put_slot(plan_ref, id, pcm, level) do
    _ =
      Runtime.put_mcu_contrib(plan_ref, id, %{
        codec_pid: nil,
        slot: %{pcm: pcm, level: level}
      })

    :ok
  end

  defp spawn_peer do
    peer = spawn(fn -> Process.sleep(60_000) end)
    on_exit(fn -> true = Process.exit(peer, :kill) end)
    peer
  end

  @tag :opus
  test "two slots: tick returns two Opus forward packets (minus-self)", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: spawn_peer()}
    b = %Participant{id: "b", peer_ref: spawn_peer()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Plan.put_participant(plan_ref, b)

    assert :ok = Egress.ensure(plan_ref, "a", opus_desc(111))
    assert :ok = Egress.ensure(plan_ref, "b", opus_desc(111))

    put_slot(plan_ref, "a", tone_pcm(100), 10)
    put_slot(plan_ref, "b", tone_pcm(200), 10)

    assert {:ok, specs, mix_rtp} = Mcu.tick(plan_ref)
    assert length(specs) == 2
    assert %Rtp{} = mix_rtp
    assert mix_rtp.payload_type == 111
    assert byte_size(mix_rtp.payload) > 0

    Enum.each(specs, fn {%Participant{} = p, %Rtp{} = rtp} ->
      assert p.id in ["a", "b"]
      assert rtp.payload_type == 111
      assert is_binary(rtp.payload)
      assert byte_size(rtp.payload) > 0
      assert byte_size(rtp.payload) != Mixer.samples_per_tick([]) * 2
    end)

    ids = specs |> Enum.map(fn {p, _} -> p.id end) |> Enum.sort()
    assert ids == ["a", "b"]

    # distinct exclusion sets => distinct payloads
    {_, ra} = Enum.find(specs, fn {p, _} -> p.id == "a" end)
    {_, rb} = Enum.find(specs, fn {p, _} -> p.id == "b" end)
    assert ra.payload != rb.payload
  end

  @tag :opus
  test "two spectators share Opus payload bytes; distinct SSRC/seq", %{plan_ref: plan_ref} do
    talker = %Participant{id: "t", peer_ref: spawn_peer()}
    s1 = %Participant{id: "s1", peer_ref: spawn_peer()}
    s2 = %Participant{id: "s2", peer_ref: spawn_peer()}
    Enum.each([talker, s1, s2], &Plan.put_participant(plan_ref, &1))

    Enum.each(["t", "s1", "s2"], fn id ->
      assert :ok = Egress.ensure(plan_ref, id, opus_desc(111))
    end)

    put_slot(plan_ref, "t", tone_pcm(100), 10)

    assert {:ok, specs, _} = Mcu.tick(plan_ref)
    by_id = Map.new(specs, fn {p, rtp} -> {p.id, rtp} end)

    assert Map.has_key?(by_id, "s1")
    assert Map.has_key?(by_id, "s2")
    assert Map.has_key?(by_id, "t")

    assert by_id["s1"].payload == by_id["s2"].payload
    assert by_id["s1"].ssrc != by_id["s2"].ssrc
    assert by_id["t"].payload != by_id["s1"].payload

    full_gk = {Egress.codec_fp(opus_desc()), :full}
    minus_t = {Egress.codec_fp(opus_desc()), {:minus, "t"}}
    assert Runtime.get_mcu_encode_group(plan_ref, full_gk)
    assert Runtime.get_mcu_encode_group(plan_ref, minus_t)
  end

  @tag :opus
  test "all-zero mix does not forward", %{plan_ref: plan_ref} do
    a = %Participant{id: "a", peer_ref: spawn_peer()}
    assert :ok = Plan.put_participant(plan_ref, a)
    assert :ok = Egress.ensure(plan_ref, "a", opus_desc())

    silence = :binary.copy(<<0, 0>>, Mixer.samples_per_tick([]))
    put_slot(plan_ref, "a", silence, 10)

    assert {:ok, [], _} = Mcu.tick(plan_ref)
  end
end
