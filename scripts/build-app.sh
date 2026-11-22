#!/bin/bash
# Sestaví Skener.app do složky build/ (stačí Xcode nebo Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Skener
BIN="$(swift build -c release --show-bin-path)/Skener"

APP="build/Skener.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Skener"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Podpis „ad-hoc“ – stačí pro spuštění na vlastním Macu.
codesign --force --sign - "$APP"
# Ať Finder a Dock hned ukážou novou ikonu.
touch "$APP"

echo ""
echo "Hotovo: $(pwd)/$APP"
echo "Spustíte: open \"$APP\"   (nebo ji přetáhněte do Aplikací)"
