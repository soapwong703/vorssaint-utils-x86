#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

# Packages an already-built Vorssaint binary into Vorssaint.app and installs it,
# skipping the full app recompile (117 Swift files). Only the small pieces are
# built from source: the fan helper (6 files), the Now Playing adapter (1 file)
# and the icon assets. The main binary is reused as-is.
#
# Usage: ./Tools/install-built.sh [--bin PATH] [--no-install] [--open]
#   --bin PATH    reuse this binary (default: probe .build/*/release/Vorssaint)
#   --no-install  stage build/stage/Vorssaint.app only, do not touch /Applications
#   --open        open the app after installing
setopt NULL_GLOB 2>/dev/null || true  # unmatched probe patterns expand to nothing
cd "$(dirname "$0")/.."

APP_NAME="Vorssaint"
EXECUTABLE="Vorssaint"
APP_BUNDLE_ID="com.vorssaint.utils"
FAN_HELPER_ID="$APP_BUNDLE_ID.fan-control"
NOW_PLAYING_ADAPTER_ID="$APP_BUNDLE_ID.now-playing"
NOW_PLAYING_ADAPTER="libVorssaintNowPlaying.dylib"
ENTITLEMENTS="Resources/Vorssaint.entitlements"
LEGACY_IDENTITY="Vorssaint Utils Signing"
STAGE="build/stage/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

BIN=""
INSTALL=1
OPEN=0
for arg in "$@"; do
    case "$arg" in
        --bin=*) BIN="${arg#--bin=}" ;;
        --no-install) INSTALL=0 ;;
        --open) OPEN=1 ;;
        -h|--help)
            echo "Usage: $0 [--bin=PATH] [--no-install] [--open]"
            exit 0 ;;
        *)
            if [[ -f "$arg" ]]; then
                BIN="$arg"
            else
                echo "✗ unknown argument: $arg" >&2
                exit 1
            fi ;;
    esac
done

if [[ -z "$BIN" ]]; then
    for candidate in .build/*/release/$EXECUTABLE .build/release/$EXECUTABLE build/$EXECUTABLE; do
        if [[ -f "$candidate" ]]; then
            BIN="$candidate"
            break
        fi
    done
fi
if [[ -z "$BIN" || ! -f "$BIN" ]]; then
    echo "✗ no built binary found — pass --bin=PATH or build first" >&2
    exit 1
fi
ARCH_INFO="$(lipo -info "$BIN" 2>/dev/null || true)"
echo "▸ Reusing binary: $BIN ($ARCH_INFO)"

case "$ARCH_INFO" in
    *x86_64*arm64*|*arm64*x86_64*)
        # Fat binary: build the small pieces for the host arch.
        if [[ "$(uname -m)" == "arm64" ]]; then TARGET="arm64-apple-macosx14.0";
        else TARGET="x86_64-apple-macosx14.0"; fi ;;
    *arm64*)  TARGET="arm64-apple-macosx14.0" ;;
    *x86_64*) TARGET="x86_64-apple-macosx14.0" ;;
    *)
        echo "✗ cannot determine architecture of $BIN" >&2
        exit 1 ;;
esac
SDK="$(xcrun --show-sdk-path)"
mkdir -p build
developer_id_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' \
        | head -1 \
        | sed -E 's/.*"(.*)".*/\1/' || true
}

legacy_identity_installed() {
    local probe signed=1
    security unlock-keychain -p vorssaint-signing \
        "$HOME/Library/Keychains/vorssaint-signing.keychain-db" 2>/dev/null || true
    probe="$(mktemp)"
    cp /bin/echo "$probe"
    /usr/bin/codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$probe" \
        >/dev/null 2>&1 && signed=0
    rm -f "$probe"
    return $signed
}

echo "▸ Compiling fan helper + Now Playing adapter ($TARGET)…"
swiftc -O -target "$TARGET" -sdk "$SDK" \
    Sources/Vorssaint/Services/FanControl/FanControlSupport.swift \
    Sources/Vorssaint/Services/FanControl/FanControlXPC.swift \
    Sources/Vorssaint/Services/SystemMonitor/SMCClient.swift \
    Sources/Vorssaint/Services/Metrics/TemperatureSensorSelector.swift \
    Sources/Vorssaint/Services/FanControl/FanControlHardware.swift \
    Sources/FanControlHelper/main.swift \
    -o "build/$FAN_HELPER_ID"
"build/$FAN_HELPER_ID" --selftest
swiftc -O -target "$TARGET" -sdk "$SDK" -emit-library \
    -module-name VorssaintNowPlaying \
    Sources/NowPlayingAdapter/NowPlayingAdapter.swift \
    -o "build/$NOW_PLAYING_ADAPTER"

echo "▸ Generating icons…"
swiftc Tools/MakeIcon.swift -o build/MakeIcon
./build/MakeIcon build/AppIcon.iconset

echo "▸ Assembling bundle…"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" \
    "$STAGE/Contents/Library/LaunchDaemons" "$STAGE/Contents/Library/LaunchServices" \
    "$STAGE/Contents/Frameworks"
cp "$BIN" "$STAGE/Contents/MacOS/$EXECUTABLE"
cp "build/$FAN_HELPER_ID" "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID"
cp "build/$NOW_PLAYING_ADAPTER" "$STAGE/Contents/Frameworks/$NOW_PLAYING_ADAPTER"
cp Resources/now-playing.pl "$STAGE/Contents/Resources/now-playing.pl"
cp Resources/com.vorssaint.utils.fan-control.plist \
    "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
cp CHANGELOG.md "$STAGE/Contents/Resources/CHANGELOG.md"
for lproj in Resources/*.lproj; do
    cp -R "$lproj" "$STAGE/Contents/Resources/"
done
FAN_HELPER_VERSION="$(
    export LC_ALL=C
    /usr/bin/shasum -a 256 \
        "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID" \
        "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist" \
        | /usr/bin/awk '{print $1}' | /usr/bin/shasum -a 256 \
        | /usr/bin/awk '{print $1}'
)"
/usr/libexec/PlistBuddy -c "Add :VorssaintFanControlHelperVersion string '$FAN_HELPER_VERSION'" \
    "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
cp build/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
cp build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png "$STAGE/Contents/Resources/"
if [[ -d Resources/Gifs ]]; then
    mkdir -p "$STAGE/Contents/Resources/Gifs"
    cp Resources/Gifs/*.gif "$STAGE/Contents/Resources/Gifs/"
fi
if [[ -d Resources/Images ]]; then
    mkdir -p "$STAGE/Contents/Resources/Images"
    cp Resources/Images/* "$STAGE/Contents/Resources/Images/"
fi
chmod +x "$STAGE/Contents/MacOS/$EXECUTABLE"
xattr -c -r "$STAGE" 2>/dev/null || true

DEVID="$(developer_id_identity)"
sign_inner() {
    local target="$1" identifier="$2"
    if [[ -n "$DEVID" ]]; then
        /usr/bin/codesign --force --strip-disallowed-xattrs --options runtime --timestamp \
            --identifier "$identifier" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$identifier" --sign "$LEGACY_IDENTITY" "$target"
    else
        /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$identifier" --sign - "$target"
    fi
}
sign_bundle() {
    local bundle="$1"
    if [[ -n "$DEVID" ]]; then
        echo "  signing with Developer ID (hardened runtime): $DEVID"
        /usr/bin/codesign --force --strip-disallowed-xattrs --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$DEVID" "$bundle"
    elif legacy_identity_installed; then
        echo "  signing with stable local identity: $LEGACY_IDENTITY"
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$bundle"
    else
        echo "  signing ad-hoc (no identity — run Tools/setup-signing.sh for stable TCC grants)"
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign - "$bundle"
    fi
}

echo "▸ Signing…"
sign_inner "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID" "$FAN_HELPER_ID"
sign_inner "$STAGE/Contents/Frameworks/$NOW_PLAYING_ADAPTER" "$NOW_PLAYING_ADAPTER_ID"
sign_bundle "$STAGE"
/usr/bin/codesign --verify --strict "$STAGE/Contents/MacOS/$EXECUTABLE"
/usr/bin/codesign --verify --strict "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID"
/usr/bin/codesign --verify --strict "$STAGE/Contents/Frameworks/$NOW_PLAYING_ADAPTER"
/usr/bin/codesign --verify --deep --strict "$STAGE"
echo "✓ Bundle ready: $STAGE"

if (( INSTALL )); then
    echo "▸ Installing into /Applications…"
    pkill -x "$EXECUTABLE" 2>/dev/null || true
    for _ in {1..50}; do
        pgrep -x "$EXECUTABLE" >/dev/null 2>&1 || break
        sleep 0.1
    done
    rm -rf "$DEST"
    ditto --noextattr --noqtn "$STAGE" "$DEST"
    xattr -c -r "$DEST" 2>/dev/null || true
    if ! codesign --verify --deep --strict "$DEST" >/dev/null 2>&1; then
        echo "  re-signing installed copy…"
        sign_inner "$DEST/Contents/Library/LaunchServices/$FAN_HELPER_ID" "$FAN_HELPER_ID"
        sign_inner "$DEST/Contents/Frameworks/$NOW_PLAYING_ADAPTER" "$NOW_PLAYING_ADAPTER_ID"
        sign_bundle "$DEST"
    fi
    /usr/bin/codesign --verify --deep --strict "$DEST"
    echo "✓ Installed: $DEST"
    if (( OPEN )); then
        open "$DEST"
    fi
fi
