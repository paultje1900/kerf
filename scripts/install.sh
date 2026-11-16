#!/bin/bash
# Builds Kerf in Release, installs it and starts it. Waits for a running copy to quit first, so
# the old one can't take the new one's socket with it. Arguments go to xcodebuild, such as
# DEVELOPMENT_TEAM=<your team ID>. The app remembers this folder: Kerf looks for updates in it,
# and its Update button runs this script again.
#
# Without admin rights it installs in ~/Applications instead of /Applications. Without an Apple
# Development certificate it signs ad hoc, which runs fine on this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -w /Applications ]; then folder=/Applications; else folder="$HOME/Applications"; fi
target="$folder/Kerf.app"
signing=()
if [[ " $* " != *" DEVELOPMENT_TEAM="* && " $* " != *" CODE_SIGN_IDENTITY="* ]] \
    && ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
    echo "No Apple Development certificate: signing ad hoc."
    signing=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi
xcodebuild -project Kerf.xcodeproj -scheme Kerf -configuration Release -derivedDataPath build/DerivedData build \
    KERF_SOURCE="$PWD" ${signing[@]+"${signing[@]}"} "$@" | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
# SIGTERM: Kerf stops as on Quit, and it needs no Apple Events permission when Kerf's own Update
# button runs this script. The pattern finds a copy in either Applications folder.
pkill -TERM -f "/Applications/Kerf.app/Contents/MacOS/Kerf$" 2>/dev/null || true
for _ in $(seq 1 50); do
    pgrep -f "/Applications/Kerf.app/Contents/MacOS/Kerf$" >/dev/null || break
    sleep 0.2
done
pkill -f "/Applications/Kerf.app/Contents/MacOS/Kerf$" 2>/dev/null || true
mkdir -p "$folder"
rm -rf "$target"
cp -R build/DerivedData/Build/Products/Release/Kerf.app "$target"
open "$target"
echo "Installed and started $target."
