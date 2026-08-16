# ws4kp-stream

Headless pipeline that renders a [ws4kp](https://github.com/snachodog/ws4kp) WeatherStar 4000+
instance in a real browser and streams it out as a continuous video feed (RTMP, or a local HLS
preview) — no OBS, no attached monitor, no desktop required.

Runs as a sidecar next to the `ws4kp` container. `docker-compose.yaml` deploys both together as one
Portainer stack.

## How it works

1. **Xvfb** — a virtual X11 display, sized slightly larger than the capture resolution (see
   "Mouse cursor" below).
2. **fluxbox** — a minimal window manager. Without one, Chromium never receives real X11
   focus/visibility state and throttles its own timers and animations as if it were a backgrounded
   tab — the app gets partway through startup and then just stalls forever. fluxbox gives it a real
   (invisible) focused window.
3. **PulseAudio** — a null-sink audio server. Chromium has no audio device at all without a running
   audio server (visible as ALSA "no such file or directory" errors otherwise), so its output would
   just be dropped. A null sink gives it somewhere to play audio *to*, which ffmpeg then reads back
   from that sink's `.monitor`.
4. **Chromium**, launched `--kiosk` and pointed at `STREAM_URL`.
5. **ffmpeg** captures the X11 display (`x11grab`) and PulseAudio monitor, encodes H.264/AAC, and
   either pushes it to `RTMP_URL` or writes a local HLS preview.

### Mouse cursor

Chromium always renders a cursor sprite, and nothing in this pipeline ever generates real input, so
it would otherwise sit dead-center in every frame forever. `unclutter-xfixes` (the usual fix for
this) was tried first and didn't actually work here. Instead, the virtual display is made 100px
larger than the capture resolution in each dimension, and `xdotool` parks the cursor in that padding
— outside the rectangle ffmpeg actually grabs. It's then physically impossible for the cursor to
appear in the stream, regardless of any cursor-hiding heuristics.

### Audio requirement

Video-only RTMP feeds can connect and encode without any ffmpeg error, but YouTube Live (and most
RTMP ingest) will still never show the stream as "receiving data" — it needs an audio track present.
That's why PulseAudio exists in this pipeline even though the visual output doesn't strictly need
it; pair it with `WSQS_mediaPlaying=true` on the `ws4kp` container (see below) so there's actual
audio to send instead of silence.

## Environment variables

| Variable | Default | Notes |
|---|---|---|
| `STREAM_URL` | `http://ws4kp:8080` | Point this at the `ws4kp` container directly (same Docker network) rather than through a reverse proxy/CDN — one less thing that can break the feed, and avoids bot/JS-challenge risk on an automated headless browser. |
| `RESOLUTION` | `1920x1080` | Capture size. `ws4kp`'s kiosk mode scales to fit, so most resolutions work. |
| `FRAMERATE` | `30` | |
| `BITRATE` / `BUFSIZE` | `4500k` / `9000k` | libx264 CBR settings; YouTube's 1080p30 recommendation is 4500-9000 kbps. |
| `RTMP_URL` | *(empty)* | e.g. `rtmp://a.rtmp.youtube.com/live2/<stream-key>`. Empty falls back to writing an HLS preview to `/output/stream.m3u8` — point `ffplay`/VLC at it to verify the pipeline before you have a real destination. Treat this like a password once it contains a real key. |

## Locking the `ws4kp` display to a fixed configuration

`ws4kp` (server mode) reads any `WSQS_<PARAM>` env var as both a forced default *and* a signal to
hide that setting's control in the browser, so a value set here can't be edited by anyone who
happens to load the page. `docker-compose.yaml` already sets all of these; adjust the values to
change what the stream shows:

- `WSQS_latLonQuery` — the fixed location (zip, city/state, or "airport name city ST USA").
- `WSQS_kiosk=true` — hides all settings UI, not just the ones listed here. Required for a clean
  stream.
- `WSQS_mediaPlaying=true` — turns on `ws4kp`'s background music by default, which is what feeds
  the audio track described above. Without this the stream still works, just silently.
- One `WSQS_<display>=true|false` per panel: `hazards`, `current_weather`, `latest_observations`,
  `hourly`, `hourly_graph`, `travel`, `regional_forecast`, `local_forecast`, `extended_forecast`,
  `almanac`, `spc_outlook`, `radar` — controls which panels are in the rotation.

## Deploying

Both services are already in the one `docker-compose.yaml`; deploy it as a single Portainer stack.
Set the `WSQS_*` and stream env vars either directly in the compose file or as the stack's
environment variables in Portainer (`stack.env`) — the latter is preferred so instance-specific
values (location, stream key) stay out of anything checked into version control.

### Image availability

Published to `ghcr.io/snachodog/ws4kp-stream:latest` via `.github/workflows/build-docker.yaml` on
every push to `main` (mirrors `ws4kp`'s own `build-docker-server.yaml`) — `docker-compose.yaml`
pulls this directly, so the same compose file works on any host without a local build first.

## Testing without a real stream destination

Leave `RTMP_URL` unset and deploy normally. ffmpeg will write a rolling HLS preview to the
`/output` volume mount instead of pushing anywhere:

```bash
ffplay /path/to/output/stream.m3u8
```

## Choosing a destination

Any RTMP-compatible platform works. For YouTube Live: YouTube Studio → **Go Live** → **Stream**
tab (not Webcam) → copy the Stream URL + key, and make sure you're on the correct channel first
(the account switcher, top-right) if the account manages multiple channels. Ingest showing
"Excellent" but Studio stuck on "Preparing stream" usually means no broadcast/event has actually
been created yet (stream health monitors the persistent key, not a specific live event) — or, on a
channel's very first-ever stream, that YouTube is still provisioning transcoding infrastructure,
which can take a few minutes.
