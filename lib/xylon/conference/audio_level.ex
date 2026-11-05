defmodule Xylon.Conference.AudioLevel do
  @moduledoc """
  Sliding-window talking detector from RFC 6464 audio levels.

  ## What problem this solves

  Conference UIs often highlight who is speaking. Browsers can attach an optional
  RTP header extension that carries a rough loudness value for each audio packet
  (RFC 6464). This module turns those samples into stable "talking" /
  "stopped-talking" edges using a sliding window, aligned with Janus-style
  thresholds.

  Lower level values mean louder audio (0 = loudest, 127 = quietest). Talking
  starts when the average of the last `audio_active_packets` samples is at or
  below `audio_level_average`. Events emit only on transitions, not every packet.

  **Internal:** used by `Xylon.Conference.Backend` when `audiolevel_events` is
  enabled. Apps receive edges via Control Presence (`talking` / `stopped-talking`).

  ## RFCs

  - [RFC 6464](https://www.rfc-editor.org/rfc/rfc6464) (RTP header extension for audio level)
  - [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) (RTP; extension rides on RTP packets)
  """

  @typedoc """
  Detector state for one participant.

  ## Fields

  - `:levels` -- most recent RFC 6464 level samples (newest first), capped by window size
  - `:talking?` -- whether the detector currently considers the participant talking
  - `:avg` -- average of samples in the window, or `nil` before any sample
  """
  @type t :: %{
          levels: [non_neg_integer()],
          talking?: boolean(),
          avg: float() | nil
        }

  @doc """
  Returns empty detector state.

  ## Examples

      iex> Xylon.Conference.AudioLevel.new()
      %{levels: [], talking?: false, avg: nil}
  """
  @spec new() :: t()
  def new, do: %{levels: [], talking?: false, avg: nil}

  @doc """
  Feeds one RFC 6464 level sample and returns updated state plus an edge event.

  Required options:

  - `:audio_active_packets` -- sliding window size (must be filled before talking can start)
  - `:audio_level_average` -- threshold in 0..127; talking when window average `<=` threshold

  Returns `{state, event}` where `event` is `:talking`, `:stopped_talking`, or `:noop`.

  ## Examples

      iex> opts = [audio_active_packets: 3, audio_level_average: 25]
      iex> state = Xylon.Conference.AudioLevel.new()
      iex> {state, :noop} = Xylon.Conference.AudioLevel.sample(state, 10, opts)
      iex> {state, :noop} = Xylon.Conference.AudioLevel.sample(state, 10, opts)
      iex> {_state, :talking} = Xylon.Conference.AudioLevel.sample(state, 10, opts)
      ...> :ok
      :ok

      iex> opts = [audio_active_packets: 3, audio_level_average: 25]
      iex> state = Xylon.Conference.AudioLevel.new()
      iex> {state, :noop} = Xylon.Conference.AudioLevel.sample(state, 80, opts)
      iex> {state, :noop} = Xylon.Conference.AudioLevel.sample(state, 80, opts)
      iex> {_state, :noop} = Xylon.Conference.AudioLevel.sample(state, 80, opts)
      ...> :ok
      :ok
  """
  @spec sample(t(), 0..127, keyword()) :: {t(), :talking | :stopped_talking | :noop}
  def sample(%{levels: levels, talking?: talking?} = state, level, opts)
      when is_integer(level) and level >= 0 and level <= 127 and is_list(opts) do
    n = Keyword.fetch!(opts, :audio_active_packets)
    threshold = Keyword.fetch!(opts, :audio_level_average)

    levels = Enum.take([level | levels], n)
    avg = Enum.sum(levels) / length(levels)
    now_talking? = length(levels) >= n and avg <= threshold

    event =
      cond do
        now_talking? and not talking? -> :talking
        not now_talking? and talking? -> :stopped_talking
        true -> :noop
      end

    {%{state | levels: levels, talking?: now_talking?, avg: avg}, event}
  end
end
