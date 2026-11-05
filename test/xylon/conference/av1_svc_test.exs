defmodule Xylon.Conference.Av1SvcTest do
  use ExUnit.Case, async: true

  doctest Xylon.Conference.Av1Svc

  alias Xylon.Conference.Av1Svc
  alias XMediaLib.Rtp
  alias XMediaLib.Rtp.{DependencyDescriptor, HeaderExtension}

  test "svc_mode? requires AV1 without SIM layers" do
    assert Av1Svc.svc_mode?("AV1", nil)
    assert Av1Svc.svc_mode?(%{codec: "AV1"})
    assert Av1Svc.svc_mode?(:AV1, nil)
    refute Av1Svc.svc_mode?(%{codec: "AV1", layers: [%{ssrc: 1, substream: 0}]})
    refute Av1Svc.svc_mode?("VP9", nil)
    refute Av1Svc.svc_mode?("VP8", nil)
  end

  test "drop? filters by max spatial and temporal when DD present" do
    rtp = rtp_dd(spatial: 1, temporal: 2)

    assert Av1Svc.drop?(rtp, 0, 0, codec: "AV1", dd_ext_id: 5) == true
    assert Av1Svc.drop?(rtp, 1, 2, codec: "AV1", dd_ext_id: 5) == false
    assert Av1Svc.drop?(rtp, 1, 1, codec: "AV1", dd_ext_id: 5) == true
  end

  test "drop? and after_decision use pre-parsed :descriptor without re-read" do
    rtp = rtp_dd(spatial: 1, temporal: 2)
    assert {:ok, desc} = DependencyDescriptor.read_descriptor(rtp, 5)

    assert Av1Svc.drop?(rtp, 0, 0, codec: "AV1", dd_ext_id: 5, descriptor: desc) == true
    assert Av1Svc.drop?(rtp, 1, 2, codec: "AV1", dd_ext_id: 5, descriptor: desc) == false

    chain = Av1Svc.new_chain()

    chain2 =
      Av1Svc.after_decision(chain, rtp, 5,
        dropped?: false,
        descriptor: desc
      )

    assert MapSet.member?(chain2.accepted_frames, desc.frame_number)
  end

  test "drop? is false when DD absent (no SVC claim)" do
    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 1,
      csrcs: [],
      extension: nil,
      payload: <<0>>
    }

    assert Av1Svc.drop?(rtp, 0, 0, codec: "AV1", dd_ext_id: 5) == false
  end

  test "drop? ignores SIM AV1" do
    rtp = rtp_dd(spatial: 2, temporal: 2)

    assert Av1Svc.drop?(rtp, 0, 0,
             codec: "AV1",
             layers: [%{ssrc: 1, substream: 0}],
             dd_ext_id: 5
           ) == false
  end

  test "drop? when dti_not_present" do
    rtp = rtp_dd(spatial: 0, temporal: 0, dti_not_present?: true)
    assert Av1Svc.drop?(rtp, 2, 2, codec: "AV1", dd_ext_id: 5) == true
  end

  test "drop? enhancement when chain broken; structure heals" do
    broken = Av1Svc.break_chain(Av1Svc.new_chain())
    enh = rtp_dd(spatial: 1, temporal: 0, structure?: false)
    assert Av1Svc.drop?(enh, 2, 2, codec: "AV1", dd_ext_id: 5, chain: broken) == true

    key = rtp_dd(spatial: 0, temporal: 0, structure?: true)
    assert Av1Svc.drop?(key, 2, 2, codec: "AV1", dd_ext_id: 5, chain: broken) == false
  end

  test "after_decision marks pli on break; heals on structure forward" do
    chain = Av1Svc.new_chain()
    enh = rtp_dd(spatial: 1, temporal: 0)
    # intentional over-cap drop does not break
    chain2 = Av1Svc.after_decision(chain, enh, 5, dropped?: true, max_spatial: 0, max_temporal: 0)
    assert chain2.broken? == false

    # in-cap drop (dti) does not break
    dti = rtp_dd(spatial: 0, temporal: 0, dti_not_present?: true)
    chain3 = Av1Svc.after_decision(chain, dti, 5, dropped?: true, max_spatial: 2, max_temporal: 2)
    assert chain3.broken? == false

    broken = Av1Svc.break_chain(chain)
    key = rtp_dd(spatial: 0, temporal: 0, structure?: true)
    healed = Av1Svc.after_decision(broken, key, 5, dropped?: false, max_spatial: 2, max_temporal: 2)
    assert healed.broken? == false
    assert healed.pli_pending? == false
  end

  test "rewrite_dd clears ADT bits above caps" do
    # targets: bit = spatial * 4 + temporal; S0T0=1, S0T1=2, S1T0=16, ...
    rtp =
      rtp_dd(
        spatial: 0,
        temporal: 0,
        active_decode_targets: 0b1111_1111
      )

    {out, _} = Av1Svc.rewrite_dd(rtp, 0, 0, 5)
    assert {:ok, desc} = DependencyDescriptor.read_descriptor(out, 5)
    # max S0 T0 -> only bit 0
    assert desc.active_decode_targets == 0b0001
  end

  test "Chrome DD drop and ADT rewrite with structure" do
    structure = DependencyDescriptor.chrome_l1t2_structure(0)

    assert {:ok, key_data} =
             DependencyDescriptor.encode_chrome(
               %{
                 start_of_frame?: true,
                 end_of_frame?: true,
                 frame_number: 1,
                 spatial: 0,
                 temporal: 0,
                 active_decode_targets: 0b11,
                 attach_structure?: true
               },
               structure
             )

    key = rtp_raw_dd(key_data)

    assert Av1Svc.drop?(key, 0, 0,
             codec: "AV1",
             dd_ext_id: 5,
             structure: nil
           ) == false

    {out, struct2} = Av1Svc.rewrite_dd(key, 0, 0, 5, structure: nil)
    assert is_map(struct2)
    assert {:ok, desc, _} = DependencyDescriptor.read_descriptor(out, 5, struct2)
    assert desc.active_decode_targets == 0b01
  end

  test "missing fdiff deps break enhancement until structure" do
    structure = DependencyDescriptor.chrome_l1t2_structure(0)

    assert {:ok, key_data} =
             DependencyDescriptor.encode_chrome(
               %{
                 start_of_frame?: true,
                 end_of_frame?: true,
                 frame_number: 10,
                 spatial: 0,
                 temporal: 0,
                 active_decode_targets: 0b11,
                 attach_structure?: true
               },
               structure
             )

    key = rtp_raw_dd(key_data)
    chain = Av1Svc.after_decision(Av1Svc.new_chain(), key, 5, dropped?: false, structure: structure)

    assert {:ok, enh_data} =
             DependencyDescriptor.encode_chrome(
               %{
                 start_of_frame?: true,
                 end_of_frame?: true,
                 frame_number: 12,
                 spatial: 0,
                 temporal: 1,
                 attach_structure?: false,
                 fdiffs: [1]
               },
               structure
             )

    # depends on frame 11 which was never accepted
    enh = rtp_raw_dd(enh_data)

    assert Av1Svc.drop?(enh, 2, 2,
             codec: "AV1",
             dd_ext_id: 5,
             chain: chain,
             structure: structure
           ) == true
  end

  defp rtp_raw_dd(data) when is_binary(data) do
    profile = HeaderExtension.profile_for([{5, data}])
    payload = HeaderExtension.encode_elements(profile, [{5, data}])

    %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 1,
      csrcs: [],
      extension: %Rtp.Extension{type: profile, payload: payload},
      payload: <<0>>
    }
  end

  defp rtp_dd(opts) do
    data =
      DependencyDescriptor.encode_structured_lab(%{
        spatial: Keyword.get(opts, :spatial, 0),
        temporal: Keyword.get(opts, :temporal, 0),
        end_of_frame?: Keyword.get(opts, :end_of_frame?, true),
        frame_number: Keyword.get(opts, :frame_number, 1),
        active_decode_targets: Keyword.get(opts, :active_decode_targets, 0xFF),
        dti_not_present?: Keyword.get(opts, :dti_not_present?, false),
        structure?: Keyword.get(opts, :structure?, false)
      })

    payload = HeaderExtension.encode_one_byte_elements([{5, data}])

    %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 1,
      csrcs: [],
      extension: %Rtp.Extension{type: 0xBEDE, payload: payload},
      payload: <<0>>
    }
  end
end
