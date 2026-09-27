#!/bin/bash
# Package bin/trndi-multi as "Trndi Multi.app" and wrap it in a .dmg, the way
# Trndi's dist/macos.sh does. Run from dist/ after `gmake`; needs create-dmg
# (MacPorts: `port install create-dmg`). The icon is this program's own
# artwork; the DMG background is just the arrow between the two icon slots
# and still comes from the vendored Trndi submodule.
#
#   VERSION      CFBundleShortVersionString (default 1.0)
#   BUILD_NUMBER CFBundleVersion            (default 1)
#
# The .app itself is put together by macos_bundle.sh, which the Makefile's
# development bundle shares.

set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP_NAME="Trndi Multi"
APP="macos/${APP_NAME}.app"
BIN="../bin/trndi-multi"
TRNDI="../vendor/trndi"

rm -rf macos
APP_NAME="${APP_NAME}" VERSION="${VERSION}" BUILD_NUMBER="${BUILD_NUMBER}" \
  ./macos_bundle.sh "${BIN}" "${APP}"

# DMG contents: the app, a first-launch README, and (added by create-dmg) an
# Applications link to drag it onto.
mkdir -p macos/stage
cp -R "${APP}" macos/stage/
cp macos_README.txt macos/stage/README.txt

# Trndi's background is just the arrow between the two icon slots, so it
# fits here unchanged. Optional: no swift, no background.
DMG_BG_ARG=()
BG_SCRIPT="${TRNDI}/dist/macos_dmg_background.swift"
if [ -f "${BG_SCRIPT}" ] && command -v swift >/dev/null 2>&1 \
   && swift "${BG_SCRIPT}" macos/dmg-background.png && [ -f macos/dmg-background.png ]; then
  DMG_BG_ARG=(--background macos/dmg-background.png)
else
  echo "WARN: no DMG background (swift or ${BG_SCRIPT} missing)" >&2
fi

DMG="trndi-multi-macos-arm64.dmg"
rm -f "${DMG}"
# Options before the positional args: some create-dmg builds stop parsing at
# the first positional and silently ignore what follows.
create-dmg \
  --volname "${APP_NAME}" \
  --format UDZO \
  --window-size 600 500 \
  "${DMG_BG_ARG[@]}" \
  --icon-size 128 \
  --icon "${APP_NAME}.app" 150 200 \
  --icon "README.txt" 300 360 \
  --app-drop-link 450 200 \
  "${DMG}" macos/stage
[ -f "${DMG}" ] || { echo "create-dmg produced no ${DMG}" >&2; exit 1; }

rm -f rw.*.dmg
rm -rf macos
echo "Packaged dist/${DMG}"
