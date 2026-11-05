defmodule Xylon.Conference.NackCache do
  @moduledoc """
  Per-route outbound RTP packet cache for Generic NACK retransmission.

  ## What problem this solves

  Subscribers detect loss and send RFC 4585 Generic NACK naming the outbound
  sequence numbers they missed. The SFU must retransmit the rewritten packets
  it already sent for that subscriber-facing SSRC. This module stores recent
  emit snapshots after rewrite/TWCC stamp, keyed by `{plan_ref, out_ssrc, seq}`.

  Each ETS value is a **lean emit record**: payload binary (BEAM-refcounted when
  shared across legs) plus frozen header/extension fields. Lookup rebuilds a
  `%XMediaLib.Rtp{}` for retransmit. Live rewrite state is never re-applied.

  Eviction is O(1) amortized via a per-`out_ssrc` insertion ring (capacity
  #{1000}) plus age drops from the ring head. Hot-path fanout must not scan
  the full SSRC cache on every store.

  **Internal:** used by `Xylon.Conference.Backend` (store) and
  `Xylon.Conference.Rtcp` (lookup / retransmit).

  ## RFCs

  - [RFC 4585](https://www.rfc-editor.org/rfc/rfc4585) (Generic NACK)
  - [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) (RTP sequence numbers)
  """

  alias XMediaLib.Rtp

  @table :xylon_conference_nack

  @max_packets_per_ssrc 1000
  @max_age_ms 1000

  @typedoc """
  Lean emit snapshot stored under `{plan_ref, out_ssrc, seq}`.

  ## Fields

  - `:padding` -- RTP padding bit
  - `:marker` -- RTP marker bit
  - `:payload_type` -- RTP payload type
  - `:sequence_number` -- outbound sequence (same as ETS key seq)
  - `:timestamp` -- outbound RTP timestamp
  - `:ssrc` -- outbound SSRC (same as ETS key out_ssrc)
  - `:csrcs` -- contributing source list
  - `:extension` -- RTP header extension map or nil (post-stamp)
  - `:payload` -- RTP payload binary
  """
  @type lean :: %{
          padding: non_neg_integer(),
          marker: non_neg_integer(),
          payload_type: non_neg_integer() | nil,
          sequence_number: non_neg_integer() | nil,
          timestamp: non_neg_integer() | nil,
          ssrc: non_neg_integer() | nil,
          csrcs: [non_neg_integer()],
          extension: term(),
          payload: binary() | nil
        }

  @typedoc """
  Per-outbound-SSRC ring metadata.

  ## Fields

  - `:seqs` -- fixed-size list of sequence numbers in insertion order (ring)
  - `:head` -- index of oldest live slot
  - `:count` -- number of live entries in the ring
  """
  @type meta :: %{seqs: tuple(), head: non_neg_integer(), count: non_neg_integer()}

  @doc """
  Ensures the NACK cache ETS table exists (`:public`, read concurrency).
  """
  @spec ensure_table!() :: :ok
  def ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Stores a rewritten RTP packet under the subscriber-facing SSRC and sequence.

  Accepts a `%Rtp{}` (or map with the same keys) and normalizes to a lean emit
  record before insert. Evicts packets older than #{@max_age_ms} ms from the
  ring head and drops the oldest insertion when more than
  #{@max_packets_per_ssrc} packets are cached for `out_ssrc`.

  Opts: `:now` -- monotonic ms timestamp (tests); default `System.monotonic_time(:millisecond)`.
  """
  @spec store(term(), non_neg_integer(), non_neg_integer(), term()) :: :ok
  @spec store(term(), non_neg_integer(), non_neg_integer(), term(), keyword()) :: :ok
  def store(plan_ref, out_ssrc, seq, packet, opts \\ [])
      when is_integer(out_ssrc) and is_integer(seq) and is_list(opts) do
    ensure_table!()
    now = Keyword.get(opts, :now, System.monotonic_time(:millisecond))
    lean = to_lean(packet)
    true = :ets.insert(@table, {{plan_ref, out_ssrc, seq}, {lean, now}})
    meta = get_meta(plan_ref, out_ssrc) |> age_evict(plan_ref, out_ssrc, now)
    meta = ring_push(meta, plan_ref, out_ssrc, seq)
    put_meta(plan_ref, out_ssrc, meta)
    :ok
  end

  @doc """
  Looks up a cached packet by outbound SSRC and sequence number.

  Returns `{:ok, %Rtp{}}` rebuilt from the lean emit record, or `:error`.
  Aged-out packets are treated as misses.

  Opts: `:now` -- monotonic ms (tests); default `System.monotonic_time(:millisecond)`.
  """
  @spec lookup(term(), non_neg_integer(), non_neg_integer()) :: {:ok, Rtp.t()} | :error
  @spec lookup(term(), non_neg_integer(), non_neg_integer(), keyword()) ::
          {:ok, Rtp.t()} | :error
  def lookup(plan_ref, out_ssrc, seq, opts \\ [])
      when is_integer(out_ssrc) and is_integer(seq) and is_list(opts) do
    ensure_table!()
    now = Keyword.get(opts, :now, System.monotonic_time(:millisecond))

    case :ets.lookup(@table, {plan_ref, out_ssrc, seq}) do
      [{_, {lean, ts}}] when now - ts <= @max_age_ms ->
        {:ok, from_lean(lean)}

      [{key, {_lean, _ts}}] ->
        true = :ets.delete(@table, key)
        _ = ring_remove(plan_ref, out_ssrc, seq)
        :error

      _ ->
        :error
    end
  end

  @doc """
  Deletes all cached packets for `plan_ref` (session teardown).
  """
  @spec clear_plan(term()) :: :ok
  def clear_plan(plan_ref) do
    ensure_table!()
    true = :ets.match_delete(@table, {{plan_ref, :_, :_}, :_})
    :ok
  end

  @doc """
  Deletes all cached packets for one outbound SSRC (unsubscribe / rewrite reset).
  """
  @spec clear_ssrc(term(), non_neg_integer()) :: :ok
  def clear_ssrc(plan_ref, out_ssrc) when is_integer(out_ssrc) do
    ensure_table!()
    true = :ets.match_delete(@table, {{plan_ref, out_ssrc, :_}, :_})
    true = :ets.delete(@table, {plan_ref, :meta, out_ssrc})
    :ok
  end

  @doc """
  Returns how many packets are cached for `out_ssrc` under `plan_ref`.

  Used by tests to assert eviction bounds.
  """
  @spec count(term(), non_neg_integer()) :: non_neg_integer()
  def count(plan_ref, out_ssrc) when is_integer(out_ssrc) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :meta, out_ssrc}) do
      [{_, %{count: n}}] when is_integer(n) -> n
      _ -> 0
    end
  end

  defp to_lean(%Rtp{} = rtp) do
    %{
      padding: rtp.padding || 0,
      marker: rtp.marker || 0,
      payload_type: rtp.payload_type,
      sequence_number: rtp.sequence_number,
      timestamp: rtp.timestamp,
      ssrc: rtp.ssrc,
      csrcs: rtp.csrcs || [],
      extension: rtp.extension,
      payload: rtp.payload
    }
  end

  defp to_lean(%{} = m) do
    %{
      padding: Map.get(m, :padding, 0) || 0,
      marker: Map.get(m, :marker, 0) || 0,
      payload_type: Map.get(m, :payload_type),
      sequence_number: Map.get(m, :sequence_number),
      timestamp: Map.get(m, :timestamp),
      ssrc: Map.get(m, :ssrc),
      csrcs: Map.get(m, :csrcs, []) || [],
      extension: Map.get(m, :extension),
      payload: Map.get(m, :payload)
    }
  end

  defp from_lean(%{} = lean) do
    %Rtp{
      padding: Map.get(lean, :padding, 0) || 0,
      marker: Map.get(lean, :marker, 0) || 0,
      payload_type: Map.get(lean, :payload_type),
      sequence_number: Map.get(lean, :sequence_number),
      timestamp: Map.get(lean, :timestamp),
      ssrc: Map.get(lean, :ssrc),
      csrcs: Map.get(lean, :csrcs, []) || [],
      extension: Map.get(lean, :extension),
      payload: Map.get(lean, :payload)
    }
  end

  defp get_meta(plan_ref, out_ssrc) do
    case :ets.lookup(@table, {plan_ref, :meta, out_ssrc}) do
      [{_, %{seqs: seqs, head: head, count: count}}] = _
      when is_tuple(seqs) and tuple_size(seqs) == @max_packets_per_ssrc ->
        %{seqs: seqs, head: head, count: count}

      _ ->
        %{seqs: empty_ring(), head: 0, count: 0}
    end
  end

  defp put_meta(plan_ref, out_ssrc, meta) do
    true = :ets.insert(@table, {{plan_ref, :meta, out_ssrc}, meta})
    :ok
  end

  defp empty_ring do
    List.to_tuple(List.duplicate(nil, @max_packets_per_ssrc))
  end

  defp age_evict(%{count: 0} = meta, _plan_ref, _out_ssrc, _now), do: meta

  defp age_evict(%{seqs: seqs, head: head, count: count} = meta, plan_ref, out_ssrc, now) do
    seq = elem(seqs, head)

    cond do
      is_nil(seq) ->
        age_evict(
          %{seqs: seqs, head: rem(head + 1, @max_packets_per_ssrc), count: count},
          plan_ref,
          out_ssrc,
          now
        )

      true ->
        case :ets.lookup(@table, {plan_ref, out_ssrc, seq}) do
          [{key, {_pkt, ts}}] when now - ts > @max_age_ms ->
            true = :ets.delete(@table, key)

            age_evict(
              %{
                seqs: put_elem(seqs, head, nil),
                head: rem(head + 1, @max_packets_per_ssrc),
                count: count - 1
              },
              plan_ref,
              out_ssrc,
              now
            )

          [] ->
            # Packet already removed (e.g. aged lookup); drop the ring slot.
            age_evict(
              %{
                seqs: put_elem(seqs, head, nil),
                head: rem(head + 1, @max_packets_per_ssrc),
                count: max(count - 1, 0)
              },
              plan_ref,
              out_ssrc,
              now
            )

          _ ->
            meta
        end
    end
  end

  defp ring_remove(plan_ref, out_ssrc, seq) do
    meta = get_meta(plan_ref, out_ssrc)
    %{seqs: seqs, head: head, count: count} = meta

    case find_ring_index(seqs, seq) do
      nil ->
        :ok

      idx ->
        seqs = put_elem(seqs, idx, nil)
        count = max(count - 1, 0)
        {head, seqs, count} = advance_past_nils(seqs, head, count)
        put_meta(plan_ref, out_ssrc, %{seqs: seqs, head: head, count: count})
    end
  end

  defp find_ring_index(seqs, seq) do
    Enum.find_value(0..(@max_packets_per_ssrc - 1), fn i ->
      if elem(seqs, i) == seq, do: i
    end)
  end

  defp advance_past_nils(seqs, head, 0), do: {head, seqs, 0}

  defp advance_past_nils(seqs, head, count) do
    if is_nil(elem(seqs, head)) do
      advance_past_nils(seqs, rem(head + 1, @max_packets_per_ssrc), count)
    else
      {head, seqs, count}
    end
  end

  defp ring_push(%{seqs: seqs, head: head, count: count}, plan_ref, out_ssrc, seq)
       when count >= @max_packets_per_ssrc do
    # Skip holes at head left by mid-ring removals.
    {head, seqs, count} = advance_past_nils(seqs, head, count)

    if count >= @max_packets_per_ssrc do
      old_seq = elem(seqs, head)

      if is_integer(old_seq) do
        true = :ets.delete(@table, {plan_ref, out_ssrc, old_seq})
      end

      seqs = put_elem(seqs, head, seq)

      %{
        seqs: seqs,
        head: rem(head + 1, @max_packets_per_ssrc),
        count: @max_packets_per_ssrc
      }
    else
      ring_push(%{seqs: seqs, head: head, count: count}, plan_ref, out_ssrc, seq)
    end
  end

  defp ring_push(%{seqs: seqs, head: head, count: count}, _plan_ref, _out_ssrc, seq) do
    idx = rem(head + count, @max_packets_per_ssrc)
    # If slot occupied by a hole-skipped layout, walk forward for a free slot.
    idx = next_free_slot(seqs, idx, 0)
    %{seqs: put_elem(seqs, idx, seq), head: head, count: count + 1}
  end

  defp next_free_slot(_seqs, idx, n) when n >= @max_packets_per_ssrc, do: idx

  defp next_free_slot(seqs, idx, n) do
    if is_nil(elem(seqs, idx)) do
      idx
    else
      next_free_slot(seqs, rem(idx + 1, @max_packets_per_ssrc), n + 1)
    end
  end
end
