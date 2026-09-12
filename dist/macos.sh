#!/bin/bash
# Package bin/trndi-multi as "Trndi Multi.app" and wrap it in a .dmg, the way
# Trndi's dist/macos.sh does. Run from dist/ after `gmake`; needs create-dmg
# (MacPorts: `port install create-dmg`). The icon and the DMG background come
# from the vendored Trndi submodule, so there is no artwork to keep in sync.
#
#   VERSION      CFBundleShortVersionString (default 1.0)
#   BUILD_NUMBER CFBundleVersion            (default 1)

set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP_NAME="Trndi Multi"
APP="macos/${APP_NAME}.app"
BIN="../bin/trndi-multi"
TRNDI="../vendor/trndi"

[ -x "${BIN}" ] || { echo "${BIN} not found; build first (gmake)" >&2; exit 1; }

rm -rf macos
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/trndi-multi"

# GPLv3 sections 4 and 6: the licence travels with the binary.
cp ../LICENSE "${APP}/Contents/Resources/LICENSE.txt"

# Dock/Finder icon: Trndi's macOS artwork, as an .icns built with the
# Apple-standard iconset names so iconutil accepts it.
ICON_SRC="${TRNDI}/Trndi-macos.png"
[ -f "${ICON_SRC}" ] || ICON_SRC="${TRNDI}/Trndi.png"
ICON_PLIST=""
if [ -f "${ICON_SRC}" ]; then
  ICONSET="macos/TrndiMulti.iconset"
  mkdir -p "${ICONSET}"
  for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
              128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 \
              512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
    size="${spec%%:*}"; name="${spec#*:}"
    sips -z "${size}" "${size}" "${ICON_SRC}" --out "${ICONSET}/${name}.png" >/dev/null
  done
  iconutil -c icns "${ICONSET}" -o "${APP}/Contents/Resources/TrndiMulti.icns"
  ICON_PLIST="  <key>CFBundleIconFile</key><string>TrndiMulti.icns</string>"
else
  echo "WARN: no icon source under ${TRNDI}; bundle gets the generic icon" >&2
fi

# Unquoted heredoc: VERSION, BUILD_NUMBER and ICON_PLIST expand.
cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>com.slicke.trndi-multi</string>
  <key>CFBundleExecutable</key><string>trndi-multi</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
${ICON_PLIST}
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
</dict>
</plist>
PLIST
chmod 644 "${APP}/Contents/Info.plist"

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
