#!/usr/bin/env bash
# Points Claude Code's statusLine at statusline.sh in this folder (Linux / macOS / Git Bash).
# Usage: ./install.sh [script args, e.g. --width 100]
# Needs jq or node. Backs up settings.json to settings.json.bak-statusline first.
set -e
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cfg=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
settings=$cfg/settings.json
cmd="bash \"$dir/statusline.sh\""
[ $# -gt 0 ] && cmd+=" $*"

mkdir -p "$cfg"
if [ -f "$settings" ]; then cp "$settings" "$settings.bak-statusline"; else echo '{}' > "$settings"; fi

if command -v jq >/dev/null 2>&1; then
  tmp=$(mktemp)
  jq --arg c "$cmd" '.statusLine = {type: "command", command: $c, refreshInterval: 30}' "$settings" > "$tmp"
  mv "$tmp" "$settings"
elif command -v node >/dev/null 2>&1; then
  node -e '
    const fs = require("fs"), [p, c] = process.argv.slice(1);
    const j = JSON.parse(fs.readFileSync(p, "utf8") || "{}");
    j.statusLine = { type: "command", command: c, refreshInterval: 30 };
    fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");' "$settings" "$cmd"
else
  echo "need jq or node" >&2; exit 1
fi
echo "statusLine set in $settings"
echo "  $cmd"
echo "Restart Claude Code to apply."
