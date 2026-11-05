defmodule Xylon.Conference.OfferTracks do
  @moduledoc """
  Extracts inbound audio/video tracks (mid, SSRC, codec) from a remote offer SDP.

  ## What problem this solves

  When a browser joins a conference it sends an SDP offer describing which media
  it will send (mids, audio, video, codecs, SSRC identifiers). The SFU must learn
  those inbound mid/SSRC values before it can route packets. This module parses
  offer SDP text and returns one track map per audio/video m-section.

  **Internal:** called from `Xylon.Conference.Backend.media_ready/4`. Apps normally
  do not call this directly.

  ## RFCs

  - [RFC 3264](https://www.rfc-editor.org/rfc/rfc3264) (SDP offer/answer)
  - [RFC 8829](https://www.rfc-editor.org/rfc/rfc8829) (JSEP offer shape)
  - [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) (RTP SSRC identifiers in SDP)
  - [RFC 5888](https://www.rfc-editor.org/rfc/rfc5888) (SDP grouping / mid)
  - Simulcast grouping follows WebRTC SDP conventions (`a=ssrc-group:SIM`, `a=rid:`)
  """

  @typedoc """
  One simulcast layer within a published track.

  ## Fields

  - `:ssrc` -- RTP synchronization source for this layer
  - `:substream` -- simulcast index (0 = lowest / primary)
  - `:rid` -- optional Restriction Identifier from SDP `a=rid:` when present
  """
  @type layer :: %{
          required(:ssrc) => non_neg_integer(),
          required(:substream) => non_neg_integer(),
          optional(:rid) => binary()
        }

  @typedoc """
  One published media track extracted from an offer m-section.

  ## Fields

  - `:mid` -- SDP media identification tag (`a=mid:`), or a synthesized index
  - `:kind` -- `:audio` or `:video`
  - `:ssrc` -- primary inbound RTP SSRC for this section
  - `:codec` -- first `a=rtpmap:` codec name when present (e.g. `"opus"`, `"VP8"`)
  - `:layers` -- simulcast layers when `a=ssrc-group:SIM` lists more than one
    SSRC, or RID-seeded layers (`ssrc: 0`) from Chrome `a=rid:` until RTP learns
    each layer SSRC
  - `:ssrc` -- `0` means unbound (Chrome RID/`a=simulcast` with no `a=ssrc:` yet);
    `Backend` learns real SSRCs from inbound RTP (RID extension)
  """
  @type track :: %{
          required(:mid) => binary(),
          required(:kind) => :audio | :video,
          required(:ssrc) => non_neg_integer(),
          optional(:codec) => binary(),
          optional(:layers) => [layer()]
        }

  @doc """
  Parses offer SDP and returns one track per audio/video m-section that has an
  SSRC, or a Chrome RID-only video section (`a=rid:` / `a=simulcast:`) with
  unbound `ssrc: 0` and RID-seeded `layers` (`ssrc: 0` per rid).

  When `a=mid:` is missing, synthesizes `"0"`, `"1"`, ... by m-line order among
  audio/video sections. SSRC selection prefers `a=ssrc-group:SIM` order when
  present; otherwise the first `a=ssrc:` line in the m-section.

  ## Examples

      iex> sdp = \"\"\"
      ...> m=audio 9 UDP/TLS/RTP/SAVPF 111
      ...> a=mid:0
      ...> a=rtpmap:111 opus/48000/2
      ...> a=ssrc:1111 cname:a
      ...> m=video 9 UDP/TLS/RTP/SAVPF 96
      ...> a=mid:1
      ...> a=rtpmap:96 VP8/90000
      ...> a=ssrc:3333 cname:v
      ...> \"\"\"
      iex> Xylon.Conference.OfferTracks.from_sdp(sdp)
      [
        %{mid: "0", kind: :audio, ssrc: 1111, codec: "opus"},
        %{mid: "1", kind: :video, ssrc: 3333, codec: "VP8"}
      ]
  """
  @spec from_sdp(binary()) :: [track()]
  def from_sdp(sdp) when is_binary(sdp) do
    sdp
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({nil, 0, []}, fn line, {cur, idx, sections} ->
      line = String.trim(line)

      cond do
        String.starts_with?(line, "m=audio") ->
          {%{kind: :audio, index: idx}, idx + 1, flush(cur, sections)}

        String.starts_with?(line, "m=video") ->
          {%{kind: :video, index: idx}, idx + 1, flush(cur, sections)}

        String.starts_with?(line, "m=") ->
          {nil, idx, flush(cur, sections)}

        is_map(cur) and match?({:ok, _}, parse_mid(line)) ->
          {:ok, mid} = parse_mid(line)
          {Map.put(cur, :mid, mid), idx, sections}

        is_map(cur) and match?({:ok, _}, parse_sim_group(line)) ->
          {:ok, ssrcs} = parse_sim_group(line)
          {Map.put(cur, :sim, ssrcs), idx, sections}

        is_map(cur) and match?({:ok, _}, parse_rid(line)) ->
          {:ok, rid} = parse_rid(line)
          rids = Map.get(cur, :rids, [])

          if rid in rids do
            {cur, idx, sections}
          else
            {Map.put(cur, :rids, rids ++ [rid]), idx, sections}
          end

        is_map(cur) and match?({:ok, _}, parse_ssrc(line)) ->
          {:ok, ssrc} = parse_ssrc(line)
          ssrcs = Map.get(cur, :ssrcs, [])

          if ssrc in ssrcs do
            {cur, idx, sections}
          else
            {Map.put(cur, :ssrcs, ssrcs ++ [ssrc]), idx, sections}
          end

        is_map(cur) and match?({:ok, _}, parse_rtpmap_name(line)) ->
          {:ok, name} = parse_rtpmap_name(line)

          if Map.has_key?(cur, :codec) do
            {cur, idx, sections}
          else
            {Map.put(cur, :codec, name), idx, sections}
          end

        true ->
          {cur, idx, sections}
      end
    end)
    |> then(fn {cur, _idx, sections} -> flush(cur, sections) end)
    |> Enum.reverse()
    |> Enum.flat_map(&section_to_tracks/1)
  end

  defp flush(nil, sections), do: sections
  defp flush(cur, sections) when is_map(cur), do: [cur | sections]

  defp section_to_tracks(entry) do
    ssrcs =
      case Map.get(entry, :sim) do
        list when is_list(list) and list != [] ->
          list

        _ ->
          case Map.get(entry, :ssrcs, []) do
            [primary | _] -> [primary]
            [] -> []
          end
      end

    case ssrcs do
      [] ->
        unbound_rid_track(entry)

      [primary | _] = list ->
        mid = Map.get(entry, :mid) || Integer.to_string(entry.index)
        track = %{mid: mid, kind: entry.kind, ssrc: primary}

        track =
          case Map.get(entry, :codec) do
            nil -> track
            codec -> Map.put(track, :codec, codec)
          end

        track =
          if length(list) > 1 do
            rids = Map.get(entry, :rids, [])

            layers =
              list
              |> Enum.with_index()
              |> Enum.map(fn {ssrc, i} ->
                layer = %{ssrc: ssrc, substream: i}

                case Enum.at(rids, i) do
                  rid when is_binary(rid) and rid != "" -> Map.put(layer, :rid, rid)
                  _ -> layer
                end
              end)

            Map.put(track, :layers, layers)
          else
            track
          end

        [track]
    end
  end

  # Chrome Unified Plan RID simulcast often omits a=ssrc until media flows.
  defp unbound_rid_track(%{kind: :video} = entry) do
    rids = Map.get(entry, :rids, [])

    if rids == [] do
      []
    else
      mid = Map.get(entry, :mid) || Integer.to_string(entry.index)

      layers =
        rids
        |> Enum.with_index()
        |> Enum.map(fn {rid, i} -> %{ssrc: 0, substream: i, rid: rid} end)

      track = %{mid: mid, kind: :video, ssrc: 0, layers: layers}

      case Map.get(entry, :codec) do
        nil -> [track]
        codec -> [Map.put(track, :codec, codec)]
      end
    end
  end

  defp unbound_rid_track(_), do: []

  defp parse_mid(<<"a=mid:", rest::binary>>), do: {:ok, String.trim(rest)}
  defp parse_mid(<<"mid:", rest::binary>>), do: {:ok, String.trim(rest)}
  defp parse_mid(_), do: :error

  defp parse_sim_group(<<"a=ssrc-group:SIM ", rest::binary>>), do: parse_ssrc_list(rest)
  defp parse_sim_group(<<"ssrc-group:SIM ", rest::binary>>), do: parse_ssrc_list(rest)
  defp parse_sim_group(_), do: :error

  defp parse_ssrc_list(rest) do
    ssrcs =
      rest
      |> String.split(~r/\s+/, trim: true)
      |> Enum.flat_map(fn part ->
        case Integer.parse(part) do
          {ssrc, ""} when ssrc >= 0 -> [ssrc]
          _ -> []
        end
      end)

    if ssrcs == [], do: :error, else: {:ok, ssrcs}
  end

  defp parse_rid(<<"a=rid:", rest::binary>>), do: parse_rid_id(rest)
  defp parse_rid(<<"rid:", rest::binary>>), do: parse_rid_id(rest)
  defp parse_rid(_), do: :error

  defp parse_rid_id(rest) do
    case Regex.run(~r/^([A-Za-z0-9\-_]+)/, rest) do
      [_, rid] -> {:ok, rid}
      _ -> :error
    end
  end

  defp parse_ssrc(<<"a=ssrc:", rest::binary>>) do
    case Integer.parse(rest) do
      {ssrc, _} when ssrc >= 0 -> {:ok, ssrc}
      _ -> :error
    end
  end

  defp parse_ssrc(<<"ssrc:", rest::binary>>) do
    case Integer.parse(rest) do
      {ssrc, _} when ssrc >= 0 -> {:ok, ssrc}
      _ -> :error
    end
  end

  defp parse_ssrc(_), do: :error

  defp parse_rtpmap_name(<<"a=rtpmap:", rest::binary>>) do
    case Regex.run(~r/^\d+\s+([A-Za-z0-9\-]+)/, rest) do
      [_, name] -> {:ok, name}
      _ -> :error
    end
  end

  defp parse_rtpmap_name(<<"rtpmap:", rest::binary>>) do
    case Regex.run(~r/^\d+\s+([A-Za-z0-9\-]+)/, rest) do
      [_, name] -> {:ok, name}
      _ -> :error
    end
  end

  defp parse_rtpmap_name(_), do: :error
end
