#!/bin/zsh
# Builds Vorssaint, assembles the .app bundle, signs it and (with --install)
# installs it into /Applications.
#
# The bundle is staged in a temporary directory outside ~/Documents: folders synced
# by File Provider gain xattrs (com.apple.provenance etc.) that invalidate codesign.
set -euo pipefail
cd "$(dirname "$0")"

# Flags: --dev builds the local-only "Vorssaint (Developer)" variant (its own
# bundle id, so it coexists with the official app); --install puts it in /Applications.
DEV=0
INSTALL=0
TEST=0
for arg in "$@"; do
    case "$arg" in
        --dev)     DEV=1 ;;
        --install) INSTALL=1 ;;
        --test)    TEST=1 ;;
    esac
done

if (( DEV )); then
    APP_NAME="Vorssaint (Developer)"
    EXECUTABLE="VorssaintDeveloper"
else
    APP_NAME="Vorssaint"
    EXECUTABLE="Vorssaint"
fi
TARGET="arm64-apple-macosx14.0"

# Prefer the macOS 26 SDK when present: the 27 SDK turns SwiftUI property wrappers
# into macros (SwiftUIMacros plugin) that the Command Line Tools cannot load yet.
PINNED_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
if [[ -d "$PINNED_SDK" ]]; then
    SDK="$PINNED_SDK"
else
    SDK="$(xcrun --show-sdk-path)"
fi

# --test: compile and run the standalone unit tests (pure metric helpers only —
# no app, no UI, no IOKit), then exit. Fast and deterministic; no XCTest needed.
if (( TEST )); then
    echo "▸ Building & running unit tests against $(basename "$SDK")…"
    rm -rf build
    mkdir -p build
    swiftc -O -target "$TARGET" -sdk "$SDK" \
        Sources/Vorssaint/Services/Metrics/MetricFormat.swift \
        Sources/Vorssaint/Services/CleaningMode/CleaningUnlockCounter.swift \
        Tests/MetricsTests.swift \
        -o build/metrics-tests
    ./build/metrics-tests
    exit $?
fi

echo "▸ Compiling (release) against $(basename "$SDK")…"
rm -rf build
mkdir -p build
swiftc -O -target "$TARGET" -sdk "$SDK" \
    Sources/Vorssaint/**/*.swift \
    -o "build/$EXECUTABLE"

echo "▸ Generating app icon…"
swift Tools/MakeIcon.swift build/AppIcon.iconset

echo "▸ Assembling and signing bundle…"
STAGE="$(mktemp -d)/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "build/$EXECUTABLE" "$STAGE/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
if (( DEV )); then
    # A distinct identity so the Developer build installs and runs next to the
    # official app, with its own permissions, preferences and login item.
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.vorssaint.utils.dev" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Vorssaint (Developer)" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Vorssaint (Developer)" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE" "$STAGE/Contents/Info.plist"
    # Stamp the source commit + build time so the running dev app shows (in About)
    # exactly which code it was compiled from. Lets you verify it matches HEAD before
    # testing, instead of unknowingly running a stale build. Dev-only; never shipped.
    SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    [[ -n "$(git status --porcelain 2>/dev/null)" ]] && SHA="$SHA-dirty"
    /usr/libexec/PlistBuddy -c "Add :VorssaintBuildCommit string '$SHA · $(date '+%Y-%m-%d %H:%M')'" "$STAGE/Contents/Info.plist"
    echo "  stamped dev build: $SHA"
fi
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
iconutil -c icns build/AppIcon.iconset -o "$STAGE/Contents/Resources/AppIcon.icns"
cp build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png "$STAGE/Contents/Resources/"
xattr -cr "$STAGE"

# Signing, in order of preference:
#   1. Developer ID Application — the real, Apple-issued identity used for
#      notarized releases. Signed with the hardened runtime (required for
#      notarization), the app's entitlements and a secure timestamp. Gives a
#      stable, team-based designated requirement, so permissions persist across
#      updates AND Gatekeeper shows no "unverified developer" warning.
#   2. "Vorssaint Utils Signing" — the legacy stable self-signed identity, kept
#      as a fallback so contributors without a Developer ID still get a constant
#      designated requirement across their local builds.
#   3. Ad-hoc — fresh clone with no identity at all.
ENTITLEMENTS="Resources/Vorssaint.entitlements"
DEVID="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/')"
LEGACY_IDENTITY="Vorssaint Utils Signing"
if [[ -n "$DEVID" ]]; then
    echo "  signing with Developer ID (hardened runtime): $DEVID"
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" --sign "$DEVID" "$STAGE"
elif security find-identity -p codesigning 2>/dev/null | grep -q "$LEGACY_IDENTITY"; then
    echo "  signing with legacy self-signed identity: $LEGACY_IDENTITY"
    codesign --force --sign "$LEGACY_IDENTITY" "$STAGE"
else
    echo "  signing ad-hoc (no identity installed — run Tools/setup-signing.sh)"
    codesign --force --sign - "$STAGE"
fi
codesign --verify --strict "$STAGE"

mkdir -p "build/stage"
rm -rf "build/stage/$APP_NAME.app"
ditto "$STAGE" "build/stage/$APP_NAME.app"
echo "✓ Bundle ready: build/stage/$APP_NAME.app"

if (( INSTALL )); then
    echo "▸ Installing into /Applications…"
    pkill -x "$EXECUTABLE" 2>/dev/null || true
    # Remove the pre-rename apps so two menu bar items never coexist. Same bundle
    # id, so macOS keeps the granted permissions for the new bundle.
    for legacy in "Vorss:Vorss" "Vorssaint Utils:VorssaintUtils"; do
        name="${legacy%%:*}"; proc="${legacy##*:}"
        if [[ -d "/Applications/$name.app" ]]; then
            pkill -x "$proc" 2>/dev/null || true
            rm -rf "/Applications/$name.app"
            echo "  (legacy $name.app removed)"
        fi
    done
    sleep 0.5
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$STAGE" "/Applications/$APP_NAME.app"
    echo "✓ Installed: /Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
fi
