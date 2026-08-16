#!/bin/bash
#
# Builds Wildcard.app.
#
#   ./build.sh                    release build, sign, install to ~/Applications
#   ./build.sh --debug            a debug build instead, native architecture only
#   ./build.sh --universal        Apple Silicon and Intel in one binary
#   ./build.sh --zip              also produce a distributable archive + checksum
#   ./build.sh --no-install       stop after signing, leave it in the build dir
#   ./build.sh --help
#
# Everything is built outside this folder. The project may live on an
# iCloud-synced Desktop, and iCloud attaches extended attributes that codesign
# rejects outright ("resource fork, Finder information, or similar detritus not
# allowed"); they cannot be stripped while the folder is syncing. Override the
# location with WILDCARD_BUILD_DIR.
#
# The signature is ad-hoc. Wildcard has no paid Apple Developer account, so it
# cannot be notarised. A copy you build yourself is never quarantined and opens
# normally; a copy downloaded from the internet is, which is what install.sh and
# the Homebrew cask deal with. See README.md, "Why the security warning".
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${WILDCARD_BUILD_DIR:-/tmp/wildcard-build}"
CONFIG=release
INSTALL=1
UNIVERSAL=0
ZIP=0

for arg in "$@"; do
  case "$arg" in
    --debug)      CONFIG=debug ;;
    --release)    CONFIG=release ;;
    --universal)  UNIVERSAL=1 ;;
    --zip)        ZIP=1 ;;
    --no-install) INSTALL=0 ;;
    -h|--help)    sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# The version lives in one place, in Swift. Everything else reads it from there.
VERSION="$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' \
  "$SRC/Sources/WildcardKit/Version.swift")"
if [ -z "$VERSION" ]; then
  echo "could not read the version out of Sources/WildcardKit/Version.swift" >&2
  exit 1
fi
BUILD_NUMBER="${WILDCARD_BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

# Must match the platform in Package.swift and LSMinimumSystemVersion below.
MACOS_MIN=14.0

APP="$BUILD/Wildcard.app"
SCRATCH="$BUILD/.build"
ARCHLABEL="$(uname -m)"
[ "$UNIVERSAL" -eq 1 ] && ARCHLABEL="universal"

echo "==> Wildcard $VERSION ($CONFIG, $ARCHLABEL)"

build_for() {   # build_for <triple-or-empty>
  local args=(--package-path "$SRC" --scratch-path "$SCRATCH" -c "$CONFIG")
  [ -n "$1" ] && args+=(--triple "$1")
  swift build "${args[@]}"
}

if [ "$UNIVERSAL" -eq 1 ]; then
  # Two ordinary builds joined with lipo, rather than `swift build --arch a
  # --arch b`. That flag hands the job to Xcode's build system, which on Xcode
  # 16 collapses into "duplicate output file" and "SWIFT_VERSION '' is
  # unsupported" for a package with several products. `--triple` stays on
  # SwiftPM's own build system, which behaves the same everywhere.
  build_for "arm64-apple-macosx$MACOS_MIN"
  build_for "x86_64-apple-macosx$MACOS_MIN"

  BIN="$SCRATCH/universal-$CONFIG"
  rm -rf "$BIN"
  mkdir -p "$BIN"
  for product in WildcardApp wildcard; do
    lipo -create -output "$BIN/$product" \
      "$SCRATCH/arm64-apple-macosx/$CONFIG/$product" \
      "$SCRATCH/x86_64-apple-macosx/$CONFIG/$product"
  done
else
  build_for ""
  BIN="$SCRATCH/$CONFIG"
fi

if [ ! -x "$BIN/WildcardApp" ] || [ ! -x "$BIN/wildcard" ]; then
  echo "built products not found in $BIN" >&2
  exit 1
fi

echo "==> Assembling"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"

cp "$BIN/WildcardApp" "$APP/Contents/MacOS/Wildcard"
cp "$BIN/wildcard"    "$APP/Contents/Helpers/wildcard"
cp "$SRC/Sources/WildcardKit/Catalog/Resources/catalog.json" "$APP/Contents/Resources/catalog.json"
cp "$SRC/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>Wildcard</string>
    <key>CFBundleDisplayName</key>          <string>Wildcard</string>
    <key>CFBundleIdentifier</key>           <string>com.wildcard.Wildcard</string>
    <key>CFBundleExecutable</key>           <string>Wildcard</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundleVersion</key>              <string>$BUILD_NUMBER</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>       <string>$MACOS_MIN</string>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSHumanReadableCopyright</key>     <string>MIT licensed. https://github.com/maksim-shabunov/wildcard</string>
    <!-- Wildcard is a normal windowed application. It is deliberately not an
         agent and puts nothing in the menu bar. -->
    <key>LSUIElement</key>                  <false/>
    <!-- How the helper raises a proposal for approval: wildcard://proposal/<id> -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>      <string>Wildcard proposal</string>
            <key>CFBundleTypeRole</key>     <string>Viewer</string>
            <key>CFBundleURLSchemes</key>
            <array><string>wildcard</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
# Nested code first, then the wrapper, so the outer seal covers a settled tree.
xattr -cr "$APP"
codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/wildcard"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

if [ "$ZIP" -eq 1 ]; then
  DIST="$BUILD/dist"
  ARCHIVE="$DIST/Wildcard-$VERSION-macos-$ARCHLABEL.zip"
  echo "==> Archiving"
  rm -rf "$DIST"
  mkdir -p "$DIST"
  # ditto, not zip: it is the only one that keeps a bundle's symlinks and
  # signature intact, and a resealed-by-zip app fails codesign on the far end.
  ditto -c -k --keepParent "$APP" "$ARCHIVE"
  ( cd "$DIST" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256" )
  echo "archive  -> $ARCHIVE"
  echo "checksum -> $(cut -d' ' -f1 < "$ARCHIVE.sha256")"
fi

if [ "$INSTALL" -eq 1 ]; then
  DEST="$HOME/Applications/Wildcard.app"
  echo "==> Installing"
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  # LaunchServices otherwise keeps pointing at a build that no longer exists.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST" >/dev/null 2>&1 || true
  echo
  echo "Wildcard.app -> $DEST"
  echo "helper       -> $DEST/Contents/Helpers/wildcard"
  echo
  echo "Open it with: open '$DEST'"
else
  echo
  echo "Wildcard.app -> $APP"
fi
