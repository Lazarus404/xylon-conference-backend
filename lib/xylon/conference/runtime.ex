defmodule Xylon.Conference.Runtime do
  @moduledoc """
  Shared ETS media runtime for a conference Session (ext ids, TWCC, talking, REMB, FIR).

  ## What problem this solves

  Session and Forwarder each call `Backend.init/2` and hold separate `backend_state`
  maps. Fields written on `media_ready/4` (Session) must be readable on
  `handle_rtp/3` (Forwarder). This module stores those maps in a public ETS table
  keyed by `plan_ref` (Session pid), matching the Plan SoT pattern.

  **Internal:** used by `Xylon.Conference.Backend` only.

  ## RFCs

  - [RFC 6464](https://www.rfc-editor.org/rfc/rfc6464) (audio level ext id storage)
  - [draft-holmer-rmcat-transport-wide-cc-extensions](https://datatracker.ietf.org/doc/html/draft-holmer-rmcat-transport-wide-cc-extensions) (TWCC ext id / arrivals)
  - No separate STUN/TURN RFC; room runtime only
  """

  @table :xylon_conference_runtime

  @typedoc "Scope key shared with `Xylon.Conference.Plan` (Session pid or test ref)."
  @type plan_ref :: pid() | reference()

  @typedoc """
  Negotiated RTP header extension ids for one publisher.

  ## Fields

  - `:twcc` -- transport-cc one-byte id, or `nil`
  - `:audio_level` -- RFC 6464 one-byte id, or `nil`
  - `:dependency_descriptor` -- DD one-byte id, or `nil`
  - `:rid` -- `sdes:rtp-stream-id` (RID) one-byte id, or `nil`
  """
  @type ext :: %{
          twcc: pos_integer() | nil,
          audio_level: pos_integer() | nil,
          dependency_descriptor: pos_integer() | nil,
          rid: pos_integer() | nil
        }

  @typedoc """
  Per-publisher TWCC queue and flush clock.

  ## Fields

  - `:arrivals` -- `[{twcc_seq, arrival_us}]` newest first (same as `Twcc.record/4`)
  - `:last_ms` -- last flush monotonic ms, or `nil`
  - `:fb_count` -- feedback count for Twcc packets
  """
  @type twcc_state :: %{
          arrivals: [{non_neg_integer(), integer()}],
          last_ms: integer() | nil,
          fb_count: non_neg_integer()
        }

  @doc "Creates the runtime ETS table if missing."
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
  Merges extension ids for `participant_id` under `plan_ref`.

  Omitted keys keep prior values. Missing prior row starts as
  `%{twcc: nil, audio_level: nil, dependency_descriptor: nil, rid: nil}`.
  """
  @spec put_ext(plan_ref(), term(), map()) :: :ok
  def put_ext(plan_ref, participant_id, patch) when is_map(patch) do
    ensure_table!()

    prev =
      get_ext(plan_ref, participant_id) ||
        %{twcc: nil, audio_level: nil, dependency_descriptor: nil, rid: nil}

    next = %{
      twcc: Map.get(patch, :twcc, prev.twcc),
      audio_level: Map.get(patch, :audio_level, Map.get(prev, :audio_level)),
      dependency_descriptor:
        Map.get(patch, :dependency_descriptor, Map.get(prev, :dependency_descriptor)),
      rid: Map.get(patch, :rid, Map.get(prev, :rid))
    }

    true = :ets.insert(@table, {{plan_ref, :ext, participant_id}, next})
    :ok
  end

  @doc "Returns ext ids for `participant_id`, or `nil`."
  @spec get_ext(plan_ref(), term()) :: ext() | nil
  def get_ext(plan_ref, participant_id) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :ext, participant_id}) do
      [{_, %{} = ext}] -> ext
      _ -> nil
    end
  end

  @doc "Stores TWCC runtime for one publisher."
  @spec put_twcc(plan_ref(), term(), twcc_state()) :: :ok
  def put_twcc(plan_ref, participant_id, %{arrivals: _} = twcc) do
    ensure_table!()
    true = :ets.insert(@table, {{plan_ref, :twcc, participant_id}, twcc})
    :ok
  end

  @doc "Returns TWCC runtime for one publisher, or `nil`."
  @spec get_twcc(plan_ref(), term()) :: twcc_state() | nil
  def get_twcc(plan_ref, participant_id) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :twcc, participant_id}) do
      [{_, %{} = twcc}] -> twcc
      _ -> nil
    end
  end

  @doc "Stores talking detector state for one publisher."
  @spec put_audio_level(plan_ref(), term(), term()) :: :ok
  def put_audio_level(plan_ref, participant_id, detector) do
    ensure_table!()
    true = :ets.insert(@table, {{plan_ref, :audio_level, participant_id}, detector})
    :ok
  end

  @doc "Returns talking detector state, or `nil`."
  @spec get_audio_level(plan_ref(), term()) :: term() | nil
  def get_audio_level(plan_ref, participant_id) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :audio_level, participant_id}) do
      [{_, det}] -> det
      _ -> nil
    end
  end

  @doc "Stores the full REMB fan-in map for the room."
  @spec put_remb(plan_ref(), map()) :: :ok
  def put_remb(plan_ref, remb_rates) when is_map(remb_rates) do
    ensure_table!()
    true = :ets.insert(@table, {{plan_ref, :remb}, remb_rates})
    :ok
  end

  @doc "Returns the REMB fan-in map, or `%{}` when unset."
  @spec get_remb(plan_ref()) :: map()
  def get_remb(plan_ref) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :remb}) do
      [{_, rates}] when is_map(rates) -> rates
      _ -> %{}
    end
  end

  @doc "Stores last periodic FIR time (monotonic ms) for a publisher."
  @spec put_last_fir(plan_ref(), term(), integer()) :: :ok
  def put_last_fir(plan_ref, participant_id, ms) when is_integer(ms) do
    ensure_table!()
    true = :ets.insert(@table, {{plan_ref, :fir, participant_id}, ms})
    :ok
  end

  @doc "Returns last FIR ms, or `nil`."
  @spec get_last_fir(plan_ref(), term()) :: integer() | nil
  def get_last_fir(plan_ref, participant_id) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :fir, participant_id}) do
      [{_, ms}] when is_integer(ms) -> ms
      _ -> nil
    end
  end

  @doc "Deletes audio-level ext and detector for one participant (unpublish audio)."
  @spec clear_audio(plan_ref(), term()) :: :ok
  def clear_audio(plan_ref, participant_id) do
    ensure_table!()

    case get_ext(plan_ref, participant_id) do
      nil ->
        :ok

      ext ->
        put_ext(plan_ref, participant_id, %{audio_level: nil})
        if is_nil(ext.twcc), do: :ets.delete(@table, {plan_ref, :ext, participant_id})
    end

    true = :ets.delete(@table, {plan_ref, :audio_level, participant_id})
    :ok
  end

  @doc "Deletes TWCC/FIR/REMB publisher rows for one participant (unpublish video)."
  @spec clear_video(plan_ref(), term()) :: :ok
  def clear_video(plan_ref, participant_id) do
    ensure_table!()

    case get_ext(plan_ref, participant_id) do
      nil ->
        :ok

      ext ->
        put_ext(plan_ref, participant_id, %{twcc: nil})
        if is_nil(ext.audio_level), do: :ets.delete(@table, {plan_ref, :ext, participant_id})
    end

    true = :ets.delete(@table, {plan_ref, :twcc, participant_id})
    true = :ets.delete(@table, {plan_ref, :fir, participant_id})

    remb =
      plan_ref
      |> get_remb()
      |> Map.delete(participant_id)

    put_remb(plan_ref, remb)
    :ok
  end

  @doc "Stores MCU codec binds for a participant (`mid => audio_bind`)."
  @spec put_mcu_bind(plan_ref(), term(), map()) :: :ok
  def put_mcu_bind(plan_ref, participant_id, by_mid) when is_map(by_mid) do
    ensure_table!()
    true = :ets.insert(@table, {{plan_ref, :mcu_bind, participant_id}, by_mid})
    :ok
  end

  @doc "Returns MCU binds map, or `nil`."
  @spec get_mcu_bind(plan_ref(), term()) :: map() | nil
  def get_mcu_bind(plan_ref, participant_id) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :mcu_bind, participant_id}) do
      [{_, %{} = by_mid}] -> by_mid
      _ -> nil
    end
  end

  @doc "Stores MCU contributor runtime (codec, JB, slot)."
  @spec put_mcu_contrib(plan_ref(), term(), map()) :: :ok
  def put_mcu_contrib(plan_ref, participant_id, contrib) when is_map(contrib) do
    ensure_table!()
    true = :ets.insert(@table, {{plan_ref, :mcu_contrib, participant_id}, contrib})
    :ok
  end

  @doc "Returns MCU contributor runtime, or `nil`."
  @spec get_mcu_contrib(plan_ref(), term()) :: map() | nil
  def get_mcu_contrib(plan_ref, participant_id) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :mcu_contrib, participant_id}) do
      [{_, %{} = contrib}] -> contrib
      _ -> nil
    end
  end

  @doc "Stores MCU egress packetizer runtime (RTP counters; no private encode port)."
  @spec put_mcu_egress(plan_ref(), term(), map()) :: :ok
  def put_mcu_egress(plan_ref, participant_id, egress) when is_map(egress) do
    ensure_table!()
    true = :ets.insert(@table, {{plan_ref, :mcu_egress, participant_id}, egress})
    :ok
  end

  @doc """
  Stores many MCU egress rows in one ETS insert.

  `pairs` is `[{listener_id, egress_map}, ...]`.
  """
  @spec put_mcu_egresses(plan_ref(), [{term(), map()}]) :: :ok
  def put_mcu_egresses(_plan_ref, []), do: :ok

  def put_mcu_egresses(plan_ref, pairs) when is_list(pairs) do
    ensure_table!()
    rows = Enum.map(pairs, fn {id, egress} when is_map(egress) -> {{plan_ref, :mcu_egress, id}, egress} end)
    true = :ets.insert(@table, rows)
    :ok
  end

  @doc "Returns MCU egress packetizer runtime, or `nil`."
  @spec get_mcu_egress(plan_ref(), term()) :: map() | nil
  def get_mcu_egress(plan_ref, participant_id) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :mcu_egress, participant_id}) do
      [{_, %{} = egress}] -> egress
      _ -> nil
    end
  end

  @doc "Stores a shared MCU encode-group runtime (`codec_pid`, `refcount`)."
  @spec put_mcu_encode_group(plan_ref(), term(), map()) :: :ok
  def put_mcu_encode_group(plan_ref, group_key, group) when is_map(group) do
    ensure_table!()
    true = :ets.insert(@table, {{plan_ref, :mcu_encode_group, group_key}, group})
    :ok
  end

  @doc "Returns MCU encode-group runtime, or `nil`."
  @spec get_mcu_encode_group(plan_ref(), term()) :: map() | nil
  def get_mcu_encode_group(plan_ref, group_key) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :mcu_encode_group, group_key}) do
      [{_, %{} = group}] -> group
      _ -> nil
    end
  end

  @doc "Deletes MCU encode-group row."
  @spec delete_mcu_encode_group(plan_ref(), term()) :: :ok
  def delete_mcu_encode_group(plan_ref, group_key) do
    ensure_table!()
    true = :ets.delete(@table, {plan_ref, :mcu_encode_group, group_key})
    :ok
  end

  @doc "Maps mix egress `out_ssrc` to listener id for REMB lookup."
  @spec put_mcu_out_ssrc(plan_ref(), non_neg_integer(), term()) :: :ok
  def put_mcu_out_ssrc(plan_ref, out_ssrc, listener_id)
      when is_integer(out_ssrc) do
    ensure_table!()
    true = :ets.insert(@table, {{plan_ref, :mcu_out_ssrc, out_ssrc}, listener_id})
    :ok
  end

  @doc "Returns listener id for mix egress `out_ssrc`, or `nil`."
  @spec get_mcu_listener_for_out_ssrc(plan_ref(), non_neg_integer()) :: term() | nil
  def get_mcu_listener_for_out_ssrc(plan_ref, out_ssrc) when is_integer(out_ssrc) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :mcu_out_ssrc, out_ssrc}) do
      [{_, listener_id}] -> listener_id
      _ -> nil
    end
  end

  @doc "Deletes mix egress `out_ssrc` index row."
  @spec delete_mcu_out_ssrc(plan_ref(), non_neg_integer()) :: :ok
  def delete_mcu_out_ssrc(plan_ref, out_ssrc) when is_integer(out_ssrc) do
    ensure_table!()
    true = :ets.delete(@table, {plan_ref, :mcu_out_ssrc, out_ssrc})
    :ok
  end

  @doc "Stores mix REMB fan-in `%{listener_id => bitrate_bps}`."
  @spec put_mcu_remb(plan_ref(), map()) :: :ok
  def put_mcu_remb(plan_ref, rates) when is_map(rates) do
    ensure_table!()
    true = :ets.insert(@table, {{plan_ref, :mcu_remb}, rates})
    :ok
  end

  @doc "Returns mix REMB fan-in map (empty when missing)."
  @spec get_mcu_remb(plan_ref()) :: map()
  def get_mcu_remb(plan_ref) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :mcu_remb}) do
      [{_, %{} = rates}] -> rates
      _ -> %{}
    end
  end

  @doc "Stores mix TWCC BWE state `%{listener_id => %{bps: integer(), ...}}`."
  @spec put_mcu_twcc(plan_ref(), map()) :: :ok
  def put_mcu_twcc(plan_ref, state) when is_map(state) do
    ensure_table!()
    true = :ets.insert(@table, {{plan_ref, :mcu_twcc}, state})
    :ok
  end

  @doc "Returns mix TWCC BWE map (empty when missing)."
  @spec get_mcu_twcc(plan_ref()) :: map()
  def get_mcu_twcc(plan_ref) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :mcu_twcc}) do
      [{_, %{} = state}] -> state
      _ -> %{}
    end
  end

  @doc "Stores whether uplink Dynacast is enabled for this plan."
  @spec put_dynacast(plan_ref(), boolean()) :: :ok
  def put_dynacast(plan_ref, enabled?) when is_boolean(enabled?) do
    ensure_table!()
    true = :ets.insert(@table, {{plan_ref, :dynacast}, enabled?})
    :ok
  end

  @doc "True when room opt `dynacast` is enabled."
  @spec dynacast?(plan_ref()) :: boolean()
  def dynacast?(plan_ref) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :dynacast}) do
      [{_, true}] -> true
      _ -> false
    end
  end

  @doc "Stores last pushed Dynacast layer flags for a track."
  @spec put_dynacast_last(plan_ref(), term(), binary(), [map()]) :: :ok
  def put_dynacast_last(plan_ref, publisher_id, mid, layers)
      when is_binary(mid) and mid != "" and is_list(layers) do
    ensure_table!()
    true = :ets.insert(@table, {{plan_ref, :dynacast_last, publisher_id, mid}, layers})
    :ok
  end

  @doc "Returns last pushed Dynacast layers, or `nil`."
  @spec get_dynacast_last(plan_ref(), term(), binary()) :: [map()] | nil
  def get_dynacast_last(plan_ref, publisher_id, mid) when is_binary(mid) and mid != "" do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :dynacast_last, publisher_id, mid}) do
      [{_, layers}] when is_list(layers) -> layers
      _ -> nil
    end
  end

  @doc "Stores debounce worker pid for a Dynacast track."
  @spec put_dynacast_worker(plan_ref(), term(), binary(), pid()) :: :ok
  def put_dynacast_worker(plan_ref, publisher_id, mid, pid)
      when is_binary(mid) and mid != "" and is_pid(pid) do
    ensure_table!()
    true = :ets.insert(@table, {{plan_ref, :dynacast_worker, publisher_id, mid}, pid})
    :ok
  end

  @doc "Takes and clears Dynacast worker pid, or `nil`."
  @spec take_dynacast_worker(plan_ref(), term(), binary()) :: pid() | nil
  def take_dynacast_worker(plan_ref, publisher_id, mid) when is_binary(mid) and mid != "" do
    ensure_table!()
    key = {plan_ref, :dynacast_worker, publisher_id, mid}

    case :ets.take(@table, key) do
      [{^key, pid}] when is_pid(pid) -> pid
      _ -> nil
    end
  end

  @doc "Clears Dynacast worker pid without returning it."
  @spec clear_dynacast_worker(plan_ref(), term(), binary()) :: :ok
  def clear_dynacast_worker(plan_ref, publisher_id, mid) when is_binary(mid) and mid != "" do
    ensure_table!()
    true = :ets.delete(@table, {plan_ref, :dynacast_worker, publisher_id, mid})
    :ok
  end

  @doc """
  Stores SFU video route TWCC send bookkeeping keyed by outbound SSRC.

  Value is `%{seq: integer(), send_map: %{twcc_seq => send_us}}`.
  """
  @spec put_sfu_twcc_send(plan_ref(), non_neg_integer(), map()) :: :ok
  def put_sfu_twcc_send(plan_ref, out_ssrc, state)
      when is_integer(out_ssrc) and is_map(state) do
    ensure_table!()
    true = :ets.insert(@table, {{plan_ref, :sfu_twcc_send, out_ssrc}, state})
    :ok
  end

  @doc "Returns SFU TWCC send state for `out_ssrc`, or `nil`."
  @spec get_sfu_twcc_send(plan_ref(), non_neg_integer()) :: map() | nil
  def get_sfu_twcc_send(plan_ref, out_ssrc) when is_integer(out_ssrc) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :sfu_twcc_send, out_ssrc}) do
      [{_, %{} = state}] -> state
      _ -> nil
    end
  end

  @doc "Deletes SFU TWCC send state for `out_ssrc`."
  @spec delete_sfu_twcc_send(plan_ref(), non_neg_integer()) :: :ok
  def delete_sfu_twcc_send(plan_ref, out_ssrc) when is_integer(out_ssrc) do
    ensure_table!()
    true = :ets.delete(@table, {plan_ref, :sfu_twcc_send, out_ssrc})
    :ok
  end

  @doc """
  Stores SFU receive-side TWCC BWE for one video subscription.

  Value is `%{bps: integer(), prev_grad_us: integer() | nil}`.
  """
  @spec put_sfu_twcc_bwe(plan_ref(), term(), term(), binary(), map()) :: :ok
  def put_sfu_twcc_bwe(plan_ref, subscriber_id, publisher_id, mid, state)
      when is_binary(mid) and mid != "" and is_map(state) do
    ensure_table!()

    true =
      :ets.insert(
        @table,
        {{plan_ref, :sfu_twcc_bwe, subscriber_id, publisher_id, mid}, state}
      )

    :ok
  end

  @doc "Returns SFU TWCC BWE for a subscription, or `nil`."
  @spec get_sfu_twcc_bwe(plan_ref(), term(), term(), binary()) :: map() | nil
  def get_sfu_twcc_bwe(plan_ref, subscriber_id, publisher_id, mid)
      when is_binary(mid) and mid != "" do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :sfu_twcc_bwe, subscriber_id, publisher_id, mid}) do
      [{_, %{} = state}] -> state
      _ -> nil
    end
  end

  @doc "Deletes SFU TWCC BWE for one subscription."
  @spec delete_sfu_twcc_bwe(plan_ref(), term(), term(), binary()) :: :ok
  def delete_sfu_twcc_bwe(plan_ref, subscriber_id, publisher_id, mid)
      when is_binary(mid) and mid != "" do
    ensure_table!()
    true = :ets.delete(@table, {plan_ref, :sfu_twcc_bwe, subscriber_id, publisher_id, mid})
    :ok
  end

  @doc "Stores MCU level-gate hysteresis state."
  @spec put_mcu_level(plan_ref(), term(), map()) :: :ok
  def put_mcu_level(plan_ref, participant_id, state) when is_map(state) do
    ensure_table!()
    true = :ets.insert(@table, {{plan_ref, :mcu_level, participant_id}, state})
    :ok
  end

  @doc "Returns MCU level-gate hysteresis state, or `nil`."
  @spec get_mcu_level(plan_ref(), term()) :: map() | nil
  def get_mcu_level(plan_ref, participant_id) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :mcu_level, participant_id}) do
      [{_, %{} = state}] -> state
      _ -> nil
    end
  end

  @doc """
  Records that `contrib_id` arrived via hub trunk `trunk_id` (cascade spoke attribution).
  """
  @spec put_mcu_trunk_attrib(plan_ref(), term(), term()) :: :ok
  def put_mcu_trunk_attrib(plan_ref, contrib_id, trunk_id) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :mcu_trunk_attrib, contrib_id}) do
      [{_, ^trunk_id}] ->
        :ok

      [{_, old_trunk}] ->
        _ = remove_from_trunk_excl(plan_ref, old_trunk, contrib_id)
        true = :ets.insert(@table, {{plan_ref, :mcu_trunk_attrib, contrib_id}, trunk_id})
        _ = add_to_trunk_excl(plan_ref, trunk_id, contrib_id)
        :ok

      [] ->
        true = :ets.insert(@table, {{plan_ref, :mcu_trunk_attrib, contrib_id}, trunk_id})
        _ = add_to_trunk_excl(plan_ref, trunk_id, contrib_id)
        :ok
    end
  end

  @doc "Trunk id for a cascade contributor, or nil."
  @spec get_mcu_trunk_attrib(plan_ref(), term()) :: term() | nil
  def get_mcu_trunk_attrib(plan_ref, contrib_id) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :mcu_trunk_attrib, contrib_id}) do
      [{_, trunk_id}] -> trunk_id
      [] -> nil
    end
  end

  @doc "Contributor ids attributed to `trunk_id` for spoke mix-minus."
  @spec get_mcu_trunk_excl(plan_ref(), term()) :: MapSet.t()
  def get_mcu_trunk_excl(plan_ref, trunk_id) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :mcu_trunk_excl, trunk_id}) do
      [{_, %MapSet{} = set}] -> set
      _ -> MapSet.new()
    end
  end

  @doc "Deletes trunk attribution for one contributor."
  @spec delete_mcu_trunk_attrib(plan_ref(), term()) :: :ok
  def delete_mcu_trunk_attrib(plan_ref, contrib_id) do
    ensure_table!()

    case get_mcu_trunk_attrib(plan_ref, contrib_id) do
      nil ->
        :ok

      trunk_id ->
        true = :ets.delete(@table, {plan_ref, :mcu_trunk_attrib, contrib_id})
        _ = remove_from_trunk_excl(plan_ref, trunk_id, contrib_id)
        :ok
    end
  end

  defp add_to_trunk_excl(plan_ref, trunk_id, contrib_id) do
    set = MapSet.put(get_mcu_trunk_excl(plan_ref, trunk_id), contrib_id)
    true = :ets.insert(@table, {{plan_ref, :mcu_trunk_excl, trunk_id}, set})
    :ok
  end

  defp remove_from_trunk_excl(plan_ref, trunk_id, contrib_id) do
    set = MapSet.delete(get_mcu_trunk_excl(plan_ref, trunk_id), contrib_id)

    if MapSet.size(set) == 0 do
      true = :ets.delete(@table, {plan_ref, :mcu_trunk_excl, trunk_id})
    else
      true = :ets.insert(@table, {{plan_ref, :mcu_trunk_excl, trunk_id}, set})
    end

    :ok
  end

  @doc "Deletes all runtime rows for one participant (leave)."
  @spec clear_participant(plan_ref(), term()) :: :ok
  def clear_participant(plan_ref, participant_id) do
    ensure_table!()

    case get_mcu_egress(plan_ref, participant_id) do
      %{out_ssrc: ssrc} when is_integer(ssrc) ->
        _ = delete_mcu_out_ssrc(plan_ref, ssrc)

      _ ->
        :ok
    end

    true = :ets.delete(@table, {plan_ref, :ext, participant_id})
    true = :ets.delete(@table, {plan_ref, :twcc, participant_id})
    true = :ets.delete(@table, {plan_ref, :audio_level, participant_id})
    true = :ets.delete(@table, {plan_ref, :fir, participant_id})
    true = :ets.delete(@table, {plan_ref, :mcu_bind, participant_id})
    true = :ets.delete(@table, {plan_ref, :mcu_contrib, participant_id})
    true = :ets.delete(@table, {plan_ref, :mcu_egress, participant_id})
    true = :ets.delete(@table, {plan_ref, :mcu_level, participant_id})
    _ = delete_mcu_trunk_attrib(plan_ref, participant_id)

    remb =
      plan_ref
      |> get_remb()
      |> Map.delete(participant_id)
      |> Map.new(fn {pub, by_sub} ->
        {pub, Map.delete(by_sub, participant_id)}
      end)
      |> Enum.reject(fn {_pub, by_sub} -> by_sub == %{} end)
      |> Map.new()

    put_remb(plan_ref, remb)

    mcu_remb =
      plan_ref
      |> get_mcu_remb()
      |> Map.delete(participant_id)

    put_mcu_remb(plan_ref, mcu_remb)

    mcu_twcc =
      plan_ref
      |> get_mcu_twcc()
      |> Map.delete(participant_id)

    put_mcu_twcc(plan_ref, mcu_twcc)

    true = :ets.match_delete(@table, {{plan_ref, :sfu_twcc_bwe, participant_id, :_, :_}, :_})
    true = :ets.match_delete(@table, {{plan_ref, :sfu_twcc_bwe, :_, participant_id, :_}, :_})
    # ponytail: send maps keyed by out_ssrc; leave orphans until plan_ref clear / rewrite reset
    :ok
  end

  @doc "Deletes every runtime row for `plan_ref` (session terminate)."
  @spec clear_plan(plan_ref()) :: :ok
  def clear_plan(plan_ref) do
    ensure_table!()
    true = :ets.match_delete(@table, {{plan_ref, :_, :_, :_, :_}, :_})
    true = :ets.match_delete(@table, {{plan_ref, :_, :_, :_}, :_})
    true = :ets.match_delete(@table, {{plan_ref, :_, :_}, :_})
    true = :ets.match_delete(@table, {{plan_ref, :_}, :_})
    :ok
  end
end
