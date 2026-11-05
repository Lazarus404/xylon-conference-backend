defmodule Xylon.Conference.Mcu.Quota do
  @moduledoc """
  Node- and room-level MCU admission caps (reject-only, no SFU degrade).

  ## What problem this solves

  Multi-tenant nodes need hard limits on MCU mixers (rooms), participants, and
  active contributors so overload fails loudly instead of silently switching
  to SFU or melting the mix tick. Caps come from Application env (node) and
  optional per-room Backend opts; counters live in a public ETS table shared
  across Session and Forwarder Backend processes.

  **Internal:** used by `Xylon.Conference.Backend` and Contributor lifecycle.

  ## RFCs

  No wire RFC; conference admission control only.
  """

  @table :xylon_conference_mcu_quota

  @typedoc "Plan key shared with Plan/Runtime."
  @type plan_ref :: pid() | reference()

  @doc "Creates the MCU quota ETS table if missing."
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

        true = :ets.insert(@table, {:totals, %{mixers: 0, participants: 0, contributors: 0}})
        :ok

      _ ->
        :ok
    end
  end

  @doc "Node caps from `config :xylon_conference_backend, :mcu_quota` (`nil` = unlimited)."
  @spec node_limits() :: map()
  def node_limits do
    case Application.get_env(:xylon_conference_backend, :mcu_quota, []) do
      kw when is_list(kw) -> Map.new(kw)
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc "Registers an MCU mixer room; fails with `:mcu_max_mixers` when node budget is full."
  @spec register_mixer(plan_ref()) :: :ok | {:error, :mcu_max_mixers}
  def register_mixer(plan_ref) do
    ensure_table!()

    case :ets.lookup(@table, {:mixer, plan_ref}) do
      [{_, _}] ->
        :ok

      [] ->
        totals = get_totals()
        max_m = Map.get(node_limits(), :max_mixers)

        if capped?(max_m, totals.mixers) do
          {:error, :mcu_max_mixers}
        else
          row = %{participants: 0, contributors: 0, contributor_ids: MapSet.new()}
          true = :ets.insert(@table, {{:mixer, plan_ref}, row})
          put_totals(%{totals | mixers: totals.mixers + 1})
          :ok
        end
    end
  end

  @doc "Removes mixer row and subtracts its counts from node totals."
  @spec unregister_mixer(plan_ref()) :: :ok
  def unregister_mixer(plan_ref) do
    ensure_table!()

    case :ets.lookup(@table, {:mixer, plan_ref}) do
      [{_, row}] ->
        true = :ets.delete(@table, {:mixer, plan_ref})
        totals = get_totals()

        put_totals(%{
          mixers: max(totals.mixers - 1, 0),
          participants: max(totals.participants - Map.get(row, :participants, 0), 0),
          contributors: max(totals.contributors - Map.get(row, :contributors, 0), 0)
        })

        :ok

      [] ->
        :ok
    end
  end

  @doc """
  Admits one MCU participant under room and node caps.

  `room_cap` is `mcu_max_participants` or `nil` (unlimited for the room).
  """
  @spec admit_participant(plan_ref(), pos_integer() | nil) ::
          :ok | {:error, :mcu_max_participants}
  def admit_participant(plan_ref, room_cap) do
    ensure_table!()

    with {:ok, row} <- fetch_mixer(plan_ref),
         :ok <- check_room_cap(room_cap, row.participants, :mcu_max_participants),
         totals = get_totals(),
         :ok <-
           check_node_cap(
             Map.get(node_limits(), :max_participants),
             totals.participants,
             :mcu_max_participants
           ) do
      next = %{row | participants: row.participants + 1}
      true = :ets.insert(@table, {{:mixer, plan_ref}, next})
      put_totals(%{totals | participants: totals.participants + 1})
      :ok
    end
  end

  @doc "Decrements participant count for the mixer (no-op if zero or missing)."
  @spec release_participant(plan_ref()) :: :ok
  def release_participant(plan_ref) do
    ensure_table!()

    case :ets.lookup(@table, {:mixer, plan_ref}) do
      [{_, %{participants: n} = row}] when n > 0 ->
        true = :ets.insert(@table, {{:mixer, plan_ref}, %{row | participants: n - 1}})
        totals = get_totals()
        put_totals(%{totals | participants: max(totals.participants - 1, 0)})
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Admits an active contributor id under room and node caps.

  Idempotent when `participant_id` is already counted for this mixer.
  """
  @spec admit_contributor(plan_ref(), term(), pos_integer() | nil) ::
          :ok | {:error, :mcu_max_contributors}
  def admit_contributor(plan_ref, participant_id, room_cap) do
    ensure_table!()

    with {:ok, row} <- fetch_mixer(plan_ref) do
      ids = Map.get(row, :contributor_ids, MapSet.new())

      if MapSet.member?(ids, participant_id) do
        :ok
      else
        with :ok <- check_room_cap(room_cap, row.contributors, :mcu_max_contributors),
             totals = get_totals(),
             :ok <-
               check_node_cap(
                 Map.get(node_limits(), :max_contributors),
                 totals.contributors,
                 :mcu_max_contributors
               ) do
          next = %{
            row
            | contributors: row.contributors + 1,
              contributor_ids: MapSet.put(ids, participant_id)
          }

          true = :ets.insert(@table, {{:mixer, plan_ref}, next})
          put_totals(%{totals | contributors: totals.contributors + 1})
          :ok
        end
      end
    end
  end

  @doc "Releases a contributor id if present."
  @spec release_contributor(plan_ref(), term()) :: :ok
  def release_contributor(plan_ref, participant_id) do
    ensure_table!()

    case :ets.lookup(@table, {:mixer, plan_ref}) do
      [{_, row}] ->
        ids = Map.get(row, :contributor_ids, MapSet.new())

        if MapSet.member?(ids, participant_id) do
          next = %{
            row
            | contributors: max(row.contributors - 1, 0),
              contributor_ids: MapSet.delete(ids, participant_id)
          }

          true = :ets.insert(@table, {{:mixer, plan_ref}, next})
          totals = get_totals()
          put_totals(%{totals | contributors: max(totals.contributors - 1, 0)})
          :ok
        else
          :ok
        end

      [] ->
        :ok
    end
  end

  @doc "Node-wide totals map."
  @spec totals() :: %{mixers: non_neg_integer(), participants: non_neg_integer(), contributors: non_neg_integer()}
  def totals do
    ensure_table!()
    get_totals()
  end

  @doc "Per-mixer counts, or `nil` when unregistered."
  @spec mixer(plan_ref()) :: map() | nil
  def mixer(plan_ref) do
    ensure_table!()

    case :ets.lookup(@table, {:mixer, plan_ref}) do
      [{_, row}] -> Map.take(row, [:participants, :contributors])
      [] -> nil
    end
  end

  @doc "Test helper: wipe quota counters."
  @spec reset() :: :ok
  def reset do
    case :ets.whereis(@table) do
      :undefined ->
        ensure_table!()

      _ ->
        true = :ets.delete_all_objects(@table)
        true = :ets.insert(@table, {:totals, %{mixers: 0, participants: 0, contributors: 0}})
    end

    :ok
  end

  @doc """
  Best-effort Control `quota.exceeded` when Control Quota is running.
  """
  @spec maybe_emit_exceeded(term(), term(), atom()) :: :ok
  def maybe_emit_exceeded(tenant_id, session_id, kind) when is_atom(kind) do
    if is_pid(Process.whereis(Xylon.Control.Quota)) do
      _ = Xylon.Control.Quota.emit_exceeded(tenant_id, session_id, Atom.to_string(kind))
    end

    :ok
  end

  defp fetch_mixer(plan_ref) do
    case :ets.lookup(@table, {:mixer, plan_ref}) do
      [{_, row}] -> {:ok, row}
      [] -> {:error, :mcu_max_mixers}
    end
  end

  defp check_room_cap(nil, _current, _err), do: :ok

  defp check_room_cap(cap, current, err)
       when is_integer(cap) and cap > 0 and is_integer(current) do
    if current >= cap, do: {:error, err}, else: :ok
  end

  defp check_room_cap(_, _, err), do: {:error, err}

  defp check_node_cap(nil, _current, _err), do: :ok

  defp check_node_cap(cap, current, err)
       when is_integer(cap) and cap > 0 and is_integer(current) do
    if current >= cap, do: {:error, err}, else: :ok
  end

  defp check_node_cap(_, _, err), do: {:error, err}

  defp capped?(nil, _), do: false
  defp capped?(cap, current) when is_integer(cap) and cap > 0, do: current >= cap
  defp capped?(_, _), do: false

  defp get_totals do
    case :ets.lookup(@table, :totals) do
      [{:totals, map}] when is_map(map) -> map
      _ -> %{mixers: 0, participants: 0, contributors: 0}
    end
  end

  defp put_totals(map) when is_map(map) do
    true = :ets.insert(@table, {:totals, map})
    :ok
  end
end
