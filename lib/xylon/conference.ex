defmodule Xylon.Conference do
  @moduledoc """
  Conference room media library for Xylon: default audio + video SFU.

  ## What problem this solves

  In a video call, each participant sends their own microphone and camera as
  separate media streams. A naive approach sends every stream to every other
  participant (a mesh), which uses bandwidth and CPU that grow quickly as the
  room gets larger. A Selective Forwarding Unit (SFU) sits in the middle: each
  person sends once to the server, and the server forwards only the streams each
  viewer asked for, after rewriting RTP headers so browsers accept them.

  This module is the attach point for that room backend. Call `attach/0` once at
  boot (or rely on `config :xylon, :backends`), then create sessions with
  catalogue id `:conference`. Subscribe graph and RTP rewrite state live in
  `Xylon.Conference.Plan`; steady-state media runs through `Xylon.Forwarder` and
  `XGW.Peer.SendHandle`.

  ## Main modules

  - `Xylon.Conference` -- attach and plan-level publish/subscribe API (this module)
  - `Xylon.Conference.Backend` -- `Xylon.Backend` SFU implementation
  - `Xylon.Conference.Plan` -- ETS subscribe graph and per-route rewrite state
  - `Xylon.Conference.SessionHooks` -- publish/subscribe with Forwarder refresh
  - `Xylon.Conference.OfferTracks` -- parse inbound SSRCs from offer SDP
  - `Xylon.Conference.Rewrite` -- pure RTP header rewrite for fanout
  - `Xylon.Conference.Rtcp` -- PLI/FIR fan-in toward publishers
  - `Xylon.Conference.AudioLevel` -- RFC 6464 talking detector

  ## RFCs

  - [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) (RTP and RTCP)
  - [RFC 6464](https://www.rfc-editor.org/rfc/rfc6464) (RTP audio level header extension)
  - [RFC 3264](https://www.rfc-editor.org/rfc/rfc3264) (SDP offer/answer; via [XSDP](https://github.com/Lazarus404/xsdp) / [Xylon](https://github.com/Lazarus404/xylon))
  - [RFC 8829](https://www.rfc-editor.org/rfc/rfc8829) (JSEP; browser signaling through Xylon HTTP/Control)
  - [RFC 8445](https://www.rfc-editor.org/rfc/rfc8445) (ICE; via [XGW](https://github.com/Lazarus404/xgw))
  - [RFC 3711](https://www.rfc-editor.org/rfc/rfc3711) (SRTP; media is decrypted by XGW before SFU rewrite)
  - [RFC 5888](https://www.rfc-editor.org/rfc/rfc5888) (SDP mid)
  """

  alias Xylon.Conference.{Backend, SessionHooks}

  @doc """
  Catalogue id for `Xylon.attach/1` and `Xylon.Session.create/3`.

  ## Examples

      iex> Xylon.Conference.id()
      :conference
  """
  @spec id() :: :conference
  def id, do: :conference

  @doc """
  Registers `Xylon.Conference.Backend` with the Xylon catalogue.

  Idempotent when called again with the same backend module. Returns
  `{:error, :invalid_backend}` if the module does not implement `Xylon.Backend`.

  ## Examples

      iex> Xylon.Catalogue.reset!()
      :ok
      iex> Xylon.Conference.attach()
      :ok
      iex> Xylon.attached?(:conference)
      true
  """
  @spec attach() :: :ok | {:error, :invalid_backend}
  def attach do
    Xylon.attach(Backend)
  end

  @doc """
  Registers a published track on the Session plan.

  Delegates to `Xylon.Conference.SessionHooks.publish/3`. Normally the backend
  calls this from `media_ready/4` after parsing the offer; apps may call it when
  injecting tracks manually.

  `track` must include `:mid`, `:kind` (`:audio` or `:video`), and inbound `:ssrc`.
  Optional keys: `:codec`, `:layers` (simulcast).
  """
  defdelegate publish(plan_ref, publisher_id, track), to: SessionHooks

  @doc """
  Subscribes one participant to a publisher track at `mid` and refreshes Forwarder plans.

  Opts: `:forwarder` (pid), `:dest_type` (`:peer` | `:trunk`), `:substream` /
  `:rid` for simulcast, `:temporal` for VP8 max TID, `:spatial_layer` /
  `:temporal_layer` for VP9 / AV1 SVC. Sends a video PLI to the publisher on
  subscribe so late joiners can decode.
  """
  defdelegate subscribe(plan_ref, subscriber_id, publisher_id, mid, opts \\ []),
    to: SessionHooks

  @doc """
  Subscribes one participant to every published mid on a publisher.
  """
  defdelegate subscribe_all(plan_ref, subscriber_id, publisher_id, opts \\ []),
    to: SessionHooks

  @doc """
  Removes a subscription and refreshes Forwarder plans.

  Does not affect the publisher's published track; only the fanout route.
  """
  defdelegate unsubscribe(plan_ref, subscriber_id, publisher_id, mid, opts \\ []),
    to: SessionHooks

  @doc """
  Stops publishing selected mids without leaving the room.

  `mids` is a nonempty list of SDP mid strings. Distinct from `moderate_av/5`
  (pause routes) and from leave (removes the participant).
  """
  defdelegate unpublish(plan_ref, publisher_id, mids, opts \\ []), to: SessionHooks

  @doc """
  Pauses RTP for a subscription without removing rewrite state.

  Equivalent to `set_send(..., false)`. The route remains in the plan for resume.
  """
  defdelegate pause(plan_ref, subscriber_id, publisher_id, mid, opts \\ []), to: SessionHooks

  @doc """
  Resumes a paused subscription.

  Equivalent to `set_send(..., true)`. Requests a video keyframe when resuming video.
  """
  defdelegate resume(plan_ref, subscriber_id, publisher_id, mid, opts \\ []), to: SessionHooks

  @doc """
  Sets the per-route send flag for a subscription.

  When `send?` is `false`, RTP is not forwarded but rewrite state is kept.
  """
  defdelegate set_send(plan_ref, subscriber_id, publisher_id, mid, send?, opts \\ []),
    to: SessionHooks

  @doc """
  Rebinds a subscription to another publisher without SDP renegotiation.

  Creates fresh rewrite state under the new publisher. Rejects when both tracks
  have codecs recorded and they differ.
  """
  defdelegate switch(plan_ref, subscriber_id, from_publisher_id, to_publisher_id, mid, opts \\ []),
    to: SessionHooks

  @doc """
  Pauses or resumes all outbound routes for a publisher (Control A/V mute).

  `action` is `:mute` or `:unmute`. `mids` defaults to all published mids.
  """
  defdelegate moderate_av(plan_ref, publisher_id, action, mids \\ nil, opts \\ []),
    to: SessionHooks

  @doc """
  Selects simulcast / SVC layer opts for a subscription.

  `opts` may include `:substream`, `:rid`, `:temporal`, `:spatial_layer`, and/or
  `:temporal_layer`. Spatial / SSRC / spatial_layer change refreshes rewrite and
  requests a video PLI; temporal-only does not.
  """
  defdelegate set_substream(plan_ref, subscriber_id, publisher_id, mid, opts), to: SessionHooks

  @doc """
  Replaces all subscribe routes for a subscriber from a stream list.

  Each entry is `%{publisher_id: id, mid: mid}` or `%{publisher_id: id}` (all mids).
  """
  defdelegate update_subscriptions(plan_ref, subscriber_id, streams, opts \\ []),
    to: SessionHooks
end
