defmodule Xylon.Conference.Mcu.Cascade do
  @moduledoc """
  Hub-mix cascade helpers: remote contributors, trunk mix egress, announce.

  ## What problem this solves

  Multi-region MCU must mix once on a hub and forward a single mix over
  `XGW.Trunk.Pipe`. Default trunk profile is Opus; opt-in `:pcm` uses L16
  PCM16LE mono @ 48 kHz. Spoke edges SFU-fanout that mix and trunk raw talker
  audio to the hub. This module holds the stable mix publisher id, trunk
  codec profiles, ensure/announce helpers, and trunk exclusion-id lookup for
  opt-in spoke mix-minus (`mcu_spoke_mix_minus`).

  **Internal:** used when `mcu_cascade: :hub` or when guarding spoke trunk loops.

  ## RFCs

  - [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) (RTP over trunk)
  - [RFC 3551](https://www.rfc-editor.org/rfc/rfc3551) (L16 audio)
  - [RFC 6716](https://www.rfc-editor.org/rfc/rfc6716) (Opus cascade profile)
  """

  alias Xylon.Conference.Mcu.{Contributor, Egress, Quota}
  alias Xylon.Conference.Runtime
  alias Xylon.Participant
  alias Xylon.Trunk.{Announce, Manager}

  @mix_id "__mcu_mix__"
  @default_trunk_id "trunk"
  # 20 ms @ 48 kHz mono PCM16LE
  @l16_frame_bytes 1920

  @doc "Stable Plan publisher id for the hub mix track on spokes."
  @spec mix_publisher_id() :: binary()
  def mix_publisher_id, do: @mix_id

  @doc "True when `id` is the synthetic mix publisher."
  @spec mix_publisher?(term()) :: boolean()
  def mix_publisher?(id), do: id == @mix_id

  @doc "Opus 48 kHz mono profile assumed on the cascade trunk contributor path."
  @spec opus_desc() :: map()
  def opus_desc do
    %{
      name: "opus",
      payload_type: 111,
      clock_rate: 48_000,
      channels: 1,
      fmtp: nil,
      mixable?: true,
      sample_rate_hz: 48_000
    }
  end

  @doc """
  Trunk codec descriptor for cascade profile (`:opus` default, or `:pcm` L16).

  PCM is raw PCM16LE mono @ 48 kHz / 20 ms (1920-byte payloads), PT 96.
  """
  @spec trunk_desc(:opus | :pcm) :: map()
  def trunk_desc(:opus), do: opus_desc()

  def trunk_desc(:pcm) do
    %{
      name: "l16",
      payload_type: 96,
      clock_rate: 48_000,
      channels: 1,
      fmtp: nil,
      mixable?: true,
      sample_rate_hz: 48_000
    }
  end

  def trunk_desc(other) do
    raise ArgumentError, "unsupported cascade trunk profile: #{inspect(other)}"
  end

  @doc "Normalizes profile atom; unknown becomes `:opus`."
  @spec normalize_trunk_profile(term()) :: :opus | :pcm
  def normalize_trunk_profile(:pcm), do: :pcm
  def normalize_trunk_profile("pcm"), do: :pcm
  def normalize_trunk_profile(:opus), do: :opus
  def normalize_trunk_profile("opus"), do: :opus
  def normalize_trunk_profile(_), do: :opus

  @doc "L16 trunk frame size in bytes (960 samples * 2)."
  @spec l16_frame_bytes() :: pos_integer()
  def l16_frame_bytes, do: @l16_frame_bytes

  @doc """
  Validates a bus PCM tick for L16 RTP packing (identity payload).

  Returns `{:ok, pcm}` when size is one 20 ms frame.
  """
  @spec pack_l16_payload(binary()) :: {:ok, binary()} | {:error, :bad_pcm_frame}
  def pack_l16_payload(pcm) when is_binary(pcm) and byte_size(pcm) == @l16_frame_bytes,
    do: {:ok, pcm}

  def pack_l16_payload(_), do: {:error, :bad_pcm_frame}

  @doc """
  Validates an L16 RTP payload as one bus PCM tick.
  """
  @spec unpack_l16_payload(binary()) :: {:ok, binary()} | {:error, :bad_l16_payload}
  def unpack_l16_payload(payload)
      when is_binary(payload) and byte_size(payload) == @l16_frame_bytes,
      do: {:ok, payload}

  def unpack_l16_payload(_), do: {:error, :bad_l16_payload}

  @doc """
  Compares two trunk profiles. Mismatch returns `{:error, :mcu_cascade_profile_mismatch}`.
  """
  @spec agree_trunk_profile(term(), term()) :: :ok | {:error, :mcu_cascade_profile_mismatch}
  def agree_trunk_profile(local, remote) do
    if normalize_trunk_profile(local) == normalize_trunk_profile(remote) do
      :ok
    else
      {:error, :mcu_cascade_profile_mismatch}
    end
  end

  @doc """
  Ensures a hub Contributor decode row for a remote (or local) cascade talker.

  Idempotent. Admits MCU contributor quota when `mcu_max_contributors` is set.
  """
  @spec ensure_remote_contributor(Runtime.plan_ref(), term(), map()) :: :ok | {:error, term()}
  def ensure_remote_contributor(plan_ref, participant_id, state)
      when is_map(state) do
    Runtime.ensure_table!()

    case Runtime.get_mcu_contrib(plan_ref, participant_id) do
      %{codec_pid: :l16_passthrough} ->
        :ok

      %{codec_pid: pid} when is_pid(pid) ->
        :ok

      _ ->
        with :ok <-
               Quota.admit_contributor(
                 plan_ref,
                 participant_id,
                 Map.get(state, :mcu_max_contributors)
               ),
             :ok <-
               Contributor.ensure(
                 plan_ref,
                 participant_id,
                 trunk_desc(normalize_trunk_profile(Map.get(state, :mcu_cascade_trunk_profile))),
                 jb_target: Map.get(state, :mcu_jb_target, 2),
                 non_mixable_pts: []
               ) do
          :ok
        end
    end
  end

  @doc """
  Ensures trunk egress on the hub for the configured cascade trunk profile.

  PCM selection (full vs spoke mix-minus) is decided in `Mcu.tick/2`.
  """
  @spec ensure_trunk_egress(Runtime.plan_ref(), term(), map()) :: :ok | {:error, term()}
  def ensure_trunk_egress(plan_ref, trunk_id, state) when is_map(state) do
    profile = normalize_trunk_profile(Map.get(state, :mcu_cascade_trunk_profile))

    Egress.ensure(plan_ref, trunk_id, trunk_desc(profile),
      sr_interval_ms: Map.get(state, :mcu_sr_interval_ms, 1000),
      opus_bitrate_bps: Map.get(state, :mcu_opus_bitrate_bps, 32_000),
      bitrate_cap: Map.get(state, :bitrate_cap)
    )
  end

  @doc """
  Builds a Trunk announce payload for the hub mix track.

  Returns `{:error, :no_trunk_egress}` when the trunk has no egress row yet.
  """
  @spec mix_announce(Runtime.plan_ref(), map(), keyword()) ::
          {:ok, Announce.t()} | {:error, term()}
  def mix_announce(plan_ref, state, opts \\ []) when is_map(state) and is_list(opts) do
    trunk_id = Keyword.get(opts, :trunk_id, @default_trunk_id)
    mid = Map.get(state, :mcu_mix_mid, "0")
    session_key = Keyword.get(opts, :session_key)

    case Runtime.get_mcu_egress(plan_ref, trunk_id) do
      %{out_ssrc: ssrc} when is_integer(ssrc) ->
        spoke_mm? = Map.get(state, :mcu_spoke_mix_minus, false) == true
        profile = normalize_trunk_profile(Map.get(state, :mcu_cascade_trunk_profile))

        track = %{
          publisher_id: @mix_id,
          mid: mid,
          ssrc: ssrc,
          kind: :audio,
          spoke_mix_minus: spoke_mm?,
          trunk_profile: profile
        }

        part = %{
          id: @mix_id,
          role: :publisher,
          labels: [],
          spoke_mix_minus: spoke_mm?,
          trunk_profile: profile
        }

        ann =
          Announce.new(
            session_key: session_key || {Map.get(state, :tenant_id), Map.get(state, :session_id)},
            from_edge: Keyword.get(opts, :from_edge, :hub),
            participants: [part],
            tracks: [track]
          )

        {:ok, Map.put(ann, :trunk_id, trunk_id)}

      _ ->
        {:error, :no_trunk_egress}
    end
  end

  @doc """
  Announces the hub mix track onto `spoke_session` (same node or local pid).

  Fails with `:mcu_cascade_profile_mismatch` when spoke trunk profile disagrees.
  """
  @spec announce_mix(pid(), pid(), keyword()) :: :ok | {:error, term()}
  def announce_mix(hub_session, spoke_session, opts \\ [])
      when is_pid(hub_session) and is_pid(spoke_session) do
    hub_state = :sys.get_state(hub_session).backend_state
    spoke_state = :sys.get_state(spoke_session).backend_state
    plan_ref = hub_state.plan_ref
    session_key = Keyword.get(opts, :session_key, {hub_state.tenant_id, hub_state.session_id})

    with :ok <-
           agree_trunk_profile(
             Map.get(hub_state, :mcu_cascade_trunk_profile),
             Map.get(spoke_state, :mcu_cascade_trunk_profile)
           ),
         {:ok, ann} <-
           mix_announce(plan_ref, hub_state, Keyword.put(opts, :session_key, session_key)) do
      Manager.announce_tracks(spoke_session, ann)
    end
  end

  @doc """
  Announces the hub mix track to `remote_node` (control plane only).

  When `opts` includes `:spoke_trunk_profile`, compares against the hub profile
  before announcing (remote spoke session is not readable from this node).
  """
  @spec announce_mix_remote(pid(), node(), {term(), term()}, keyword()) ::
          :ok | {:error, term()}
  def announce_mix_remote(hub_session, remote_node, session_key, opts \\ [])
      when is_pid(hub_session) and is_atom(remote_node) do
    hub_state = :sys.get_state(hub_session).backend_state
    plan_ref = hub_state.plan_ref
    hub_profile = Map.get(hub_state, :mcu_cascade_trunk_profile)

    with :ok <- maybe_agree_remote_profile(hub_profile, opts),
         {:ok, ann} <-
           mix_announce(plan_ref, hub_state, Keyword.put(opts, :session_key, session_key)) do
      Manager.announce_tracks_remote(remote_node, session_key, ann)
    end
  end

  defp maybe_agree_remote_profile(hub_profile, opts) do
    case Keyword.fetch(opts, :spoke_trunk_profile) do
      {:ok, spoke_profile} -> agree_trunk_profile(hub_profile, spoke_profile)
      :error -> :ok
    end
  end
  @doc """
  Agree trunk profiles between two sessions when one is a cascade hub.

  No-op (`:ok`) when neither side is `mcu_cascade: :hub`.
  """
  @spec agree_session_profiles(pid(), pid()) :: :ok | {:error, :mcu_cascade_profile_mismatch}
  def agree_session_profiles(session_a, session_b)
      when is_pid(session_a) and is_pid(session_b) do
    sa = :sys.get_state(session_a).backend_state
    sb = :sys.get_state(session_b).backend_state

    cond do
      Map.get(sa, :mcu_cascade) == :hub ->
        agree_trunk_profile(
          Map.get(sa, :mcu_cascade_trunk_profile),
          Map.get(sb, :mcu_cascade_trunk_profile)
        )

      Map.get(sb, :mcu_cascade) == :hub ->
        agree_trunk_profile(
          Map.get(sb, :mcu_cascade_trunk_profile),
          Map.get(sa, :mcu_cascade_trunk_profile)
        )

      true ->
        :ok
    end
  end

  @doc """
  Agree hub profile against spoke `backend_opts` before `connect_remote`.
  """
  @spec agree_hub_backend_opts(pid(), keyword()) ::
          :ok | {:error, :mcu_cascade_profile_mismatch}
  def agree_hub_backend_opts(hub_session, backend_opts)
      when is_pid(hub_session) and is_list(backend_opts) do
    if hub_session?(hub_session) do
      hub = :sys.get_state(hub_session).backend_state

      agree_trunk_profile(
        Map.get(hub, :mcu_cascade_trunk_profile),
        Keyword.get(backend_opts, :mcu_cascade_trunk_profile, :opus)
      )
    else
      :ok
    end
  end

  @doc """
  After trunk pair/connect, announce mix from hub session toward spoke.

  Returns announce errors (including `:mcu_cascade_profile_mismatch`).
  """
  @spec maybe_announce_after_pair(pid(), pid()) :: :ok | {:error, term()}
  def maybe_announce_after_pair(session_a, session_b)
      when is_pid(session_a) and is_pid(session_b) do
    cond do
      hub_session?(session_a) and not hub_session?(session_b) ->
        announce_mix(session_a, session_b)

      hub_session?(session_b) and not hub_session?(session_a) ->
        announce_mix(session_b, session_a)

      true ->
        :ok
    end
  end

  @doc """
  After `connect_remote`, announce mix from local hub to the far edge.

  Passes `:spoke_trunk_profile` when present in `opts`.
  """
  @spec maybe_announce_after_remote(pid(), node(), {term(), term()}, keyword()) ::
          :ok | {:error, term()}
  def maybe_announce_after_remote(hub_session, remote_node, session_key, opts \\ [])
      when is_pid(hub_session) and is_atom(remote_node) do
    if hub_session?(hub_session) do
      announce_mix_remote(hub_session, remote_node, session_key, opts)
    else
      :ok
    end
  end

  @doc """
  True when spoke is SFU with PCM trunk and must edge-transcode L16 mix to Opus.
  """
  @spec pcm_sfu_edge?(map()) :: boolean()
  def pcm_sfu_edge?(state) when is_map(state) do
    Map.get(state, :mcu_cascade) == :spoke and Map.get(state, :audio) == :sfu and
      normalize_trunk_profile(Map.get(state, :mcu_cascade_trunk_profile)) == :pcm
  end

  @doc "True when participant should receive full mix (trunk on hub)."
  @spec full_mix_listener?(Participant.t() | map()) :: boolean()
  def full_mix_listener?(%Participant{role: :trunk}), do: true
  def full_mix_listener?(%{role: :trunk}), do: true
  def full_mix_listener?(_), do: false

  @doc """
  Contributor ids attributed to `trunk_id` for opt-in spoke mix-minus.

  Empty set when nothing has been attributed yet.
  """
  @spec trunk_exclude_ids(Runtime.plan_ref(), term()) :: MapSet.t()
  def trunk_exclude_ids(plan_ref, trunk_id) do
    Runtime.get_mcu_trunk_excl(plan_ref, trunk_id)
  end

  @doc false
  @spec hub_session?(pid()) :: boolean()
  def hub_session?(session) when is_pid(session) do
    Map.get(:sys.get_state(session).backend_state, :mcu_cascade) == :hub
  end
end
