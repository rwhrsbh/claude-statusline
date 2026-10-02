#!/usr/bin/env bash
# Claude Code statusline (bash): caveman badge | model | ctx | cache timer | 5h | 7d
#
# Adapts to the terminal width: picks the richest layout that fits (see set_level).
# Needs jq or node to parse the JSON Claude Code sends on stdin.
# Options (all optional):
#   --width 80      fit into 80 columns     --width 60%   60% of the terminal width
#   --level N       force a layout (0 = richest .. 8 = most compact), no auto-fit
#   --ttl N         prompt-cache TTL in minutes (default: auto-detected, else 5)
#   --reserve N     columns kept free at the right edge (default 4)
#   --no-caveman    never show the caveman badge

WIDTH=""; LEVEL=-1; TTL_ARG=0; RESERVE=4; NOCAVE=0
while [ $# -gt 0 ]; do
  case $1 in
    --width)   WIDTH=$2; shift ;;
    --level)   LEVEL=$2; shift ;;
    --ttl)     TTL_ARG=$2; shift ;;
    --reserve) RESERVE=$2; shift ;;
    --no-caveman) NOCAVE=1 ;;
  esac
  shift
done

export LC_ALL=C
# Never block on stdin: skip it when it is the keyboard (reading would swallow the
# user's keystrokes), and give up after 2 s if the pipe is never closed.
input=""
[ -t 0 ] || IFS= read -r -d '' -t 2 input
esc=$'\033'

# ---------------------------------------------------------------- parse JSON
MODEL=""; CTX=""; TRANSCRIPT=""; H5=""; H5_LEFT=""; D7=""; D7_LEFT=""
if command -v jq >/dev/null 2>&1; then
  eval "$(printf '%s' "$input" | jq -r '
    def secs: if . == null then "" else (try (
        if type == "number" then (. - now | floor)
        else ((sub("\\.[0-9]+"; "") | fromdateiso8601) - now | floor) end) catch "") end;
    @sh "MODEL=\(.model.display_name // "")",
    @sh "CTX=\(.context_window.used_percentage // "")",
    @sh "TRANSCRIPT=\(.transcript_path // "")",
    @sh "H5=\(.rate_limits.five_hour.used_percentage // "")",
    @sh "H5_LEFT=\(.rate_limits.five_hour.resets_at | secs)",
    @sh "D7=\(.rate_limits.seven_day.used_percentage // "")",
    @sh "D7_LEFT=\(.rate_limits.seven_day.resets_at | secs)"' 2>/dev/null)"
elif command -v node >/dev/null 2>&1; then
  eval "$(printf '%s' "$input" | node -e '
    let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
      let j = {}; try { j = JSON.parse(s) } catch {}
      const q = v => "\x27" + String(v == null ? "" : v).replace(/\x27/g, "") + "\x27";
      const secs = t => { if (t == null) return "";
        const ms = typeof t === "number" ? t * 1000 : Date.parse(t);
        return isNaN(ms) ? "" : Math.round((ms - Date.now()) / 1000); };
      const rl = j.rate_limits || {}, f = rl.five_hour || {}, w = rl.seven_day || {};
      console.log("MODEL=" + q((j.model || {}).display_name));
      console.log("CTX=" + q((j.context_window || {}).used_percentage));
      console.log("TRANSCRIPT=" + q(j.transcript_path));
      console.log("H5=" + q(f.used_percentage) + "; H5_LEFT=" + q(secs(f.resets_at)));
      console.log("D7=" + q(w.used_percentage) + "; D7_LEFT=" + q(secs(w.resets_at)));
    })')"
fi

# ---------------------------------------------------------------- helpers
pct_int() { printf '%.0f' "${1:-0}" 2>/dev/null || echo 0; }
pct_color() { local p; p=$(pct_int "$1"); if [ "$p" -ge 80 ]; then echo 196; elif [ "$p" -ge 50 ]; then echo 214; else echo 78; fi; }
bar() { # pct width
  local n i out="" p; p=$(pct_int "$1"); n=$(( (p * $2 + 50) / 100 ))
  [ "$n" -gt "$2" ] && n=$2; [ "$n" -lt 0 ] && n=0
  for ((i = 0; i < $2; i++)); do if [ $i -lt $n ]; then out+="█"; else out+="░"; fi; done
  printf '%s' "$out"
}
left() { # seconds -> 3d2h / 3h05m / 12m
  local s=$1
  [ -z "$s" ] && return
  [ "$s" -le 0 ] 2>/dev/null && return
  if   [ "$s" -ge 86400 ]; then printf '%dd%dh' $((s / 86400)) $((s % 86400 / 3600))
  elif [ "$s" -ge 3600 ];  then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  else printf '%dm' $(( (s + 59) / 60 )); fi
}
paint() { printf '%s[38;5;%sm%s%s[0m' "$esc" "$1" "$2" "$esc"; }
seg() { # label pct left_secs
  local body="$1 " l
  [ "$BAR" -gt 0 ] && body+="$(bar "$2" "$BAR") "
  body+="$(pct_int "$2")%"
  if [ "$RESET" = 1 ]; then l=$(left "$3"); [ -n "$l" ] && body+=" ↻$l"; fi
  paint "$(pct_color "$2")" "$body"
}
# visible width: bytes minus 2 per 3-byte glyph (█ ░ │ ↻ ◷ all start with 0xE2)
vislen() {
  local plain bytes wide
  plain=$(printf '%s' "$1" | sed "s/${esc}\[[0-9;]*m//g")
  bytes=${#plain}   # LC_ALL=C -> byte count
  wide=$(printf '%s' "$plain" | tr -cd '\342' | wc -c)
  echo $(( bytes - 2 * wide ))
}

# prompt-cache TTL: --ttl > $CLAUDE_CACHE_TTL_MIN > detected from the transcript
# (non-zero ephemeral_1h_* = 60 min, ephemeral_5m_* = 5 min) > 5
detect_ttl() {
  [ "$TTL_ARG" -gt 0 ] 2>/dev/null && { echo "$TTL_ARG"; return; }
  [[ $CLAUDE_CACHE_TTL_MIN =~ ^[0-9]+$ ]] && { echo "$CLAUDE_CACHE_TTL_MIN"; return; }
  local m; m=$(tail -c 400000 "$1" 2>/dev/null | grep -aoE '"ephemeral_(1h|5m)_input_tokens":[1-9]' | tail -n1)
  case $m in *1h*) echo 60 ;; *) echo 5 ;; esac
}

CACHE_TXT=""; CACHE_COL=78
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  ttl=$(detect_ttl "$TRANSCRIPT")
  mtime=$(stat -c %Y "$TRANSCRIPT" 2>/dev/null || stat -f %m "$TRANSCRIPT" 2>/dev/null)
  if [ -n "$mtime" ]; then
    rem=$(( ttl * 60 - ($(date +%s) - mtime) ))
    if [ "$rem" -le 0 ]; then CACHE_COL=240; CACHE_TXT=cold
    else
      if   [ "$rem" -le 60 ]; then CACHE_COL=196
      elif [ "$rem" -le $(( ttl * 12 )) ]; then CACHE_COL=214   # <= 20% of TTL
      fi
      CACHE_TXT="$(( (rem + 59) / 60 ))m"
    fi
  fi
fi

# caveman badge: shown only when the caveman plugin is installed and active
# (its flag file exists). Skipped silently otherwise.
CAVE=""
if [ "$NOCAVE" = 0 ]; then
  cdir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}; flag=$cdir/.caveman-active
  if [ -f "$flag" ] && [ ! -L "$flag" ] && [ "$(wc -c < "$flag")" -le 64 ]; then
    m=$(head -n1 "$flag" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')
    case $m in lite|full|ultra|wenyan|wenyan-lite|wenyan-full|wenyan-ultra|commit|review|compress) CAVE=$m ;; esac
  fi
fi

short_model() { # "Sonnet 5.5" -> "S5.5"
  local n=${1#Claude } v
  v=$(printf '%s' "$n" | grep -oE '[0-9]+(\.[0-9]+)*' | head -n1)
  [ ${#v} -gt 3 ] && v=${v: -3}
  printf '%s%s' "${n:0:1}" "$v"
}

# ---------------------------------------------------------------- layouts
# BAR = bar width (0 = percent only), RESET = show "↻time", MODEL_M / CAVE_M = full|short|none, SHOW7
set_level() {
  case $1 in
    0) BAR=10 RESET=1 MODEL_M=full  CAVE_M=full  SHOW7=1 ;;
    1) BAR=10 RESET=0 MODEL_M=full  CAVE_M=full  SHOW7=1 ;;
    2) BAR=5  RESET=0 MODEL_M=full  CAVE_M=full  SHOW7=1 ;;
    3) BAR=0  RESET=0 MODEL_M=full  CAVE_M=full  SHOW7=1 ;;
    4) BAR=0  RESET=0 MODEL_M=short CAVE_M=full  SHOW7=1 ;;
    5) BAR=0  RESET=0 MODEL_M=short CAVE_M=short SHOW7=1 ;;
    6) BAR=0  RESET=0 MODEL_M=none  CAVE_M=short SHOW7=1 ;;
    7) BAR=0  RESET=0 MODEL_M=none  CAVE_M=none  SHOW7=1 ;;
    *) BAR=0  RESET=0 MODEL_M=none  CAVE_M=none  SHOW7=0 ;;
  esac
}
LAST=8

render() {
  local parts=() s out="" p
  if [ -n "$CAVE" ] && [ "$CAVE_M" != none ]; then
    if [ "$CAVE_M" = short ]; then
      if [ "$CAVE" = full ]; then s=C
      else s="C:$(printf '%s' "$CAVE" | tr '-' '\n' | cut -c1 | tr -d '\n' | tr 'a-z' 'A-Z')"; fi
    else
      if [ "$CAVE" = full ]; then s=CAVEMAN; else s="CAVEMAN:$(printf '%s' "$CAVE" | tr 'a-z' 'A-Z')"; fi
    fi
    parts+=("$(paint 172 "[$s]")")
  fi
  if [ -n "$MODEL" ] && [ "$MODEL_M" != none ]; then
    if [ "$MODEL_M" = short ]; then s=$(short_model "$MODEL"); else s=$MODEL; fi
    parts+=("$(paint 110 "$s")")
  fi
  [ -n "$CTX" ] && parts+=("$(seg ctx "$CTX" "")")
  [ -n "$CACHE_TXT" ] && parts+=("$(paint "$CACHE_COL" "◷ $CACHE_TXT")")
  [ -n "$H5" ] && parts+=("$(seg 5h "$H5" "$H5_LEFT")")
  [ "$SHOW7" = 1 ] && [ -n "$D7" ] && parts+=("$(seg 7d "$D7" "$D7_LEFT")")
  for p in "${parts[@]}"; do out+="${out:+ │ }$p"; done
  printf '%s' "$out"
}

# ---------------------------------------------------------------- fit
cols=0
[[ $COLUMNS =~ ^[0-9]+$ ]] && cols=$COLUMNS
[ "$cols" -le 0 ] && cols=$(tput cols 2>/dev/null </dev/tty || echo 0)
[[ $cols =~ ^[0-9]+$ ]] || cols=0

avail=0
if [[ $WIDTH =~ ^([0-9]+)%$ ]]; then
  base=$cols; [ "$base" -le 0 ] && base=120
  avail=$(( base * BASH_REMATCH[1] / 100 ))
elif [[ $WIDTH =~ ^[0-9]+$ ]]; then
  avail=$WIDTH
elif [ "$cols" -gt 0 ]; then
  avail=$(( cols - RESERVE ))
fi

if [ "$LEVEL" -ge 0 ] 2>/dev/null; then
  lv=$LEVEL; [ "$lv" -gt "$LAST" ] && lv=$LAST
  set_level "$lv"; out=$(render)
else
  lv=0; set_level 0; out=$(render)
  if [ "$avail" -gt 0 ]; then
    while [ "$lv" -lt "$LAST" ] && [ "$(vislen "$out")" -gt "$avail" ]; do
      lv=$((lv + 1)); set_level "$lv"; out=$(render)
    done
  fi
fi
printf '%s' "$out"
