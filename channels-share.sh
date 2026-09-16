#!/bin/bash

# channels-share
# Stream one channel from a local Channels DVR to a temporary, external-facing
# HLS URL that plays by tapping a link in a phone browser (Safari/Chrome).
#
#   - Auto-detects codec and transcodes OTA (MPEG-2/AC-3) to H.264/AAC so it
#     plays on iPhones; copies through when the source is already H.264/AAC.
#   - Serves a small HTML player page (hls.js + native HLS) so the shared link
#     just works in a browser instead of downloading the .m3u8.
#   - Builds a rich link preview (Open Graph tags + program artwork) so the link
#     shows the current program in iMessage/Slack/etc.
#   - Exposes the stream over HTTPS through a Cloudflare quick tunnel
#     (cloudflared) and gates it behind an unguessable random token path.

# --- CONFIGURATION ---
HLS_DIR="hls_output"      # Directory for HLS files (relative to CWD)
HLS_PORT=8090             # Local HTTP server port (also the tunnel target)
DEFAULT_DURATION="1h"     # Default duration if user enters nothing
DVR_HOST="${DVR_HOST:-127.0.0.1}"   # Channels DVR host (override to run off-box, e.g. DVR_HOST=pawnee.local)
DVR_PORT="${DVR_PORT:-8089}"        # Channels DVR HTTP port

# --- RUNTIME STATE ---
FFMPEG_PID=""
SERVER_PID=""
TUNNEL_PID=""             # cloudflared PID
TOKEN=""
COMMAND=""
SHARE_URL=""
# PIDs persisted so `stop` from another terminal can tear everything down.
PID_FILE="$HLS_DIR/pids.pid"


# --- USAGE ---
show_help() {
    cat <<'EOF'
channels-share - stream a Channels DVR channel to a shareable HTTPS link

USAGE:
  channels-share          Start a stream (prompts for channel + duration)
  channels-share stop      Stop a running stream
  channels-share --help    Show this help

The stream is exposed over HTTPS via a Cloudflare quick tunnel (cloudflared)
and served under a random token path, e.g.

  https://<random>.trycloudflare.com/<token>/

so the link itself is the credential. The shared link carries a rich preview
(the current program's title, description, and artwork). Streaming stops
automatically after the chosen duration.

REQUIRES: ffmpeg (with ffprobe), python 3, and cloudflared.
  Install cloudflared with:  brew install cloudflared

ENVIRONMENT:
  DVR_HOST   Channels DVR host (default 127.0.0.1; e.g. DVR_HOST=mydvr.local)
  DVR_PORT   Channels DVR port (default 8089)
EOF
}


# --- TUNNEL TEARDOWN ---
# Uses TUNNEL_PID (set in-process, or read from PID_FILE by the `stop` command).
stop_tunnel() {
    if [ -n "$TUNNEL_PID" ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
        echo "    Stopping cloudflared (PID: $TUNNEL_PID)..."
        kill "$TUNNEL_PID" 2>/dev/null
    fi
    pkill -f "cloudflared tunnel --url http://localhost:$HLS_PORT" 2>/dev/null || true
}


# --- CLEANUP FUNCTION ---
# Called on exit/interrupt, and directly by the `stop` command.
cleanup() {
    echo
    echo "🛑 Stopping processes..."

    # Read persisted PIDs if available (needed by `stop`).
    if [ -f "$PID_FILE" ]; then
        read -r FFMPEG_PID SERVER_PID TUNNEL_PID < "$PID_FILE"
        echo "    Read state from $PID_FILE: ffmpeg=$FFMPEG_PID server=$SERVER_PID cloudflared=$TUNNEL_PID"
        rm -f "$PID_FILE"
    fi

    if [ -n "$FFMPEG_PID" ] && kill -0 "$FFMPEG_PID" 2>/dev/null; then
        echo "    Killing ffmpeg (PID: $FFMPEG_PID)..."
        kill "$FFMPEG_PID"
        wait "$FFMPEG_PID" 2>/dev/null
    fi
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "    Killing HTTP server (PID: $SERVER_PID)..."
        kill "$SERVER_PID"
        wait "$SERVER_PID" 2>/dev/null
    fi

    stop_tunnel

    echo "🧹 Cleaning up temporary HLS files..."
    # Safety check on the directory name before removing.
    if [[ "$HLS_DIR" == "hls_output" ]]; then
        rm -rf "$HLS_DIR"
        echo "    Removed directory: $HLS_DIR"
    else
        echo "    Skipping removal of HLS_DIR (unexpected name): $HLS_DIR"
    fi

    echo "✅ Stream shutdown complete."

    if [ "$COMMAND" != "stop" ]; then
        trap - SIGINT SIGTERM EXIT
        exit 0
    fi
}


# --- ARGUMENT PARSING ---
while [ $# -gt 0 ]; do
    case "$1" in
        stop)
            COMMAND="stop"; shift ;;
        -h|--help)
            show_help; exit 0 ;;
        *)
            echo "❌ ERROR: Unknown argument: $1" >&2
            show_help >&2
            exit 1 ;;
    esac
done

# --- HANDLE `stop` COMMAND ---
if [ "$COMMAND" == "stop" ]; then
    echo "Received stop command."
    cleanup
    exit 0
fi

# --- PREFLIGHT: required tools ---
if ! command -v cloudflared >/dev/null 2>&1; then
    echo "❌ ERROR: 'cloudflared' is required but not installed." >&2
    echo "    Install it with:  brew install cloudflared" >&2
    exit 1
fi

# --- TRAP SIGNALS (only for a live run) ---
trap cleanup SIGINT SIGTERM EXIT

# --- INITIAL CLEANUP of old instances ---
echo "🧹 Cleaning up any old processes and files from previous runs..."
pkill -f "ffmpeg .*$HLS_DIR" 2>/dev/null || true
pkill -f "python3 - $HLS_PORT $HLS_DIR" 2>/dev/null || true
pkill -f "cloudflared tunnel --url http://localhost:$HLS_PORT" 2>/dev/null || true
sleep 2

if [[ "$HLS_DIR" == "hls_output" ]]; then
    rm -rf "$HLS_DIR"
fi

# --- CREATE TOKEN + DIRECTORIES ---
if command -v openssl >/dev/null 2>&1; then
    TOKEN=$(openssl rand -hex 12)
else
    TOKEN=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi
TOKEN_DIR="$HLS_DIR/$TOKEN"
mkdir -p "$TOKEN_DIR" || { echo "❌ ERROR: Failed to create directory '$TOKEN_DIR'" >&2; exit 1; }


# --- DURATION CONVERSION FUNCTION ---
# Converts a duration string (e.g., 1h, 30m, 2h30m, 120s, or just 120) to seconds.
calculate_seconds() {
    local duration_str="$1"
    local total_seconds=0
    local num

    if [[ "$duration_str" =~ ^[0-9]+$ ]]; then
        echo "$duration_str"
        return 0
    fi

    if [[ "$duration_str" =~ ([0-9]+)h ]]; then
        num=${BASH_REMATCH[1]}
        total_seconds=$((total_seconds + num * 3600))
        duration_str=${duration_str/${num}h/}
    fi

    if [[ "$duration_str" =~ ([0-9]+)m ]]; then
        num=${BASH_REMATCH[1]}
        total_seconds=$((total_seconds + num * 60))
        duration_str=${duration_str/${num}m/}
    fi

    if [[ "$duration_str" =~ ([0-9]+)s ]]; then
        num=${BASH_REMATCH[1]}
        total_seconds=$((total_seconds + num))
        duration_str=${duration_str/${num}s/}
    fi

    duration_str=$(echo "$duration_str" | tr -d '[:space:]')
    if [[ -n "$duration_str" ]]; then
        echo "❌ ERROR: Invalid characters or format in duration: $1 (Remaining: '$duration_str')" >&2
        return 1
    fi

    echo "$total_seconds"
    return 0
}


# --- DETERMINE LOCAL IP (for the on-screen local hint only) ---
LOCAL_IP=""
if command -v ip > /dev/null; then
    LOCAL_IP=$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -n 1)
fi
if [ -z "$LOCAL_IP" ] && command -v ifconfig > /dev/null; then
    LOCAL_IP=$(ifconfig | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | head -n 1)
fi


# --- GET USER INPUT ---
read -p "Enter Channel Number (e.g., 1001, 13.1): " CHANNEL_NUM
CHANNEL_NUM=$(echo "$CHANNEL_NUM" | tr -d '[:space:]')
if ! [[ "$CHANNEL_NUM" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "❌ ERROR: Channel number '$CHANNEL_NUM' must be a valid number format (e.g., 1001 or 13.1)." >&2
    exit 1
fi

read -p "Enter duration (e.g., 1h, 30m, 2h30m, 90s, or just 120) [Default: $DEFAULT_DURATION]: " DURATION_INPUT
DURATION="${DURATION_INPUT:-$DEFAULT_DURATION}"
DURATION=$(echo "$DURATION" | tr -d '[:space:]')

SLEEP_SECONDS=$(calculate_seconds "$DURATION")
if [ $? -ne 0 ]; then
    exit 1
fi
echo "⏱️  Calculated sleep time: $SLEEP_SECONDS seconds"


# --- CONSTRUCT STREAM SOURCE URL ---
STREAM_URL="http://$DVR_HOST:$DVR_PORT/devices/ANY/channels/$CHANNEL_NUM/stream.mpg?codec=copy&format=ts"
echo "🎯 Pulling channel $CHANNEL_NUM from Channels DVR at $DVR_HOST:$DVR_PORT"


# --- AUTO-DETECT CODEC (ffprobe) ---
probe_codec() {
    # $1 = stream specifier (v:0 or a:0)
    ffprobe -v error -rw_timeout 10000000 \
        -select_streams "$1" -show_entries stream=codec_name \
        -of csv=p=0 -i "$STREAM_URL" 2>/dev/null | head -n1 | tr -d '[:space:]'
}

echo "🔎 Probing source codecs..."
VCODEC=$(probe_codec v:0)
ACODEC=$(probe_codec a:0)
echo "    video=${VCODEC:-unknown} audio=${ACODEC:-unknown}"

if [ "$VCODEC" = "h264" ] && [ "$ACODEC" = "aac" ]; then
    MODE="copy"
    VIDEO_ARGS=(-c:v copy)
    AUDIO_ARGS=(-c:a copy)
    echo "    → Source is already H.264/AAC; copying through (low CPU)."
else
    MODE="transcode"
    VIDEO_ARGS=(-c:v libx264 -preset veryfast -pix_fmt yuv420p)
    AUDIO_ARGS=(-c:a aac -ac 2)
    echo "    → Transcoding to H.264/AAC for broad device support (uses CPU)."
fi


# --- FETCH CURRENT PROGRAM METADATA (for the shared link preview) ---
# Pulls what's airing now on this channel from the Channels DVR guide so the
# iMessage/Slack/etc. link preview shows the program instead of a bare URL.
echo "📺 Looking up what's on channel $CHANNEL_NUM..."
DVR_URL="http://$DVR_HOST:$DVR_PORT"
PROG_TITLE=""; PROG_DESC=""; PROG_IMG_URL=""; CH_NAME=""; CH_LOGO=""

META=$(curl -s --max-time 10 "$DVR_URL/devices/ANY/guide" 2>/dev/null | CH="$CHANNEL_NUM" python3 -c '
import json,sys,os,time
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
ch=os.environ["CH"]; now=int(time.time()); found=None
for obj in d:
    for a in obj.get("Airings",[]):
        if str(a.get("Channel"))==ch and a.get("Time",0)<=now<a.get("Time",0)+a.get("Duration",0):
            found=a; break
    if found: break
if not found: sys.exit(0)
title=(found.get("Title") or ""); ep=(found.get("EpisodeTitle") or "")
if ep: title=title+" - "+ep
desc=(found.get("Summary") or found.get("FullSummary") or "")
img=(found.get("Image") or "")
print("\t".join(x.replace("\t"," ").replace("\n"," ") for x in (title,desc,img)))
' 2>/dev/null)
if [ -n "$META" ]; then
    PROG_TITLE=$(printf '%s' "$META" | cut -f1)
    PROG_DESC=$(printf '%s' "$META" | cut -f2)
    PROG_IMG_URL=$(printf '%s' "$META" | cut -f3)
fi

CH_META=$(curl -s --max-time 8 "$DVR_URL/api/v1/channels" 2>/dev/null | CH="$CHANNEL_NUM" python3 -c '
import json,sys,os
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
ch=os.environ["CH"]
for c in d:
    if str(c.get("number"))==ch:
        print("\t".join(((c.get("name") or ""), (c.get("logo_url") or "")))); break
' 2>/dev/null)
if [ -n "$CH_META" ]; then
    CH_NAME=$(printf '%s' "$CH_META" | cut -f1)
    CH_LOGO=$(printf '%s' "$CH_META" | cut -f2)
fi

# Compose the preview title/description with sensible fallbacks.
OG_TITLE="${PROG_TITLE:-${CH_NAME:-Channel $CHANNEL_NUM}}"
if [ -n "$PROG_DESC" ] && [ -n "$CH_NAME" ]; then
    OG_DESC="$PROG_DESC · $CH_NAME (ch $CHANNEL_NUM)"
elif [ -n "$PROG_DESC" ]; then
    OG_DESC="$PROG_DESC"
elif [ -n "$CH_NAME" ]; then
    OG_DESC="Live on $CH_NAME (ch $CHANNEL_NUM)"
else
    OG_DESC="Live on channel $CHANNEL_NUM"
fi
echo "    Now playing: $OG_TITLE"

# --- DOWNLOAD PREVIEW IMAGE (poster.jpg) ---
# Prefer the program's promo art, then the channel logo, then a live frame grab.
POSTER_OK=""
for SRC in "$PROG_IMG_URL" "$CH_LOGO"; do
    [ -z "$SRC" ] && continue
    if curl -s --max-time 12 -o "$TOKEN_DIR/poster.jpg" "$SRC" && [ -s "$TOKEN_DIR/poster.jpg" ]; then
        POSTER_OK=1; break
    fi
done
if [ -z "$POSTER_OK" ]; then
    # Last resort: grab a single live frame (runs before the main ffmpeg starts).
    ffmpeg -y -rw_timeout 10000000 -i "$STREAM_URL" -frames:v 1 -q:v 3 "$TOKEN_DIR/poster.jpg" >/dev/null 2>&1 \
        && [ -s "$TOKEN_DIR/poster.jpg" ] && POSTER_OK=1
fi


# --- START FFMPEG ---
echo "🎬 Starting ffmpeg ($MODE)..."
ffmpeg -re -i "$STREAM_URL" \
    "${VIDEO_ARGS[@]}" "${AUDIO_ARGS[@]}" \
    -f hls \
    -hls_time 4 \
    -hls_list_size 5 \
    -hls_flags delete_segments+omit_endlist \
    -hls_segment_filename "$TOKEN_DIR/segment%03d.ts" \
    "$TOKEN_DIR/stream.m3u8" > "$HLS_DIR/ffmpeg.log" 2>&1 &

FFMPEG_PID=$!
sleep 3
if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
    echo "❌ ERROR: ffmpeg failed to start. Check the stream URL, network, and that Channels DVR is running." >&2
    echo "    Log content ($HLS_DIR/ffmpeg.log):" >&2
    cat "$HLS_DIR/ffmpeg.log" >&2
    exit 1
fi
echo "    ffmpeg running with PID: $FFMPEG_PID"


# --- START HTTP SERVER (with correct HLS MIME types) ---
echo "🌐 Starting HTTP server on port $HLS_PORT (serving '$HLS_DIR')..."
python3 - "$HLS_PORT" "$HLS_DIR" > "$HLS_DIR/server.log" 2>&1 <<'PYEOF' &
import http.server, os, sys
port = int(sys.argv[1])
os.chdir(sys.argv[2])
Handler = http.server.SimpleHTTPRequestHandler
Handler.extensions_map = dict(Handler.extensions_map)
Handler.extensions_map['.m3u8'] = 'application/vnd.apple.mpegurl'
Handler.extensions_map['.ts'] = 'video/mp2t'
httpd = http.server.ThreadingHTTPServer(('', port), Handler)
httpd.serve_forever()
PYEOF
SERVER_PID=$!
sleep 1
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "❌ ERROR: HTTP server failed to start. Check $HLS_DIR/server.log for details." >&2
    cat "$HLS_DIR/server.log" >&2
    exit 1
fi
echo "    Server running with PID: $SERVER_PID"


# --- START CLOUDFLARE TUNNEL ---
echo "🔌 Opening Cloudflare tunnel (HTTPS)..."
cloudflared tunnel --url "http://localhost:$HLS_PORT" > "$HLS_DIR/cloudflared.log" 2>&1 &
TUNNEL_PID=$!
# Wait for the trycloudflare URL to appear in the log (up to ~20s).
CF_URL=""
for _ in $(seq 1 40); do
    CF_URL=$(grep -Eo 'https://[a-z0-9.-]+\.trycloudflare\.com' "$HLS_DIR/cloudflared.log" 2>/dev/null | head -n1)
    [ -n "$CF_URL" ] && break
    if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then break; fi
    sleep 0.5
done
if [ -n "$CF_URL" ]; then
    SHARE_URL="$CF_URL/$TOKEN/"
else
    echo "❌ ERROR: cloudflared did not report a URL. Check $HLS_DIR/cloudflared.log." >&2
    exit 1
fi


# --- WRITE PLAYER PAGE (now that we know the public URL for preview tags) ---
OG_IMAGE=""
[ -n "$POSTER_OK" ] && OG_IMAGE="${SHARE_URL}poster.jpg"
python3 - "$TOKEN_DIR/index.html" "$SHARE_URL" "$OG_TITLE" "$OG_DESC" "$OG_IMAGE" <<'PYEOF'
import sys, html
path, url, title, desc, image = sys.argv[1:6]
def e(s): return html.escape(s or "", quote=True)
tags = [
    '<meta property="og:type" content="video.other">',
    f'<meta property="og:title" content="{e(title)}">',
    f'<meta property="og:url" content="{e(url)}">',
    '<meta property="og:site_name" content="Channels DVR">',
]
if desc:
    tags.append(f'<meta property="og:description" content="{e(desc)}">')
if image:
    tags += [
        f'<meta property="og:image" content="{e(image)}">',
        '<meta name="twitter:card" content="summary_large_image">',
        f'<meta name="twitter:image" content="{e(image)}">',
    ]
else:
    tags.append('<meta name="twitter:card" content="summary">')
tags.append(f'<meta name="twitter:title" content="{e(title)}">')
if desc:
    tags.append(f'<meta name="twitter:description" content="{e(desc)}">')
meta = "\n  ".join(tags)
page = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>{e(title)}</title>
  {meta}
  <style>
    html, body {{ margin: 0; height: 100%; background: #000; }}
    #wrap {{ display: flex; align-items: center; justify-content: center; height: 100%; }}
    video {{ width: 100%; height: 100%; max-height: 100vh; background: #000; }}
  </style>
</head>
<body>
  <div id="wrap">
    <video id="v" controls autoplay playsinline muted></video>
  </div>
  <script src="https://cdn.jsdelivr.net/npm/hls.js@1"></script>
  <script>
    var video = document.getElementById('v');
    var src = 'stream.m3u8';
    // Safari / iOS play HLS natively.
    if (video.canPlayType('application/vnd.apple.mpegurl')) {{
      video.src = src;
    }} else if (window.Hls && window.Hls.isSupported()) {{
      // Other browsers (Chrome/Android/desktop) use hls.js.
      var hls = new Hls({{ lowLatencyMode: true }});
      hls.loadSource(src);
      hls.attachMedia(video);
      hls.on(Hls.Events.MANIFEST_PARSED, function () {{ video.play().catch(function(){{}}); }});
    }} else {{
      document.body.innerHTML = '<p style="color:#fff;font:16px system-ui;padding:1rem">Your browser cannot play this stream.</p>';
    }}
    // Autoplay policies require a muted start; let the viewer unmute quickly.
    video.addEventListener('playing', function () {{ video.muted = false; }}, {{ once: true }});
  </script>
</body>
</html>
"""
with open(path, "w") as f:
    f.write(page)
PYEOF


# --- PERSIST STATE (for `stop`) ---
echo "$FFMPEG_PID $SERVER_PID $TUNNEL_PID" > "$PID_FILE"


# --- READY ---
echo
echo "🚀 Stream is live."
echo "──────────────────────────────────────────────────────────────"
echo "   Share this link (tap it on a phone, plays in Safari/Chrome):"
echo
echo "     $SHARE_URL"
echo
echo "   Link preview will show: $OG_TITLE"
echo "──────────────────────────────────────────────────────────────"
if [ -n "$LOCAL_IP" ]; then
    echo "   On your home network: http://$LOCAL_IP:$HLS_PORT/$TOKEN/"
fi
echo "   Streaming for approximately $DURATION."
echo "   Press Ctrl+C to stop, or run 'channels-share stop' elsewhere."
echo

sleep "$SLEEP_SECONDS"

echo
echo "⏳ Timer finished ($DURATION elapsed). Initiating shutdown..."
# The EXIT trap triggers cleanup.
