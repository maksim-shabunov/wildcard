#!/bin/bash
#
# Installs Wildcard.
#
#   curl -fsSL https://raw.githubusercontent.com/maksim-shabunov/wildcard/main/install.sh | bash
#
# Downloads the latest release, checks it against the checksum published beside
# it, and puts Wildcard.app in /Applications. Run it again to update.
#
#   WILDCARD_VERSION=1.0.0   install a specific version rather than the latest
#   WILDCARD_PREFIX=~/Applications   install somewhere else
#
set -euo pipefail

REPO="maksim-shabunov/wildcard"
APP_NAME="Wildcard.app"

bold()  { printf '\033[1m%s\033[0m\n' "$1"; }
info()  { printf '  %s\n' "$1"; }
die()   { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# --- checks -----------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "Wildcard is a macOS application."

major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] 2>/dev/null || die "Wildcard needs macOS 14 (Sonoma) or later. This is $(sw_vers -productVersion)."

command -v curl >/dev/null || die "curl is required."

# --- which version ----------------------------------------------------------

VERSION="${WILDCARD_VERSION:-}"
if [ -z "$VERSION" ]; then
  # The redirect on /releases/latest names the tag, which avoids depending on
  # the API and its rate limit for what is a single string.
  resolved="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    "https://github.com/$REPO/releases/latest" 2>/dev/null || true)"
  case "$resolved" in
    */releases/tag/*) VERSION="${resolved##*/tag/}" ;;
  esac
fi
VERSION="${VERSION#v}"
# A URL, an error page or an empty string all fail this, and all of them would
# otherwise turn into a baffling 404 two lines further down.
case "$VERSION" in
  [0-9]*.[0-9]*) : ;;
  *) die "could not work out the latest version. Set WILDCARD_VERSION to install a specific one." ;;
esac

ARCHIVE="Wildcard-$VERSION-macos-universal.zip"
BASE="https://github.com/$REPO/releases/download/v$VERSION"

bold "Wildcard $VERSION"

# --- download ---------------------------------------------------------------

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

info "Downloading…"
curl -fsSL --retry 3 -o "$TMP/$ARCHIVE" "$BASE/$ARCHIVE" \
  || die "could not download $BASE/$ARCHIVE"
curl -fsSL --retry 3 -o "$TMP/$ARCHIVE.sha256" "$BASE/$ARCHIVE.sha256" \
  || die "could not download the checksum for $ARCHIVE"

info "Checking the download…"
expected="$(cut -d' ' -f1 < "$TMP/$ARCHIVE.sha256")"
actual="$(shasum -a 256 "$TMP/$ARCHIVE" | cut -d' ' -f1)"
[ "$expected" = "$actual" ] || die "checksum mismatch — the download is not what was published.
  expected $expected
  got      $actual"

ditto -x -k "$TMP/$ARCHIVE" "$TMP/unpacked" || die "could not unpack the download."
[ -d "$TMP/unpacked/$APP_NAME" ] || die "the archive did not contain $APP_NAME."

# Belt and braces. curl does not set the quarantine flag — that comes from
# browsers — so this is normally a no-op. It matters when someone has downloaded
# the zip in Safari and pointed this script at it, in which case an ad-hoc
# signed app would otherwise be refused outright rather than merely warned about.
xattr -dr com.apple.quarantine "$TMP/unpacked/$APP_NAME" 2>/dev/null || true

codesign --verify --strict "$TMP/unpacked/$APP_NAME" 2>/dev/null \
  || die "the downloaded app failed its own signature check. Not installing it."

# --- install ----------------------------------------------------------------

PREFIX="${WILDCARD_PREFIX:-/Applications}"
PREFIX="${PREFIX/#\~/$HOME}"
if [ ! -w "$PREFIX" ]; then
  PREFIX="$HOME/Applications"
  mkdir -p "$PREFIX"
  info "/Applications is not writable, using $PREFIX instead."
fi
DEST="$PREFIX/$APP_NAME"

# Replacing a bundle out from under a running process gets you a half-old app.
if pgrep -x Wildcard >/dev/null 2>&1; then
  info "Quitting the running copy…"
  osascript -e 'quit app "Wildcard"' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x Wildcard >/dev/null 2>&1 || break
    sleep 0.3
  done
fi

# Braces are load-bearing: bash 3.2, which is what /bin/bash still is on macOS
# and therefore what `curl | bash` runs, reads the bytes of a multi-byte
# character as part of a variable name. "$DEST…" looked up a variable called
# DEST… and died under `set -u`.
info "Installing to ${DEST}…"
rm -rf "$DEST"
ditto "$TMP/unpacked/$APP_NAME" "$DEST"

# Otherwise LaunchServices can keep pointing at the copy that was just deleted.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST" >/dev/null 2>&1 || true

echo
bold "Installed."
info "$DEST"
echo
info "Open it now:  open -a Wildcard"
info "Command line and agent access are set up from Settings → Integrations."
echo
