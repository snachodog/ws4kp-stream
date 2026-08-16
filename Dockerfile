FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
	chromium \
	xvfb \
	fluxbox \
	xdotool \
	pulseaudio \
	pulseaudio-utils \
	ffmpeg \
	fonts-liberation \
	dumb-init \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENV DISPLAY=:99
ENV STREAM_URL=http://ws4kp:8080
ENV RESOLUTION=1920x1080
ENV FRAMERATE=30
ENV BITRATE=4500k
ENV BUFSIZE=9000k
ENV RTMP_URL=

ENTRYPOINT ["dumb-init", "--"]
CMD ["/app/entrypoint.sh"]
