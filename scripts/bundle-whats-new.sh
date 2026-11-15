#!/bin/bash
# Copies the notes in WhatsNew/ into the app, for the What's New window.
set -euo pipefail
OUT="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/WhatsNew"
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$SRCROOT"/WhatsNew/*.json "$OUT/"
