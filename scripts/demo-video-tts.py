"""Speaks video/story.json with Kokoro-82M (offline) and writes the voice track and the timing the video follows.

Run by scripts/make-demo-video.sh with the venv python and `-I`:
    python -I demo-video-tts.py <tts-dir> <voice> <out-dir>
<tts-dir> holds kokoro-v1.0.onnx and voices-v1.0.bin. The narration text stays on this Mac.
Writes <out-dir>/narration.wav and <out-dir>/timing.json (seconds).
"""
import json
import sys

import numpy as np
import soundfile as sf
from kokoro_onnx import Kokoro

tts_dir, voice, out_dir = sys.argv[1:4]
story_path = out_dir + "/../story.json"
SPEED = 1.0
GAP = 0.32          # silence after each sentence
LEAD = 0.55         # quiet time at the start of a beat before the first word
TAIL = 0.65         # quiet time after the last word of a beat
LANG = "en-gb" if voice.startswith("b") else "en-us"

kokoro = Kokoro(tts_dir + "/kokoro-v1.0.onnx", tts_dir + "/voices-v1.0.bin")
story = json.load(open(story_path))
# the product name lives in video/brand.json; story.json writes it as {name}
name = json.load(open(out_dir + "/../brand.json"))["name"]
for beat in story["beats"]:
    beat["headline"] = beat["headline"].replace("{name}", name)
    for s in beat["sentences"]:
        s["text"] = s["text"].replace("{name}", name)
SR = 24000
chunks, beats, t = [], [], 0.0
for beat in story["beats"]:
    start = t
    t += LEAD
    chunks.append(np.zeros(int(LEAD * SR), dtype=np.float32))
    sentences = []
    for s in beat["sentences"]:
        audio, sr = kokoro.create(s["text"], voice=voice, speed=SPEED, lang=LANG)
        assert sr == SR
        dur = len(audio) / SR
        sentences.append({"text": s["text"], "cue": s["cue"], "start": round(t, 3), "dur": round(dur, 3)})
        chunks.append(audio.astype(np.float32))
        t += dur
        chunks.append(np.zeros(int(GAP * SR), dtype=np.float32))
        t += GAP
    chunks.append(np.zeros(int(TAIL * SR), dtype=np.float32))
    t += TAIL
    beats.append({"id": beat["id"], "headline": beat["headline"], "start": round(start, 3),
                  "dur": round(t - start, 3), "sentences": sentences})

sf.write(out_dir + "/narration.wav", np.concatenate(chunks), SR)
json.dump({"voice": voice, "total": round(t, 3), "beats": beats}, open(out_dir + "/timing.json", "w"), indent=1)
# the GIF preview starts a little into the hold-card beat (card slides in, cursor approves it)
holds = next(b for b in beats if b["id"] == "holds")
open(out_dir + "/gif_start.txt", "w").write(str(round(holds["start"] + 0.3, 2)))
print("voice", voice, "total seconds", round(t, 1))
