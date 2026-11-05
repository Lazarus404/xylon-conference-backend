defmodule Mix.Tasks.Xylon.Conference do
  @moduledoc """
  Boot Xylon with Conference, Datachannel, and Echo backends for the HTTP Lab.

  ## What problem this solves

  Developers need a single command to run a local Xylon server with the conference
  backend attached, a browser test client, and optional Control auth for feeds and
  talking events. This Mix task configures backends, ICE advertisement, and Control
  mode, then starts the application and prints lab URLs. Use `--audio mcu` to print
  MCU create recipes (clients still pass `backend_opts` on session create).

  ## Usage

      XYLON_ADVERTISED_IP=127.0.0.1 XTURN_LOCAL_DEPS=1 mix xylon.conference --http-port 8080
      XYLON_ADVERTISED_IP=127.0.0.1 XTURN_LOCAL_DEPS=1 mix xylon.conference --http-port 8080 --audio mcu
      XYLON_ADVERTISED_IP=127.0.0.1 XTURN_LOCAL_DEPS=1 mix xylon.conference --http-port 8080 --control hmac
      XYLON_ADVERTISED_IP=127.0.0.1 XTURN_LOCAL_DEPS=1 mix xylon.conference --http-port 8080 --control lab

  Open http://127.0.0.1:8080/client/ ([xylon-test-client](https://github.com/Lazarus404/xylon-test-client)).

  HTTP Lab libraries:

  - `conference` -- two tabs, same `session_id`, different participant ids; mic/cam;
    mesh SFU from offer SSRCs (or manual subscribe via `backend_opts`). With
    `--audio mcu`, create with `backend_opts` `audio: mcu`, `video: sfu`; one mix
    mid (default `"0"`) sendrecv; mesh auto-subscribes video only.
  - `datachannel` -- chat fanout (same as `mix xylon.datachannel`)
  - `echo` -- loopback

  `--control hmac` enables [Xylon.Control](https://github.com/Lazarus404/xylon) with
  TTL-HMAC bearer auth (`XYLON_CONTROL_HMAC_SECRET`, default `lab-hmac-secret`).
  Required for `feeds.*` and talking WS fanout (Presence). `--control lab` uses
  `x-tenant-id` trust. `--control jwt` needs `XYLON_CONTROL_JWKS_URL`. Default is
  control off.

  Requires `XYLON_ADVERTISED_IP` (or `config :xylon, :ice`) for host ICE candidates.

  Multi-home lab (two Mix processes): set `XYLON_CLUSTER=1` and `XYLON_REGION_ID`,
  optional `XYLON_HUB_PRIORITY`, `XYLON_EDGE_URLS` (JSON map), and trunk key envs
  `XYLON_TRUNK_KEY_AB` / `XYLON_TRUNK_SALT_AB` / `XYLON_TRUNK_KEY_BA` /
  `XYLON_TRUNK_SALT_BA` (hex). See workspace `scripts/e2e-lab-hub-spoke.sh`.

  Room recording (optional): set `XYLON_RECORD_DIR` to enable
  `XylonRecord.Handler` (requires `xylon_record` on the load path; local labs use
  `XTURN_LOCAL_DEPS=1`). Pair with `XYLON_CONTROL_WEBHOOK_URL` pointing at
  [xylon-compose-worker](https://github.com/Lazarus404/xylon-compose-worker) for
  remux after `record/stop`.

  ## RFCs

  - [RFC 8829](https://www.rfc-editor.org/rfc/rfc8829) (JSEP over HTTP in the lab client)
  - [RFC 3264](https://www.rfc-editor.org/rfc/rfc3264) (SDP offer/answer via Xylon/XSDP)
  - [RFC 8445](https://www.rfc-editor.org/rfc/rfc8445) (ICE; configure via `Xylon.Ice`)
  - [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) (conference RTP/RTCP)
  - [RFC 6716](https://www.rfc-editor.org/rfc/rfc6716) (Opus MCU mix / lab profile)
  - No STUN/TURN RFC in this task; relay/TURN is configured separately on Xylon if needed
  """
  use Mix.Task

  @shortdoc "Run Xylon conference lab (HTTP JSEP + datachannel)"

  @doc false
  @spec parse_args([binary()]) :: {:ok, keyword()} | {:error, term()}
  def parse_args(args) when is_list(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [http_port: :integer, control: :string, audio: :string],
        aliases: [h: :http_port]
      )

    cond do
      invalid != [] ->
        {:error, {:invalid_args, invalid}}

      true ->
        case Keyword.get(opts, :audio, "sfu") do
          "sfu" -> {:ok, Keyword.put(opts, :audio, :sfu)}
          "mcu" -> {:ok, Keyword.put(opts, :audio, :mcu)}
          other -> {:error, {:invalid_audio, other}}
        end
    end
  end

  @impl Mix.Task
  def run(args) do
    opts =
      case parse_args(args) do
        {:ok, opts} ->
          opts

        {:error, {:invalid_audio, other}} ->
          Mix.raise("unknown --audio #{inspect(other)} (use sfu or mcu)")

        {:error, reason} ->
          Mix.raise("invalid args: #{inspect(reason)}")
      end

    port = Keyword.get(opts, :http_port, 8080)
    audio = Keyword.fetch!(opts, :audio)
    Application.put_env(:xylon, :http_port, port)

    Application.put_env(:xylon, :backends, [
      Xylon.Backend.Echo,
      Xylon.Datachannel.Backend,
      Xylon.Conference.Backend
    ])

    Application.put_env(:xylon, :default_backend, :conference)

    require_ice!()
    apply_control(Keyword.get(opts, :control))
    apply_recording!()
    apply_cluster_lab!()
    Mix.Task.run("app.start")

    Mix.shell().info("""
    xylon conference lab running
      HTTP   http://127.0.0.1:#{port}/
      Client http://127.0.0.1:#{port}/client/
      ICE    mode=#{Xylon.Ice.mode()} advertise #{Xylon.Ice.summary()}
      default backend #{inspect(Xylon.default_backend())}
      audio mode #{audio}
      control #{control_summary()}
      recording #{recording_summary()}
      cluster #{cluster_summary()}
      attached echo + datachannel + conference
    HTTP Lab: library=conference (A/V) or library=datachannel (chat).
    Feeds/talking WS need --control (Presence). Two tabs: same session_id,
    different participant_id.
    #{audio_lab_hint(audio)}
    Ctrl+C to stop.
    """)

    Process.sleep(:infinity)
  end

  @doc """
  Builds `:cluster` Application env from lab environment variables.

  Returns `nil` when clustering is not requested.
  """
  @spec cluster_lab_config() :: keyword() | nil
  def cluster_lab_config do
    enabled? =
      System.get_env("XYLON_CLUSTER") in ["1", "true", "yes"] or
        case System.get_env("XYLON_REGION_ID") do
          id when is_binary(id) and id != "" -> true
          _ -> false
        end

    if enabled? do
      region = System.get_env("XYLON_REGION_ID") || "local"
      priority = String.to_integer(System.get_env("XYLON_HUB_PRIORITY") || "0")
      edge_urls = parse_edge_urls(System.get_env("XYLON_EDGE_URLS"))

      cfg = [
        enabled: true,
        region_id: region,
        hub_priority: priority,
        topologies: [],
        edge_urls: edge_urls
      ]

      case trunk_keys_from_env() do
        {:ok, keys} -> Keyword.put(cfg, :trunk_keys, keys)
        :error -> cfg
      end
    else
      nil
    end
  end

  defp apply_cluster_lab! do
    case cluster_lab_config() do
      nil ->
        :ok

      cfg ->
        Application.put_env(:xylon, :cluster, cfg)
        :ok
    end
  end

  defp cluster_summary do
    case Application.get_env(:xylon, :cluster, []) do
      cfg when is_list(cfg) ->
        if Keyword.get(cfg, :enabled, false) do
          "on region=#{Keyword.get(cfg, :region_id)} priority=#{Keyword.get(cfg, :hub_priority)}"
        else
          "off"
        end

      _ ->
        "off"
    end
  end

  defp parse_edge_urls(nil), do: %{}
  defp parse_edge_urls(""), do: %{}

  defp parse_edge_urls(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) ->
        Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)

      _ ->
        %{}
    end
  end

  defp trunk_keys_from_env do
    names = ~w(XYLON_TRUNK_KEY_AB XYLON_TRUNK_SALT_AB XYLON_TRUNK_KEY_BA XYLON_TRUNK_SALT_BA)

    if Enum.all?(names, &(System.get_env(&1) not in [nil, ""])) do
      {:ok,
       [
         key_ab: hex_bin!(System.get_env("XYLON_TRUNK_KEY_AB")),
         salt_ab: hex_bin!(System.get_env("XYLON_TRUNK_SALT_AB")),
         key_ba: hex_bin!(System.get_env("XYLON_TRUNK_KEY_BA")),
         salt_ba: hex_bin!(System.get_env("XYLON_TRUNK_SALT_BA"))
       ]}
    else
      :error
    end
  end

  defp hex_bin!(<<"0x", hex::binary>>), do: Base.decode16!(hex, case: :mixed)
  defp hex_bin!(hex) when is_binary(hex), do: Base.decode16!(hex, case: :mixed)

  defp audio_lab_hint(:sfu) do
    "SFU: mesh auto-subscribes A/V from offer SSRCs (or manual subscribe)."
  end

  defp audio_lab_hint(:mcu) do
    """
    MCU lab create backend_opts (JSON):
      {"audio":"mcu","video":"sfu","subscribe_mode":"mesh"}
    One mix mid (default \"0\") sendrecv; mesh auto-subscribes video only;
    audio is the room mix egress (mix-minus-self for local talkers).
    """
  end

  defp require_ice! do
    Xylon.Ice.ensure_configured!()
  rescue
    e in ArgumentError -> Mix.raise(Exception.message(e))
  end

  defp apply_control(nil), do: :ok
  defp apply_control("off"), do: :ok

  defp apply_control("lab") do
    Application.put_env(:xylon, :control, base_control(auth: :lab))
  end

  defp apply_control("hmac") do
    secret = System.get_env("XYLON_CONTROL_HMAC_SECRET") || "lab-hmac-secret"

    hmac_opts =
      case System.get_env("XYLON_CONTROL_SECRETS_URL") do
        url when is_binary(url) and url != "" ->
          [auth: :hmac, hmac_secret: secret, secrets: {Xylon.Control.Secrets.Local, [url: url]}]

        _ ->
          [auth: :hmac, hmac_secret: secret]
      end

    Application.put_env(:xylon, :control, base_control(hmac_opts))
  end

  defp apply_control("jwt") do
    jwks_url = System.get_env("XYLON_CONTROL_JWKS_URL")

    unless is_binary(jwks_url) and jwks_url != "" do
      Mix.raise("--control jwt requires XYLON_CONTROL_JWKS_URL")
    end

    opts = [auth: :jwt, jwks_url: jwks_url]

    opts =
      case System.get_env("XYLON_CONTROL_JWT_ISS") do
        iss when is_binary(iss) and iss != "" -> Keyword.put(opts, :jwt_iss, iss)
        _ -> opts
      end

    opts =
      case System.get_env("XYLON_CONTROL_JWT_AUD") do
        aud when is_binary(aud) and aud != "" -> Keyword.put(opts, :jwt_aud, aud)
        _ -> opts
      end

    Application.put_env(:xylon, :control, base_control(opts))
  end

  defp apply_control(other) do
    Mix.raise("unknown --control #{inspect(other)} (use hmac, jwt, lab, or off)")
  end

  defp apply_recording! do
    case System.get_env("XYLON_RECORD_DIR") do
      dir when is_binary(dir) and dir != "" ->
        unless Code.ensure_loaded?(XylonRecord.Handler) do
          Mix.raise(
            "XYLON_RECORD_DIR set but XylonRecord.Handler is not loaded (XTURN_LOCAL_DEPS=1?)"
          )
        end

        File.mkdir_p!(dir)
        queue_max = parse_positive_int(System.get_env("XYLON_RECORD_QUEUE_MAX"), 2000)

        Application.put_env(:xylon, :recording,
          handler: XylonRecord.Handler,
          dir: dir,
          queue_max: queue_max
        )

      _ ->
        :ok
    end
  end

  defp parse_positive_int(nil, default), do: default

  defp parse_positive_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp recording_summary do
    case Application.get_env(:xylon, :recording, []) do
      cfg when is_list(cfg) ->
        case Keyword.get(cfg, :handler) do
          mod when is_atom(mod) and mod != nil ->
            dir = Keyword.get(cfg, :dir) || "?"
            "handler=#{inspect(mod)} dir=#{dir}"

          _ ->
            "off"
        end

      _ ->
        "off"
    end
  end

  defp base_control(extra) do
    [
      enabled: true,
      topics: %{"chat" => %{label: "chat"}},
      quotas: %{max_participants: 50, inject_per_minute: 120, join_per_minute: 60},
      history_limit: 100,
      history_max_bytes: 4096
    ]
    |> Keyword.merge(extra)
    |> maybe_webhooks()
    |> maybe_grpc_port()
  end

  defp maybe_webhooks(opts) do
    opts
    |> put_env_opt(:webhook_url, "XYLON_CONTROL_WEBHOOK_URL")
    |> put_env_opt(:webhook_secret, "XYLON_CONTROL_WEBHOOK_SECRET")
    |> put_env_opt(:webhook_dlq_path, "XYLON_CONTROL_WEBHOOK_DLQ_PATH")
  end

  defp maybe_grpc_port(opts) do
    case System.get_env("XYLON_CONTROL_GRPC_PORT") do
      port_s when is_binary(port_s) and port_s != "" ->
        case Integer.parse(port_s) do
          {port, ""} when port > 0 -> Keyword.put(opts, :grpc_port, port)
          _ -> opts
        end

      _ ->
        opts
    end
  end

  defp put_env_opt(opts, key, env_name) do
    case Keyword.get(opts, key) || System.get_env(env_name) do
      val when is_binary(val) and val != "" -> Keyword.put(opts, key, val)
      _ -> opts
    end
  end

  defp control_summary do
    cfg = Application.get_env(:xylon, :control, [])

    if Keyword.get(cfg, :enabled, false) do
      auth = Keyword.get(cfg, :auth, :lab)
      parts = ["enabled auth=#{auth}"]

      parts =
        case Keyword.get(cfg, :grpc_port) do
          port when is_integer(port) and port > 0 -> parts ++ ["grpc_port=#{port}"]
          _ -> parts
        end

      parts =
        case Keyword.get(cfg, :webhook_url) do
          url when is_binary(url) and url != "" ->
            path = Keyword.get(cfg, :webhook_dlq_path) || "(tmp default)"
            parts ++ ["webhooks=on dlq=#{path}"]

          _ ->
            parts
        end

      Enum.join(parts, " ")
    else
      "disabled"
    end
  end
end
