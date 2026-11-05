defmodule Xylon.Conference.Mcu.AccelTest do
  use ExUnit.Case, async: false

  alias Xylon.Conference.Mcu.Accel

  setup do
    prev_app = Application.get_env(:xylon_conference_backend, :mcu_accel)
    prev_env = System.get_env("MCU_ACCEL")
    System.delete_env("MCU_ACCEL")

    on_exit(fn ->
      if prev_app == nil do
        Application.delete_env(:xylon_conference_backend, :mcu_accel)
      else
        Application.put_env(:xylon_conference_backend, :mcu_accel, prev_app)
      end

      if prev_env == nil do
        System.delete_env("MCU_ACCEL")
      else
        System.put_env("MCU_ACCEL", prev_env)
      end
    end)

    :ok
  end

  test "defaults to enabled when app env missing" do
    Application.delete_env(:xylon_conference_backend, :mcu_accel)
    assert Accel.enabled?([]) == true
  end

  test "app env enabled: false disables" do
    Application.put_env(:xylon_conference_backend, :mcu_accel, enabled: false)
    assert Accel.enabled?([]) == false
  end

  test "room mcu_nif: false overrides app enabled" do
    Application.put_env(:xylon_conference_backend, :mcu_accel, enabled: true)
    assert Accel.enabled?(mcu_nif: false) == false
  end

  test "room mcu_nif: true overrides app disabled" do
    Application.put_env(:xylon_conference_backend, :mcu_accel, enabled: false)
    assert Accel.enabled?(mcu_nif: true) == true
  end

  test "MCU_ACCEL=0 disables when app would enable" do
    Application.put_env(:xylon_conference_backend, :mcu_accel, enabled: true)
    prev = System.get_env("MCU_ACCEL")

    on_exit(fn ->
      if prev == nil, do: System.delete_env("MCU_ACCEL"), else: System.put_env("MCU_ACCEL", prev)
    end)

    System.put_env("MCU_ACCEL", "0")
    assert Accel.enabled?([]) == false
  end

  test "MCU_ACCEL=1 enables when app disabled" do
    Application.put_env(:xylon_conference_backend, :mcu_accel, enabled: false)
    prev = System.get_env("MCU_ACCEL")

    on_exit(fn ->
      if prev == nil, do: System.delete_env("MCU_ACCEL"), else: System.put_env("MCU_ACCEL", prev)
    end)

    System.put_env("MCU_ACCEL", "1")
    assert Accel.enabled?([]) == true
  end

  test "room mcu_nif: false wins over MCU_ACCEL=1" do
    prev = System.get_env("MCU_ACCEL")

    on_exit(fn ->
      if prev == nil, do: System.delete_env("MCU_ACCEL"), else: System.put_env("MCU_ACCEL", prev)
    end)

    System.put_env("MCU_ACCEL", "1")
    assert Accel.enabled?(mcu_nif: false) == false
  end
end
