# channels-share

Stream a single channel from your [Channels DVR](https://getchannels.com/) to a
temporary **HTTPS link** that plays by **tapping it in a phone browser** (Safari
or Chrome) — including live OTA channels — without handing out your Channels
credentials.

It:

- **Auto-detects the source codec** and transcodes OTA (MPEG-2 / AC-3) to
  H.264 / AAC so it plays on iPhones, or copies through untouched when the
  source is already H.264 / AAC (lower CPU).
- Serves a small **HTML player page** (hls.js with native-HLS fallback), so the
  shared link just plays instead of downloading a `.m3u8` file.
- Exposes the stream over HTTPS through a **Cloudflare quick tunnel**
  (`cloudflared`) — no port forwarding, no exposed home IP — and gates it behind
  a **random token path**, so the link itself is the credential and stops
  working when the stream ends.
- Adds a **rich link preview**: the shared link carries Open Graph tags with the
  current program's title, description, and artwork (pulled from your Channels
  DVR guide), so it shows up in iMessage/Slack/etc. as the show you're sharing
  rather than a bare URL.

## Requirements

- python 3
- ffmpeg (with `ffprobe`)
- [`cloudflared`](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/)
  (`brew install cloudflared`) — installed automatically by the Homebrew formula.
- By default this script runs on the same machine as your Channels DVR server
  (it reads from `127.0.0.1:8089`). To run it elsewhere on your LAN, point it at
  the DVR with `DVR_HOST` / `DVR_PORT`, e.g. `DVR_HOST=mydvr.local channels-share`.

## Install

```bash
brew install colemccarren/channels-share/channels-share
```

If you're on an older machine and Homebrew can't install `ffmpeg` properly:

1. Download a static `ffmpeg` binary from [https://evermeet.cx/ffmpeg/](https://evermeet.cx/ffmpeg/).
2. Install without dependencies:

```bash
brew install --ignore-dependencies colemccarren/channels-share/channels-share
```

## How external access works

The stream is exposed over HTTPS through a [Cloudflare quick
tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/):
`cloudflared` opens an outbound connection to Cloudflare and hands back a random
`https://<random>.trycloudflare.com` URL that proxies to your local server. That
means:

- **No port forwarding** and **no exposed home IP** — the connection is
  outbound-only.
- **Real HTTPS**, so it works cleanly in mobile Safari and Chrome.
- **No account or config** — it's zero-setup and the URL is throwaway.

The stream is served under a random token path (e.g.
`https://<random>.trycloudflare.com/<token>/`), so the link itself is the
credential — nobody can reach it without the exact URL, and it stops working
when the stream ends.

## Usage

```bash
channels-share
```

Then specify:

- The **channel** you want to stream (from your Channels DVR guide).
- The **duration** to serve it (e.g., `1h`, `30m`, `2h30m`, `90s`, or `120`).

The script probes the source, starts `ffmpeg` and a small HTTP server, opens the
tunnel, and prints a single link to share:

```
     https://random-words-here.trycloudflare.com/ab12cd34ef56.../
```

Tap it on a phone and it plays in the browser. Streaming stops automatically
after the duration you chose.

## Stopping the server

Out and about — started it over SSH and lost the terminal? Stop everything
(ffmpeg, the HTTP server, and the tunnel) with:

```bash
channels-share stop
```

Ctrl+C in the running terminal does the same.

## Responsible use

This tool is for accessing **your own** content from **your own** Channels DVR.
Sharing live OTA or subscription streams with people outside your household may
run afoul of Channels' terms and your content providers' licensing — know the
rules that apply to you before you share a link.
