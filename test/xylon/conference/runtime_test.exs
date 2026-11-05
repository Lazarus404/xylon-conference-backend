defmodule Xylon.Conference.RuntimeTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.Runtime

  setup do
    Runtime.ensure_table!()
    plan_ref = make_ref()
    on_exit(fn -> Runtime.clear_plan(plan_ref) end)
    %{plan_ref: plan_ref}
  end

  test "put_ext / get_ext round-trip and merge", %{plan_ref: plan_ref} do
    assert :ok = Runtime.put_ext(plan_ref, "a", %{twcc: 4})
    assert %{twcc: 4, audio_level: nil, rid: nil} = Runtime.get_ext(plan_ref, "a")

    assert :ok = Runtime.put_ext(plan_ref, "a", %{audio_level: 3})
    assert %{twcc: 4, audio_level: 3} = Runtime.get_ext(plan_ref, "a")

    assert :ok = Runtime.put_ext(plan_ref, "a", %{rid: 7})
    assert %{twcc: 4, audio_level: 3, rid: 7} = Runtime.get_ext(plan_ref, "a")
  end

  test "twcc / audio_level / fir / remb put get", %{plan_ref: plan_ref} do
    twcc = %{arrivals: [{1, 100}], last_ms: 50, fb_count: 2}
    assert :ok = Runtime.put_twcc(plan_ref, "a", twcc)
    assert ^twcc = Runtime.get_twcc(plan_ref, "a")

    det = %{window: [1, 2], talking?: false, avg: 10.0}
    assert :ok = Runtime.put_audio_level(plan_ref, "a", det)
    assert ^det = Runtime.get_audio_level(plan_ref, "a")

    assert :ok = Runtime.put_last_fir(plan_ref, "a", 99)
    assert 99 = Runtime.get_last_fir(plan_ref, "a")

    remb = %{"a" => %{"b" => 100_000}}
    assert :ok = Runtime.put_remb(plan_ref, remb)
    assert ^remb = Runtime.get_remb(plan_ref)
  end

  test "clear_participant removes participant rows and remb edges", %{plan_ref: plan_ref} do
    assert :ok = Runtime.put_ext(plan_ref, "a", %{twcc: 1, audio_level: 2})
    assert :ok = Runtime.put_twcc(plan_ref, "a", %{arrivals: [], last_ms: nil, fb_count: 0})
    assert :ok = Runtime.put_audio_level(plan_ref, "a", %{})
    assert :ok = Runtime.put_last_fir(plan_ref, "a", 1)

    assert :ok =
             Runtime.put_remb(plan_ref, %{
               "a" => %{"b" => 1},
               "c" => %{"a" => 2, "b" => 3}
             })

    assert :ok = Runtime.clear_participant(plan_ref, "a")

    assert is_nil(Runtime.get_ext(plan_ref, "a"))
    assert is_nil(Runtime.get_twcc(plan_ref, "a"))
    assert is_nil(Runtime.get_audio_level(plan_ref, "a"))
    assert is_nil(Runtime.get_last_fir(plan_ref, "a"))
    assert %{"c" => %{"b" => 3}} = Runtime.get_remb(plan_ref)
  end

  test "clear_plan removes all rows for plan_ref", %{plan_ref: plan_ref} do
    other = make_ref()
    on_exit(fn -> Runtime.clear_plan(other) end)

    assert :ok = Runtime.put_ext(plan_ref, "a", %{twcc: 1})
    assert :ok = Runtime.put_ext(other, "a", %{twcc: 9})
    assert :ok = Runtime.clear_plan(plan_ref)

    assert is_nil(Runtime.get_ext(plan_ref, "a"))
    assert %{twcc: 9, audio_level: nil} = Runtime.get_ext(other, "a")
  end
end
