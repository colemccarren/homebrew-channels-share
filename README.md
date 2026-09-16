# channels-share

Stream a single channel from your [Channels DVR](https://getchannels.com/) to a
temporary HTTPS link that plays simply from a tunneled, generated URL (for use while mobile in a web browser, for example) — including live OTA channels — without sharing your Channels credentials.

The script does a lot of cool things in one quick swoop:

- Auto-detects the source codec and transcodes OTA (MPEG-2 / AC-3) to
  H.264 / AAC so it plays on iPhones, or copies through untouched when the
  source is already H.264 / AAC.
- Serves a small HTML player page (hls.js with native-HLS fallback), so the
  shared link just plays instead of downloading a `.m3u8` file.
- Exposes the stream over HTTPS through a Cloudflare quick tunnel
  (`cloudflared`) without requiring port forwarding or exposing your home IP, and gates it behind
  a random token path so the link itself stops
  working when the stream ends.
- Since the cloudflared URL is a bit... much :) the script also leverages your beautiful Channels DVR data once more and shared links carry Open Graph tags with the
  current program's title, description, and artwork, so it shows up in iMessage/etc. as the show you're sharing,
  rather than a bare URL.

## Requirements

- python 3
- ffmpeg (with `ffprobe`)
- [`cloudflared`](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/)
  (`brew install cloudflared`) — installed automatically by the Homebrew formula.
- By default this script should run on the same machine as your Channels DVR server
  (it reads from `127.0.0.1:8089`). To run it elsewhere on your LAN, point it at
  the DVR with `DVR_HOST` / `DVR_PORT`, e.g. `DVR_HOST=mydvr.local channels-share`.

## Install

Via Homebrew:

```bash
brew install colemccarren/channels-share/channels-share
```

If you're on an older machine and Homebrew can't install `ffmpeg` properly:

1. Download a static `ffmpeg` binary from [https://evermeet.cx/ffmpeg/](https://evermeet.cx/ffmpeg/).
2. Install without dependencies:

```bash
brew install --ignore-dependencies channels-share
```

## Usage

```bash
channels-share
```

Then specify:

- The **channel** you want to stream (the exact number from your Channels DVR guide, such as "2.1" from your HDHomeRun, or "302" from a TVE / other source channel).
- The **duration** to serve it (e.g., `1h`, `30m`, `2h30m`, `90s`, or `120`).

The script probes the source, starts `ffmpeg` and a small HTTP server, opens the
tunnel, and prints a single link to share:

```
https://random-words-here.trycloudflare.com/ab12cd34ef56.../
```

Paste this in a browser and watch your TV! Streaming will stop automatically
after the duration you chose.

## Stopping the server

Out and about and started this script over SSH and lost access to the terminal? Stop everything
(ffmpeg, the HTTP server, and the tunnel) with:

```bash
channels-share stop
```

## Responsible use

This tool is, obviously, for accessing **your own** content from **your own** Channels DVR.
