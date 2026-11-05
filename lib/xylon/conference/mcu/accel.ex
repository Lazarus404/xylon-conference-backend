defmodule Xylon.Conference.Mcu.Accel do
  @moduledoc """
  Resolves whether MCU mix NIF acceleration is enabled.

  ## What problem this solves

  Mix ticks can run on a dirty-CPU NIF or on pure Elixir. Operators need a
  node-wide default and a per-room override without forking the Backend.

  Resolution order:

  1. Room `mcu_nif:` opt when boolean
  2. Process env `MCU_ACCEL` when set (`0`/`false`/`off`/`no` -> off;
     `1`/`true`/`on`/`yes` -> on)
  3. Application `:mcu_accel` `:enabled` (default `true`)

  Missing NIF binaries still fall back to Elixir in `Mixer` regardless of
  this flag.

  ## RFCs

  None (process/config only).
  """

  @doc """
  True when mix NIF should be attempted.

  Opts may include `mcu_nif: true | false`. When omitted, uses `MCU_ACCEL`
  then `Application.get_env(:xylon_conference_backend, :mcu_accel, [])`
  `:enabled`, defaulting to `true`.
  """
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) when is_list(opts) do
    case Keyword.fetch(opts, :mcu_nif) do
      {:ok, true} -> true
      {:ok, false} -> false
      :error -> app_enabled?()
      {:ok, _} -> app_enabled?()
    end
  end

  defp app_enabled? do
    case env_override() do
      {:ok, enabled?} -> enabled?
      :none -> config_enabled?()
    end
  end

  defp env_override do
    case System.get_env("MCU_ACCEL") do
      nil ->
        :none

      raw ->
        case String.downcase(String.trim(raw)) do
          v when v in ["0", "false", "off", "no"] -> {:ok, false}
          v when v in ["1", "true", "on", "yes"] -> {:ok, true}
          _ -> :none
        end
    end
  end

  defp config_enabled? do
    case Application.get_env(:xylon_conference_backend, :mcu_accel, []) do
      kw when is_list(kw) -> Keyword.get(kw, :enabled, true) != false
      %{enabled: false} -> false
      %{enabled: _} -> true
      _ -> true
    end
  end
end
