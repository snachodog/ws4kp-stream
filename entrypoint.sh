#!/bin/bash
set -euo pipefail

WIDTH="${RESOLUTION%x*}"
HEIGHT="${RESOLUTION#*x}"

# The virtual screen is padded beyond the captured resolution so the mouse
# cursor can be parked outside the region ffmpeg actually grabs - it's then
# physically impossible for it to appear in the stream, regardless of any
# cursor-hiding heuristics (tried unclutter-xfixes first; it accepted its
# flags without error but never actually hid the cursor here).
PAD=100
VWIDTH=$((WIDTH + PAD))
VHEIGHT=$((HEIGHT + PAD))
PARK_X=$((WIDTH + PAD / 2))
PARK_Y=$((HEIGHT + PAD / 2))

# Clean up stale lock/socket files left behind by an unclean exit of a
# previous run (e.g. a Chromium/ffmpeg crash, OOM kill - `set -euo pipefail`
# means any of those tears down this whole script). Docker's restart policy
# then relaunches entrypoint.sh into the same container filesystem, where
# these files are still on disk even though nothing is listening on them
# anymore. Left in place, Xvfb/PulseAudio/Chromium each refuse to (re)start
# and the container restart-loops forever with no way to recover on its own.
DISPLAY_NUM="${DISPLAY#:}"
rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"
# PulseAudio's real daemon state (pid file, native socket) lives under a
# machine-id-keyed runtime dir it re-derives from ~/.config/pulse on every
# start, not just the custom socket= path we pass below - a stale pid file
# there makes it think a daemon is already running and refuse to start.
rm -f /tmp/pulseaudio.socket
rm -rf /root/.config/pulse /tmp/pulse-*
rm -f /tmp/chromium-profile/Singleton*

echo "[stream] Starting virtual display ${DISPLAY} at ${VWIDTH}x${VHEIGHT} (capturing ${RESOLUTION} from 0,0)"
Xvfb "$DISPLAY" -screen 0 "${VWIDTH}x${VHEIGHT}x24" -nolisten tcp &
sleep 2

echo "[stream] Parking mouse cursor off-capture at ${PARK_X},${PARK_Y}"
xdotool mousemove "$PARK_X" "$PARK_Y"

# Without a window manager, Chromium never gets X11 focus/visibility state and
# treats the page as backgrounded, throttling its timers/animations - the app
# gets partway through startup and then just stalls. fluxbox gives it a real
# (invisible, since nothing else is on screen) focused/foreground window.
echo "[stream] Starting window manager"
fluxbox &
sleep 2

# Chromium has no audio device without a running audio server (see the ALSA
# "no such file or directory" errors otherwise) - give it a real PulseAudio
# server with a null sink, so its output is capturable instead of dropped.
echo "[stream] Starting PulseAudio"
export PULSE_SERVER=unix:/tmp/pulseaudio.socket
pulseaudio -D --exit-idle-time=-1 --disallow-exit \
	--load="module-native-protocol-unix socket=${PULSE_SERVER#unix:} auth-anonymous=1" \
	--load="module-null-sink sink_name=ws4kp_audio sink_properties=device.description=WS4KPAudio" \
	--log-target=stderr
sleep 2
pactl set-default-sink ws4kp_audio

echo "[stream] Launching Chromium (kiosk) -> ${STREAM_URL}"
chromium \
	--kiosk \
	--no-sandbox \
	--disable-gpu \
	--disable-dev-shm-usage \
	--disable-infobars \
	--disable-session-crashed-bubble \
	--disable-features=TranslateUI \
	--autoplay-policy=no-user-gesture-required \
	--disable-background-timer-throttling \
	--disable-backgrounding-occluded-windows \
	--disable-renderer-backgrounding \
	--disable-ipc-flooding-protection \
	--window-position=0,0 \
	--window-size="${WIDTH},${HEIGHT}" \
	--user-data-dir=/tmp/chromium-profile \
	"$STREAM_URL" &

sleep 10

# fluxbox/Chromium can warp the pointer back to center when the window takes
# focus, so re-park it once more right before capture starts.
xdotool mousemove "$PARK_X" "$PARK_Y"
sleep 2

GOP=$((FRAMERATE * 2))

if [ -n "${RTMP_URL:-}" ]; then
	echo "[stream] Encoding to RTMP: ${RTMP_URL}"
	# YouTube Live (and most RTMP ingest) expects an audio track alongside
	# video - a video-only feed can connect and encode without any ffmpeg
	# error but still never show up as "receiving data" on the platform
	# side. Capture Chromium's real audio (ws4kp's background music, if
	# enabled) from the PulseAudio null sink's monitor.
	exec ffmpeg -y \
		-f x11grab -video_size "$RESOLUTION" -framerate "$FRAMERATE" -i "$DISPLAY" \
		-f pulse -i ws4kp_audio.monitor \
		-c:v libx264 -preset veryfast -tune zerolatency \
		-b:v "$BITRATE" -maxrate "$BITRATE" -bufsize "$BUFSIZE" \
		-pix_fmt yuv420p -g "$GOP" \
		-c:a aac -b:a 128k -ar 44100 \
		-f flv "$RTMP_URL"
else
	echo "[stream] RTMP_URL not set - writing an HLS preview to /output/stream.m3u8 instead"
	echo "[stream] point VLC/ffplay at the mounted output volume to verify the pipeline"
	mkdir -p /output
	exec ffmpeg -y \
		-f x11grab -video_size "$RESOLUTION" -framerate "$FRAMERATE" -i "$DISPLAY" \
		-f pulse -i ws4kp_audio.monitor \
		-c:v libx264 -preset veryfast -tune zerolatency \
		-b:v "$BITRATE" -maxrate "$BITRATE" -bufsize "$BUFSIZE" \
		-pix_fmt yuv420p -g "$GOP" \
		-c:a aac -b:a 128k -ar 44100 \
		-f hls -hls_time 2 -hls_list_size 6 -hls_flags delete_segments+append_list \
		/output/stream.m3u8
fi
