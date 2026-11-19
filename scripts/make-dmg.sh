#!/usr/bin/env bash
# make-dmg.sh - Put a finished .app on a disk image: the app and an Applications shortcut
# either side of an arrow, over a background with the app's icon and name. It needs nothing but macOS and the
# Xcode command line tools (xcode-select --install).
#
#   bash make-dmg.sh <path/to/Some.app> [options]
#
#   --out <folder>            where the disk image goes; the folder the app is in otherwise
#   --name <name>             the disk's name and the name on the background; the app's display name otherwise
#   --icon <icon.png|.icns>   the picture for the background (square, 1024 best); the app's .icns otherwise
#   --accent <RRGGBB>         the arrow's colour; dark grey otherwise
#   --text "<line>"           the line under the icons; "Drag <name> into Applications to install" otherwise
#   --title-font <font>       the font for the name: a .ttf/.otf file or an installed font's PostScript name;
#                             Arial Bold otherwise
#   --text-font <font>        the font for the line under the icons, the same way; Arial otherwise
#   --identity <identity>     sign the disk image with this ("Developer ID Application: ..."); otherwise the one
#                             Developer ID Application certificate in the keychain, else it isn't signed
#   --notary-profile <name>   notarize and staple the signed disk image with this profile (xcrun notarytool
#                             store-credentials)
#
# The app itself isn't changed or re-signed: sign it before (notarizing needs it signed with Developer ID and the
# hardened runtime). Finder lays out the disk image's window, so this needs someone logged in to the Mac's screen and
# permission to control Finder (System Settings > Privacy & Security > Automation).
#
# Gives <out>/<name>-<version>.dmg, with the version from the app's Info.plist.

set -euo pipefail

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

APP=""
OUT_DIR=""
NAME=""
ICON_IMAGE=""
ACCENT="3A3F47"
INSTALL_TEXT=""
TITLE_FONT="Arial-BoldMT"
TEXT_FONT="ArialMT"
IDENTITY=""
NOTARY_PROFILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT_DIR="${2:-}"; shift 2 ;;
        --name) NAME="${2:-}"; shift 2 ;;
        --icon) ICON_IMAGE="${2:-}"; shift 2 ;;
        --accent) ACCENT="${2:-}"; shift 2 ;;
        --text) INSTALL_TEXT="${2:-}"; shift 2 ;;
        --title-font) TITLE_FONT="${2:-}"; shift 2 ;;
        --text-font) TEXT_FONT="${2:-}"; shift 2 ;;
        --identity) IDENTITY="${2:-}"; shift 2 ;;
        --notary-profile) NOTARY_PROFILE="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*) fail "unknown option $1 (see the top of make-dmg.sh)." ;;
        *) [[ -z "$APP" ]] || fail "give one app, not $APP and $1."; APP="$1"; shift ;;
    esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "make-dmg.sh makes a macOS disk image, so it has to run on a Mac."
[[ -n "$APP" ]] || fail "give the app: bash make-dmg.sh <path/to/Some.app>"
APP="${APP%/}"
[[ -d "$APP" && "$APP" == *.app ]] || fail "$APP isn't an .app."
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
PLIST="$APP/Contents/Info.plist"
[[ -f "$PLIST" ]] || fail "$APP has no Contents/Info.plist."
ACCENT="${ACCENT#\#}"
[[ "$ACCENT" =~ ^[0-9A-Fa-f]{6}$ ]] || fail "--accent $ACCENT isn't a colour like B22234."

for tool in hdiutil codesign lipo plutil osascript tiffutil SetFile sips iconutil ditto shasum; do
    command -v "$tool" > /dev/null || fail "$tool not found. Install the Xcode command line tools (xcode-select --install)."
done
# A font given as a file must exist; anything else is an installed font's name, checked when drawing
for font in "$TITLE_FONT" "$TEXT_FONT"; do
    if [[ "$font" == */* || "$font" == *.ttf || "$font" == *.otf || "$font" == *.ttc ]]; then
        [[ -f "$font" ]] || fail "the font $font doesn't exist."
    fi
done

# Signing: the identity given, else the one Developer ID Application certificate in the keychain, else none
if [[ -z "$IDENTITY" ]]; then
    found="$(security find-identity -v -p codesigning 2> /dev/null | grep -o '"Developer ID Application: [^"]*"' | tr -d '"' | sort -u || true)"
    if [[ -n "$found" && "$(wc -l <<< "$found")" -eq 1 ]]; then
        IDENTITY="$found"
    fi
fi
[[ -z "$NOTARY_PROFILE" || -n "$IDENTITY" ]] ||
    fail "notarizing needs a signed disk image, and there's no signing identity (give --identity)."

# Finder lays out the window: that needs a desktop session and permission to control Finder
session="$(launchctl managername 2> /dev/null || echo unknown)"
[[ "$session" == "Aqua" ]] ||
    fail "Finder lays out the disk image's window, which needs someone logged in to the Mac's screen; this runs in a \"$session\" session. Run it in Terminal on the Mac."
if ! result="$(osascript -e 'tell application "Finder" to get name of startup disk' 2>&1)"; then
    fail "couldn't ask Finder to lay out the window (allow this program in System Settings > Privacy & Security > Automation): $result"
fi

plist_value() {
    plutil -extract "$1" raw -o - "$PLIST" 2> /dev/null || true
}

appFile="$(basename "$APP")"
[[ -n "$NAME" ]] || NAME="$(plist_value CFBundleDisplayName)"
[[ -n "$NAME" ]] || NAME="$(plist_value CFBundleName)"
[[ -n "$NAME" ]] || NAME="${appFile%.app}"
VERSION="$(plist_value CFBundleShortVersionString)"
[[ -n "$VERSION" ]] || VERSION="$(plist_value CFBundleVersion)"
[[ -n "$VERSION" ]] || VERSION="0"
[[ -n "$INSTALL_TEXT" ]] || INSTALL_TEXT="Drag $NAME into Applications to install"
[[ -n "$OUT_DIR" ]] || OUT_DIR="$(dirname "$APP")"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"


# The app's icon, for the background and the disk's own icon
appIcns=""
iconFile="$(plist_value CFBundleIconFile)"
if [[ -n "$iconFile" ]]; then
    [[ "$iconFile" == *.icns ]] || iconFile="$iconFile.icns"
    if [[ -f "$APP/Contents/Resources/$iconFile" ]]; then
        appIcns="$APP/Contents/Resources/$iconFile"
    fi
fi
if [[ -z "$ICON_IMAGE" ]]; then
    [[ -n "$appIcns" ]] ||
        fail "$appFile has no .icns icon (CFBundleIconFile) to draw the background from; give one with --icon <icon.png>."
    ICON_IMAGE="$appIcns"
fi
[[ -f "$ICON_IMAGE" ]] || fail "the icon $ICON_IMAGE doesn't exist."

work="$(mktemp -d "${TMPDIR:-/tmp}/make-dmg.XXXXXX")"
mountPoint=""
cleanup() {
    if [[ -n "$mountPoint" && -d "$mountPoint" ]]; then
        hdiutil detach -quiet "$mountPoint" || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

# The window's layout, in points: its content is square, and the icons' centres are at (APP_X, ICON_Y) and
# (APPLICATIONS_X, ICON_Y) from the top left. The background puts the arrow between them.
WINDOW_SIZE=600
ICON_SIZE=108
LABEL_SIZE=14
ICON_Y=300
APP_X=160
APPLICATIONS_X=440

# The background: the icon and the name centred across the top, the arrow from the app to Applications, and the
# instruction under the icons; drawn at normal and Retina sizes with macOS's own drawing code, through osascript's
# JavaScript
cat > "$work/Background.js" << 'JAVASCRIPT'
ObjC.import('AppKit');
ObjC.import('CoreText');

function run(argv) {
    const [name, iconPath, titleFontArg, textFontArg, accentHex, text, outDir] = argv;
    const [windowSize, iconSize, iconY, appX, applicationsX] = argv.slice(7).map(Number);

    const colour = (r, g, b) => $.NSColor.colorWithSRGBRedGreenBlueAlpha(r / 255, g / 255, b / 255, 1);
    const white = colour(255, 255, 255);
    const titleColour = colour(27, 35, 47);
    const mutedColour = colour(96, 104, 116);
    const accentValue = parseInt(accentHex, 16);
    const accent = colour((accentValue >> 16) & 255, (accentValue >> 8) & 255, accentValue & 255);

    // A font file's first face, or an installed font by its PostScript name
    function loadFont(font, size) {
        let result = null;
        if (font.includes('/') || /\.(ttf|otf|ttc)$/i.test(font)) {
            const descriptors = ObjC.castRefToObject(
                $.CTFontManagerCreateFontDescriptorsFromURL($.NSURL.fileURLWithPath(font)));
            if (descriptors && descriptors.count > 0) {
                result = $.NSFont.fontWithDescriptorSize(descriptors.objectAtIndex(0), size);
            }
        } else {
            result = $.NSFont.fontWithNameSize(font, size);
        }
        if (!result || result.isNil()) {
            throw new Error(`couldn't load the font ${font}.`);
        }
        return result;
    }

    // A string and its attributes, drawn with NSString's own drawing methods. On macOS 26 the JavaScript bridge can't
    // reach NSAttributedString's initialisers, and turns JavaScript arrays given to dictionaryWithObjectsForKeys into
    // an empty dictionary, so the attributes are set one at a time. $() is nil (null would be passed as NSNull).
    function makeText(string, font, colour) {
        const attributes = $.NSMutableDictionary.dictionary;
        attributes.setObjectForKey(font, $.NSFontAttributeName);
        attributes.setObjectForKey(colour, $.NSForegroundColorAttributeName);
        return { string: $.NSString.stringWithString(string), attributes };
    }
    // The ink's bounds, from the baseline's start, y up (8 is NSStringDrawingUsesDeviceMetrics)
    const inkBounds = (text) => text.string.boundingRectWithSizeOptionsAttributesContext(
        $.NSMakeSize(100000, 100000), 8, text.attributes, $());
    // Without NSStringDrawingUsesLineFragmentOrigin, the rectangle's origin is the baseline's start
    const drawText = (text, x, baseline) => text.string.drawWithRectOptionsAttributesContext(
        $.NSMakeRect(x, baseline, 100000, 100000), 0, text.attributes, $());

    const icon = $.NSImage.alloc.initWithContentsOfFile(iconPath);
    if (icon.isNil()) {
        throw new Error(`couldn't read the icon ${iconPath}.`);
    }

    // Sizes in points, drawn at s pixels per point. Positions are worked out from the top, as the window's are, and
    // turned over for AppKit, which counts from the bottom.
    function draw(s, path) {
        const size = windowSize * s;
        const bitmap = $.NSBitmapImageRep.alloc
            .initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(
                null, size, size, 8, 4, true, false, $.NSDeviceRGBColorSpace, 0, 0);
        bitmap.size = $.NSMakeSize(size, size);
        $.NSGraphicsContext.saveGraphicsState;
        const context = $.NSGraphicsContext.graphicsContextWithBitmapImageRep(bitmap);
        $.NSGraphicsContext.setCurrentContext(context);
        context.imageInterpolation = $.NSImageInterpolationHigh;

        white.setFill;
        $.NSBezierPath.fillRect($.NSMakeRect(0, 0, size, size));

        // The icon and the name, together centred across the top; a name too long to fit is drawn smaller
        const markSize = Math.round(76 * s);
        const gap = 18 * s;
        let titleSize = 64 * s;
        let title = makeText(name, loadFont(titleFontArg, titleSize), titleColour);
        let nameBounds = inkBounds(title);
        const room = size - 2 * 36 * s - markSize - gap;
        if (nameBounds.size.width > room) {
            titleSize *= room / nameBounds.size.width;
            title = makeText(name, loadFont(titleFontArg, titleSize), titleColour);
            nameBounds = inkBounds(title);
        }
        const left = Math.floor((size - (markSize + gap + nameBounds.size.width)) * 0.5);
        const centreY = 118 * s;
        const markTop = Math.round(centreY - markSize * 0.5);
        icon.drawInRectFromRectOperationFraction($.NSMakeRect(left, size - markTop - markSize, markSize, markSize),
                                                 $.NSZeroRect, $.NSCompositingOperationSourceOver, 1);
        const nameBaseline = centreY + nameBounds.size.height * 0.5 + nameBounds.origin.y;
        drawText(title, left + markSize + gap - nameBounds.origin.x, size - nameBaseline);

        // The arrow from the app's icon to the Applications folder's: a shaft with a rounded tail, and a pointed head
        const startX = (appX + iconSize * 0.5 + 22) * s;
        const endX = (applicationsX - iconSize * 0.5 - 22) * s;
        const y = size - iconY * s;
        const shaftHalfWidth = 7 * s, headLength = 24 * s, headHalfWidth = 18 * s;
        accent.setFill;
        $.NSBezierPath.fillRect($.NSMakeRect(startX, y - shaftHalfWidth, endX - headLength + shaftHalfWidth - startX,
                                             2 * shaftHalfWidth));
        $.NSBezierPath.bezierPathWithOvalInRect(
            $.NSMakeRect(startX - shaftHalfWidth, y - shaftHalfWidth, 2 * shaftHalfWidth, 2 * shaftHalfWidth)).fill;
        const head = $.NSBezierPath.bezierPath;
        head.moveToPoint($.NSMakePoint(endX - headLength, y + headHalfWidth));
        head.lineToPoint($.NSMakePoint(endX, y));
        head.lineToPoint($.NSMakePoint(endX - headLength, y - headHalfWidth));
        head.closePath;
        head.fill;

        // What to do, centred under the icons' names
        const textFont = loadFont(textFontArg, 17 * s);
        const line = makeText(text, textFont, mutedColour);
        const lineBounds = inkBounds(line);
        drawText(line, (size - lineBounds.size.width) * 0.5 - lineBounds.origin.x,
                 size - (430 * s + textFont.ascender));

        context.flushGraphics;
        $.NSGraphicsContext.restoreGraphicsState;
        const png = bitmap.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $.NSDictionary.dictionary);
        if (png.isNil() || !png.writeToFileAtomically(path, true)) {
            throw new Error(`couldn't write ${path}.`);
        }
    }

    draw(1, `${outDir}/background.png`);
    draw(2, `${outDir}/background@2x.png`);
}
JAVASCRIPT

# Finder lays out the window and saves it: macOS 26 shows a background picture only when Finder set it itself
cat > "$work/Window.applescript" << 'APPLESCRIPT'
on run argv
    set volumeName to item 1 of argv
    set appName to item 2 of argv
    set windowSize to (item 3 of argv) as integer
    set iconSize to (item 4 of argv) as integer
    set labelSize to (item 5 of argv) as integer
    set iconY to (item 6 of argv) as integer
    set appX to (item 7 of argv) as integer
    set applicationsX to (item 8 of argv) as integer

    tell application "Finder"
        tell disk volumeName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {200, 120, 200 + windowSize, 120 + windowSize}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to iconSize
            set text size of viewOptions to labelSize
            set background picture of viewOptions to file ".background:background.tiff"
            set position of item appName of container window to {appX, iconY}
            set position of item "Applications" of container window to {applicationsX, iconY}
            update without registering applications
            delay 2
            close
        end tell
    end tell
end run
APPLESCRIPT

echo "[make-dmg] Drawing the background..."
osascript -l JavaScript "$work/Background.js" "$NAME" "$ICON_IMAGE" "$TITLE_FONT" "$TEXT_FONT" "$ACCENT" "$INSTALL_TEXT" "$work" \
    "$WINDOW_SIZE" "$ICON_SIZE" "$ICON_Y" "$APP_X" "$APPLICATIONS_X" || fail "couldn't draw the background."

# The disk's own icon: the app's .icns, else one made from the picture given
volumeIcns="$appIcns"
if [[ -z "$volumeIcns" ]]; then
    iconset="$work/Volume.iconset"
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        sips -s format png -z "$size" "$size" "$ICON_IMAGE" --out "$iconset/icon_${size}x${size}.png" > /dev/null
        sips -s format png -z $((size * 2)) $((size * 2)) "$ICON_IMAGE" --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
    done
    volumeIcns="$work/Volume.icns"
    iconutil -c icns "$iconset" -o "$volumeIcns" || fail "couldn't make the disk's icon from $ICON_IMAGE."
fi

# What goes on the disk: the app, an Applications shortcut and the background in a hidden .background folder
stageDir="$work/stage"
mkdir -p "$stageDir/.background"
ditto "$APP" "$stageDir/$appFile"
ln -s /Applications "$stageDir/Applications"
tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" \
    -out "$stageDir/.background/background.tiff" 2> /dev/null

# A writable image first, with room for the window settings Finder saves on it; compressed afterwards
echo "[make-dmg] Making the disk image..."
OUT_FILE="$OUT_DIR/$NAME-$VERSION.dmg"
rwImage="$work/rw.dmg"
rm -f "$OUT_FILE"
sizeMb=$(( $(du -sm "$stageDir" | cut -f 1) + 20 ))
hdiutil create -quiet -volname "$NAME" -srcfolder "$stageDir" -fs HFS+ -format UDRW -size "${sizeMb}m" -ov "$rwImage"
mountPoint="$(hdiutil attach -readwrite -noverify -noautoopen "$rwImage" | awk -F'\t' '/\/Volumes\// { print $NF }')"
[[ -d "$mountPoint" ]] || fail "couldn't open the disk image to lay out its window."
osascript "$work/Window.applescript" "$(basename "$mountPoint")" "$appFile" "$WINDOW_SIZE" "$ICON_SIZE" "$LABEL_SIZE" \
    "$ICON_Y" "$APP_X" "$APPLICATIONS_X" || fail "Finder couldn't lay out the disk image's window."
# The disk's own icon, after Finder is done with the window (Finder drops it otherwise)
cp "$volumeIcns" "$mountPoint/.VolumeIcon.icns"
SetFile -a C "$mountPoint"
rm -rf "$mountPoint/.fseventsd"
sync
# Finder or an indexer can still hold the volume for a moment: hdiutil then exits 16 (busy). Retry, then force.
retry() {
    local attempt
    for attempt in 1 2 3 4 5; do
        "$@" && return 0
        sleep 3
    done
    return 1
}
# A detach can report failure after the volume is already gone, so a missing mount point counts as detached.
detach_volume() {
    local attempt
    for attempt in 1 2 3 4 5; do
        hdiutil detach -quiet "$mountPoint" && return 0
        [[ -d "$mountPoint" ]] || return 0
        sleep 3
    done
    hdiutil detach -force "$mountPoint" || [[ ! -d "$mountPoint" ]]
}
detach_volume
mountPoint=""
retry hdiutil convert -quiet "$rwImage" -format UDZO -ov -o "$OUT_FILE"

if [[ -n "$IDENTITY" ]]; then
    codesign --force --timestamp --sign "$IDENTITY" "$OUT_FILE"
    if [[ -n "$NOTARY_PROFILE" ]]; then
        xcrun notarytool submit "$OUT_FILE" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$OUT_FILE"
    fi
fi

echo ""
echo "Disk image: $OUT_FILE"
echo "SHA256:     $(shasum -a 256 "$OUT_FILE" | awk '{print $1}')"
if [[ -n "$IDENTITY" ]]; then
    echo "Signed with: $IDENTITY"
else
    echo "Not signed: no Developer ID Application certificate found (give one with --identity)."
fi
