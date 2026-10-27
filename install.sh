#!/bin/bash
# Build, then install into ~/Applications so it starts without a terminal.
# Re-run after changing code to upgrade.
set -euo pipefail
cd "$(dirname "$0")"

./app/build.sh

DEST="$HOME/Applications/Pelican.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "app/PelicanFloat.app" "$DEST"

# Show up in Spotlight and Launchpad right away, no wait for a scan
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$DEST" || true

# Replace the running old process, or the new code never gets on screen
pkill -x PelicanFloat 2>/dev/null && sleep 1 || true
open "$DEST"

echo "已装好并重启：现在跑的就是刚编出来的这版。"
echo "以后再开：双击它，或按住 ⌘ 空格搜 Pelican。"
