defmodule Xylon.Conference.SessionHooks do
  @moduledoc """
  Control-plane helpers: publish, subscribe, and Forwarder plan refresh.

  ## What problem this solves

  Changing who receives whose media updates an in-memory subscribe graph
  (`Xylon.Conference.Plan`) and must also refresh each publisher's row in
  `Xylon.Forwarder` so RTP fanout stays consistent. Signaling handlers, Control
  WS commands, and tests call these functions with a `plan_ref` (usually the
  Session pid) and optional `:forwarder` pid.

  Video subscribe/resume/switch paths send a PLI to the publisher so subscribers
  can decode without waiting for a spontaneous keyframe.

  **Internal:** prefer `Xylon.Conference` or `Xylon.Session.subscribe/4` from
  application code unless you hold a `plan_ref` directly.

  ## RFCs

  - [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) (RTP routing; PLI as RTCP feedback)
  - [RFC 4585](https://www.rfc-editor.org/rfc/rfc4585) (PLI RTCP feedback profile)
  - [RFC 3264](https://www.rfc-editor.org/rfc/rfc3264) (tracks originate from SDP offers via Xylon)
  - [RFC 5888](https://www.rfc-editor.org/rfc/rfc5888) (SDP mid)
  """

  alias Xylon.Conference.Mcu.Cascade
  alias Xylon.Conference.{Allocator, Dynacast, Plan, Rtcp}
  alias Xylon.Forwarder
  alias Xylon.Participant

  @doc """
  Registers a published track on the plan.

  Delegates to `Plan.put_track/3`. Returns `{:error, :invalid_track}` when
  `:mid`, `:kind`, or `:ssrc` is missing or invalid.
  """
  @spec publish(Plan.plan_ref(), term(), map()) :: :ok | {:error, term()}
  def publish(plan_ref, publisher_id, track) when is_map(track) do
    with :ok <- Plan.put_track(plan_ref, publisher_id, track) do
      maybe_layout_subscribe_track(plan_ref, publisher_id, track, [])
    end
  end

  @doc """
  Subscribes `subscriber_id` to `publisher_id`'s track at `mid` and refreshes Forwarder.

  When the published track is video, sends one PLI to the publisher peer (inbound
  SSRC) so a late joiner can decode without waiting for a spontaneous keyframe.

  Opts: `:forwarder` (pid), `:dest_type` (`:peer` | `:trunk` | `:record`),
  `:substream` / `:rid` for simulcast layer selection.
  """
  @spec subscribe(Plan.plan_ref(), term(), term(), Plan.mid(), keyword()) ::
          :ok | {:error, term()}
  def subscribe(plan_ref, subscriber_id, publisher_id, mid, opts \\ [])
      when is_binary(mid) and mid != "" and is_list(opts) do
    if Keyword.get(opts, :dest_type) == :trunk and Cascade.mix_publisher?(publisher_id) do
      {:error, :mcu_mix_trunk_loop}
    else
      with :ok <- Plan.subscribe(plan_ref, subscriber_id, publisher_id, mid, opts) do
        _ = request_keyframe(plan_ref, publisher_id, mid, subscriber_id)
        _ = Dynacast.maybe_notify(plan_ref, publisher_id, mid)
        refresh_publisher_plan(plan_ref, publisher_id, opts)
      end
    end
  end

  @doc """
  Subscribes `subscriber_id` to every published mid on `publisher_id`.
  """
  @spec subscribe_all(Plan.plan_ref(), term(), term(), keyword()) :: :ok | {:error, term()}
  def subscribe_all(plan_ref, subscriber_id, publisher_id, opts \\ []) when is_list(opts) do
    Enum.reduce_while(Plan.published_mids(plan_ref, publisher_id), :ok, fn mid, :ok ->
      case subscribe(plan_ref, subscriber_id, publisher_id, mid, opts) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc """
  Removes a subscription and refreshes Forwarder for the publisher.
  """
  @spec unsubscribe(Plan.plan_ref(), term(), term(), Plan.mid(), keyword()) ::
          :ok | {:error, term()}
  def unsubscribe(plan_ref, subscriber_id, publisher_id, mid, opts \\ [])
      when is_binary(mid) and mid != "" and is_list(opts) do
    :ok = Plan.unsubscribe(plan_ref, subscriber_id, publisher_id, mid)
    _ = Dynacast.maybe_notify(plan_ref, publisher_id, mid)
    refresh_publisher_plan(plan_ref, publisher_id, opts)
  end

  @doc """
  Stops publishing selected mids without removing the participant.

  Deletes tracks and outbound routes for each mid. Idempotent for missing tracks.
  Opts: `:forwarder` (pid) to refresh the Forwarder plan row.
  """
  @spec unpublish(Plan.plan_ref(), term(), [Plan.mid()], keyword()) ::
          :ok | {:error, term()}
  def unpublish(plan_ref, publisher_id, mids, opts \\ [])
      when is_list(mids) and is_list(opts) do
    with {:ok, mids} <- normalize_unpublish_mids(mids) do
      Enum.each(mids, fn mid ->
        _ = Plan.delete_track(plan_ref, publisher_id, mid)
      end)

      refresh_publisher_plan(plan_ref, publisher_id, opts)
    end
  end

  defp normalize_unpublish_mids([]), do: {:error, :invalid_mids}

  defp normalize_unpublish_mids(mids) do
    if Enum.all?(mids, &(is_binary(&1) and &1 != "")) do
      {:ok, Enum.uniq(mids)}
    else
      {:error, :invalid_mids}
    end
  end

  @doc """
  Pauses RTP for a subscription (`send: false`) while keeping rewrite state.

  Refreshes Forwarder so fanout stops for that route.
  """
  @spec pause(Plan.plan_ref(), term(), term(), Plan.mid(), keyword()) ::
          :ok | {:error, term()}
  def pause(plan_ref, subscriber_id, publisher_id, mid, opts \\ [])
      when is_binary(mid) and mid != "" and is_list(opts) do
    with :ok <- Plan.pause(plan_ref, subscriber_id, publisher_id, mid) do
      refresh_publisher_plan(plan_ref, publisher_id, opts)
    end
  end

  @doc """
  Resumes RTP for a subscription (`send: true`).

  Requests a video keyframe when resuming video, then refreshes Forwarder.
  """
  @spec resume(Plan.plan_ref(), term(), term(), Plan.mid(), keyword()) ::
          :ok | {:error, term()}
  def resume(plan_ref, subscriber_id, publisher_id, mid, opts \\ [])
      when is_binary(mid) and mid != "" and is_list(opts) do
    with :ok <- Plan.resume(plan_ref, subscriber_id, publisher_id, mid) do
      _ = request_keyframe(plan_ref, publisher_id, mid, subscriber_id)
      refresh_publisher_plan(plan_ref, publisher_id, opts)
    end
  end

  @doc """
  Sets the send flag for one subscription.

  When `send?` is `true` on a video track, requests a keyframe before refresh.
  """
  @spec set_send(Plan.plan_ref(), term(), term(), Plan.mid(), boolean(), keyword()) ::
          :ok | {:error, term()}
  def set_send(plan_ref, subscriber_id, publisher_id, mid, send?, opts \\ [])
      when is_binary(mid) and mid != "" and is_boolean(send?) and is_list(opts) do
    with :ok <- Plan.set_send(plan_ref, subscriber_id, publisher_id, mid, send?) do
      if send?, do: request_keyframe(plan_ref, publisher_id, mid, subscriber_id)
      refresh_publisher_plan(plan_ref, publisher_id, opts)
    end
  end

  @doc """
  Switches a subscriber from one publisher to another for `mid`.

  Creates fresh rewrite state under the new publisher. Refreshes Forwarder for
  both publishers; sends PLI to the new video publisher when applicable.
  """
  @spec switch(Plan.plan_ref(), term(), term(), term(), Plan.mid(), keyword()) ::
          :ok | {:error, term()}
  def switch(plan_ref, subscriber_id, from_publisher_id, to_publisher_id, mid, opts \\ [])
      when is_binary(mid) and mid != "" and is_list(opts) do
    with :ok <-
           Plan.switch(plan_ref, subscriber_id, from_publisher_id, to_publisher_id, mid, opts) do
      _ = request_keyframe(plan_ref, to_publisher_id, mid, subscriber_id)
      _ = refresh_publisher_plan(plan_ref, from_publisher_id, opts)
      refresh_publisher_plan(plan_ref, to_publisher_id, opts)
    end
  end

  @doc """
  Changes simulcast / SVC layer opts for an existing subscription.

  Refreshes rewrite when the inbound SSRC changes. Sends PLI on video when
  SSRC or `spatial_layer` changes (not temporal-only / temporal_layer-only).
  Clears AV1 DD chain state on spatial / SSRC change.
  """
  @spec set_substream(Plan.plan_ref(), term(), term(), Plan.mid(), keyword()) ::
          :ok | {:error, term()}
  def set_substream(plan_ref, subscriber_id, publisher_id, mid, opts)
      when is_binary(mid) and mid != "" and is_list(opts) do
    adaptive? = Keyword.get(opts, :adaptive, false)
    opts = Keyword.delete(opts, :adaptive)

    prev_ssrc = Plan.inbound_ssrc(plan_ref, publisher_id, mid, subscriber_id)
    prev_spatial = Plan.spatial_layer(plan_ref, publisher_id, mid, subscriber_id)

    with :ok <- maybe_guard_adaptive(plan_ref, publisher_id, mid, subscriber_id, adaptive?),
         :ok <- Plan.set_substream(plan_ref, subscriber_id, publisher_id, mid, opts) do
      if adaptive? do
        policy = Plan.get_layer_policy(plan_ref, publisher_id, mid, subscriber_id)
        _ = Plan.put_layer_policy(plan_ref, publisher_id, mid, subscriber_id, %{
          policy
          | source: :adaptive,
            pending: nil,
            pending_count: 0
        })
      else
        _ = Plan.mark_layer_manual(plan_ref, publisher_id, mid, subscriber_id)
      end

      next_ssrc = Plan.inbound_ssrc(plan_ref, publisher_id, mid, subscriber_id)
      next_spatial = Plan.spatial_layer(plan_ref, publisher_id, mid, subscriber_id)

      spatial_changed? =
        Keyword.has_key?(opts, :spatial_layer) and prev_spatial != next_spatial

      if prev_ssrc != next_ssrc or spatial_changed? do
        _ = Plan.clear_dd_chain(plan_ref, publisher_id, mid, subscriber_id)
        _ = request_keyframe(plan_ref, publisher_id, mid, subscriber_id)
      end

      _ = Dynacast.maybe_notify(plan_ref, publisher_id, mid)
      refresh_publisher_plan(plan_ref, publisher_id, opts)
    end
  end

  @doc """
  Applies allocator-recommended layer opts when the route is not manual-sticky.

  Returns `:ok`, `:skipped`, or `{:error, reason}`. SIM spatial switch keeps
  the subscriber `out_ssrc` (rewrite seq/ts reset only).
  """
  @spec set_substream_adaptive(Plan.plan_ref(), term(), term(), Plan.mid(), keyword()) ::
          :ok | :skipped | {:error, term()}
  def set_substream_adaptive(plan_ref, subscriber_id, publisher_id, mid, opts)
      when is_binary(mid) and mid != "" and is_list(opts) do
    policy = Plan.get_layer_policy(plan_ref, publisher_id, mid, subscriber_id)

    if policy.source == :manual do
      :skipped
    else
      rec = opts_to_rec(opts)
      current = Plan.current_layer_opts(plan_ref, publisher_id, mid, subscriber_id)
      {apply?, policy2} = Allocator.should_apply?(policy, rec, current)
      _ = Plan.put_layer_policy(plan_ref, publisher_id, mid, subscriber_id, policy2)

      if apply? do
        case set_substream(
               plan_ref,
               subscriber_id,
               publisher_id,
               mid,
               Keyword.put(opts, :adaptive, true)
             ) do
          :ok -> :ok
          {:error, _} = err -> err
        end
      else
        :skipped
      end
    end
  end

  defp maybe_guard_adaptive(plan_ref, publisher_id, mid, subscriber_id, true) do
    case Plan.get_layer_policy(plan_ref, publisher_id, mid, subscriber_id) do
      %{source: :manual} -> {:error, :manual_sticky}
      _ -> :ok
    end
  end

  defp maybe_guard_adaptive(_, _, _, _, _), do: :ok

  defp opts_to_rec(opts) do
    []
    |> maybe_put_rec(:substream, Keyword.get(opts, :substream))
    |> maybe_put_rec(:temporal, Keyword.get(opts, :temporal))
    |> maybe_put_rec(:spatial_layer, Keyword.get(opts, :spatial_layer))
    |> maybe_put_rec(:temporal_layer, Keyword.get(opts, :temporal_layer))
    |> Map.new()
  end

  defp maybe_put_rec(acc, _k, nil), do: acc
  defp maybe_put_rec(acc, k, v), do: [{k, v} | acc]

  @doc """
  Pauses or resumes all outbound routes for a publisher (Control A/V mute).

  `action` is `:mute` (`send: false`) or `:unmute` (`send: true`).
  `mids` defaults to all published mids on the publisher. On unmute, requests
  keyframes for all video subscribers.
  """
  @spec moderate_av(Plan.plan_ref(), term(), :mute | :unmute, [Plan.mid()] | nil, keyword()) ::
          :ok
  def moderate_av(plan_ref, publisher_id, action, mids \\ nil, opts \\ [])
      when action in [:mute, :unmute] and is_list(opts) do
    mids = mids || Plan.published_mids(plan_ref, publisher_id)
    send? = action == :unmute
    :ok = Plan.set_send_for_publisher(plan_ref, publisher_id, mids, send?)

    if send? do
      for mid <- mids,
          %{kind: :video} <- [Plan.get_track(plan_ref, publisher_id, mid)],
          sub <- MapSet.to_list(Plan.subscribers(plan_ref, publisher_id, mid)) do
        request_keyframe(plan_ref, publisher_id, mid, sub)
      end
    end

    refresh_publisher_plan(plan_ref, publisher_id, opts)
  end

  @doc """
  Replaces all subscribe routes for `subscriber_id` from `streams`.

  Each entry is `%{publisher_id: id, mid: mid}` or `%{publisher_id: id}` (all
  published mids on that publisher). Unsubscribes routes not in the desired set
  and subscribes missing ones.
  """
  @spec update_subscriptions(Plan.plan_ref(), term(), [map()], keyword()) ::
          :ok | {:error, term()}
  def update_subscriptions(plan_ref, subscriber_id, streams, opts \\ [])
      when is_list(streams) and is_list(opts) do
    desired = expand_desired(plan_ref, streams)
    current = current_subscriptions(plan_ref, subscriber_id)

    to_remove = MapSet.difference(current, desired)
    to_add = MapSet.difference(desired, current)

    Enum.each(to_remove, fn {pub, mid} ->
      unsubscribe(plan_ref, subscriber_id, pub, mid, opts)
    end)

    Enum.reduce_while(to_add, :ok, fn {pub, mid}, :ok ->
      case subscribe(plan_ref, subscriber_id, pub, mid, opts) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc """
  Installs the `__layout__` Plan participant and subscribes every published
  track to it with `dest_type: :record`.

  Idempotent. Used when Session recording starts with `layout: true`.
  """
  @spec attach_layout(Plan.plan_ref(), keyword()) :: :ok | {:error, term()}
  def attach_layout(plan_ref, opts \\ []) when is_list(opts) do
    layout_id = layout_subscriber_id()

    layout = %Participant{
      id: layout_id,
      peer_ref: nil,
      role: :record,
      meta: %{layout: true}
    }

    :ok = Plan.put_participant(plan_ref, layout)

    pubs =
      plan_ref
      |> Plan.participant_ids()
      |> Enum.reject(&(&1 == layout_id))

    Enum.reduce_while(pubs, :ok, fn pub, :ok ->
      case subscribe_all(plan_ref, layout_id, pub, Keyword.put(opts, :dest_type, :record)) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc """
  Removes `__layout__` subscriptions and the layout participant.
  """
  @spec detach_layout(Plan.plan_ref(), keyword()) :: :ok
  def detach_layout(plan_ref, opts \\ []) when is_list(opts) do
    layout_id = layout_subscriber_id()

    Enum.each(Plan.participant_ids(plan_ref), fn pub ->
      if pub != layout_id do
        Enum.each(Plan.published_mids(plan_ref, pub), fn mid ->
          _ = unsubscribe(plan_ref, layout_id, pub, mid, opts)
        end)
      end
    end)

    _ = Plan.delete_participant(plan_ref, layout_id)
    :ok
  end

  @doc "Synthetic Plan subscriber id for the live layout sink."
  @spec layout_subscriber_id() :: String.t()
  def layout_subscriber_id, do: "__layout__"

  @doc """
  Installs or refreshes the SFU Forwarder plan row for a publisher Peer.

  When `:forwarder` is present in `opts`, looks up the publisher participant and
  calls `Forwarder.put_plan/3` with `%{mode: :sfu, participant: ...}`.
  Returns `{:error, :no_publisher}` when the participant or peer pid is missing.
  No-op when `:forwarder` is omitted.
  """
  @spec refresh_publisher_plan(Plan.plan_ref(), term(), keyword()) :: :ok | {:error, term()}
  def refresh_publisher_plan(plan_ref, publisher_id, opts \\ []) do
    case Keyword.get(opts, :forwarder) do
      fwd when is_pid(fwd) ->
        case Plan.get_participant(plan_ref, publisher_id) do
          %Participant{peer_ref: peer} = participant when is_pid(peer) ->
            Forwarder.put_plan(fwd, peer, %{mode: :sfu, participant: participant})

          _ ->
            {:error, :no_publisher}
        end

      _ ->
        :ok
    end
  end

  defp maybe_layout_subscribe_track(plan_ref, publisher_id, track, opts) do
    layout_id = layout_subscriber_id()
    mid = Map.get(track, :mid) || Map.get(track, "mid")

    case Plan.get_participant(plan_ref, layout_id) do
      %Participant{role: :record} when is_binary(mid) and mid != "" and publisher_id != layout_id ->
        subscribe(plan_ref, layout_id, publisher_id, mid, Keyword.put(opts, :dest_type, :record))

      _ ->
        :ok
    end
  end

  defp expand_desired(plan_ref, streams) do
    streams
    |> Enum.flat_map(fn
      %{publisher_id: pub, mid: mid} when is_binary(mid) and mid != "" ->
        [{pub, mid}]

      %{publisher_id: pub} ->
        Enum.map(Plan.published_mids(plan_ref, pub), &{pub, &1})

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp current_subscriptions(plan_ref, subscriber_id) do
    plan_ref
    |> Plan.participant_ids()
    |> MapSet.to_list()
    |> Enum.flat_map(fn pub ->
      Enum.flat_map(Plan.published_mids(plan_ref, pub), fn mid ->
        if MapSet.member?(Plan.subscribers(plan_ref, pub, mid), subscriber_id) do
          [{pub, mid}]
        else
          []
        end
      end)
    end)
    |> MapSet.new()
  end

  defp request_keyframe(plan_ref, publisher_id, mid, subscriber_id) do
    case Plan.get_track(plan_ref, publisher_id, mid) do
      %{kind: :video} ->
        Rtcp.request_keyframe(plan_ref, publisher_id, subscriber_id: subscriber_id)

      _ ->
        :ok
    end
  end
end
