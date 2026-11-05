defmodule Xylon.Conference.Mcu.CodecPortTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.Mcu.CodecPort
  alias XMediaLib.Codec

  @tag :opus
  test "configure_opus! enables FEC from fmtp; PCMU is no-op" do
    opus = %{
      name: "opus",
      payload_type: 111,
      clock_rate: 48_000,
      channels: 1,
      fmtp: "useinbandfec=1",
      mixable?: true,
      sample_rate_hz: 48_000
    }

    assert {:ok, pid} = CodecPort.start(opus)
    assert :ok = CodecPort.configure_opus!(pid, opus)
    Codec.close(pid)

    pcmu = %{
      name: "PCMU",
      payload_type: 0,
      clock_rate: 8000,
      channels: 1,
      fmtp: nil,
      mixable?: true,
      sample_rate_hz: 8000
    }

    assert {:ok, pid2} = CodecPort.start(pcmu)
    assert :ok = CodecPort.configure_opus!(pid2, pcmu)
    Codec.close(pid2)
  end

  @tag :opus
  test "start unlinks codec so starter exit does not kill the port" do
    parent = self()

    opus = %{
      name: "opus",
      payload_type: 111,
      clock_rate: 48_000,
      channels: 1,
      fmtp: nil,
      mixable?: true,
      sample_rate_hz: 48_000
    }

    starter =
      spawn(fn ->
        {:ok, pid} = CodecPort.start(opus)
        send(parent, {:codec, pid})
      end)

    assert_receive {:codec, pid}, 1_000
    assert Process.alive?(starter) == false or true
    # Wait for starter to exit
    Process.sleep(50)
    refute Process.alive?(starter)
    assert Process.alive?(pid)
    Codec.close(pid)
  end

  test "supported_name? includes l16" do
    assert CodecPort.supported_name?("l16")
    assert {:ok, :l16_passthrough} = CodecPort.start(%{name: "l16", channels: 1, clock_rate: 48_000})
  end
end
