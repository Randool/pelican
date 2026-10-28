#!/bin/bash
# Compile and assemble PelicanFloat.app (system AppKit / WebKit / SQLite only)
set -euo pipefail
cd "$(dirname "$0")"

APP="PelicanFloat.app"
BIN="$APP/Contents/MacOS/PelicanFloat"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# One module: every file under Sources is compiled together, main.swift is
# the only one with top-level code.
swiftc -O -swift-version 5 \
  -framework Cocoa -framework WebKit -lsqlite3 \
  Sources/*.swift -o "$BIN"

cp Info.plist "$APP/Contents/Info.plist"
cp pelican.html "$APP/Contents/Resources/pelican.html"
cp Pelican.icns "$APP/Contents/Resources/Pelican.icns"
# Optional: extra agent dirs to watch, from a list kept out of the repo
[ -f agents.txt ] && cp agents.txt "$APP/Contents/Resources/agents.txt"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "已生成 $(pwd)/$APP"
