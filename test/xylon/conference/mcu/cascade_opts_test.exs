defmodule Xylon.Conference.Mcu.CascadeOptsTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.Backend
  alias Xylon.Conference.Mcu.Quota
  alias Xylon.Session

  setup do
    Quota.reset()
    on_exit(fn -> Quota.reset() end)
    :ok
  end

  test "hub requires audio mcu; spoke allows sfu or mcu" do
    session = %Session{id: "c1", tenant_id: "t1"}

    assert {:ok, state} =
             Backend.init(session,
               session_pid: make_ref(),
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :hub
             )

    assert state.mcu_cascade == :hub
    assert state.mcu_mix_mid == "0"

    assert {:error, :invalid_mcu_cascade} =
             Backend.init(session,
               session_pid: make_ref(),
               audio: :sfu,
               video: :sfu,
               mcu_cascade: :hub
             )

    assert {:ok, spoke} =
             Backend.init(session,
               session_pid: make_ref(),
               audio: :sfu,
               video: :sfu,
               mcu_cascade: :spoke
             )

    assert spoke.mcu_cascade == :spoke

    assert {:ok, spoke_mcu} =
             Backend.init(session,
               session_pid: make_ref(),
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :spoke
             )

    assert spoke_mcu.mcu_cascade == :spoke
    assert spoke_mcu.audio == :mcu
  end

  test "nil cascade is single-node default" do
    session = %Session{id: "c2", tenant_id: "t1"}

    assert {:ok, state} =
             Backend.init(session, session_pid: make_ref(), audio: :mcu, video: :sfu)

    assert state.mcu_cascade == nil
  end

  test "mcu_spoke_mix_minus defaults false and accepts true" do
    session = %Session{id: "c3", tenant_id: "t1"}

    assert {:ok, state} =
             Backend.init(session,
               session_pid: make_ref(),
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :hub
             )

    assert state.mcu_spoke_mix_minus == false

    assert {:ok, on} =
             Backend.init(session,
               session_pid: make_ref(),
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :hub,
               mcu_spoke_mix_minus: true
             )

    assert on.mcu_spoke_mix_minus == true

    assert {:error, {:invalid_mcu_spoke_mix_minus, :maybe}} =
             Backend.init(session,
               session_pid: make_ref(),
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :hub,
               mcu_spoke_mix_minus: :maybe
             )
  end

  test "mcu_cascade_trunk_profile defaults opus and accepts pcm" do
    session = %Session{id: "c4", tenant_id: "t1"}

    assert {:ok, state} =
             Backend.init(session,
               session_pid: make_ref(),
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :hub
             )

    assert state.mcu_cascade_trunk_profile == :opus

    assert {:ok, pcm} =
             Backend.init(session,
               session_pid: make_ref(),
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :hub,
               mcu_cascade_trunk_profile: :pcm
             )

    assert pcm.mcu_cascade_trunk_profile == :pcm

    assert {:ok, spoke_pcm} =
             Backend.init(session,
               session_pid: make_ref(),
               audio: :sfu,
               video: :sfu,
               mcu_cascade: :spoke,
               mcu_cascade_trunk_profile: :pcm
             )

    assert spoke_pcm.mcu_cascade_trunk_profile == :pcm

    assert {:error, {:invalid_mcu_cascade_trunk_profile, :g722}} =
             Backend.init(session,
               session_pid: make_ref(),
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :hub,
               mcu_cascade_trunk_profile: :g722
             )
  end

  test "spoke MCU registers mixer and respects contributor quota" do
    session = %Session{id: "c5", tenant_id: "t1"}

    assert {:ok, state} =
             Backend.init(session,
               session_pid: make_ref(),
               audio: :mcu,
               video: :sfu,
               mcu_cascade: :spoke,
               mcu_max_contributors: 1
             )

    assert Quota.totals().mixers >= 1

    assert :ok =
             Xylon.Conference.Mcu.Cascade.ensure_remote_contributor(
               state.plan_ref,
               Xylon.Conference.Mcu.Cascade.mix_publisher_id(),
               state
             )

    assert {:error, :mcu_max_contributors} =
             Xylon.Conference.Mcu.Cascade.ensure_remote_contributor(state.plan_ref, "extra", state)
  end
end
