# Xylon Conference Backend

Room media library for [Xylon](https://github.com/Lazarus404/xylon): audio +
video over `Xylon.Forwarder` and `XGW.Peer.SendHandle`. Default audio is SFU;
optional `audio: :mcu` mixes contributors once per room.

Ported and updated from an earlier Xirsys conference implementation; 
released for public use.

## What problem this solves

In a multiparty call, each participant sends their own microphone and camera.
Sending every stream to every other participant (a mesh) scales poorly.

A Selective Forwarding Unit (SFU) receives each stream once and forwards only
the streams each viewer subscribed to, rewriting RTP headers so browsers accept
them. That is the default for audio and video (`audio: :sfu`, `video: :sfu`).

Rooms may instead use an audio MCU (`audio: :mcu`, `video: :sfu`): the server
decodes mixable codecs into a shared PCM bus, mixes once, and sends each
listener a single Opus (or negotiated) mix stream. Video stays SFU in the same
Session.

This package is the `:conference` backend for Xylon: attach it at boot, create
sessions with catalogue id `:conference`, and use mesh or manual subscribe modes,
feeds discovery, talking detection, and simulcast layer selection.

## Main modules

- `Xylon.Conference` -- attach and plan-level publish/subscribe API
- `Xylon.Conference.Backend` -- `Xylon.Backend` SFU + MCU implementation
- `Xylon.Conference.Allocator` -- receive-side REMB/TWCC layer recommendations (opt-in)
- `Xylon.Conference.Dynacast` -- opt-in SIM uplink pause via Control WS `publish_layers`
- `Xylon.Conference.Bwe.Twcc` -- shared TWCC bitrate estimate (MCU + SFU adaptive)
- `Xylon.Conference.Plan` -- ETS subscribe graph and per-route rewrite state
- `Xylon.Conference.Runtime` -- ETS media runtime (ext ids, TWCC, talking, REMB, FIR, MCU rows)
- `Xylon.Conference.SessionHooks` -- publish/subscribe with Forwarder refresh
- `Xylon.Conference.OfferTracks` -- parse inbound SSRCs from offer SDP
- `Xylon.Conference.Rewrite` -- pure RTP header rewrite for fanout
- `Xylon.Conference.Rtcp` -- PLI/FIR fan-in toward publishers
- `Xylon.Conference.AudioLevel` -- RFC 6464 talking detector
- `Xylon.Conference.Mcu.*` -- internal MCU decode / mix / egress / cascade helpers
  (`Mcu.Mixer`, `Mcu.Accel`, `Mcu.Native` for optional dirty-CPU mix)
- `Mix.Tasks.Xylon.Conference` -- HTTP Lab Mix task (`--audio sfu|mcu`)
- `Mix.Tasks.Xylon.Conference.McuSoak` -- mix_tick density soak (p50/p99, overruns)

## RFCs

- [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) (RTP and RTCP)
- [RFC 6464](https://www.rfc-editor.org/rfc/rfc6464) (RTP audio level header extension)
- [RFC 6716](https://www.rfc-editor.org/rfc/rfc6716) (Opus; MCU egress and cascade profile)
- [RFC 3264](https://www.rfc-editor.org/rfc/rfc3264) (SDP offer/answer; via [XSDP](https://github.com/Lazarus404/xsdp))
- [RFC 8829](https://www.rfc-editor.org/rfc/rfc8829) (JSEP; browser signaling through Xylon)
- [RFC 8445](https://www.rfc-editor.org/rfc/rfc8445) (ICE; via [XGW](https://github.com/Lazarus404/xgw))
- [RFC 3711](https://www.rfc-editor.org/rfc/rfc3711) (SRTP on the wire; SFU rewrite runs on plaintext after decrypt)
- [RFC 4585](https://www.rfc-editor.org/rfc/rfc4585) (PLI RTCP feedback for video keyframes)

## Attach

```elixir
:ok = Xylon.Conference.attach()
# or: Xylon.attach(Xylon.Conference.Backend)

{:ok, session} =
  Xylon.Session.create(tenant_id, session_id, :conference,
    audio: :sfu,
    video: :sfu,
    subscribe_mode: :mesh,
    max_publishers: nil
  )
```

MCU audio (video remains SFU):

```elixir
{:ok, session} =
  Xylon.Session.create(tenant_id, session_id, :conference,
    audio: :mcu,
    video: :sfu,
    subscribe_mode: :mesh
  )
```

Catalogue id: `:conference`.

Default strategies: `%{audio: :sfu, video: :sfu, application: :none}`.
`audio: :mcu` with `video: :sfu` enables the MCU audio mix (Opus / PCMU /
PCMA / G.722, shared encode, mix-minus-self, PLC, RTP timestamp drift
align, CN/DTMF inactive path, optional egress CN, soft limiter, mix audio-level
extension, conference-owned mix Sender Reports, REMB- and TWCC-driven Opus
bitrate). Opus `useinbandfec=1` enables in-band FEC on mix egress encode and Contributor
ingress recovery (`decode_fec` / `decode_plc` with PCM PLC fallback).
G.711/G.722 gaps use PCM PLC only. Mix BWE uses subscriber TWCC about the mix
SSRC when transport-cc is negotiated (min with REMB when both exist); REMB-only
otherwise.
`video: :mcu` is rejected at init.

### Client notes (MCU)

- Negotiate **one** audio mid for the mix (`mcu_mix_mid`, default `"0"`). Use
  sendrecv on that mid; the server does not invent a second synthetic mix mid.
- Under MCU, listeners receive the **room mix** RTP (mix-minus-self for local
  talkers). Do not expect per-publisher audio SSRCs on the wire to listeners.
- Mesh mode still auto-subscribes **video** only; audio arrives via mix egress.
- Cascade: hub uses `mcu_cascade: :hub`; spoke uses `mcu_cascade: :spoke` with
  `audio: :sfu` (SFU of `__mcu_mix__`) or `audio: :mcu` (spoke mix-of-mixes).
  Default trunk is Opus 48 kHz; set `mcu_cascade_trunk_profile: :pcm` on both
  edges for L16. Trunk mix is full by default or spoke mix-minus when the hub
  sets `mcu_spoke_mix_minus: true`.

### Room opts (Janus-aligned)

| Opt | Default | Meaning |
| --- | --- | --- |
| `subscribe_mode` | `:mesh` | `:mesh` auto-subscribes everyone to everyone on `media_ready`. `:manual` publishes only; clients call subscribe. `:policy` is not supported (YAGNI until a real app needs server-side topology rules); use `:manual` + app subscribe. |
| `max_publishers` | `nil` (unlimited) | Cap on participants with published A/V. Exceeding fails the offer with `:max_publishers`. |
| `audiolevel_events` | `false` | Emit Control WS `talking` / `stopped-talking` from RFC 6464 audio levels (does not auto-subscribe). |
| `audio_active_packets` | `100` | Sliding window size for talking detection (Janus name). |
| `audio_level_average` | `25` | Threshold (0 loud .. 127 quiet); talking when window average `<=` this value. |
| `bitrate_cap` | `nil` | Optional ceiling (bps) applied when translating subscriber REMB toward publishers. |
| `adaptive_layers` | `false` | When `true`, subscriber REMB (and TWCC-bps when transport-cc is stamped on SFU fanout) drive receive-side SIM `substream` / VP8 `temporal` or SVC `spatial_layer` / `temporal_layer` via `Allocator` (2-update hysteresis; effective bitrate is `min(REMB, TWCC)` when TWCC is present). App `subscribe` / `set_substream` with layer opts is sticky manual and is never overridden. SIM spatial/SSRC switch keeps the subscriber `out_ssrc`. |
| `dynacast` | `false` | When `true`, aggregates max required SIM substream across subscribers and pushes Control WS `publish_layers` to the publisher so the SDK can set `encodings[].active`. SIM only (not one-SSRC SVC). Independent of `adaptive_layers`. |
| `twcc_period_ms` | `100` | How often to emit transport-cc feedback toward each publisher (Janus-style period). |
| `fir_interval_ms` | `0` | When `> 0`, send a PLI to each video publisher with subscribers on this interval while video RTP flows (`0` = off; Janus `fir_freq`). |
| `require_publish_cap` | `false` | When `true`, publishing tracks requires Control capability `"publish"` (or map `publish: true`) via `:authorize`. Spectators join/subscribe without it. |
| `mcu_top_n` | `nil` | When `audio: :mcu`, cap active mix contributors to N loudest (`nil` = unlimited). |
| `mcu_level_hysteresis` | `10` | MCU mix gate hysteresis on the RFC 6464 / energy level scale. |
| `mcu_plc_max` | `5` | Max consecutive PCM PLC packets for a contributor sequence gap. |
| `mcu_jb_target` | `2` | Startup playout hold depth before first JB drain (0..8). |
| `mcu_drift_max_pad` | `960` | Max bus samples padded per packet when RTP ts runs behind decode. |
| `mcu_dtx_hold_ticks` | `3` | Silent mix ticks before optional egress CN (when CN PT negotiated). |
| `mcu_sr_interval_ms` | `1000` | Min interval between mix Sender Reports per listener. |
| `mcu_opus_bitrate_bps` | `32000` | Initial Opus encode bitrate before subscriber REMB/TWCC. |
| `mcu_max_participants` | `nil` | When `audio: :mcu`, cap participants in this room (`nil` = unlimited). Exceeding fails join with `:mcu_max_participants`. |
| `mcu_max_contributors` | `nil` | When `audio: :mcu`, cap concurrent audio send contributors (`nil` = unlimited). Exceeding fails `media_ready` with `:mcu_max_contributors`. |
| `mcu_cascade` | `nil` | `:hub` requires `audio: :mcu` (mix once). `:spoke` allows `audio: :sfu` (SFU fanout of remote mix) or `audio: :mcu` (spoke mix-of-mixes). Trunk raw talkers to hub either way. `nil` = single-node. |
| `mcu_mix_mid` | `"0"` | SDP mid announced for the hub mix track on spokes. |
| `mcu_nif` | app default | When `true`/`false`, force MCU mix NIF on/off for this room. Omit to use Application `:mcu_accel`. |
| `mcu_spoke_mix_minus` | `false` | Hub only (`mcu_cascade: :hub`). When `true`, each trunk receives mix excluding contributors that arrived on that trunk (spoke talkers do not hear themselves in `__mcu_mix__`; local SFU still carries peer talkers). Default `false` keeps full trunk mix. |
| `mcu_cascade_trunk_profile` | `:opus` | Cascade trunk codec. `:opus` (default) or `:pcm` (L16 PCM16LE mono @ 48 kHz / 20 ms, PT 96). Must match on hub and spoke or announce fails with `:mcu_cascade_profile_mismatch`. |

### MCU mix NIF

`Mixer.mix_tick/2` uses a dirty-CPU NIF (`priv/mcu_mix_nif.so`) when enabled and
loaded. `mix compile` builds it via the `:mcu_nif` compiler (`make`); you can
also run `make` by hand. If `make` fails or the `.so` is missing/wrong-arch,
mix falls back to Elixir silently (compile still succeeds).

Node-wide default (on):

```elixir
config :xylon_conference_backend, :mcu_accel, enabled: true
```

Force Elixir without config:

```bash
MCU_ACCEL=0 mix test
```

Or set `enabled: false` / room `mcu_nif: false`. `MCU_ACCEL=1` forces NIF
attempt when Application would disable it. Room `mcu_nif:` always wins.

### MCU soak + telemetry

Density microbench (synthetic contributors, no SFU load clone):

```bash
XTURN_LOCAL_DEPS=1 mix xylon.conference.mcu_soak
XTURN_LOCAL_DEPS=1 mix xylon.conference.mcu_soak --ticks 200 --contributors 8 --nif true
```

Prints p50/p99 `duration_us`, overrun count vs the 20 ms tick budget, and
exits non-zero when overrun rate exceeds `--max-overrun-rate` (default 0.05).

Attach recipe (no Grafana required):

```elixir
:ok =
  :telemetry.attach(
    "mcu-tick-log",
    [:xylon, :conference, :mcu, :tick],
    fn _event, %{duration_us: us, overrun: o, encode_groups: g} = m, meta, _cfg ->
      if o == 1 do
        require Logger
        Logger.warning("mcu tick overrun us=#{us} groups=#{g} meta=#{inspect(meta)} m=#{inspect(m)}")
      end
    end,
    nil
  )

:ok =
  :telemetry.attach(
    "mcu-codec-error",
    [:xylon, :conference, :mcu, :codec_error],
    fn _event, _m, meta, _cfg ->
      require Logger
      Logger.error("mcu codec_error #{inspect(meta)}")
    end,
    nil
  )
```

HTTP Lab / Playwright prove cascade opts (spoke mix-minus, PCM trunk, spoke MCU)
on Chrome, Firefox, and WebKit via the workspace `e2e/` matrix
(`npm run test:p18` / `./scripts/e2e-l3-browser.sh`).

### Node MCU quota

Node-wide caps (Application `:mcu_quota`) reject new mixers / contributors
loudly (`:mcu_max_mixers`, `:mcu_max_contributors`). Room opts
`mcu_max_participants` / `mcu_max_contributors` fail join / `media_ready` the
same way. Covered in ExUnit (`admission_test`, `quota_test`).

### MCU cascade (hub-mix)

Bidirectional mix-once over `XGW.Trunk.Pipe`:

- Hub (`mcu_cascade: :hub`): remote trunk talkers become MCU contributors; one
  mix RTP goes to each trunk (Opus or L16 per `mcu_cascade_trunk_profile`).
  Default is **full** mix (spoke self-hear accepted). With `mcu_spoke_mix_minus: true`,
  the trunk mix excludes contributors attributed to that trunk.
- Spoke (`mcu_cascade: :spoke`): SFU-forwards local publishers up the trunk.
  With `audio: :sfu`, installs announced `__mcu_mix__` and SFU-fanouts to locals.
  With `audio: :mcu`, decodes `__mcu_mix__` as a contributor and mixes with
  local talkers (mix-of-mixes); locals get spoke MCU egress.
  Subscribing the trunk to `__mcu_mix__` is rejected (`:mcu_mix_trunk_loop`).
- Default cascade trunk is **Opus 48 kHz**; `mcu_cascade_trunk_profile: :pcm`
  selects L16 on the Pipe (both edges must agree). SFU spokes edge-transcode
  the L16 mix to Opus for local listeners so WebRTC peers are not handed raw L16.
- `Manager.connect_pair/3` and `Manager.connect_remote/3` auto-announce the hub
  mix onto the spoke after the trunk is up. Manual refresh:
  `Cascade.announce_mix/3` (same node) or `Cascade.announce_mix_remote/4`.
- Lab "A+B" means hub mixes local and remote contributors; listeners on either
  edge hear that one mix (or spoke MCU remix of hub mix + locals).

Node-wide MCU caps (Application env, all `nil` = unlimited):

```elixir
config :xylon_conference_backend, :mcu_quota,
  max_mixers: nil,
  max_participants: nil,
  max_contributors: nil
```

Over node `max_mixers`, `Session.create` with `audio: :mcu` fails with `:mcu_max_mixers`.
MCU never silently falls back to SFU.

Telemetry events under `[:xylon, :conference, :mcu, event]`:

| Event | Meaning |
| --- | --- |
| `:tick` | Mix tick; measurements include `duration_us`, `overrun`, `active_contributors`, `encode_groups`, `cpu_millis` |
| `:codec_error` | Decode/encode failure; `meta.op` is `:decode` or `:encode` |

JSON create `backend_opts`:

```json
{
  "subscribe_mode": "manual",
  "max_publishers": 6,
  "require_publish_cap": true,
  "audiolevel_events": true,
  "audio_active_packets": 100,
  "audio_level_average": 25
}
```

Conference answers accept `urn:ietf:params:rtp-hdrext:ssrc-audio-level` when the
client offers it. Talking edges fan out on the Control presence channel as
`talking` / `stopped-talking` (with `participant_id` and `audio_level_dbov_avg`).

### Feeds (publishers list)

Membership `presence.*` is join/leave only. Active A/V publishers use **feeds**:

- On Control WS join: `feeds.snapshot` with `publishers[]` (`participant_id`,
  `streams: [{mid, kind, codec?}, ...]`)
- On `media_ready`: `feeds.diff` action `published`
- On `unpublish` (selected mids): `feeds.diff` `published` with remaining streams, or
  `unpublished` when none remain (participant stays in the room)
- On leave: `feeds.diff` action `unpublished`

The app then calls `subscribe` / `unsubscribe` / `update` by mid. Feeds do not
auto-subscribe.

Feeds and talking frames require Control enabled with Presence running
(`--control hmac` / `lab` / `jwt`). HTTP-only without Presence cannot discover
publishers via `feeds.*`.

## Broadcast / webinar pattern

Broadcast is the same conference SFU with two permission classes: people who may
**publish** A/V and people who only **spectate** (subscribe).

Recommended room opts:

- `subscribe_mode: :manual`
- `max_publishers: N` (e.g. 1 host or a small panel)
- `require_publish_cap: true` when Control HMAC/JWT is on

Mint publisher tokens with capability `"publish"` (or map `publish: true`).
Spectator tokens omit it -- they can still join and subscribe to feeds, but
offers that try to publish are rejected (`403` / `:forbidden`). Spectators
should use recvonly (or no camera) in the client; the server gate is the
authority.

Panel members subscribe to each other via the same feeds + subscribe path as
the audience. Do not use `:mesh` for large audiences.

## App path (manual subscribe)

When `subscribe_mode` is `manual`, the app listens to feeds and calls subscribe.
`:mesh` skips this path (server mesh-subscribes on `media_ready`).

### Run with Control

Build [xylon-test-client](https://github.com/Lazarus404/xylon-test-client), then:

```bash
XYLON_ADVERTISED_IP=127.0.0.1 XTURN_LOCAL_DEPS=1 mix xylon.conference --http-port 8080 --control hmac
```

(`--control lab` or `jwt` also work; omit `--control` only for mesh HTTP Lab.)

### Create (HTTP)

```json
{
  "session_id": "room-1",
  "library": "conference",
  "backend_opts": { "subscribe_mode": "manual" }
}
```

### Join (Control WS)

Include the same `backend_opts` on the first join that creates the session.
The HTTP Lab / Control WS test client sends `subscribe_mode: manual` automatically
when `library=conference`.

### Listen and subscribe

1. Two participants, different `participant_id`; each offers when publishing.
2. On `feeds.snapshot` / `feeds.diff` action `published`, for each remote publisher
   and each stream mid, send Control WS
   `{"type":"subscribe","publisher_id":"...","mid":"0"}` (and other mids as needed),
   or use the HTTP subscribe curl below / bulk `update`. Never subscribe to self.
3. On `unpublished`, unsubscribe those mids. On `published` replace, unsubscribe
   mids that disappeared for that participant.
4. Mesh (`subscribe_mode` omitted or `"mesh"`) skips steps 2-3.

Optional: `talking` / `stopped-talking` for layout only -- never auto-subscribe
from levels. For loudest tiles, the app may `switch` publishers and/or select a
simulcast `substream` (0..n-1) on subscribe or later via `set_substream`.
Room opt `adaptive_layers: true` (default off) lets REMB (and TWCC-bps when
present) drive those picks automatically. Room opt `dynacast: true` (default
off) pauses unused SIM publisher encodings via Control WS `publish_layers` and
the SDK (`encodings.active`). Soft spot: RIDs that never send stay unbound
(`no_layer` until RTP).
VP8 SIM also accepts `temporal` (max TID to forward). VP9 / AV1 one-SSRC SVC
accepts `spatial_layer` / `temporal_layer` (Janus names). AV1 / VP9 DD use
Chrome/WebRTC Dependency Descriptor bit packing (plus lab FakePeer formats):
the SFU parses template structure once per inbound packet (publisher + mid),
rewrites ADT per subscriber caps without writing cap-masked structure back to
the shared cache, and auto-breaks the frame chain on missing fdiffs until a
structure packet.
SDK `videoPublish` / Chrome `@svc` e2e (`scripts/e2e-svc.sh`) cover
`scalabilityMode` and SIM publish with RID layer learn (`set_substream` by
`rid`).

```json
{"type":"subscribe","publisher_id":"alice","mid":"1","substream":1,"temporal":0}
```

```json
{"type":"subscribe","publisher_id":"alice","mid":"1","spatial_layer":1,"temporal_layer":0}
```

```json
{"type":"set_substream","publisher_id":"alice","mid":"1","substream":0}
```

HTTP: `POST /v1/sessions/:id/set_substream` with the same JSON body fields
(`publisher_id`, `mid`, optional `substream` / `rid` / `temporal` /
`spatial_layer` / `temporal_layer`).

Elixir: `Xylon.Conference.set_substream(plan, me, them, "1", substream: 2)` or
`temporal: 1` alone (no PLI). Spatial / SSRC change still requests a video PLI.
Dropped higher-TID packets call `Rewrite.note_inbound/2` (advance inbound
cursor, no send) so outbound sequence stays contiguous.

## HTTP Lab (conference + datachannel + echo)

Build [xylon-test-client](https://github.com/Lazarus404/xylon-test-client), then:

```bash
XYLON_ADVERTISED_IP=127.0.0.1 XTURN_LOCAL_DEPS=1 mix xylon.conference --http-port 8080
```

For feeds/talking discovery, add `--control hmac` (see App path above).

Open http://127.0.0.1:8080/client/ **HTTP Lab**:

- `library=conference` -- two tabs, same session id, different participant ids; mic (and optional video); lab UI sends `subscribe_mode: manual` (call subscribe yourself on feeds events, or use mesh by creating the session without those opts)
- `library=datachannel` -- chat fanout (same as `mix xylon.datachannel`)
- `library=echo` -- A/V loopback

## Publish / subscribe

Routes are keyed by SDP **mid** (not audio/video kind). Kind remains a field on
each published track for codecs and detectors.

Elixir (plan API or Session):

```elixir
plan_ref = Xylon.Session.plan_ref(session)
fwd = Xylon.Session.forwarder(session)

:ok = Xylon.Conference.publish(plan_ref, "alice", %{mid: "0", kind: :audio, ssrc: inbound_ssrc})
:ok = Xylon.Conference.subscribe(plan_ref, "bob", "alice", "0", forwarder: fwd)
# or:
:ok = Xylon.Session.subscribe(session, "bob", "alice", "0")

# Bulk replace desired streams:
:ok = Xylon.Session.update_subscriptions(session, "bob", [
       %{publisher_id: "alice", mid: "0"},
       %{publisher_id: "alice", mid: "1"}
     ])
```

HTTP (lab / Control; subscriber id from `participant_id` query or token, not body).
Under `:hmac` / `:jwt`, the token `participant_id` is identity; a query
`participant_id` must match or the request is 403 (require_pvtid-style).

```bash
curl -sS -X POST "http://127.0.0.1:8080/v1/sessions/room-1/subscribe?participant_id=bob" \
  -H "x-tenant-id: t1" -H "content-type: application/json" \
  -d '{"publisher_id":"alice","mid":"0"}'

curl -sS -X POST "http://127.0.0.1:8080/v1/sessions/room-1/update?participant_id=bob" \
  -H "x-tenant-id: t1" -H "content-type: application/json" \
  -d '{"streams":[{"publisher_id":"alice","mid":"0"},{"publisher_id":"alice","mid":"1"}]}'
```

Control WS frames after `join`: `{"type":"subscribe","publisher_id":"alice","mid":"1"}`
(and `unsubscribe`). With `:hmac` / `:jwt`, join cannot override the token
`participant_id`. Omit `mid` on subscribe to take every published mid on that
publisher (`subscribe_all`). Optional `substream` / `rid` on subscribe for simulcast.
`{"type":"switch","publisher_id":"...","mid":"1"}` rebinds without renegotiation.
`{"type":"update","streams":[...]}` replaces the subscriber's desired set.
Elixir `pause` / `resume` pause a route (`send: false`) without unsubscribing.

### Unpublish vs mute vs leave vs kick

| Action | API | Effect |
| --- | --- | --- |
| Mute / pause | `Session.moderate_av` / Control `moderate` mute | Pauses outbound fanout (`set_send`); track stays published and in feeds. Optional body `"mids":["0"]` (omit = all published). |
| Unpublish | `Session.unpublish(session, id, mids)` | Deletes selected mids and routes; feeds refresh or `unpublished`; participant stays |
| Leave | `Session.leave` / `DELETE .../participants/:id` | Removes participant, tracks, subscriptions, and feed |
| Kick | Control `moderate` `action: "kick"` | Force leave (same leave path / feeds `unpublished`); optional `"ban": true` in one request |

```json
{"action":"kick","participant_id":"alice","ban":true,"notice":true,"reason":"spam"}
```

```elixir
:ok = Xylon.Session.unpublish(session, "alice", ["1"])
:ok = Xylon.Session.unpublish(session, "alice")  # all mids
```

HTTP: `POST .../unpublish?participant_id=alice` with JSON body
`{"mids":["1"]}` (omit `mids` to unpublish all). Control WS:
`{"type":"unpublish","mids":["1"]}`. Re-publish with a new offer -> `media_ready`.

HTTP switch: `POST .../switch` with the same JSON body as subscribe.

Destination maps use `type: :peer` for local participants. `type: :trunk` uses the
same rewrite and Forwarder send path. Multi-home lab cascade uses
`Xylon.Trunk.Manager.connect_remote/3` + `XGW.Trunk.Pipe` (see Xylon SCALING);
this package keeps Plan `:trunk` subscribe only.

## Local deps

```bash
XTURN_LOCAL_DEPS=1 mix deps.get
XTURN_LOCAL_DEPS=1 mix test
```

`mix compile` / `mix test` build `priv/mcu_mix_nif.so` (or run `make`). Elixir
mix path works if the NIF build fails. Force Elixir with `MCU_ACCEL=0`.
