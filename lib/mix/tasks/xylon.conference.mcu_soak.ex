defmodule Mix.Tasks.Xylon.Conference.McuSoak do
  @moduledoc """
  Density microbench for MCU `Mixer.mix_tick/2` (synthetic contributors).

  ## What problem this solves

  Operators need a one-command soak that prints p50/p99 tick duration, overrun
  count vs the 20 ms budget, and encode-group width without standing up a full
  SFU load harness. Exits non-zero when the overrun rate exceeds a threshold.

  ## Usage

      XTURN_LOCAL_DEPS=1 mix xylon.conference.mcu_soak
      XTURN_LOCAL_DEPS=1 mix xylon.conference.mcu_soak --ticks 200 --contributors 8 --nif true

  ## RFCs

  Observability / load only; no wire RFC.
  """
  use Mix.Task

  alias Xylon.Conference.Mcu.{Mixer, Native}

  @shortdoc "MCU mix_tick soak: p50/p99 duration and overrun rate"

  @tick_budget_us 20_000
  @samples 960

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          ticks: :integer,
          contributors: :integer,
          nif: :string,
          max_overrun_rate: :float,
          warmup: :integer
        ]
      )

    if invalid != [] do
      Mix.raise("invalid args: #{inspect(invalid)}")
    end

    ticks = Keyword.get(opts, :ticks, 100)
    n = Keyword.get(opts, :contributors, 8)
    warmup = Keyword.get(opts, :warmup, 5)
    max_rate = Keyword.get(opts, :max_overrun_rate, 0.05)

    nif? =
      case Keyword.get(opts, :nif, "auto") do
        "true" -> true
        "false" -> false
        "auto" -> Native.loaded?()
        other -> Mix.raise("invalid --nif #{inspect(other)} (true|false|auto)")
      end

    Mix.shell().info(
      "mcu_soak ticks=#{ticks} contributors=#{n} nif=#{nif?} loaded=#{Native.loaded?()}"
    )

    cs = contributors(n)
    mix_opts = [samples: @samples, threshold: 25, mcu_nif: nif?]

    for _ <- 1..warmup do
      _ = Mixer.mix_tick(cs, mix_opts)
    end

    durations =
      for _ <- 1..ticks do
        {us, result} = :timer.tc(fn -> Mixer.mix_tick(cs, mix_opts) end)

        case result do
          {:ok, _} -> us
          other -> Mix.raise("mix_tick failed: #{inspect(other)}")
        end
      end

    sorted = Enum.sort(durations)
    p50 = percentile(sorted, 0.50)
    p99 = percentile(sorted, 0.99)
    overruns = Enum.count(durations, &(&1 > @tick_budget_us))
    rate = overruns / max(ticks, 1)

    # One encode group for a single full mix (shared encode width = 1 here).
    encode_groups = 1

    Mix.shell().info("""
    duration_us p50=#{p50} p99=#{p99} max=#{List.last(sorted)}
    overruns=#{overruns}/#{ticks} rate=#{Float.round(rate, 4)} (budget_us=#{@tick_budget_us})
    encode_groups=#{encode_groups}
    """)

    if rate > max_rate do
      Mix.raise(
        "overrun rate #{Float.round(rate, 4)} exceeds max #{max_rate} (use --max-overrun-rate to relax)"
      )
    end

    :ok
  end

  defp contributors(n) when is_integer(n) and n > 0 do
    for i <- 1..n do
      %{id: "c#{i}", pcm: pcm_tone(i * 1000), level: rem(i, 50) + 10}
    end
  end

  defp pcm_tone(amp) do
    for i <- 0..(@samples - 1), into: <<>> do
      s = rem(amp + i, 20_000) - 10_000
      <<s::signed-little-integer-size(16)>>
    end
  end

  defp percentile([], _), do: 0

  defp percentile(sorted, p) when p >= 0 and p <= 1 do
    idx = max(0, min(length(sorted) - 1, round(p * (length(sorted) - 1))))
    Enum.at(sorted, idx)
  end
end
