#!/bin/bash
# Builds build/Skener.app (needs Xcode or the Command Line Tools).
#   VERSION=0.4.0 ./scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Skener
BIN="$(swift build -c release --show-bin-path)/Skener"

APP="build/Skener.app"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/Skener"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
cp Resources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP}/Contents/Info.plist"
fi

# Ad-hoc signature: enough to run on your own Mac.
codesign --force --sign - "${APP}"
touch "${APP}"

echo "Built $(pwd)/${APP}"
