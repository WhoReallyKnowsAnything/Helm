# Credits for the Helm launch video

`helm-demo.mp4` and `helm-demo.gif` are built by `scripts/make-demo-video.sh` from the source in `video/`.

## Music

- Track: "Digital Lemonade"
- Artist: Kevin MacLeod (incompetech.com)
- Source: https://incompetech.com/music/royalty-free/ (direct file: https://incompetech.com/music/royalty-free/mp3-royaltyfree/Digital%20Lemonade.mp3)
- Licence: Creative Commons Attribution 4.0 (CC BY 4.0), http://creativecommons.org/licenses/by/4.0/
- The attribution is also shown on the video's end card. The audio file itself is not in this repository: the build script downloads it to `~/.cache/canopy-video/music/`.
- I looked for a CC0 or public-domain track first and found none whose licence could be verified on its source page (FreePD.com is offline, and the archive.org mirror of it has no licence field).

## Voice-over

- Model: Kokoro-82M (hexgrad), Apache-2.0 licence, https://huggingface.co/hexgrad/Kokoro-82M
- Runtime: `kokoro-onnx` (MIT licence), https://github.com/thewh1teagle/kokoro-onnx, with its `kokoro-v1.0.onnx` and `voices-v1.0.bin` files
- Voice: `af_heart`
- The model runs offline on the Mac that builds the video. The narration text is never sent to a service.

## Video tooling

- Remotion (https://www.remotion.dev), used under its Free License for individuals and companies of up to 3 people (https://www.remotion.dev/docs/license/pricing). The render passes `--license-key=free-license`.
- Remotion agent skills (https://github.com/remotion-dev/skills) were used while building the video. They are not committed.

## Content

All screens are redrawn demo UI with made-up data (`acme-weather-app`). The app icon is `Resources/AppIcon.svg`. Colours come from the design kit tokens in `Sources/OrchestratorGUI/DesignKit/Tokens.swift`.
