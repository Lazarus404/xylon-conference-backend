# Architecture

`xylon-conference-backend` is one attachable `Xylon.Backend` (catalogue id `:conference`).

## SFU path (default)

```text
Peer (publisher)
    |  {:xgw, :rtp, ...}
    v
Xylon.Forwarder
    |  handle_rtp
    v
Xylon.Conference.Backend
    |  Plan ETS routes + Rewrite
    |  {:forward, specs}
    v
Xylon.Forwarder -> XGW.Peer.SendHandle -> Peers (subscribers)
```

## MCU audio path (`audio: :mcu`, `video: :sfu`)

Video keeps the SFU path above. Published audio SSRCs take the MCU branch:

```text
Publisher RTP
    -> Forwarder -> Backend.handle_rtp
         | audio: :mcu and published audio SSRC
         v
    Contributor.decode -> Runtime PCM slot
         -> Mcu.tick -> Mixer -> shared encode groups
         -> Egress.packetize -> {:forward, specs}
         -> Forwarder / SendHandle (and trunk Pipe when cascade hub)
```

- Mix mid bind (`Mcu.CodecBind`): one negotiated audio mid (default / `mcu_mix_mid`
  `"0"`); no synthetic second mid.
- Local talkers get mix-minus-self; trunk destinations on a cascade hub get
  full mix by default, or spoke mix-minus when `mcu_spoke_mix_minus: true`.
- Mesh subscribe under MCU auto-wires **video** only; audio reaches listeners
  via mix egress.

## Plan ETS

`Xylon.Conference.Plan` is keyed by Session pid (`plan_ref`) so Session and
Forwarder (each calling `Backend.init/2`) share one subscribe graph.

Rows cover participants, published tracks (kind + inbound SSRC), subscriber
sets, destinations (`:peer` | `:trunk`), and per-route rewrite state (outbound
SSRC, seq/ts continuity).

## Runtime ETS

`Xylon.Conference.Runtime` is keyed by the same `plan_ref`. It holds media
fields that Session writes and Forwarder reads (or that leave must scrub):

- negotiated TWCC / audio-level extension ids (`media_ready`)
- TWCC arrival queues and flush clocks
- talking detector state
- REMB fan-in rates
- periodic FIR timestamps
- MCU contributor decode rows and PCM slots
- MCU egress encoders / packetizers and shared encode groups
- MCU level / DTX hold state

`backend_state` keeps room opts only (`twcc_period_ms`, `audiolevel_events`,
`mcu_*`, …). Dual init stays intentional; Plan + Runtime are the shared source
of truth.

## Control vs media

- Join / leave / publish / subscribe: control plane (`SessionHooks`, Session).
- Steady-state RTP: Forwarder only (Session mailbox stays clear).
- RTCP (Forwarder -> Backend -> `Conference.Rtcp` / `NackCache` / `Twcc`):
  PLI/FIR toward publishers; Generic NACK retransmission from the outbound
  packet cache to the NACKing subscriber; REMB fan-in/replace toward publishers
  (optional `bitrate_cap`); periodic transport-cc feedback toward publishers
  (`twcc_period_ms`). When `fir_interval_ms > 0`, periodic PLI toward video
  publishers that have subscribers (piggybacked on inbound video RTP).
  Extensions stay stripped on subscriber fanout.
- MCU also owns mix Sender Reports and applies REMB to Opus encode bitrate.

## Strategies

| Kind | Default | Notes |
| --- | --- | --- |
| audio | `:sfu` (default) or `:mcu` | MCU: multi-codec mix, drift/JB/CN, soft limiter, mix SR/REMB |
| video | `:sfu` | MCU rejected at init |
| application | `:none` | Datachannel fanout is a separate library |

## Cascade (hub-mix)

Multi-region rooms use one mix hub and SFU or MCU spokes:

- Hub: `audio: :mcu`, `mcu_cascade: :hub` -- remote trunk talkers become
  contributors; one mix stream per trunk (Opus default, or L16 when
  `mcu_cascade_trunk_profile: :pcm`; full by default; spoke mix-minus when
  `mcu_spoke_mix_minus: true`).
- Spoke SFU: `audio: :sfu`, `mcu_cascade: :spoke` -- SFU local talkers up the
  trunk; SFU-fanout announced `__mcu_mix__` to local listeners when trunk is
  Opus. With `mcu_cascade_trunk_profile: :pcm`, decode L16 mix and egress Opus
  to locals (edge transcode; no raw L16 SFU to peers).
- Spoke MCU: `audio: :mcu`, `mcu_cascade: :spoke` -- decode remote mix as a
  contributor; mix with local talkers; egress local mix-minus; raw talkers
  still trunk to the hub.
- Media on `XGW.Trunk.Pipe` (UDP+SRTP). Announce is control-only.
- Trunk subscribe to `__mcu_mix__` is rejected (`:mcu_mix_trunk_loop`).
- Hub and spoke trunk profiles must match or announce fails
  (`:mcu_cascade_profile_mismatch`).

Lab proof: workspace Playwright projects `chrome` / `firefox` / `webkit` drive
the HTTP Lab cascade opts (including PCM trunk and spoke MCU). Operators can
run `mix xylon.conference.mcu_soak` for mix_tick p50/p99 and overrun rate, and
attach `[:xylon, :conference, :mcu, :tick]` / `:codec_error` via `:telemetry`
(see package README).
