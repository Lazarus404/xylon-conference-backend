defmodule Xylon.Conference.Mcu.QuotaTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.Mcu.Quota

  setup do
    Quota.reset()
    on_exit(fn -> Quota.reset() end)
    :ok
  end

  test "register_mixer increments totals; unregister restores" do
    pr = make_ref()
    assert :ok = Quota.register_mixer(pr)
    assert Quota.totals() == %{mixers: 1, participants: 0, contributors: 0}
    assert %{participants: 0, contributors: 0} = Quota.mixer(pr)

    assert :ok = Quota.unregister_mixer(pr)
    assert Quota.totals() == %{mixers: 0, participants: 0, contributors: 0}
    assert Quota.mixer(pr) == nil
  end

  test "register_mixer rejects when node max_mixers reached" do
    prev = Application.get_env(:xylon_conference_backend, :mcu_quota)
    Application.put_env(:xylon_conference_backend, :mcu_quota, max_mixers: 1)
    on_exit(fn -> Application.put_env(:xylon_conference_backend, :mcu_quota, prev) end)

    assert :ok = Quota.register_mixer(make_ref())
    assert {:error, :mcu_max_mixers} = Quota.register_mixer(make_ref())
  end

  test "admit_participant respects room and node caps; release restores totals" do
    prev = Application.get_env(:xylon_conference_backend, :mcu_quota)
    Application.put_env(:xylon_conference_backend, :mcu_quota, max_participants: 2)
    on_exit(fn -> Application.put_env(:xylon_conference_backend, :mcu_quota, prev) end)

    pr = make_ref()
    assert :ok = Quota.register_mixer(pr)
    assert :ok = Quota.admit_participant(pr, 1)
    assert {:error, :mcu_max_participants} = Quota.admit_participant(pr, 1)

    assert :ok = Quota.release_participant(pr)
    assert :ok = Quota.admit_participant(pr, 1)

    pr2 = make_ref()
    assert :ok = Quota.register_mixer(pr2)
    assert :ok = Quota.admit_participant(pr2, nil)
    assert {:error, :mcu_max_participants} = Quota.admit_participant(pr2, nil)
  end

  test "admit_contributor is idempotent per id; release and node cap" do
    prev = Application.get_env(:xylon_conference_backend, :mcu_quota)
    Application.put_env(:xylon_conference_backend, :mcu_quota, max_contributors: 1)
    on_exit(fn -> Application.put_env(:xylon_conference_backend, :mcu_quota, prev) end)

    pr = make_ref()
    assert :ok = Quota.register_mixer(pr)
    assert :ok = Quota.admit_contributor(pr, "a", nil)
    assert :ok = Quota.admit_contributor(pr, "a", nil)
    assert Quota.totals().contributors == 1
    assert {:error, :mcu_max_contributors} = Quota.admit_contributor(pr, "b", nil)

    assert :ok = Quota.release_contributor(pr, "a")
    assert Quota.totals().contributors == 0
    assert :ok = Quota.admit_contributor(pr, "b", 1)
  end

  test "unregister_mixer subtracts room participants and contributors from totals" do
    pr = make_ref()
    assert :ok = Quota.register_mixer(pr)
    assert :ok = Quota.admit_participant(pr, nil)
    assert :ok = Quota.admit_contributor(pr, "a", nil)
    assert Quota.totals() == %{mixers: 1, participants: 1, contributors: 1}

    assert :ok = Quota.unregister_mixer(pr)
    assert Quota.totals() == %{mixers: 0, participants: 0, contributors: 0}
  end
end
