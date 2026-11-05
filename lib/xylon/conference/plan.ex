defmodule Xylon.Conference.Plan do
  @moduledoc """
  ETS subscribe graph and per-route RTP rewrite state for a conference Session.

  ## What problem this solves

  An SFU must remember, for each room: who is publishing which SSRC, who subscribed
  to whom, and how to rewrite RTP headers for each fanout leg. This module stores
  that graph in a shared ETS table keyed by `plan_ref` (normally the Session pid
  so Session and Forwarder share one graph). `routes_for_inbound/3` caches active
  route lists per `{publisher_id, in_ssrc}` and invalidates on subscribe-graph
  mutations (subscribe/unsubscribe, pause/resume/`set_send`, layer/track changes,
  and subscriber `peer_ref` updates via `put_participant/2`). Cache hits hydrate
  **rewrite state only** (`get_rewrite`); they must not re-read `sending?` or
  destination rows -- invalidate is the source of truth for those. Hot-path
  `put_rewrite/3` / `put_rewrites/2` do not invalidate the route list cache.

  Tracks and subscriptions are keyed by SDP media id (`mid`), not by kind alone,
  so multiple video m-lines or renegotiation stay distinct.

  **Internal:** application code should use `Xylon.Conference` or Session APIs.
  Direct `Plan` calls are for tests and backend internals.

  ## RFCs

  - [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) (RTP SSRC, sequence, timestamp rewrite state)
  - [RFC 5888](https://www.rfc-editor.org/rfc/rfc5888) (SDP mid)
  - No STUN/TURN RFC; room subscribe graph only
  """

  alias Xylon.Participant

  @table :xylon_conference_plan

  @typedoc """
  Scope key for one conference room's plan rows.

  Prefer the Session pid; a reference is accepted for isolated tests.
  """
  @type plan_ref :: pid() | reference()

  @typedoc "SDP media identification tag (`a=mid:`)."
  @type mid :: binary()

  @typedoc "Published track media kind (`:audio` or `:video`)."
  @type kind :: :audio | :video

  @typedoc """
  Forward destination type.

  - `:peer` -- another participant in the same Session
  - `:trunk` -- cascade-ready peer-like destination (same byte path as `:peer` on
    a single node; multi-node trunk protocol is separate)
  - `:record` -- live layout composite sink (Phase 8; no Peer / ICE)
  """
  @type dest_type :: :peer | :trunk | :record

  @typedoc """
  Where RTP for one subscription is delivered.

  ## Fields

  - `:type` -- `:peer`, `:trunk`, or `:record`
  - `:participant` -- subscriber `%Xylon.Participant{}` (includes `peer_ref` for
    `:peer` / `:trunk`; may be nil peer_ref for `:record`)
  """
  @type destination :: %{
          type: dest_type(),
          participant: Participant.t()
        }

  @typedoc """
  Per-route RTP header rewrite state (see `Xylon.Conference.Rewrite`).

  ## Fields

  - `:out_ssrc` -- SSRC written on packets to this subscriber
  - `:last_in_seq` -- last publisher sequence number seen
  - `:last_out_seq` -- last rewritten sequence number sent
  - `:last_in_ts` -- last publisher RTP timestamp seen
  - `:last_out_ts` -- last rewritten timestamp sent
  """
  @type rewrite_state :: %{
          out_ssrc: non_neg_integer(),
          last_in_seq: non_neg_integer() | nil,
          last_out_seq: non_neg_integer() | nil,
          last_in_ts: non_neg_integer() | nil,
          last_out_ts: non_neg_integer() | nil
        }

  @typedoc """
  One fanout route built for an inbound RTP packet.

  ## Fields

  - `:subscriber_id` -- participant receiving the rewritten packet
  - `:publisher_id` -- participant who sent the inbound packet
  - `:mid` -- SDP media id for this route
  - `:kind` -- `:audio` or `:video` (from the published track)
  - `:codec` -- optional codec name from the published track
  - `:max_temporal` -- max VP8 TID to forward, or `nil` for no filter
  - `:max_spatial` -- max VP9/AV1 SVC spatial layer, or `nil`
  - `:max_temporal_layer` -- max VP9/AV1 SVC temporal layer, or `nil`
  - `:destination` -- subscriber destination map
  - `:rewrite_key` -- `{publisher_id, mid, subscriber_id}` tuple for `put_rewrite/3`
  - `:rewrite` -- current rewrite state for this route
  """
  @type route :: %{
          subscriber_id: term(),
          publisher_id: term(),
          mid: mid(),
          kind: kind(),
          codec: String.t() | nil,
          max_temporal: non_neg_integer() | nil,
          max_spatial: non_neg_integer() | nil,
          max_temporal_layer: non_neg_integer() | nil,
          destination: destination(),
          rewrite_key: term(),
          rewrite: rewrite_state()
        }

  @doc """
  Ensures the named ETS table (`:xylon_conference_plan`) exists.

  Idempotent; safe to call before any other function in this module.
  """
  @spec ensure_table!() :: :ok
  def ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        _ =
          :ets.new(@table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])

        :ok

      _tid ->
        :ok
    end
  end

  @doc """
  Creates or reuses a plan scoped by `plan_ref`.

  Returns `plan_ref`. When the meta row already exists, no-op.
  """
  @spec new(plan_ref()) :: plan_ref()
  def new(plan_ref) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :meta}) do
      [] ->
        true =
          :ets.insert(@table, {{plan_ref, :meta}, %{participants: MapSet.new()}})

        plan_ref

      [_] ->
        plan_ref
    end
  end

  @doc """
  Drops all ETS rows for `plan_ref` (tracks, subscriptions, rewrite, meta).

  Called from backend `terminate/2` when the Session ends.
  """
  @spec delete(plan_ref()) :: :ok
  def delete(plan_ref) do
    ensure_table!()
    :ets.match_delete(@table, {{plan_ref, :_}, :_})
    :ets.match_delete(@table, {{plan_ref, :_, :_}, :_})
    :ets.match_delete(@table, {{plan_ref, :_, :_, :_}, :_})
    :ets.match_delete(@table, {{plan_ref, :_, :_, :_, :_}, :_})
    _ = Xylon.Conference.NackCache.clear_plan(plan_ref)
    :ok
  end

  @doc """
  Stores a participant in the plan.

  `peer_ref` on the `%Xylon.Participant{}` is required for forward destinations.
  When an existing subscriber's `peer_ref` changes, destination rows and inbound
  route caches for every publisher they subscribe to are refreshed/invalidated
  so lean fanout hydrate does not keep a stale peer.
  """
  @spec put_participant(plan_ref(), Participant.t()) :: :ok
  def put_participant(plan_ref, %Participant{id: id} = participant) do
    ensure_table!()
    meta = get_meta(plan_ref)
    participants = MapSet.put(meta.participants, id)
    true = :ets.insert(@table, {{plan_ref, :meta}, %{meta | participants: participants}})
    true = :ets.insert(@table, {{plan_ref, :participant, id}, participant})
    _ = refresh_subscriber_destinations(plan_ref, id, participant)
    _ = invalidate_route_cache(plan_ref, id)
    :ok
  end

  @doc """
  Removes a participant and all related plan rows.

  Deletes published tracks, subscriptions where they are publisher or subscriber,
  rewrite/dest/send/layer rows, and removes them from other publishers' subscriber sets.
  """
  @spec delete_participant(plan_ref(), term()) :: :ok
  def delete_participant(plan_ref, participant_id) do
    ensure_table!()
    meta = get_meta(plan_ref)
    participants = MapSet.delete(meta.participants, participant_id)
    true = :ets.insert(@table, {{plan_ref, :meta}, %{meta | participants: participants}})
    true = :ets.delete(@table, {plan_ref, :participant, participant_id})

    :ets.match_delete(@table, {{plan_ref, :track, participant_id, :_}, :_})
    :ets.match_delete(@table, {{plan_ref, :subscribers, participant_id, :_}, :_})
    :ets.match_delete(@table, {{plan_ref, :rewrite, participant_id, :_, :_}, :_})
    :ets.match_delete(@table, {{plan_ref, :rewrite, :_, :_, participant_id}, :_})
    :ets.match_delete(@table, {{plan_ref, :dest, participant_id, :_, :_}, :_})
    :ets.match_delete(@table, {{plan_ref, :dest, :_, :_, participant_id}, :_})
    :ets.match_delete(@table, {{plan_ref, :send, participant_id, :_, :_}, :_})
    :ets.match_delete(@table, {{plan_ref, :send, :_, :_, participant_id}, :_})
    :ets.match_delete(@table, {{plan_ref, :layer, participant_id, :_, :_}, :_})
    :ets.match_delete(@table, {{plan_ref, :layer, :_, :_, participant_id}, :_})
    :ets.match_delete(@table, {{plan_ref, :temporal, participant_id, :_, :_}, :_})
    :ets.match_delete(@table, {{plan_ref, :temporal, :_, :_, participant_id}, :_})
    :ets.match_delete(@table, {{plan_ref, :spatial_layer, participant_id, :_, :_}, :_})
    :ets.match_delete(@table, {{plan_ref, :spatial_layer, :_, :_, participant_id}, :_})
    :ets.match_delete(@table, {{plan_ref, :temporal_layer, participant_id, :_, :_}, :_})
    :ets.match_delete(@table, {{plan_ref, :temporal_layer, :_, :_, participant_id}, :_})
    :ets.match_delete(@table, {{plan_ref, :dd_chain, participant_id, :_, :_}, :_})
    :ets.match_delete(@table, {{plan_ref, :dd_chain, :_, :_, participant_id}, :_})
    :ets.match_delete(@table, {{plan_ref, :dd_structure, participant_id, :_}, :_})
    :ets.match_delete(@table, {{plan_ref, :layer_policy, participant_id, :_, :_}, :_})
    :ets.match_delete(@table, {{plan_ref, :layer_policy, :_, :_, participant_id}, :_})
    _ = invalidate_route_cache(plan_ref, participant_id)

    # Drop this id from other publishers' subscriber lists.
    Enum.each(:ets.match(@table, {{plan_ref, :subscribers, :"$1", :"$2"}, :"$3"}), fn [
                                                                                       pub,
                                                                                       mid,
                                                                                       set
                                                                                     ] ->
      if MapSet.member?(set, participant_id) do
        true =
          :ets.insert(
            @table,
            {{plan_ref, :subscribers, pub, mid}, MapSet.delete(set, participant_id)}
          )

        true = :ets.delete(@table, {plan_ref, :rewrite, pub, mid, participant_id})
        true = :ets.delete(@table, {plan_ref, :dest, pub, mid, participant_id})
        true = :ets.delete(@table, {plan_ref, :send, pub, mid, participant_id})
        true = :ets.delete(@table, {plan_ref, :layer, pub, mid, participant_id})
        true = :ets.delete(@table, {plan_ref, :temporal, pub, mid, participant_id})
        true = :ets.delete(@table, {plan_ref, :spatial_layer, pub, mid, participant_id})
        true = :ets.delete(@table, {plan_ref, :temporal_layer, pub, mid, participant_id})
        true = :ets.delete(@table, {plan_ref, :dd_chain, pub, mid, participant_id})
        true = :ets.delete(@table, {plan_ref, :layer_policy, pub, mid, participant_id})
        _ = invalidate_route_cache(plan_ref, pub)
      end
    end)

    :ok
  end

  @doc """
  Returns the stored `%Xylon.Participant{}` for `participant_id`, or `nil`.
  """
  @spec get_participant(plan_ref(), term()) :: Participant.t() | nil
  def get_participant(plan_ref, participant_id) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :participant, participant_id}) do
      [{_, %Participant{} = p}] -> p
      _ -> nil
    end
  end

  @doc """
  Registers a published track.

  `track` keys: `:mid` (nonempty binary), `:kind` (`:audio` | `:video`), `:ssrc`
  (inbound; `0` = unbound pending first RTP), optional `:codec`, `:layers`.
  """
  @spec put_track(plan_ref(), term(), map()) :: :ok | {:error, term()}
  def put_track(plan_ref, publisher_id, track) when is_map(track) do
    ensure_table!()
    mid = Map.fetch!(track, :mid)
    kind = Map.fetch!(track, :kind)
    ssrc = Map.fetch!(track, :ssrc)

    if is_binary(mid) and mid != "" and kind in [:audio, :video] and is_integer(ssrc) do
      entry = %{mid: mid, kind: kind, ssrc: ssrc}

      entry =
        case Map.get(track, :codec) do
          codec when is_binary(codec) and codec != "" -> Map.put(entry, :codec, codec)
          _ -> entry
        end

      entry =
        case Map.get(track, :layers) do
          layers when is_list(layers) and layers != [] -> Map.put(entry, :layers, layers)
          _ -> entry
        end

      true = :ets.insert(@table, {{plan_ref, :track, publisher_id, mid}, entry})

      case :ets.lookup(@table, {plan_ref, :subscribers, publisher_id, mid}) do
        [] ->
          true =
            :ets.insert(@table, {{plan_ref, :subscribers, publisher_id, mid}, MapSet.new()})

        _ ->
          :ok
      end

      _ = invalidate_route_cache(plan_ref, publisher_id)
      :ok
    else
      {:error, :invalid_track}
    end
  end

  @doc """
  Looks up a published track map for `publisher_id` and `mid`.

  Returns `nil` when nothing is published for that mid.
  """
  @spec get_track(plan_ref(), term(), mid()) :: map() | nil
  def get_track(plan_ref, publisher_id, mid) when is_binary(mid) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :track, publisher_id, mid}) do
      [{_, track}] -> track
      _ -> nil
    end
  end

  @doc """
  Binds a real inbound SSRC onto an unbound track (`ssrc: 0`) and retargets
  subscriber layer keys that still pointed at `0`.

  Used when Chrome RID/`a=simulcast` offers omit `a=ssrc:` until media flows.
  Idempotent when the track already has `ssrc`. Returns `{:error, :not_unbound}`
  when the mid is missing or already bound to a different SSRC.
  """
  @spec bind_track_ssrc(plan_ref(), term(), mid(), non_neg_integer()) ::
          :ok | {:error, term()}
  def bind_track_ssrc(plan_ref, publisher_id, mid, ssrc)
      when is_binary(mid) and mid != "" and is_integer(ssrc) and ssrc > 0 do
    ensure_table!()

    case get_track(plan_ref, publisher_id, mid) do
      %{ssrc: ^ssrc} ->
        :ok

      %{ssrc: 0} = track ->
        true = :ets.insert(@table, {{plan_ref, :track, publisher_id, mid}, %{track | ssrc: ssrc}})

        for subscriber_id <- MapSet.to_list(subscribers(plan_ref, publisher_id, mid)) do
          case :ets.lookup(@table, {plan_ref, :layer, publisher_id, mid, subscriber_id}) do
            [{_, 0}] ->
              true =
                :ets.insert(
                  @table,
                  {{plan_ref, :layer, publisher_id, mid, subscriber_id}, ssrc}
                )

              :ok

            _ ->
              :ok
          end
        end

        _ = invalidate_route_cache(plan_ref, publisher_id)
        :ok

      nil ->
        {:error, :no_track}

      _ ->
        {:error, :not_unbound}
    end
  end

  @doc """
  Returns the first published track for `publisher_id` with unbound `ssrc: 0`,
  or `nil`.
  """
  @spec find_unbound_track(plan_ref(), term()) :: map() | nil
  def find_unbound_track(plan_ref, publisher_id) do
    ensure_table!()

    Enum.find(tracks_for(plan_ref, publisher_id), fn
      %{ssrc: 0} -> true
      _ -> false
    end)
  end

  @doc """
  Learns a simulcast layer SSRC from an inbound RID (`rtp-stream-id`) mapping.

  Updates the matching `layers` entry. When the track is still unbound
  (`ssrc: 0`), also binds the primary track SSRC and retargets subscriber
  `:layer` keys that pointed at `0`. Unlearned rids keep `ssrc: 0`;
  `set_substream(rid:)` / non-primary `substream` returns `:no_layer` until
  that rid is learned (so subscribers cannot select an unbound layer early).

  Idempotent when the rid already maps to `ssrc`. Returns `{:error, :no_layer}`
  when the mid has no matching rid in `layers`.
  """
  @spec learn_layer_ssrc(plan_ref(), term(), mid(), binary(), non_neg_integer()) ::
          :ok | {:error, term()}
  def learn_layer_ssrc(plan_ref, publisher_id, mid, rid, ssrc)
      when is_binary(mid) and mid != "" and is_binary(rid) and rid != "" and is_integer(ssrc) and
             ssrc > 0 do
    ensure_table!()

    case get_track(plan_ref, publisher_id, mid) do
      nil ->
        {:error, :no_track}

      track ->
        layers = Map.get(track, :layers)

        case find_layer_by_rid(layers, rid) do
          nil ->
            {:error, :no_layer}

          %{ssrc: ^ssrc} ->
            maybe_bind_primary_from_learn(plan_ref, publisher_id, mid, track, ssrc)

          %{ssrc: prev} when prev > 0 and prev != ssrc ->
            {:error, :ssrc_conflict}

          layer ->
            new_layers =
              Enum.map(layers, fn
                %{rid: ^rid} = l -> %{l | ssrc: ssrc}
                other -> other
              end)

            updated = %{track | layers: new_layers}

            updated =
              if Map.get(updated, :ssrc, 0) == 0 do
                %{updated | ssrc: ssrc}
              else
                updated
              end

            true = :ets.insert(@table, {{plan_ref, :track, publisher_id, mid}, updated})
            retarget_layer_keys(plan_ref, publisher_id, mid, layer, ssrc, Map.get(track, :ssrc, 0))
            _ = invalidate_route_cache(plan_ref, publisher_id)
            :ok
        end
    end
  end

  defp maybe_bind_primary_from_learn(plan_ref, publisher_id, mid, %{ssrc: 0}, ssrc) do
    bind_track_ssrc(plan_ref, publisher_id, mid, ssrc)
  end

  defp maybe_bind_primary_from_learn(_, _, _, _, _), do: :ok

  defp retarget_layer_keys(plan_ref, publisher_id, mid, _layer, ssrc, 0) do
    # First RID learn also binds primary; retarget default subscribers still on 0.
    for subscriber_id <- MapSet.to_list(subscribers(plan_ref, publisher_id, mid)) do
      key = {plan_ref, :layer, publisher_id, mid, subscriber_id}

      case :ets.lookup(@table, key) do
        [{_, 0}] ->
          true = :ets.insert(@table, {key, ssrc})
          :ok

        _ ->
          :ok
      end
    end

    _ = invalidate_route_cache(plan_ref, publisher_id)
    :ok
  end

  defp retarget_layer_keys(_plan_ref, _publisher_id, _mid, _layer, _ssrc, _prev_primary),
    do: :ok

  @doc """
  Returns all published track maps for `publisher_id`.
  """
  @spec tracks_for(plan_ref(), term()) :: [map()]
  def tracks_for(plan_ref, publisher_id) do
    ensure_table!()

    :ets.match(@table, {{plan_ref, :track, publisher_id, :"$1"}, :"$2"})
    |> Enum.map(fn [mid, track] -> Map.put(track, :mid, mid) end)
  end

  @doc """
  Returns mids with a published track for `publisher_id`.
  """
  @spec published_mids(plan_ref(), term()) :: [mid()]
  def published_mids(plan_ref, publisher_id) do
    ensure_table!()

    :ets.match(@table, {{plan_ref, :track, publisher_id, :"$1"}, :_})
    |> Enum.map(fn [mid] -> mid end)
  end

  @doc """
  Finds the first published track for `publisher_id` with the given `kind`.

  Used by RTCP and audio paths that only know media kind, not mid.
  Returns `nil` when no track matches.
  """
  @spec find_track_by_kind(plan_ref(), term(), kind()) :: map() | nil
  def find_track_by_kind(plan_ref, publisher_id, kind) when kind in [:audio, :video] do
    plan_ref
    |> tracks_for(publisher_id)
    |> Enum.sort_by(& &1.mid)
    |> Enum.find(fn track -> track.kind == kind end)
  end

  @doc """
  Subscribes `subscriber_id` to `publisher_id`'s track identified by `mid`.

  Destination defaults to `:peer` using the stored subscriber Participant.
  """
  @spec subscribe(plan_ref(), term(), term(), mid(), keyword()) :: :ok | {:error, term()}
  def subscribe(plan_ref, subscriber_id, publisher_id, mid, opts \\ [])
      when is_binary(mid) and mid != "" do
    ensure_table!()

    cond do
      is_nil(get_track(plan_ref, publisher_id, mid)) ->
        {:error, :no_track}

      is_nil(get_participant(plan_ref, subscriber_id)) ->
        {:error, :no_subscriber}

      true ->
        %Participant{} = sub = get_participant(plan_ref, subscriber_id)
        dest_type = Keyword.get(opts, :dest_type, :peer)

        with {:ok, in_ssrc} <- resolve_layer_ssrc(plan_ref, publisher_id, mid, opts) do
          destination = %{
            type: dest_type,
            participant: sub
          }

          true =
            :ets.insert(
              @table,
              {{plan_ref, :dest, publisher_id, mid, subscriber_id}, destination}
            )

          set = subscribers(plan_ref, publisher_id, mid)

          true =
            :ets.insert(
              @table,
              {{plan_ref, :subscribers, publisher_id, mid}, MapSet.put(set, subscriber_id)}
            )

          prev_layer =
            case :ets.lookup(@table, {plan_ref, :layer, publisher_id, mid, subscriber_id}) do
              [{_, ssrc}] when is_integer(ssrc) -> ssrc
              _ -> nil
            end

          true =
            :ets.insert(
              @table,
              {{plan_ref, :layer, publisher_id, mid, subscriber_id}, in_ssrc}
            )

          case :ets.lookup(@table, {plan_ref, :rewrite, publisher_id, mid, subscriber_id}) do
            [] ->
              insert_fresh_rewrite(plan_ref, publisher_id, mid, subscriber_id, in_ssrc)

            [_] when prev_layer == in_ssrc ->
              :ok

            [_] ->
              reset_rewrite_state(plan_ref, publisher_id, mid, subscriber_id)
          end

          put_temporal(plan_ref, publisher_id, mid, subscriber_id, opts)
          put_svc_layers(plan_ref, publisher_id, mid, subscriber_id, opts)
          put_layer_policy_on_subscribe(plan_ref, publisher_id, mid, subscriber_id, opts)

          true =
            :ets.insert(
              @table,
              {{plan_ref, :send, publisher_id, mid, subscriber_id}, true}
            )

          _ = invalidate_route_cache(plan_ref, publisher_id)
          :ok
        end
    end
  end

  @doc """
  Sets whether RTP is forwarded for a subscription (`send: false` pauses).

  Keeps dest + rewrite state. Missing subscription returns `{:error, :no_route}`.
  """
  @spec set_send(plan_ref(), term(), term(), mid(), boolean()) :: :ok | {:error, term()}
  def set_send(plan_ref, subscriber_id, publisher_id, mid, send?)
      when is_binary(mid) and mid != "" and is_boolean(send?) do
    ensure_table!()

    cond do
      is_nil(get_rewrite(plan_ref, publisher_id, mid, subscriber_id)) ->
        {:error, :no_route}

      true ->
        true =
          :ets.insert(
            @table,
            {{plan_ref, :send, publisher_id, mid, subscriber_id}, send?}
          )

        _ = invalidate_route_cache(plan_ref, publisher_id)
        :ok
    end
  end

  @doc """
  Pauses forwarding for a subscription (`send: false`).

  Keeps destination and rewrite rows; see also `set_send/5`.
  """
  @spec pause(plan_ref(), term(), term(), mid()) :: :ok | {:error, term()}
  def pause(plan_ref, subscriber_id, publisher_id, mid) when is_binary(mid) and mid != "" do
    set_send(plan_ref, subscriber_id, publisher_id, mid, false)
  end

  @doc """
  Resumes forwarding for a paused subscription (`send: true`).
  """
  @spec resume(plan_ref(), term(), term(), mid()) :: :ok | {:error, term()}
  def resume(plan_ref, subscriber_id, publisher_id, mid) when is_binary(mid) and mid != "" do
    set_send(plan_ref, subscriber_id, publisher_id, mid, true)
  end

  @doc """
  Removes a published track and all outbound routes for that mid.

  Clears NACK cache entries for each route's outbound SSRC. Does not remove the
  participant or their subscriptions to other publishers. Idempotent when the
  track is already absent. Always returns `:ok`.
  """
  @spec delete_track(plan_ref(), term(), mid()) :: :ok
  def delete_track(plan_ref, publisher_id, mid) when is_binary(mid) and mid != "" do
    ensure_table!()

    Enum.each(MapSet.to_list(subscribers(plan_ref, publisher_id, mid)), fn subscriber_id ->
      case get_rewrite(plan_ref, publisher_id, mid, subscriber_id) do
        %{out_ssrc: out_ssrc} when is_integer(out_ssrc) ->
          _ = Xylon.Conference.NackCache.clear_ssrc(plan_ref, out_ssrc)

        _ ->
          :ok
      end

      true = :ets.delete(@table, {plan_ref, :dest, publisher_id, mid, subscriber_id})
      true = :ets.delete(@table, {plan_ref, :rewrite, publisher_id, mid, subscriber_id})
      true = :ets.delete(@table, {plan_ref, :send, publisher_id, mid, subscriber_id})
      true = :ets.delete(@table, {plan_ref, :layer, publisher_id, mid, subscriber_id})
      true = :ets.delete(@table, {plan_ref, :temporal, publisher_id, mid, subscriber_id})
      true = :ets.delete(@table, {plan_ref, :spatial_layer, publisher_id, mid, subscriber_id})
      true = :ets.delete(@table, {plan_ref, :temporal_layer, publisher_id, mid, subscriber_id})
      true = :ets.delete(@table, {plan_ref, :dd_chain, publisher_id, mid, subscriber_id})
      true = :ets.delete(@table, {plan_ref, :layer_policy, publisher_id, mid, subscriber_id})
    end)

    true = :ets.delete(@table, {plan_ref, :track, publisher_id, mid})
    true = :ets.delete(@table, {plan_ref, :subscribers, publisher_id, mid})
    true = :ets.delete(@table, {plan_ref, :dd_structure, publisher_id, mid})
    _ = invalidate_route_cache(plan_ref, publisher_id)
    :ok
  end

  @doc """
  Removes a subscription between `subscriber_id` and `publisher_id` for `mid`.

  Deletes dest, rewrite, send, and layer rows for that pair. Always returns `:ok`.
  """
  @spec unsubscribe(plan_ref(), term(), term(), mid()) :: :ok
  def unsubscribe(plan_ref, subscriber_id, publisher_id, mid)
      when is_binary(mid) and mid != "" do
    ensure_table!()

    case get_rewrite(plan_ref, publisher_id, mid, subscriber_id) do
      %{out_ssrc: out_ssrc} when is_integer(out_ssrc) ->
        _ = Xylon.Conference.NackCache.clear_ssrc(plan_ref, out_ssrc)

      _ ->
        :ok
    end

    set = subscribers(plan_ref, publisher_id, mid)

    true =
      :ets.insert(
        @table,
        {{plan_ref, :subscribers, publisher_id, mid}, MapSet.delete(set, subscriber_id)}
      )

    true = :ets.delete(@table, {plan_ref, :dest, publisher_id, mid, subscriber_id})
    true = :ets.delete(@table, {plan_ref, :rewrite, publisher_id, mid, subscriber_id})
    true = :ets.delete(@table, {plan_ref, :send, publisher_id, mid, subscriber_id})
    true = :ets.delete(@table, {plan_ref, :layer, publisher_id, mid, subscriber_id})
    true = :ets.delete(@table, {plan_ref, :temporal, publisher_id, mid, subscriber_id})
    true = :ets.delete(@table, {plan_ref, :spatial_layer, publisher_id, mid, subscriber_id})
    true = :ets.delete(@table, {plan_ref, :temporal_layer, publisher_id, mid, subscriber_id})
    true = :ets.delete(@table, {plan_ref, :dd_chain, publisher_id, mid, subscriber_id})
    true = :ets.delete(@table, {plan_ref, :layer_policy, publisher_id, mid, subscriber_id})
    _ = invalidate_route_cache(plan_ref, publisher_id)
    :ok
  end

  @doc """
  Changes SIM / SVC layer opts for a subscription.

  `opts` may include `:substream`, `:rid`, `:temporal`, `:spatial_layer`, and/or
  `:temporal_layer`. When `:substream` / `:rid` are omitted, the current layer
  SSRC is kept (temporal / SVC-layer-only updates). When the inbound SSRC
  changes, rewrite seq/ts state is reset but the subscriber `out_ssrc` is kept
  (so REMB / NACK keep naming the same SSRC). Returns `{:error, :no_layer}`
  when the track has no matching layer.
  """
  @spec set_substream(plan_ref(), term(), term(), mid(), keyword()) ::
          :ok | {:error, term()}
  def set_substream(plan_ref, subscriber_id, publisher_id, mid, opts)
      when is_binary(mid) and mid != "" and is_list(opts) do
    ensure_table!()

    cond do
      is_nil(get_rewrite(plan_ref, publisher_id, mid, subscriber_id)) ->
        {:error, :no_route}

      true ->
        with {:ok, in_ssrc} <-
               resolve_layer_ssrc_for_update(plan_ref, publisher_id, mid, subscriber_id, opts) do
          send? = sending?(plan_ref, publisher_id, mid, subscriber_id)
          prev = route_in_ssrc(plan_ref, publisher_id, mid, subscriber_id, get_track(plan_ref, publisher_id, mid))

          if prev != in_ssrc do
            reset_rewrite_state(plan_ref, publisher_id, mid, subscriber_id)
          end

          true =
            :ets.insert(
              @table,
              {{plan_ref, :layer, publisher_id, mid, subscriber_id}, in_ssrc}
            )

          put_temporal(plan_ref, publisher_id, mid, subscriber_id, opts)
          put_svc_layers(plan_ref, publisher_id, mid, subscriber_id, opts)

          true =
            :ets.insert(
              @table,
              {{plan_ref, :send, publisher_id, mid, subscriber_id}, send?}
            )

          _ = invalidate_route_cache(plan_ref, publisher_id)
          :ok
        end
    end
  end

  @doc """
  Rebinds `subscriber_id` from `from_publisher_id` to `to_publisher_id` for `mid`.

  `mid` is the subscriber's current route mid on `from_publisher_id`. The new
  subscription uses the same mid on `to_publisher_id` when that track exists;
  otherwise the first track on `to_publisher_id` with the same kind as the
  from-track. Recreates dest + fresh rewrite (does not move old rewrite).
  Preserves pause (`send: false`) if the old route was paused.
  Rejects when both tracks have codecs and they differ.
  """
  @spec switch(plan_ref(), term(), term(), term(), mid(), keyword()) ::
          :ok | {:error, term()}
  def switch(plan_ref, subscriber_id, from_publisher_id, to_publisher_id, mid, opts \\ [])
      when is_binary(mid) and mid != "" do
    ensure_table!()

    cond do
      from_publisher_id == to_publisher_id ->
        :ok

      is_nil(get_rewrite(plan_ref, from_publisher_id, mid, subscriber_id)) ->
        {:error, :no_route}

      is_nil(get_track(plan_ref, from_publisher_id, mid)) ->
        {:error, :no_route}

      true ->
        from_track = get_track(plan_ref, from_publisher_id, mid)
        to_mid = resolve_switch_mid(plan_ref, to_publisher_id, mid, from_track)

        cond do
          is_nil(to_mid) ->
            {:error, :no_track}

          codec_mismatch?(from_track, get_track(plan_ref, to_publisher_id, to_mid)) ->
            {:error, :codec_mismatch}

          true ->
            send? = sending?(plan_ref, from_publisher_id, mid, subscriber_id)
            dest_type = Keyword.get(opts, :dest_type, :peer)
            :ok = unsubscribe(plan_ref, subscriber_id, from_publisher_id, mid)

            case subscribe(plan_ref, subscriber_id, to_publisher_id, to_mid,
                   dest_type: dest_type
                 ) do
              :ok ->
                if send?, do: :ok, else: set_send(plan_ref, subscriber_id, to_publisher_id, to_mid, false)

              {:error, _} = err ->
                err
            end
        end
    end
  end

  @doc """
  Returns the publisher id this subscriber is subscribed to for `mid`.

  Returns `{:ok, publisher_id}` or `:error` when no route exists.
  """
  @spec subscribed_publisher(plan_ref(), term(), mid()) :: {:ok, term()} | :error
  def subscribed_publisher(plan_ref, subscriber_id, mid) when is_binary(mid) and mid != "" do
    ensure_table!()

    case :ets.match(@table, {{plan_ref, :rewrite, :"$1", mid, subscriber_id}, :_}) do
      [[pub] | _] -> {:ok, pub}
      _ -> :error
    end
  end

  @doc """
  Sets send for every subscriber of `publisher_id`'s listed mids (publisher outbound mute).
  """
  @spec set_send_for_publisher(plan_ref(), term(), [mid()], boolean()) :: :ok
  def set_send_for_publisher(plan_ref, publisher_id, mids, send?)
      when is_list(mids) and mids != [] and is_boolean(send?) do
    ensure_table!()

    for mid <- mids,
        is_binary(mid) and mid != "",
        sub <- MapSet.to_list(subscribers(plan_ref, publisher_id, mid)) do
      _ = set_send(plan_ref, sub, publisher_id, mid, send?)
    end

    :ok
  end

  @doc """
  Returns a `MapSet` of subscriber ids for `publisher_id`'s track at `mid`.

  Empty set when no subscribers or no published track.
  """
  @spec subscribers(plan_ref(), term(), mid()) :: MapSet.t()
  def subscribers(plan_ref, publisher_id, mid) when is_binary(mid) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :subscribers, publisher_id, mid}) do
      [{_, set}] -> set
      _ -> MapSet.new()
    end
  end

  @doc """
  Builds forward routes for an inbound packet from `publisher_id` with `in_ssrc`.

  Returns `:peer`, `:trunk`, and `:record` destinations that are actively sending.

  Route lists are cached per `{publisher_id, in_ssrc}` and invalidated when the
  subscribe graph, send flags, layers, tracks, or subscriber `peer_ref` change.
  Live rewrite state is always read from ETS on each call (hot-path
  `put_rewrite/3` / `put_rewrites/2` do not invalidate). Destination and send
  flags are taken from the cache built at invalidate time (invalidate is source
  of truth for lean hydrate).
  """
  @spec routes_for_inbound(plan_ref(), term(), non_neg_integer() | nil) :: [route()]
  def routes_for_inbound(_plan_ref, _publisher_id, nil), do: []

  def routes_for_inbound(plan_ref, publisher_id, in_ssrc) when is_integer(in_ssrc) do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :route_cache, publisher_id, in_ssrc}) do
      [{_, routes}] when is_list(routes) ->
        hydrate_cached_routes(plan_ref, routes)

      _ ->
        routes = build_routes_for_inbound(plan_ref, publisher_id, in_ssrc)
        cached = Enum.map(routes, &Map.delete(&1, :rewrite))
        true = :ets.insert(@table, {{plan_ref, :route_cache, publisher_id, in_ssrc}, cached})
        routes
    end
  end

  @doc """
  Returns the stored SVC spatial_layer cap for a subscription, or `nil`.
  """
  @spec spatial_layer(plan_ref(), term(), mid(), term()) :: non_neg_integer() | nil
  def spatial_layer(plan_ref, publisher_id, mid, subscriber_id)
      when is_binary(mid) and mid != "" do
    ensure_table!()
    max_spatial(plan_ref, publisher_id, mid, subscriber_id)
  end

  @doc """
  Returns the AV1 DD chain state for a subscription, or a fresh chain when absent.
  """
  @spec get_dd_chain(plan_ref(), term(), mid(), term()) :: Xylon.Conference.Av1Svc.chain()
  def get_dd_chain(plan_ref, publisher_id, mid, subscriber_id)
      when is_binary(mid) and mid != "" do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :dd_chain, publisher_id, mid, subscriber_id}) do
      [{_, chain}] when is_map(chain) -> chain
      _ -> Xylon.Conference.Av1Svc.new_chain()
    end
  end

  @doc """
  Stores AV1 DD chain state for a subscription.
  """
  @spec put_dd_chain(plan_ref(), term(), mid(), term(), Xylon.Conference.Av1Svc.chain()) :: :ok
  def put_dd_chain(plan_ref, publisher_id, mid, subscriber_id, chain)
      when is_binary(mid) and mid != "" and is_map(chain) do
    ensure_table!()

    true =
      :ets.insert(
        @table,
        {{plan_ref, :dd_chain, publisher_id, mid, subscriber_id}, chain}
      )

    :ok
  end

  @doc """
  Clears AV1 DD chain state for a subscription (fresh chain).
  """
  @spec clear_dd_chain(plan_ref(), term(), mid(), term()) :: :ok
  def clear_dd_chain(plan_ref, publisher_id, mid, subscriber_id)
      when is_binary(mid) and mid != "" do
    put_dd_chain(plan_ref, publisher_id, mid, subscriber_id, Xylon.Conference.Av1Svc.new_chain())
  end

  @doc """
  Returns cached Chrome DD structure for a published mid, or `nil`.
  """
  @spec get_dd_structure(plan_ref(), term(), mid()) ::
          XMediaLib.Rtp.DependencyDescriptor.structure() | nil
  def get_dd_structure(plan_ref, publisher_id, mid) when is_binary(mid) and mid != "" do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :dd_structure, publisher_id, mid}) do
      [{_, structure}] when is_map(structure) -> structure
      _ -> nil
    end
  end

  @doc """
  Stores Chrome DD structure for a published mid.
  """
  @spec put_dd_structure(
          plan_ref(),
          term(),
          mid(),
          XMediaLib.Rtp.DependencyDescriptor.structure()
        ) :: :ok
  def put_dd_structure(plan_ref, publisher_id, mid, structure)
      when is_binary(mid) and mid != "" and is_map(structure) do
    ensure_table!()
    true = :ets.insert(@table, {{plan_ref, :dd_structure, publisher_id, mid}, structure})
    :ok
  end

  @doc """
  Deletes cached Chrome DD structure for a published mid.
  """
  @spec clear_dd_structure(plan_ref(), term(), mid()) :: :ok
  def clear_dd_structure(plan_ref, publisher_id, mid) when is_binary(mid) and mid != "" do
    ensure_table!()
    true = :ets.delete(@table, {plan_ref, :dd_structure, publisher_id, mid})
    :ok
  end

  @doc """
  Returns layer policy for a subscription (`:manual` sticky or `:adaptive`).
  """
  @spec get_layer_policy(plan_ref(), term(), mid(), term()) :: Xylon.Conference.Allocator.policy()
  def get_layer_policy(plan_ref, publisher_id, mid, subscriber_id)
      when is_binary(mid) and mid != "" do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :layer_policy, publisher_id, mid, subscriber_id}) do
      [{_, %{source: _} = policy}] -> policy
      _ -> Xylon.Conference.Allocator.new_policy(:adaptive)
    end
  end

  @doc """
  Stores layer policy for a subscription.
  """
  @spec put_layer_policy(
          plan_ref(),
          term(),
          mid(),
          term(),
          Xylon.Conference.Allocator.policy()
        ) :: :ok
  def put_layer_policy(plan_ref, publisher_id, mid, subscriber_id, policy)
      when is_binary(mid) and mid != "" and is_map(policy) do
    ensure_table!()

    true =
      :ets.insert(
        @table,
        {{plan_ref, :layer_policy, publisher_id, mid, subscriber_id}, policy}
      )

    :ok
  end

  @doc """
  Marks the subscription as manual (app configure); clears hysteresis pending.
  """
  @spec mark_layer_manual(plan_ref(), term(), mid(), term()) :: :ok
  def mark_layer_manual(plan_ref, publisher_id, mid, subscriber_id)
      when is_binary(mid) and mid != "" do
    put_layer_policy(
      plan_ref,
      publisher_id,
      mid,
      subscriber_id,
      Xylon.Conference.Allocator.new_policy(:manual)
    )
  end

  @doc """
  Current layer opts for allocator comparison (SIM and/or SVC fields present).
  """
  @spec current_layer_opts(plan_ref(), term(), mid(), term()) :: map()
  def current_layer_opts(plan_ref, publisher_id, mid, subscriber_id)
      when is_binary(mid) and mid != "" do
    ensure_table!()
    track = get_track(plan_ref, publisher_id, mid)

    base =
      case max_temporal(plan_ref, publisher_id, mid, subscriber_id) do
        nil -> %{}
        t -> %{temporal: t}
      end

    base =
      case max_spatial(plan_ref, publisher_id, mid, subscriber_id) do
        nil -> base
        s -> Map.put(base, :spatial_layer, s)
      end

    base =
      case max_temporal_layer(plan_ref, publisher_id, mid, subscriber_id) do
        nil -> base
        t -> Map.put(base, :temporal_layer, t)
      end

    case track do
      %{layers: layers} when is_list(layers) and layers != [] ->
        in_ssrc = route_in_ssrc(plan_ref, publisher_id, mid, subscriber_id, track)

        sub =
          case Enum.find(layers, &(&1.ssrc == in_ssrc)) do
            %{substream: s} when is_integer(s) -> s
            _ -> 0
          end

        Map.put(base, :substream, sub)

      _ ->
        base
    end
  end

  @doc """
  Returns the inbound SSRC selected for a subscription (simulcast layer or primary track).

  Returns `nil` when the publisher has no track for `mid`.
  """
  @spec inbound_ssrc(plan_ref(), term(), mid(), term()) :: non_neg_integer() | nil
  def inbound_ssrc(plan_ref, publisher_id, mid, subscriber_id)
      when is_binary(mid) and mid != "" do
    ensure_table!()

    case get_track(plan_ref, publisher_id, mid) do
      nil -> nil
      track -> route_in_ssrc(plan_ref, publisher_id, mid, subscriber_id, track)
    end
  end

  @doc """
  Persists updated rewrite state after `Xylon.Conference.Rewrite.apply/2`.

  `rewrite_key` is `{publisher_id, mid, subscriber_id}`.
  """
  @spec put_rewrite(plan_ref(), {term(), mid(), term()}, rewrite_state()) :: :ok
  def put_rewrite(plan_ref, {publisher_id, mid, subscriber_id}, rewrite)
      when is_binary(mid) do
    ensure_table!()

    true =
      :ets.insert(@table, {{plan_ref, :rewrite, publisher_id, mid, subscriber_id}, rewrite})

    :ok
  end

  @doc """
  Persists many rewrite states in one flush (end of an inbound fanout packet).

  Each pair is `{rewrite_key, rewrite_state}` with
  `rewrite_key = {publisher_id, mid, subscriber_id}`.
  """
  @spec put_rewrites(plan_ref(), [{{term(), mid(), term()}, rewrite_state()}]) :: :ok
  def put_rewrites(plan_ref, pairs) when is_list(pairs) do
    ensure_table!()

    Enum.each(pairs, fn {{publisher_id, mid, subscriber_id}, rewrite}
                        when is_binary(mid) ->
      true =
        :ets.insert(@table, {{plan_ref, :rewrite, publisher_id, mid, subscriber_id}, rewrite})
    end)

    :ok
  end

  @doc """
  Finds publisher id and mid for an outbound (rewritten) media SSRC.

  Returns `{:ok, publisher_id, mid}` or `:error`.
  """
  @spec publisher_for_out_ssrc(plan_ref(), non_neg_integer()) ::
          {:ok, term(), mid()} | :error
  def publisher_for_out_ssrc(plan_ref, out_ssrc) when is_integer(out_ssrc) do
    ensure_table!()

    case :ets.match(@table, {{plan_ref, :rewrite, :"$1", :"$2", :"$3"}, %{out_ssrc: out_ssrc}}) do
      [[publisher_id, mid, _sub] | _] -> {:ok, publisher_id, mid}
      _ -> :error
    end
  end

  @doc """
  Finds publisher id and mid for an inbound (published) media SSRC.

  Matches primary track SSRC or any layer SSRC. Returns
  `{:ok, publisher_id, mid}` or `:error`.
  """
  @spec publisher_for_in_ssrc(plan_ref(), non_neg_integer()) ::
          {:ok, term(), mid()} | :error
  def publisher_for_in_ssrc(plan_ref, in_ssrc) when is_integer(in_ssrc) do
    ensure_table!()

    case :ets.match(@table, {{plan_ref, :track, :"$1", :"$2"}, %{ssrc: in_ssrc}}) do
      [[publisher_id, mid] | _] ->
        {:ok, publisher_id, mid}

      _ ->
        plan_ref
        |> participant_ids()
        |> MapSet.to_list()
        |> Enum.find_value(:error, fn publisher_id ->
          Enum.find_value(tracks_for(plan_ref, publisher_id), fn track ->
            layers = Map.get(track, :layers, [])

            if Enum.any?(layers, &match?(%{ssrc: ^in_ssrc}, &1)) do
              {:ok, publisher_id, track.mid}
            else
              nil
            end
          end)
        end)
    end
  end

  @doc """
  Returns a `MapSet` of participant ids registered in the plan.
  """
  @spec participant_ids(plan_ref()) :: MapSet.t()
  def participant_ids(plan_ref) do
    ensure_table!()
    get_meta(plan_ref).participants
  end

  @doc """
  Returns publishers that have at least one published track.

  Each entry is `%{id: participant_id, streams: [%{mid: mid, kind: kind, ...}]}`.
  Stream maps include `:codec` when the track has one.
  """
  @spec publishers(plan_ref()) :: [%{id: term(), streams: [map()]}]
  def publishers(plan_ref) do
    ensure_table!()

    plan_ref
    |> participant_ids()
    |> MapSet.to_list()
    |> Enum.flat_map(fn id ->
      streams =
        plan_ref
        |> tracks_for(id)
        |> Enum.sort_by(& &1.mid)
        |> Enum.map(fn track ->
          stream = %{mid: track.mid, kind: track.kind}

          case Map.get(track, :codec) do
            codec when is_binary(codec) and codec != "" -> Map.put(stream, :codec, codec)
            _ -> stream
          end
        end)

      if streams == [], do: [], else: [%{id: id, streams: streams}]
    end)
  end

  defp get_meta(plan_ref) do
    case :ets.lookup(@table, {plan_ref, :meta}) do
      [{_, meta}] -> meta
      [] -> %{participants: MapSet.new()}
    end
  end

  defp get_dest(plan_ref, publisher_id, mid, subscriber_id) do
    case :ets.lookup(@table, {plan_ref, :dest, publisher_id, mid, subscriber_id}) do
      [{_, dest}] -> dest
      _ -> nil
    end
  end

  @doc """
  Returns whether RTP is forwarded for a subscription.

  Missing `:send` row defaults to `true` (active after subscribe).
  """
  @spec sending?(plan_ref(), term(), mid(), term()) :: boolean()
  def sending?(plan_ref, publisher_id, mid, subscriber_id)
      when is_binary(mid) and mid != "" do
    ensure_table!()

    case :ets.lookup(@table, {plan_ref, :send, publisher_id, mid, subscriber_id}) do
      [{_, false}] -> false
      _ -> true
    end
  end

  defp get_rewrite(plan_ref, publisher_id, mid, subscriber_id) do
    case :ets.lookup(@table, {plan_ref, :rewrite, publisher_id, mid, subscriber_id}) do
      [{_, rewrite}] -> rewrite
      _ -> nil
    end
  end

  defp resolve_switch_mid(plan_ref, to_publisher_id, from_mid, from_track) do
    cond do
      get_track(plan_ref, to_publisher_id, from_mid) ->
        from_mid

      true ->
        case find_track_by_kind(plan_ref, to_publisher_id, from_track.kind) do
          %{mid: mid} -> mid
          nil -> nil
        end
    end
  end

  defp codec_mismatch?(from_track, to_track) do
    from_c = track_codec(from_track)
    to_c = track_codec(to_track)
    is_binary(from_c) and is_binary(to_c) and from_c != to_c
  end

  defp track_codec(%{codec: c}) when is_binary(c) and c != "", do: c
  defp track_codec(_), do: nil

  defp route_in_ssrc(plan_ref, publisher_id, mid, subscriber_id, track) do
    case :ets.lookup(@table, {plan_ref, :layer, publisher_id, mid, subscriber_id}) do
      [{_, ssrc}] when is_integer(ssrc) -> ssrc
      _ -> track.ssrc
    end
  end

  defp resolve_layer_ssrc(plan_ref, publisher_id, mid, opts) do
    track = get_track(plan_ref, publisher_id, mid)

    cond do
      is_nil(track) ->
        {:error, :no_track}

      true ->
        layers = Map.get(track, :layers)
        rid = Keyword.get(opts, :rid)
        substream = Keyword.get(opts, :substream)

        cond do
          is_binary(rid) and rid != "" ->
            case find_layer_by_rid(layers, rid) do
              %{ssrc: ssrc} when is_integer(ssrc) and ssrc > 0 -> {:ok, ssrc}
              _ -> {:error, :no_layer}
            end

          true ->
            resolve_by_substream(track, layers, substream)
        end
    end
  end

  defp resolve_layer_ssrc_for_update(plan_ref, publisher_id, mid, subscriber_id, opts) do
    if Keyword.has_key?(opts, :substream) or Keyword.has_key?(opts, :rid) do
      resolve_layer_ssrc(plan_ref, publisher_id, mid, opts)
    else
      case get_track(plan_ref, publisher_id, mid) do
        nil ->
          {:error, :no_track}

        track ->
          {:ok, route_in_ssrc(plan_ref, publisher_id, mid, subscriber_id, track)}
      end
    end
  end

  defp put_temporal(plan_ref, publisher_id, mid, subscriber_id, opts) do
    case Keyword.fetch(opts, :temporal) do
      {:ok, n} when is_integer(n) and n >= 0 ->
        true =
          :ets.insert(
            @table,
            {{plan_ref, :temporal, publisher_id, mid, subscriber_id}, n}
          )

        :ok

      _ ->
        :ok
    end
  end

  defp put_svc_layers(plan_ref, publisher_id, mid, subscriber_id, opts) do
    case Keyword.fetch(opts, :spatial_layer) do
      {:ok, n} when is_integer(n) and n >= 0 ->
        true =
          :ets.insert(
            @table,
            {{plan_ref, :spatial_layer, publisher_id, mid, subscriber_id}, n}
          )

        :ok

      _ ->
        :ok
    end

    case Keyword.fetch(opts, :temporal_layer) do
      {:ok, n} when is_integer(n) and n >= 0 ->
        true =
          :ets.insert(
            @table,
            {{plan_ref, :temporal_layer, publisher_id, mid, subscriber_id}, n}
          )

        :ok

      _ ->
        :ok
    end
  end

  defp put_layer_policy_on_subscribe(plan_ref, publisher_id, mid, subscriber_id, opts) do
    source = if layer_opts?(opts), do: :manual, else: :adaptive

    put_layer_policy(
      plan_ref,
      publisher_id,
      mid,
      subscriber_id,
      Xylon.Conference.Allocator.new_policy(source)
    )
  end

  defp layer_opts?(opts) when is_list(opts) do
    Enum.any?(
      [:substream, :rid, :temporal, :spatial_layer, :temporal_layer],
      &Keyword.has_key?(opts, &1)
    )
  end

  defp max_temporal(plan_ref, publisher_id, mid, subscriber_id) do
    case :ets.lookup(@table, {plan_ref, :temporal, publisher_id, mid, subscriber_id}) do
      [{_, n}] when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  defp max_spatial(plan_ref, publisher_id, mid, subscriber_id) do
    case :ets.lookup(@table, {plan_ref, :spatial_layer, publisher_id, mid, subscriber_id}) do
      [{_, n}] when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  defp max_temporal_layer(plan_ref, publisher_id, mid, subscriber_id) do
    case :ets.lookup(@table, {plan_ref, :temporal_layer, publisher_id, mid, subscriber_id}) do
      [{_, n}] when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  defp resolve_by_substream(track, layers, nil) when is_list(layers) and layers != [] do
    case Enum.find(layers, &(&1.substream == 0)) || List.first(layers) do
      %{ssrc: ssrc} when is_integer(ssrc) and ssrc > 0 -> {:ok, ssrc}
      _ when is_integer(track.ssrc) and track.ssrc > 0 -> {:ok, track.ssrc}
      _ -> {:ok, 0}
    end
  end

  defp resolve_by_substream(track, _layers, nil), do: {:ok, track.ssrc}

  defp resolve_by_substream(_track, layers, substream)
       when is_integer(substream) and substream >= 0 and is_list(layers) do
    case Enum.find(layers, &(&1.substream == substream)) do
      %{ssrc: ssrc} when is_integer(ssrc) and ssrc > 0 -> {:ok, ssrc}
      _ -> {:error, :no_layer}
    end
  end

  defp resolve_by_substream(track, _layers, 0)
       when is_integer(track.ssrc) and track.ssrc > 0,
       do: {:ok, track.ssrc}

  defp resolve_by_substream(_track, _layers, 0), do: {:ok, 0}
  defp resolve_by_substream(_track, _layers, _), do: {:error, :no_layer}

  defp find_layer_by_rid(layers, rid) when is_list(layers) do
    Enum.find(layers, fn
      %{rid: ^rid} -> true
      _ -> false
    end)
  end

  defp find_layer_by_rid(_, _), do: nil

  defp insert_fresh_rewrite(plan_ref, publisher_id, mid, subscriber_id, in_ssrc) do
    _ = :ets.delete(@table, {plan_ref, :rewrite, publisher_id, mid, subscriber_id})
    out_ssrc = fresh_ssrc(plan_ref, in_ssrc)

    true =
      :ets.insert(
        @table,
        {{plan_ref, :rewrite, publisher_id, mid, subscriber_id},
         %{
           out_ssrc: out_ssrc,
           last_in_seq: nil,
           last_out_seq: nil,
           last_in_ts: nil,
           last_out_ts: nil
         }}
      )

    :ok
  end

  # Keep subscriber out_ssrc across SIM spatial / SSRC switches; reset seq/ts
  # so Rewrite deltas restart cleanly. Clears NACK cache for that out_ssrc.
  defp reset_rewrite_state(plan_ref, publisher_id, mid, subscriber_id) do
    case get_rewrite(plan_ref, publisher_id, mid, subscriber_id) do
      %{out_ssrc: out_ssrc} = rewrite when is_integer(out_ssrc) ->
        _ = Xylon.Conference.NackCache.clear_ssrc(plan_ref, out_ssrc)
        _ = Xylon.Conference.Runtime.delete_sfu_twcc_send(plan_ref, out_ssrc)

        true =
          :ets.insert(
            @table,
            {{plan_ref, :rewrite, publisher_id, mid, subscriber_id},
             %{
               rewrite
               | last_in_seq: nil,
                 last_out_seq: nil,
                 last_in_ts: nil,
                 last_out_ts: nil
             }}
          )

        :ok

      _ ->
        :ok
    end
  end

  defp fresh_ssrc(plan_ref, avoid) do
    used =
      :ets.match(@table, {{plan_ref, :rewrite, :_, :_, :_}, %{out_ssrc: :"$1"}})
      |> List.flatten()
      |> MapSet.new()
      |> MapSet.put(avoid)

    Stream.repeatedly(fn -> :rand.uniform(0xFFFF_FFFF) end)
    |> Enum.find(fn ssrc -> not MapSet.member?(used, ssrc) end)
  end

  defp build_routes_for_inbound(plan_ref, publisher_id, in_ssrc) do
    for mid <- published_mids(plan_ref, publisher_id),
        track = get_track(plan_ref, publisher_id, mid),
        track,
        subscriber_id <- MapSet.to_list(subscribers(plan_ref, publisher_id, mid)),
        layer_ssrc = route_in_ssrc(plan_ref, publisher_id, mid, subscriber_id, track),
        layer_ssrc == in_ssrc,
        sending?(plan_ref, publisher_id, mid, subscriber_id),
        dest = get_dest(plan_ref, publisher_id, mid, subscriber_id),
        dest && dest.type in [:peer, :trunk, :record],
        rewrite = get_rewrite(plan_ref, publisher_id, mid, subscriber_id),
        rewrite do
      %{
        subscriber_id: subscriber_id,
        publisher_id: publisher_id,
        mid: mid,
        kind: track.kind,
        codec: Map.get(track, :codec),
        layers: Map.get(track, :layers),
        max_temporal: max_temporal(plan_ref, publisher_id, mid, subscriber_id),
        max_spatial: max_spatial(plan_ref, publisher_id, mid, subscriber_id),
        max_temporal_layer: max_temporal_layer(plan_ref, publisher_id, mid, subscriber_id),
        destination: dest,
        rewrite_key: {publisher_id, mid, subscriber_id},
        rewrite: rewrite
      }
    end
  end

  defp hydrate_cached_routes(plan_ref, routes) do
    # Lean hydrate: rewrite only. Send flags and destinations were fixed when the
    # cache row was built; mutators must invalidate_route_cache/2.
    Enum.flat_map(routes, fn route ->
      case get_rewrite(
             plan_ref,
             route.publisher_id,
             route.mid,
             route.subscriber_id
           ) do
        nil -> []
        rewrite -> [Map.put(route, :rewrite, rewrite)]
      end
    end)
  end

  defp refresh_subscriber_destinations(plan_ref, subscriber_id, participant) do
    Enum.each(
      :ets.match(@table, {{plan_ref, :dest, :"$1", :"$2", subscriber_id}, :"$3"}),
      fn [pub, mid, dest] ->
        if is_map(dest) do
          true =
            :ets.insert(
              @table,
              {{plan_ref, :dest, pub, mid, subscriber_id},
               %{dest | participant: participant}}
            )

          _ = invalidate_route_cache(plan_ref, pub)
        end
      end
    )

    :ok
  end

  defp invalidate_route_cache(plan_ref, publisher_id) do
    true = :ets.match_delete(@table, {{plan_ref, :route_cache, publisher_id, :_}, :_})
    :ok
  end
end
