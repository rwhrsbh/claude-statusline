#!/usr/bin/env bash
# Installs the Claude Code statusline on Linux / macOS. No clone needed:
#
#   curl -fsSL https://raw.githubusercontent.com/rwhrsbh/claude-statusline/main/install.sh | bash
#
# Puts statusline.sh into the Claude config folder (~/.claude, or $CLAUDE_CONFIG_DIR)
# and points "statusLine" in settings.json at it. Running it again updates the script.
# On Windows (Git Bash) it hands over to install.ps1, which installs the PowerShell version.
# Whatever it replaces is kept so that uninstall.sh can put it back:
#   settings.json.bak-statusline   full copy of settings.json from before the install
#   statusline.prev.json           the previous "statusLine" value
#   statusline.sh.bak-statusline   a different statusline.sh that was already there
#
# The script needs jq or node to read JSON. If neither is installed it offers to
# install jq (and installs it without asking when there is no terminal to ask on).

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
      if [ -n "$self_dir" ] && [ -f "$self_dir/install.ps1" ]; then
        exec "$ps" -NoProfile -ExecutionPolicy Bypass -File "$self_dir/install.ps1"
      fi
      exec "$ps" -NoProfile -ExecutionPolicy Bypass -Command "irm $base/install.ps1 | iex" ;;
  esac

  local cfg=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
  local settings=$cfg/settings.json target=$cfg/statusline.sh prev=$cfg/statusline.prev.json

  die() { echo "Install failed: $*" >&2; exit 1; }

  # question -> 0 yes, 1 no, 2 nobody to ask. Asked on the terminal directly,
  # because under `curl | bash` stdin is the script itself.
  ask() {
    local a
    { : >/dev/tty; } 2>/dev/null || return 2
    printf '%s [y/N] ' "$1" >/dev/tty
    IFS= read -r a </dev/tty || return 2
    case $a in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
  }

  # $1 = 1 when there is a terminal, so sudo may ask for a password.
  install_jq() {
    local pm s=""
    for pm in apt-get dnf yum pacman zypper apk brew none; do
      command -v "$pm" >/dev/null 2>&1 && break
    done
    [ "$pm" = none ] && return 1
    if [ "$pm" != brew ] && [ "$(id -u)" != 0 ]; then
      command -v sudo >/dev/null 2>&1 || return 1
      if [ "$1" = 1 ]; then s="sudo"; else s="sudo -n"; fi
    fi
    case $pm in
      brew)    brew install jq ;;
      apt-get) $s apt-get install -y jq || { $s apt-get update && $s apt-get install -y jq; } ;;
      dnf|yum) $s "$pm" install -y jq ;;
      pacman)  $s pacman -S --noconfirm --needed jq ;;
      zypper)  $s zypper --non-interactive install jq ;;
      apk)     $s apk add jq ;;
    esac
    command -v jq >/dev/null 2>&1
  }

  # Reads and edits "statusLine" in a settings file, with jq or node.
  #   ok F | has F | cmd F | raw F | set F COMMAND
  js() {
    if command -v jq >/dev/null 2>&1; then
      case $1 in
        ok)  jq -e 'type == "object"' "$2" >/dev/null 2>&1 ;;
        has) jq -e 'has("statusLine")' "$2" >/dev/null 2>&1 ;;
        cmd) jq -r '(.statusLine | objects | .command | strings) // empty' "$2" ;;
        raw) jq '.statusLine' "$2" ;;
        set) jq --arg c "$3" '.statusLine = {type: "command", command: $c, refreshInterval: 30}' "$2" > "$2.tmp-statusline" &&
             cat "$2.tmp-statusline" > "$2" && rm -f "$2.tmp-statusline" ;;
      esac
    else
      node -e '
        const fs = require("fs"), [op, f, a] = process.argv.slice(1);
        let j; try { j = JSON.parse(fs.readFileSync(f, "utf8")) } catch { process.exit(1) }
        if (j === null || typeof j !== "object" || Array.isArray(j)) process.exit(1);
        const s = j.statusLine;
        if (op === "has") process.exit(s === undefined ? 1 : 0);
        else if (op === "cmd") process.stdout.write(s && typeof s.command === "string" ? s.command : "");
        else if (op === "raw") process.stdout.write(JSON.stringify(s, null, 2) + "\n");
        else if (op === "set") {
          j.statusLine = { type: "command", command: a, refreshInterval: 30 };
          fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
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

  # ---- dependencies: jq or node. Nothing has been changed up to here.
  if ! command -v jq >/dev/null 2>&1 && ! command -v node >/dev/null 2>&1; then
    echo "The statusline needs jq or node to read JSON, and neither is installed."
    ask "Install jq now?"
    case $? in
      0) install_jq 1 || die "could not install jq (no supported package manager, or the install failed). Install jq (https://jqlang.org/download/) and run this again. Nothing was changed." ;;
      2) echo "No terminal to ask on, installing jq."
         install_jq 0 || die "could not install jq (no supported package manager, or sudo needs a password). Install jq (https://jqlang.org/download/) and run this again. Nothing was changed." ;;
      *) echo "Nothing was changed. Install jq or node, then run this again."; exit 1 ;;
    esac
  fi

  mkdir -p "$cfg" || die "cannot create $cfg"

  # ---- look at settings.json before changing anything
  local has=0 ours=0 current=""
  if [ -s "$settings" ]; then
    js ok "$settings" || die "$settings is not valid JSON. Nothing was changed."
    js has "$settings" && has=1
    current=$(js cmd "$settings")
    is_ours "$current" && ours=1
  fi

  # ---- the script: from this folder when run from a clone, otherwise downloaded
  local tmp=$target.tmp-statusline
  if [ -n "$self_dir" ] && [ -f "$self_dir/statusline.sh" ]; then
    if [ "$self_dir/statusline.sh" -ef "$target" ]; then tmp=""; else cp "$self_dir/statusline.sh" "$tmp" || die "cannot write $tmp"; fi
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$base/statusline.sh" -o "$tmp" || die "download failed. Nothing was changed."
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$base/statusline.sh" || die "download failed. Nothing was changed."
  else
    die "need curl or wget. Nothing was changed."
  fi
  if [ -n "$tmp" ]; then
    is_our_script "$tmp" || { rm -f "$tmp"; die "downloaded file is not the statusline script. Nothing was changed."; }
    if [ -e "$target" ] && ! is_our_script "$target"; then
      mv -f "$target" "$target.bak-statusline"
      echo "Existing statusline.sh was not ours; kept as $target.bak-statusline"
    fi
    mv -f "$tmp" "$target" || die "cannot write $target"
  fi
  chmod +x "$target" 2>/dev/null

  # ---- remember what is being replaced, unless it is already this statusline
  if [ "$ours" = 0 ]; then
    [ -s "$settings" ] && cp -p "$settings" "$settings.bak-statusline"
    if [ "$has" = 1 ]; then
      js raw "$settings" > "$prev"
      echo "Replaced an existing statusLine; uninstall will restore it."
    else
      rm -f "$prev"
    fi
  fi

  echo "Statusline installed: $target"
  # An update leaves an existing entry alone, so options added to it by hand survive.
  if [ "$ours" = 1 ] && [ "${current#*"$target"}" != "$current" ]; then
    echo "statusLine in $settings already runs it; left as it is."
  else
    [ -s "$settings" ] || echo '{}' > "$settings"
    local cmd="bash \"$target\""
    js set "$settings" "$cmd" || die "could not update $settings"
    echo "statusLine set in $settings"
    echo "  $cmd"
  fi
  echo "Restart Claude Code to apply."
}

main "$@"
