defmodule Xylon.Conference.Mcu.Native do
  @moduledoc """
  Dirty-CPU NIF entrypoints for MCU mix acceleration.

  ## What problem this solves

  `Mixer.mix_tick/2` is the hottest BEAM path on the audio MCU. This module
  loads `priv/mcu_mix_nif` when built and exposes `mix_tick/2`. Callers must
  check `loaded?/0` (and `Accel.enabled?/1`) before invoking; stubs raise
  `:not_loaded` if the `.so` is absent.

  ## RFCs

  None for native PCM arithmetic.
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    paths =
      case :code.priv_dir(:xylon_conference_backend) do
        {:error, _} ->
          [Path.expand("../../../priv/mcu_mix_nif", __DIR__)]

        dir ->
          [
            Path.join(dir, "mcu_mix_nif"),
            Path.expand("../../../priv/mcu_mix_nif", __DIR__)
          ]
      end

    loaded? =
      Enum.any?(paths, fn path ->
        match?(:ok, :erlang.load_nif(String.to_charlist(path), 0))
      end)

    :persistent_term.put({__MODULE__, :loaded}, loaded?)
    :ok
  end

  @doc "True when `mcu_mix_nif` loaded successfully."
  @spec loaded?() :: boolean()
  def loaded? do
    :persistent_term.get({__MODULE__, :loaded}, false)
  end

  @doc """
  Mixes active PCM frames and builds mix-minus-self for every contributor id.

  `active` is a list of `{id, pcm16le_binary}`. `all_ids` lists every input
  contributor id (including inactive) for minus-self keys. `samples` is the
  frame length in samples.

  Returns `{:ok, {full_pcm, [{id, minus_pcm}, ...]}}` or `{:error, reason}`.
  """
  @spec mix_tick([{term(), binary()}], [term()], pos_integer()) ::
          {:ok, {binary(), [{term(), binary()}]}} | {:error, term()}
  def mix_tick(_active, _all_ids, _samples), do: :erlang.nif_error(:not_loaded)
end
