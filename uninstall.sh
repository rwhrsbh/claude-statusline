#!/usr/bin/env bash
# Removes the Claude Code statusline on Linux / macOS:
#
#   curl -fsSL https://raw.githubusercontent.com/rwhrsbh/claude-statusline/main/uninstall.sh | bash
#
# - "statusLine" in settings.json: if it is this statusline, it is removed and the
#   one that was there before the install is put back. If it is someone else's, you
#   are asked first (and it is left alone when there is no terminal to ask on).
# - statusline.sh / statusline.ps1 and statusline.prev.json are deleted; a
#   statusline script that the install had moved aside is put back.
# - settings.json.bak-statusline is left in place.
# On Windows (Git Bash) it hands over to uninstall.ps1.

# Everything is in main(), called on the last line, so a download that is cut off
# half way runs nothing.
main() {
  local base=https://raw.githubusercontent.com/rwhrsbh/claude-statusline/main
  local marker='Claude Code statusline \((PowerShell|bash)\): caveman badge'
  local self_dir=""
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  fi

  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      local ps=powershell
      command -v pwsh >/dev/null 2>&1 && ps=pwsh
      if [ -n "$self_dir" ] && [ -f "$self_dir/uninstall.ps1" ]; then
        exec "$ps" -NoProfile -ExecutionPolicy Bypass -File "$self_dir/uninstall.ps1"
      fi
      exec "$ps" -NoProfile -ExecutionPolicy Bypass -Command "irm $base/uninstall.ps1 | iex" ;;
  esac

  local cfg=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
  local settings=$cfg/settings.json target=$cfg/statusline.sh prev=$cfg/statusline.prev.json

  die() { echo "Uninstall failed: $*" >&2; exit 1; }

  # question -> 0 yes, 1 no, 2 nobody to ask. Asked on the terminal directly,
  # because under `curl | bash` stdin is the script itself.
  ask() {
    local a
    { : >/dev/tty; } 2>/dev/null || return 2
    printf '%s [y/N] ' "$1" >/dev/tty
    IFS= read -r a </dev/tty || return 2
    case $a in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
  }

  # Reads and edits "statusLine" in a settings file, with jq or node.
  #   ok F | has F | cmd F | del F | setraw F FILE_WITH_VALUE
  js() {
    if command -v jq >/dev/null 2>&1; then
      case $1 in
        ok)  jq -e 'type == "object"' "$2" >/dev/null 2>&1 ;;
        has) jq -e 'has("statusLine")' "$2" >/dev/null 2>&1 ;;
        cmd) jq -r '(.statusLine | objects | .command | strings) // empty' "$2" ;;
        del) jq 'del(.statusLine)' "$2" > "$2.tmp-statusline" &&
             cat "$2.tmp-statusline" > "$2" && rm -f "$2.tmp-statusline" ;;
        setraw) jq --slurpfile p "$3" '.statusLine = $p[0]' "$2" > "$2.tmp-statusline" &&
             cat "$2.tmp-statusline" > "$2" && rm -f "$2.tmp-statusline" ;;
      esac
    else
      node -e '
        const fs = require("fs"), [op, f, a] = process.argv.slice(1);
        let j; try { j = JSON.parse(fs.readFileSync(f, "utf8")) } catch { process.exit(1) }
        if (j === null || typeof j !== "object" || Array.isArray(j)) process.exit(1);
        const s = j.statusLine, save = () => fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
        if (op === "has") process.exit(s === undefined ? 1 : 0);
        else if (op === "cmd") process.stdout.write(s && typeof s.command === "string" ? s.command : "");
        else if (op === "del") { delete j.statusLine; save(); }
        else if (op === "setraw") {
          try { j.statusLine = JSON.parse(fs.readFileSync(a, "utf8")) } catch { process.exit(1) }
          save();
        }' "$@"
    fi
  }

  is_our_script() { [ -f "$1" ] && head -n 5 "$1" 2>/dev/null | grep -qE "$marker"; }
  # statusLine command -> 0 when it runs this statusline (installed copy or a clone)
  is_ours() {
    local p
    p=$(printf '%s' "$1" | sed -nE 's/.*"([^"]*statusline\.(sh|ps1))".*/\1/p')
    [ -n "$p" ] || p=$(printf '%s' "$1" | grep -oE '[^[:space:]"]*statusline\.(sh|ps1)' | head -n1)
    [ -n "$p" ] || return 1
    p=${p/#\~/$HOME}
    is_our_script "$p" && return 0
    [ "$p" = "$target" ] && [ ! -e "$p" ]
  }

  if [ -s "$settings" ]; then
    if ! command -v jq >/dev/null 2>&1 && ! command -v node >/dev/null 2>&1; then
      die "need jq or node to edit $settings. Install one, or delete the \"statusLine\" entry by hand. Nothing was changed."
    fi
    js ok "$settings" || die "$settings is not valid JSON. Nothing was changed."
    if ! js has "$settings"; then
      echo "No statusLine in $settings."
    else
      local cmd; cmd=$(js cmd "$settings")
      if is_ours "$cmd"; then
        if [ -s "$prev" ] && js setraw "$settings" "$prev"; then
          echo "statusLine restored to what it was before the install."
        else
          js del "$settings" || die "could not update $settings"
          echo "statusLine removed from $settings."
        fi
      else
        echo "The statusLine in $settings is not this statusline:"
        echo "  $cmd"
        ask "Remove it anyway?"
        case $? in
          0) js del "$settings" || die "could not update $settings"
             echo "statusLine removed from $settings." ;;
          2) echo "No terminal to ask on, so it was left as it is." ;;
          *) echo "Left as it is." ;;
        esac
      fi
    fi
  else
    echo "No $settings."
  fi

  local ext f
  for ext in sh ps1; do
    f=$cfg/statusline.$ext
    if is_our_script "$f"; then rm -f "$f"; echo "Deleted $f"; fi
    if [ -e "$f.bak-statusline" ] && [ ! -e "$f" ]; then
      mv "$f.bak-statusline" "$f"
      echo "Put back your own $f"
    fi
  done
  rm -f "$prev"
  [ -e "$settings.bak-statusline" ] && echo "Kept $settings.bak-statusline (settings from before the install)."
  echo "Restart Claude Code to apply."
}

main "$@"
