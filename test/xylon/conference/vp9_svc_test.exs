defmodule Xylon.Conference.Vp9SvcTest do
  use ExUnit.Case, async: true

  doctest Xylon.Conference.Vp9Svc

  alias Xylon.Conference.Vp9Svc
  alias XMediaLib.Rtp
  alias XMediaLib.Rtp.HeaderExtension

  # L=1, no I: first octet 0x20; layer octet tid<<5 | sid<<1
  defp vp9_pd(spatial, temporal, opts \\ []) do
    e = if Keyword.get(opts, :e?, false), do: 1, else: 0
    first = <<0::1, 0::1, 1::1, 0::1, 0::1, e::1, 0::1, 0::1>>
    layer = <<temporal::3, 0::1, spatial::3, 0::1>>
    first <> layer <> <<0x00>>
  end

  test "layers parses spatial and temporal" do
    assert {:ok, %{spatial: 2, temporal: 1, e?: false}} = Vp9Svc.layers(vp9_pd(2, 1))
    assert {:ok, %{spatial: 0, temporal: 0, e?: true}} = Vp9Svc.layers(vp9_pd(0, 0, e?: true))
  end

  test "svc_mode? requires VP9 without SIM layers" do
    assert Vp9Svc.svc_mode?("VP9", nil)
    assert Vp9Svc.svc_mode?(%{codec: "VP9"})
    refute Vp9Svc.svc_mode?(%{codec: "VP9", layers: [%{ssrc: 1, substream: 0}]})
    refute Vp9Svc.svc_mode?("VP8", nil)
  end

  test "drop? filters by max spatial and temporal" do
    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 1,
      csrcs: [],
      extension: nil,
      payload: vp9_pd(1, 2)
    }

    assert Vp9Svc.drop?(rtp, 0, 0, codec: "VP9") == true
    assert Vp9Svc.drop?(rtp, 1, 2, codec: "VP9") == false
    assert Vp9Svc.drop?(rtp, 1, 1, codec: "VP9") == true
    assert Vp9Svc.drop?(rtp, 0, 0, codec: "VP9", layers: [%{ssrc: 1, substream: 0}]) == false
  end

  test "drop? prefers compact DD over PD when ext present" do
    dd_data = <<0xFE, 0b000_000_00>>
    # id=5, len-1=0 for 1-byte data; but dd_data is 2 bytes so len-1=1
    payload = HeaderExtension.encode_one_byte_elements([{5, dd_data}])

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 1,
      csrcs: [],
      extension: %Rtp.Extension{type: 0xBEDE, payload: payload},
      # PD says spatial 2 temporal 2 -- would drop under max 0
      payload: vp9_pd(2, 2)
    }

    # DD says S0 T0 -- forward under max 0
    assert Vp9Svc.drop?(rtp, 0, 0, codec: "VP9", dd_ext_id: 5) == false

    # DD says S1 T0 -- drop under max spatial 0
    dd_hi = HeaderExtension.encode_one_byte_elements([{5, <<0xFE, 0b001_000_00>>}])

    rtp2 = %{
      rtp
      | extension: %Rtp.Extension{type: 0xBEDE, payload: dd_hi}
    }

    assert Vp9Svc.drop?(rtp2, 0, 0, codec: "VP9", dd_ext_id: 5) == true
  end

  test "drop? uses pre-parsed :descriptor spatial/temporal" do
    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 1,
      csrcs: [],
      extension: nil,
      # PD would say S0 T0 -- forward under max 0 without :descriptor
      payload: vp9_pd(0, 0)
    }

    assert Vp9Svc.drop?(rtp, 0, 0,
             codec: "VP9",
             descriptor: %{spatial: 1, temporal: 0}
           ) == true

    assert Vp9Svc.drop?(rtp, 0, 0,
             codec: "VP9",
             descriptor: %{spatial: 0, temporal: 0}
           ) == false
  end
end
