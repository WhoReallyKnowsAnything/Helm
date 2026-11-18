#!/bin/bash
# Build, sign (Apple Development when present, else ad hoc; no notarization, no sandbox) and install the app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Helm.app"
# HELM_INSTALL_DIR lets a check install into a scratch folder instead of replacing the live app.
INSTALL_DIR="${HELM_INSTALL_DIR:-/Applications}"
DEST="$INSTALL_DIR/Helm.app"

# Signing identity first, before any build. -v lists valid identities only.
IDENTITY="$(security find-identity -v -p codesigning \
  | awk '/"Apple Development:/ { print $2; exit }')"
if [[ -z "$IDENTITY" ]]; then
  echo "no 'Apple Development:' signing identity found; signing ad hoc" >&2
  IDENTITY="-"
fi

cd "$ROOT"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Helm"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Helm"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Before codesign: the signature seals Resources. ditto keeps file modes.
ditto "$ROOT/orchestration" "$APP/Contents/Resources/orchestration"

# A keychain access prompt for the signing key needs a person to allow it.
codesign --force --sign "$IDENTITY" "$APP"

rm -rf "$DEST"
# Remove the older per-user copy so only one is installed (not when installing to a scratch folder).
[[ -z "${HELM_INSTALL_DIR:-}" ]] && rm -rf "$HOME/Applications/Helm.app"
mkdir -p "$INSTALL_DIR"
ditto "$APP" "$DEST"
echo "$DEST"
