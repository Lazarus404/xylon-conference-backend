defmodule Xylon.Conference.Mcu.Telemetry do
  @moduledoc """
  Internal telemetry helper for MCU mix ticks and codec errors.

  ## What problem this solves

  Operators need counters for mix tick duration (overrun vs 20 ms budget),
  active contributors, encode-group width, and decode/encode failures without
  scraping GenServer state. This module wraps `:telemetry.execute/3` under
  `[:xylon, :conference, :mcu, event]`.

  ## Internal

  Not part of the public Session API. Subscribe with `:telemetry.attach/4`.

  ## RFCs

  Observability only; no wire RFC.
  """

  @doc """
  Emits `[:xylon, :conference, :mcu, event]` with `measurements` and `meta`.
  """
  @spec emit(atom(), map(), map()) :: :ok
  def emit(event, measurements \\ %{}, meta \\ %{})
      when is_atom(event) and is_map(measurements) and is_map(meta) do
    :telemetry.execute([:xylon, :conference, :mcu, event], measurements, meta)
    :ok
  end
end
