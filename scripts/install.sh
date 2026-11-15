#!/bin/bash
# Builds Kerf in Release, installs it in /Applications and starts it. Waits for a running copy
# to quit first, so the old one can't take the new one's socket with it. Arguments go to
# xcodebuild, such as DEVELOPMENT_TEAM=<your team ID>. The app remembers this folder: Kerf looks
# for updates in it, and its Update button runs this script again.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Kerf.xcodeproj -scheme Kerf -configuration Release -derivedDataPath build/DerivedData build KERF_SOURCE="$PWD" "$@" | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
# SIGTERM: Kerf stops as on Quit, and it needs no Apple Events permission when Kerf's own Update
# button runs this script.
pkill -TERM -f "/Applications/Kerf.app/Contents/MacOS/Kerf$" 2>/dev/null || true
for _ in $(seq 1 50); do
    pgrep -f "/Applications/Kerf.app/Contents/MacOS/Kerf$" >/dev/null || break
    sleep 0.2
done
pkill -f "/Applications/Kerf.app/Contents/MacOS/Kerf$" 2>/dev/null || true
rm -rf /Applications/Kerf.app
cp -R build/DerivedData/Build/Products/Release/Kerf.app /Applications/Kerf.app
open /Applications/Kerf.app
echo "Installed and started /Applications/Kerf.app."
