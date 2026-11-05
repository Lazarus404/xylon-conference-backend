defmodule Xylon.Conference.Mcu.CodecPort do
  @moduledoc """
  Starts `XMediaLib.Codec` ports for MCU mixable audio codecs.

  ## What problem this solves

  Contributor ingress and egress encode groups must open the right native
  driver (Opus, PCMU, PCMA, G.722) from a `CodecBind` descriptor, or use
  L16 passthrough (raw PCM16LE bus frames as RTP payload). Centralising
  the name -> `Codec.start_link/1` args avoids drift between modules.
  `configure_opus!/2` applies `useinbandfec` from fmtp onto encode ports
  (egress). Ingress gates FEC recovery with `opus_fec?/1` + `decode_fec`.

  **Internal.**

  ## RFCs

  - [RFC 3551](https://www.rfc-editor.org/rfc/rfc3551) (static PTs; G.722 clock; L16)
  - [RFC 6716](https://www.rfc-editor.org/rfc/rfc6716) (Opus)
  """

  alias XMediaLib.Codec

  @bus_rate 48_000

  @doc """
  Starts a codec port for `codec_desc`.

  Returns `{:ok, pid}`, `{:error, :unsupported_codec}`, or start errors.

  The port is unlinked from the caller so a short-lived starter (e.g. `:erpc`)
  exiting does not kill decode/encode ports still referenced from Runtime ETS.
  Callers must still `Codec.close/1` via Contributor/Egress clear paths.
  """
  @spec start(map()) :: {:ok, pid() | :l16_passthrough} | {:error, term()}
  def start(%{} = codec_desc) do
    name = codec_desc |> Map.get(:name) |> to_string() |> String.downcase()

    if name == "l16" do
      {:ok, :l16_passthrough}
    else
      case driver_args(codec_desc) do
        {:ok, args} ->
          case Codec.start_link(args) do
            {:ok, pid} ->
              true = Process.unlink(pid)
              {:ok, pid}

            {:stop, reason} ->
              {:error, reason}

            other ->
              {:error, other}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Applies Opus in-band FEC from `codec_desc.fmtp` when `useinbandfec=1`.

  For **encode** ports (MCU egress): sets `set_inband_fec(true)` and
  `set_packet_loss_perc(20)`. Non-Opus or FEC off is a no-op (`:ok`).
  Returns `{:error, reason}` only when an Opus ctl fails.

  Ingress Contributor ports use `opus_fec?/1` + `Codec.decode_fec/2` instead;
  they do not need this call.
  """
  @spec configure_opus!(pid(), map()) :: :ok | {:error, term()}
  def configure_opus!(pid, %{} = codec_desc) when is_pid(pid) do
    name = codec_desc |> Map.get(:name) |> to_string() |> String.downcase()

    with "opus" <- name,
         %{useinbandfec: true} <- Codec.OpusFmtp.parse(Map.get(codec_desc, :fmtp)),
         :ok <- Codec.set_inband_fec(pid, true),
         :ok <- Codec.set_packet_loss_perc(pid, 20) do
      :ok
    else
      {:error, _} = err -> err
      _ -> :ok
    end
  end

  @doc """
  True when `codec_desc` Opus fmtp requests in-band FEC.
  """
  @spec opus_fec?(map()) :: boolean()
  def opus_fec?(%{} = codec_desc) do
    name = codec_desc |> Map.get(:name) |> to_string() |> String.downcase()

    name == "opus" and
      Codec.OpusFmtp.parse(Map.get(codec_desc, :fmtp)).useinbandfec
  end

  @doc """
  Builds `{charlist_name, sample_rate, channels}` for `Codec.start_link/1`.
  """
  @spec driver_args(map()) :: {:ok, {charlist(), pos_integer(), pos_integer()}} | {:error, term()}
  def driver_args(%{} = codec_desc) do
    name = codec_desc |> Map.fetch!(:name) |> to_string() |> String.downcase()
    channels = Map.get(codec_desc, :channels, 1)
    channels = if is_integer(channels) and channels > 0, do: channels, else: 1
    sample = Map.get(codec_desc, :sample_rate_hz) || Map.get(codec_desc, :clock_rate)

    case name do
      "opus" ->
        rate = if is_integer(sample) and sample > 0, do: sample, else: @bus_rate
        {:ok, {~c"OPUS", rate, channels}}

      "pcmu" ->
        {:ok, {~c"PCMU", 8000, 1}}

      "pcma" ->
        {:ok, {~c"PCMA", 8000, 1}}

      "g722" ->
        rate = if is_integer(sample) and sample > 0, do: sample, else: 16_000
        {:ok, {~c"G722", rate, 1}}

      _ ->
        {:error, :unsupported_codec}
    end
  end

  @doc """
  Fingerprint used to detect renegotiation codec changes.
  """
  @spec fingerprint(map()) :: {binary(), term(), term(), term(), term()}
  def fingerprint(%{} = codec_desc) do
    name = codec_desc |> Map.fetch!(:name) |> to_string() |> String.downcase()

    {name, Map.get(codec_desc, :payload_type), Map.get(codec_desc, :sample_rate_hz),
     Map.get(codec_desc, :channels), Map.get(codec_desc, :fmtp)}
  end

  @doc "True when `name` is a supported MCU mix codec."
  @spec supported_name?(binary() | atom()) :: boolean()
  def supported_name?(name) do
    case String.downcase(to_string(name)) do
      n when n in ["opus", "pcmu", "pcma", "g722", "l16"] -> true
      _ -> false
    end
  end
end
