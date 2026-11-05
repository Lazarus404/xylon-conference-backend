defmodule Xylon.Conference.Dynacast do
  @moduledoc """
  Opt-in uplink Dynacast: pause unused SIM encodings on the publisher.

  ## What problem this solves

  Receive-side SIM filtering alone still makes publishers encode every RID.
  When room opt `dynacast: true`, this module aggregates the max required
  substream across sending subscribers for a SIM video track and pushes a
  Control WS `publish_layers` frame to the publisher so the SDK can toggle
  `RTCRtpEncodingParameters.active`.

  Scope: SIM (multi-SSRC / RID) only. One-SSRC SVC is skipped. Independent of
  `adaptive_layers`. Debounces rapid subscribe churn (~50ms).

  ## Internal

  Called from `Xylon.Conference.SessionHooks` after subscribe / unsubscribe /
  set_substream. Reads `Runtime.dynacast?/1`.

  ## RFCs

  - None directly; uses Plan SIM layers and Control WS framing
  """

  alias Xylon.Conference.{Plan, Runtime}
  alias Xylon.Participant

  @debounce_ms 50

  @doc """
  Aggregates publisher layer active flags for a SIM track.

  Returns `{:ok, layers}` where each entry is `%{"rid" => rid, "active" => bool}`
  (JSON-friendly), or `:skip` when the track is not SIM video / has no layers.
  Max required substream across sending subscribers; layers at or below that
  index stay active. With no subscribers, all layers are inactive.
  """
  @spec aggregate(Plan.plan_ref(), term(), Plan.mid()) ::
          {:ok, [map()]} | :skip
  def aggregate(plan_ref, publisher_id, mid) when is_binary(mid) and mid != "" do
    case Plan.get_track(plan_ref, publisher_id, mid) do
      %{kind: :video, layers: layers} when is_list(layers) and layers != [] ->
        max_sub = max_required_substream(plan_ref, publisher_id, mid, layers)
        {:ok, layer_flags(layers, max_sub)}

      _ ->
        :skip
    end
  end

  @doc """
  Schedules a debounced `publish_layers` push when dynacast is enabled.

  No-op when `Runtime.dynacast?/1` is false or the track is not SIM.
  """
  @spec maybe_notify(Plan.plan_ref(), term(), Plan.mid()) :: :ok
  def maybe_notify(plan_ref, publisher_id, mid) when is_binary(mid) and mid != "" do
    if Runtime.dynacast?(plan_ref) do
      schedule(plan_ref, publisher_id, mid)
    else
      :ok
    end
  end

  @doc "Flushes one pending dynacast notify (tests / debounce worker)."
  @spec flush(Plan.plan_ref(), term(), Plan.mid()) :: :ok
  def flush(plan_ref, publisher_id, mid) when is_binary(mid) and mid != "" do
    _ = Runtime.clear_dynacast_worker(plan_ref, publisher_id, mid)

    case aggregate(plan_ref, publisher_id, mid) do
      {:ok, layers} ->
        case Runtime.get_dynacast_last(plan_ref, publisher_id, mid) do
          ^layers ->
            :ok

          _ ->
            _ = Runtime.put_dynacast_last(plan_ref, publisher_id, mid, layers)
            push_publish_layers(plan_ref, publisher_id, mid, layers)
        end

      :skip ->
        :ok
    end
  end

  defp schedule(plan_ref, publisher_id, mid) do
    case Runtime.take_dynacast_worker(plan_ref, publisher_id, mid) do
      pid when is_pid(pid) ->
        Process.exit(pid, :kill)

      _ ->
        :ok
    end

    parent = self()

    pid =
      spawn(fn ->
        Process.sleep(@debounce_ms)
        # Ignore if parent died; flush is idempotent against Plan/Runtime.
        _ = parent
        flush(plan_ref, publisher_id, mid)
      end)

    _ = Runtime.put_dynacast_worker(plan_ref, publisher_id, mid, pid)
    :ok
  end

  defp max_required_substream(plan_ref, publisher_id, mid, layers) do
    Plan.subscribers(plan_ref, publisher_id, mid)
    |> MapSet.to_list()
    |> Enum.reduce(nil, fn subscriber_id, acc ->
      if Plan.sending?(plan_ref, publisher_id, mid, subscriber_id) do
        sub = subscriber_substream(plan_ref, publisher_id, mid, subscriber_id, layers)
        max_nil(acc, sub)
      else
        acc
      end
    end)
  end

  defp subscriber_substream(plan_ref, publisher_id, mid, subscriber_id, layers) do
    opts = Plan.current_layer_opts(plan_ref, publisher_id, mid, subscriber_id)

    cond do
      is_integer(Map.get(opts, :substream)) ->
        Map.get(opts, :substream)

      true ->
        in_ssrc = Plan.inbound_ssrc(plan_ref, publisher_id, mid, subscriber_id)

        case Enum.find(layers, &(&1.ssrc == in_ssrc)) do
          %{substream: s} when is_integer(s) -> s
          _ -> 0
        end
    end
  end

  defp layer_flags(layers, nil) do
    Enum.map(layers, fn layer ->
      %{"rid" => rid_of(layer), "active" => false}
    end)
  end

  defp layer_flags(layers, max_sub) when is_integer(max_sub) do
    Enum.map(layers, fn layer ->
      sub = Map.get(layer, :substream, 0)
      %{"rid" => rid_of(layer), "active" => is_integer(sub) and sub <= max_sub}
    end)
  end

  defp rid_of(%{rid: rid}) when is_binary(rid) and rid != "", do: rid
  defp rid_of(%{substream: s}) when is_integer(s), do: Integer.to_string(s)
  defp rid_of(_), do: "0"

  defp max_nil(nil, v), do: v
  defp max_nil(a, b) when is_integer(a) and is_integer(b), do: max(a, b)

  defp push_publish_layers(plan_ref, publisher_id, mid, layers) do
    case Plan.get_participant(plan_ref, publisher_id) do
      %Participant{meta: %{signaling_pid: pid}} when is_pid(pid) ->
        send(pid, {:xylon_control_publish_layers, %{mid: mid, layers: layers}})
        :ok

      _ ->
        :ok
    end
  end
end
