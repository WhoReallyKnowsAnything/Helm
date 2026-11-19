#!/bin/bash
# Build the release: an ad-hoc signed arm64 Helm.app on the styled disk image, plus its SHA-256 file.
#
#   scripts/release.sh <vX.Y.Z> [--out <folder>] [--upload] [make-dmg.sh options]
#
# --out <folder>  where Helm-<version>.dmg and Helm-<version>.dmg.sha256 go; build/release otherwise
# --upload        create the GitHub release for the tag (or, if it exists, replace its two files) with gh
# --upload-only   send the two files an earlier run built to --out (no build); CI runs it as its own step
# Any other option goes to make-dmg.sh unchanged (--identity, --notary-profile: the hook for later).
#
# Local release path: Finder lays out the disk image window, so this needs a Mac with a logged-in desktop.
# Clone the public repo at the tag (its history and its tag are not the dev repo's), check the tag out, and
# run scripts/release.sh <tag> --upload from that clone.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

TAG="${1:-}"
[[ -n "$TAG" ]] || fail "give a tag: scripts/release.sh v0.1.0 [--out <folder>] [--upload]"
shift
OUT="$ROOT/build/release"
UPLOAD=0
UPLOAD_ONLY=0
PASS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) [[ -n "${2:-}" ]] || fail "--out needs a folder."; OUT="$2"; shift 2 ;;
    --upload) UPLOAD=1; shift ;;
    --upload-only) UPLOAD=1; UPLOAD_ONLY=1; shift ;;
    *) PASS+=("$1"); shift ;;
  esac
done

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "the tag $TAG is not v plus three dot-separated numbers (like v0.1.0)."
git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG^{commit}" > /dev/null || fail "the tag $TAG does not exist in this clone."
[[ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" == "false" ]] ||
  fail "this is a shallow clone, so the build number (a count of commits) would be wrong. Clone with full history."
[[ "$(git -C "$ROOT" rev-parse HEAD)" == "$(git -C "$ROOT" rev-parse "$TAG^{commit}")" ]] ||
  fail "HEAD is not the commit $TAG points to, so the build would not be the tagged code. Check the tag out."

VERSION="${TAG#v}"
BUILD="$(git -C "$ROOT" rev-list --count "$TAG")"
APP="$ROOT/build/Helm.app"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
DMG="Helm-$VERSION.dmg"

upload_release() {
  if gh release view "$TAG" > /dev/null 2>&1; then
    gh release upload "$TAG" "$OUT/$DMG" "$OUT/$DMG.sha256" --clobber
  else
    gh release create "$TAG" "$OUT/$DMG" "$OUT/$DMG.sha256" --title "Helm $VERSION" --generate-notes
  fi
}

# --upload-only sends the files an earlier run built. CI uses it so only this step holds the GitHub token.
if [[ "$UPLOAD_ONLY" -eq 1 ]]; then
  [[ -f "$OUT/$DMG" && -f "$OUT/$DMG.sha256" ]] || fail "$OUT has no $DMG and $DMG.sha256 to upload. Build first."
  upload_release
  echo "$OUT/$DMG"
  exit 0
fi

# bundle-app.sh installs too; point it at a scratch folder so /Applications and the live app stay untouched.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/helm-release.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
HELM_INSTALL_DIR="$SCRATCH" "$ROOT/scripts/bundle-app.sh" > /dev/null

# The stamp breaks any seal bundle-app.sh made (it may have used an Apple Development identity), so sign ad hoc after it.
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

ARCHS="$(lipo -archs "$APP/Contents/MacOS/Helm")"
[[ "$ARCHS" == "arm64" ]] || fail "the app is built for \"$ARCHS\", and a release is arm64 only."

"$ROOT/scripts/make-dmg.sh" "$APP" --out "$OUT" ${PASS[@]+"${PASS[@]}"}
(cd "$OUT" && shasum -a 256 "$DMG" > "$DMG.sha256")

if [[ "$UPLOAD" -eq 1 ]]; then
  upload_release
fi
echo "$OUT/$DMG"
