defmodule Xylon.Conference.Mcu.TrunkAttribTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.Mcu.Cascade
  alias Xylon.Conference.{Plan, Runtime}

  setup do
    plan_ref = Plan.new(make_ref())
    Runtime.ensure_table!()

    on_exit(fn ->
      Runtime.clear_plan(plan_ref)
      Plan.delete(plan_ref)
    end)

    %{plan_ref: plan_ref}
  end

  test "trunk_exclude_ids collects contribs attributed to a trunk", %{plan_ref: plan_ref} do
    assert MapSet.size(Cascade.trunk_exclude_ids(plan_ref, "trunk")) == 0

    assert :ok = Runtime.put_mcu_trunk_attrib(plan_ref, "b", "trunk")
    assert :ok = Runtime.put_mcu_trunk_attrib(plan_ref, "c", "trunk")
    assert :ok = Runtime.put_mcu_trunk_attrib(plan_ref, "d", "trunk2")

    assert Cascade.trunk_exclude_ids(plan_ref, "trunk") == MapSet.new(["b", "c"])
    assert Cascade.trunk_exclude_ids(plan_ref, "trunk2") == MapSet.new(["d"])
  end

  test "clear_participant removes trunk attribution", %{plan_ref: plan_ref} do
    assert :ok = Runtime.put_mcu_trunk_attrib(plan_ref, "b", "trunk")
    assert :ok = Runtime.clear_participant(plan_ref, "b")
    assert Cascade.trunk_exclude_ids(plan_ref, "trunk") == MapSet.new()
  end
end
