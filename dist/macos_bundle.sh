#!/bin/bash
# Wrap a trndi-multi binary in a macOS .app: the executable, the licence, the
# Finder icon and an Info.plist. Shared by dist/macos.sh (the DMG) and the
# Makefile's development bundle, which differ only in identity and version.
#
#   macos_bundle.sh <binary> <app path>
#
#   APP_ID       CFBundleIdentifier         (default com.slicke.trndi-multi)
#   APP_NAME     CFBundleName/DisplayName   (default Trndi Multi)
#   VERSION      CFBundleShortVersionString (default 1.0)
#   BUILD_NUMBER CFBundleVersion            (default 1)
#   ICON_SRC     square PNG for the icon    (default TrndiMulti.png beside dist/)

set -euo pipefail

BIN="$1"
APP="$2"
APP_ID="${APP_ID:-com.slicke.trndi-multi}"
APP_NAME="${APP_NAME:-Trndi Multi}"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ICON_SRC="${ICON_SRC:-$(dirname "$0")/../TrndiMulti.png}"

[ -x "${BIN}" ] || { echo "${BIN} not found; build first (gmake)" >&2; exit 1; }

mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
# A copy, not a link: LaunchServices and NSBundle resolve the bundle from the
# executable's real path, so a symlinked one would run outside the bundle.
cp "${BIN}" "${APP}/Contents/MacOS/trndi-multi"

# GPLv3 sections 4 and 6: the licence travels with the binary.
cp "$(dirname "$0")/../LICENSE" "${APP}/Contents/Resources/LICENSE.txt"

# Finder icon: ICON_SRC, by default TrndiMulti.png, the square app icon `make icon` normalises
# out of logo.png, as an .icns built with the Apple-standard iconset names
# so iconutil accepts it. The icon of the *running* app is the binary's
# MAINICON resource, which the LCL's Cocoa widgetset pushes to the Dock at
# startup, and trndimulti.branding hands the Dock back to this icon when the
# program runs as an .app; the development bundle passes its own artwork.
ICNS="${APP}/Contents/Resources/TrndiMulti.icns"
ICON_PLIST=""
if [ -f "${ICON_SRC}" ]; then
  ICONSET="$(dirname "${APP}")/TrndiMulti.iconset"
  rm -rf "${ICONSET}"
  mkdir -p "${ICONSET}"
  for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
              128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 \
              512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
    size="${spec%%:*}"; name="${spec#*:}"
    sips -z "${size}" "${size}" "${ICON_SRC}" --out "${ICONSET}/${name}.png" >/dev/null
  done
  iconutil -c icns "${ICONSET}" -o "${ICNS}"
  rm -rf "${ICONSET}"
  ICON_PLIST="  <key>CFBundleIconFile</key><string>TrndiMulti.icns</string>"
else
  echo "WARN: ${ICON_SRC} not found; bundle gets the generic icon" >&2
fi

# Unquoted heredoc: the identity, versions and ICON_PLIST expand.
cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${APP_ID}</string>
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
# Finder and the Dock cache a bundle's look by its modification time.
touch "${APP}"
