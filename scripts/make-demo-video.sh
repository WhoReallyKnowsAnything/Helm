#!/usr/bin/env bash
# Rebuilds docs/media/helm-demo.mp4 and .gif from scratch with one command: scripts/make-demo-video.sh
#
#   1. Kokoro-82M (offline) speaks video/story.json -> video/gen/narration.wav + video/gen/timing.json
#   2. Remotion renders video/ (React, redrawn demo UI, kinetic headlines, captions) -> video/out/launch.mp4 (silent)
#   3. ffmpeg mixes voice + music (music ducked under the voice, faded in and out) and muxes the final mp4
#   4. ffmpeg cuts the GIF preview from the approve-a-hold beat
#
# Needs: node/npm, ffmpeg, python3. Everything downloaded lives in CACHE (outside the repo):
#   $CACHE/tts/venv + the Kokoro model files, $CACHE/music/Digital Lemonade.mp3 (both fetched on first run, see docs/media/CREDITS.md).
# The product name is set once in video/brand.json (title card, end card, window title, captions and narration all use it).
# Env: VOICE (default af_heart), FORCE_TTS=1 to re-speak, SKIP_RENDER=1 to reuse the last render.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${CANOPY_VIDEO_CACHE:-$HOME/.cache/canopy-video}"
TTS="$CACHE/tts"
VOICE="${VOICE:-af_heart}"
MUSIC_FILE="${MUSIC_FILE:-$CACHE/music/Digital Lemonade.mp3}"
MUSIC_CREDIT='Music: “Digital Lemonade” by Kevin MacLeod (incompetech.com), CC BY 4.0'
OUT="$ROOT/docs/media"
GEN="$ROOT/video/gen"
MODEL_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
MUSIC_URL="https://incompetech.com/music/royalty-free/mp3-royaltyfree/Digital%20Lemonade.mp3"

mkdir -p "$TTS" "$CACHE/music" "$OUT" "$GEN"

# --- 0. one-time downloads (the narration text is never sent anywhere; only these files come in)
if [ ! -x "$TTS/venv/bin/python" ]; then
  python3 -m venv "$TTS/venv"
  "$TTS/venv/bin/pip" install -q kokoro-onnx soundfile
fi
for f in kokoro-v1.0.onnx voices-v1.0.bin; do
  [ -f "$TTS/$f" ] || curl -fL -o "$TTS/$f" "$MODEL_URL/$f"
done
[ -f "$MUSIC_FILE" ] || curl -fL -A 'Mozilla/5.0' -o "$MUSIC_FILE" "$MUSIC_URL"

# --- 1. voice + timing. Re-spoken whenever the name (video/brand.json), the text (video/story.json), the voice or the TTS script changes.
TTS_HASH=$(cat "$ROOT/video/brand.json" "$ROOT/video/story.json" "$ROOT/scripts/demo-video-tts.py" <(echo "$VOICE") | shasum | cut -d' ' -f1)
if [ "${FORCE_TTS:-0}" = "1" ] || [ ! -f "$GEN/narration.wav" ] || [ "$(cat "$GEN/tts.hash" 2>/dev/null)" != "$TTS_HASH" ]; then
  "$TTS/venv/bin/python" -I "$ROOT/scripts/demo-video-tts.py" "$TTS" "$VOICE" "$GEN"
  echo "$TTS_HASH" > "$GEN/tts.hash"
fi

# --- 2. render the silent video
cd "$ROOT/video"
[ -d node_modules ] || npm ci --no-audit --no-fund
if [ "${SKIP_RENDER:-0}" != "1" ]; then
  npx remotion render src/index.ts Launch out/launch.mp4 --props="{\"credit\":\"$MUSIC_CREDIT\"}" \
    --license-key=free-license --is-production=false --crf=16
fi
cd "$ROOT"

# --- 3. mix: voice at full level, music about 20 dB under it while the voice speaks, louder in the gaps
TOTAL=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$ROOT/video/out/launch.mp4")
FADE_OUT_AT=$(awk -v t="$TOTAL" 'BEGIN{printf "%.2f", t-4}')
ffmpeg -v error -y -i "$ROOT/video/out/launch.mp4" -i "$GEN/narration.wav" -i "$MUSIC_FILE" -filter_complex "
  [1:a]apad,atrim=0:${TOTAL},loudnorm=I=-16:TP=-1.5:LRA=7,asplit[n1][n2];
  [2:a]atrim=0:${TOTAL},asetpts=PTS-STARTPTS,afade=t=in:st=0:d=2,afade=t=out:st=${FADE_OUT_AT}:d=4,volume=-9dB[m];
  [m][n2]sidechaincompress=threshold=0.015:ratio=9:attack=25:release=700:makeup=1[md];
  [n1][md]amix=inputs=2:normalize=0:duration=first,alimiter=limit=0.95[a]" \
  -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k -ar 44100 -t "$TOTAL" -movflags +faststart "$OUT/helm-demo.mp4"

# --- 4. GIF preview: the hold card slides in, the cursor clicks Approve, the worker turns to running
GIF_FROM=$(cat "$GEN/gif_start.txt")
ffmpeg -v error -y -ss "$GIF_FROM" -t 7 -i "$OUT/helm-demo.mp4" \
  -vf "fps=14,scale=800:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=160:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
  -loop 0 "$OUT/helm-demo.gif"

ls -l "$OUT"
ffprobe -v error -show_entries stream=codec_name,width,height,duration -of compact "$OUT/helm-demo.mp4"
