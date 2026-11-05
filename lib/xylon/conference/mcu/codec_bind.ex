defmodule Xylon.Conference.Mcu.CodecBind do
  @moduledoc """
  Binds MCU send/recv codecs and mix mid from offer (and optional answer) SDP.

  ## What problem this solves

  Before the MCU can decode a contributor or encode a mix for a listener, it must
  know payload type, clock, channels, fmtp, and whether the format is mixable
  (Opus/G.711/G.722) or not (`telephone-event`, comfort noise). This module
  extracts that binding from SDP text with no network or Session involvement.

  **Mix mid model (sendrecv):** the client's audio m-section mid is both the
  contributor ingress mid and the mix egress mid (`mix_mid == mid`). Phase 2
  does not invent a second synthetic mix mid.

  ## RFCs

  - [RFC 3264](https://www.rfc-editor.org/rfc/rfc3264) (SDP offer/answer)
  - [RFC 3551](https://www.rfc-editor.org/rfc/rfc3551) (static payload types; G.722 RTP clock)
  - [RFC 4733](https://www.rfc-editor.org/rfc/rfc4733) (telephone-event -- not mixable)
  - [RFC 6716](https://www.rfc-editor.org/rfc/rfc6716) (Opus)
  - [RFC 8866](https://www.rfc-editor.org/rfc/rfc8866) (SDP)
  """

  alias XMediaLib.SDP
  alias XMediaLib.SDP.{Codec, Fmtp, Media}

  @typedoc """
  One negotiated audio codec for MCU decode or encode.

  ## Fields

  - `:name` -- codec name (e.g. `"opus"`, `"PCMU"`, `"G722"`)
  - `:payload_type` -- RTP payload type
  - `:clock_rate` -- RTP timestamp clock in Hz (G.722 is 8000 on the wire)
  - `:channels` -- channel count when known (default 1 for mono telephony)
  - `:fmtp` -- raw `a=fmtp` parameter string, or `nil`
  - `:mixable?` -- `false` for telephone-event / CN; `true` for PCM mix codecs
  - `:sample_rate_hz` -- PCM sample rate for decode/encode (G.722 is 16000)
  """
  @type codec_desc :: %{
          name: binary(),
          payload_type: non_neg_integer(),
          clock_rate: pos_integer(),
          channels: pos_integer(),
          fmtp: binary() | nil,
          mixable?: boolean(),
          sample_rate_hz: pos_integer()
        }

  @typedoc """
  Per-audio-mid MCU bind for one participant offer (optional answer).

  ## Fields

  - `:mid` -- SDP media id for the audio m-section
  - `:kind` -- always `:audio`
  - `:send` -- codec the client sends (MCU decode path)
  - `:recv` -- codec the client receives for the mix (MCU encode path)
  - `:mix_mid` -- egress mid for the mix; equals `:mid` under sendrecv model
  - `:non_mixable_pts` -- CN / telephone-event PTs on the **offer** mid (ingress ignore)
  - `:cn_payload_type` -- comfort-noise PT for egress; answer mid wins, else offer
  """
  @type audio_bind :: %{
          mid: binary(),
          kind: :audio,
          send: codec_desc(),
          recv: codec_desc(),
          mix_mid: binary(),
          non_mixable_pts: [non_neg_integer()],
          cn_payload_type: non_neg_integer() | nil
        }

  @doc """
  Extracts audio MCU bindings from an offer SDP.

  Opts:

  - `:answer` -- optional answer SDP binary; when set, `:recv` is the first
    mixable codec on the matching answer audio mid (send still from offer)

  Returns `{:ok, [audio_bind()]}` or `{:error, reason}`. An audio m-section with
  only non-mixable codecs (e.g. telephone-event) yields
  `{:error, {:no_mixable_audio_codec, mid}}`.

  ## Examples

      iex> offer = \"\"\"
      ...> v=0
      ...> o=- 0 0 IN IP4 127.0.0.1
      ...> s=-
      ...> t=0 0
      ...> m=audio 9 UDP/TLS/RTP/SAVPF 111
      ...> a=mid:0
      ...> a=rtpmap:111 opus/48000/2
      ...> \"\"\"
      iex> {:ok, [bind]} = Xylon.Conference.Mcu.CodecBind.from_sdp(offer)
      iex> {bind.mid, bind.mix_mid, bind.send.name, bind.send.payload_type}
      {"0", "0", "opus", 111}
  """
  @spec from_sdp(binary(), keyword()) :: {:ok, [audio_bind()]} | {:error, term()}
  def from_sdp(offer, opts \\ []) when is_binary(offer) and is_list(opts) do
    with {:ok, offer_sdp} <- SDP.parse(offer, strict: true),
         {:ok, answer_sdp} <- maybe_parse_answer(Keyword.get(opts, :answer)) do
      bind_offer(offer_sdp, answer_sdp)
    end
  end

  defp maybe_parse_answer(nil), do: {:ok, nil}

  defp maybe_parse_answer(bin) when is_binary(bin), do: SDP.parse(bin, strict: true)

  defp bind_offer(%SDP{media: media}, answer_sdp) do
    audio_sections =
      media
      |> Enum.with_index()
      |> Enum.filter(fn {%Media{type: type}, _} -> type == :audio end)

    Enum.reduce_while(audio_sections, {:ok, []}, fn {m, index}, {:ok, acc} ->
      mid = m.mid || Integer.to_string(index)

      case first_mixable(m) do
        nil ->
          {:halt, {:error, {:no_mixable_audio_codec, mid}}}

        send_desc ->
          recv_desc =
            case answer_recv(answer_sdp, mid) do
              nil -> send_desc
              recv -> recv
            end

          descs = ordered_codecs(m)
          non_mixable_pts = non_mixable_pts(descs)
          # Egress CN follows recv: answer PT when present, else offer
          cn_pt = cn_payload_type_answer(answer_sdp, mid) || cn_payload_type(descs)

          bind = %{
            mid: mid,
            kind: :audio,
            send: send_desc,
            recv: recv_desc,
            mix_mid: mid,
            non_mixable_pts: non_mixable_pts,
            cn_payload_type: cn_pt
          }

          {:cont, {:ok, acc ++ [bind]}}
      end
    end)
  end

  defp non_mixable_pts(descs) do
    descs
    |> Enum.reject(& &1.mixable?)
    |> Enum.map(& &1.payload_type)
  end

  defp cn_payload_type(descs) do
    Enum.find_value(descs, fn
      %{name: "CN", payload_type: pt} -> pt
      _ -> nil
    end)
  end

  defp cn_payload_type_answer(nil, _mid), do: nil

  defp cn_payload_type_answer(%SDP{media: media}, mid) do
    media
    |> Enum.with_index()
    |> Enum.find_value(fn {m, index} ->
      if m.type == :audio and (m.mid || Integer.to_string(index)) == mid do
        cn_payload_type(ordered_codecs(m))
      else
        nil
      end
    end)
  end

  defp answer_recv(nil, _mid), do: nil

  defp answer_recv(%SDP{media: media}, mid) do
    media
    |> Enum.with_index()
    |> Enum.find_value(fn {m, index} ->
      if m.type == :audio and (m.mid || Integer.to_string(index)) == mid do
        first_mixable(m)
      else
        nil
      end
    end)
  end

  defp first_mixable(%Media{} = m) do
    m
    |> ordered_codecs()
    |> Enum.find(& &1.mixable?)
  end

  defp ordered_codecs(%Media{formats: formats, codecs: codecs, fmtp: fmtps}) do
    by_pt = Map.new(codecs, fn %Codec{payload_type: pt} = c -> {pt, c} end)
    fmtp_by_pt = Map.new(fmtps, fn %Fmtp{payload_type: pt, parameters: p} -> {pt, p} end)

    formats
    |> Enum.map(&parse_pt/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn pt ->
      case Map.get(by_pt, pt) do
        %Codec{} = c ->
          to_desc(c, Map.get(fmtp_by_pt, pt))

        nil ->
          static_desc(pt, Map.get(fmtp_by_pt, pt))
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_pt(fmt) when is_binary(fmt) do
    case Integer.parse(fmt) do
      {pt, ""} -> pt
      _ -> nil
    end
  end

  defp parse_pt(_), do: nil

  defp to_desc(%Codec{name: name, payload_type: pt, clock_rate: clock, encoding_params: enc}, fmtp) do
    norm = normalize_name(name)
    channels = channels_from(enc, norm)

    %{
      name: norm,
      payload_type: pt,
      clock_rate: clock,
      channels: channels,
      fmtp: fmtp_or_nil(fmtp),
      mixable?: mixable_name?(norm),
      sample_rate_hz: sample_rate_hz(norm, clock)
    }
  end

  # RFC 3551 static types when rtpmap is omitted
  defp static_desc(0, fmtp),
    do: to_desc(%Codec{name: "PCMU", payload_type: 0, clock_rate: 8000}, fmtp)

  defp static_desc(8, fmtp),
    do: to_desc(%Codec{name: "PCMA", payload_type: 8, clock_rate: 8000}, fmtp)

  defp static_desc(9, fmtp),
    do: to_desc(%Codec{name: "G722", payload_type: 9, clock_rate: 8000}, fmtp)

  defp static_desc(_pt, _fmtp), do: nil

  defp fmtp_or_nil(nil), do: nil
  defp fmtp_or_nil(""), do: nil
  defp fmtp_or_nil(s) when is_binary(s), do: s

  defp normalize_name(name) when is_binary(name) do
    case String.downcase(name) do
      "g722" -> "G722"
      "pcmu" -> "PCMU"
      "pcma" -> "PCMA"
      "opus" -> "opus"
      "telephone-event" -> "telephone-event"
      "cn" -> "CN"
      other -> other
    end
  end

  defp mixable_name?("telephone-event"), do: false
  defp mixable_name?("CN"), do: false
  defp mixable_name?("opus"), do: true
  defp mixable_name?("PCMU"), do: true
  defp mixable_name?("PCMA"), do: true
  defp mixable_name?("G722"), do: true
  defp mixable_name?(_), do: false

  defp sample_rate_hz("G722", _clock), do: 16_000
  defp sample_rate_hz(_name, clock) when is_integer(clock) and clock > 0, do: clock

  defp channels_from(enc, _name) when is_binary(enc) do
    case Integer.parse(enc) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp channels_from(_, _), do: 1
end
