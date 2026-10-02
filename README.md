# claude-statusline

A Claude Code statusline that shows, in one line:

```
[CAVEMAN:ULTRA] │ Sonnet 5.5 │ ctx ████░░░░░░ 42% │ ◷ 60m │ 5h ██████░░░░ 63% ↻2h04m │ 7d ██░░░░░░░░ 18% ↻3d20h
```

- `ctx` – context window usage
- `◷ 60m` – minutes left in the prompt cache (counts down while idle, `cold` when expired).
  The TTL (5 or 60 min) is detected automatically from the session transcript.
- `5h` / `7d` – subscription rate limits with time until reset (only shown if Claude Code provides them)
- `[CAVEMAN:…]` – only if the [caveman](https://github.com/JuliusBrussee/caveman) plugin is installed and active; silently skipped otherwise

Two equivalent implementations: `statusline.ps1` (Windows PowerShell 5.1+/7) and `statusline.sh` (bash + `jq` or `node`).

## Install

One line, pasted into a terminal (needs `git`).

Windows (PowerShell):

```powershell
git clone https://github.com/rwhrsbh/claude-statusline "$HOME\.claude\claude-statusline"; powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.claude\claude-statusline\install.ps1"
```

Linux / macOS / Git Bash:

```bash
git clone https://github.com/rwhrsbh/claude-statusline ~/.claude/claude-statusline && bash ~/.claude/claude-statusline/install.sh
```

To update later: `git -C ~/.claude/claude-statusline pull`.

From an existing clone, run `.\install.ps1` (Windows) or `./install.sh` (Linux / macOS / Git Bash) in its folder.

This sets `statusLine` in `~/.claude/settings.json` (backup: `settings.json.bak-statusline`) with `refreshInterval: 30`,
so the cache timer keeps ticking while you are idle. Restart Claude Code afterwards.

Manual setup:

```json
"statusLine": {
  "type": "command",
  "command": "pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"C:\\path\\to\\statusline.ps1\"",
  "refreshInterval": 30
}
```

Keep `refreshInterval` well above the time one run takes. Every refresh starts a new shell:
about 0.7 s with PowerShell 7 (`pwsh`), about 1.5 s with Windows PowerShell 5.1 (`powershell`).
A 5 s interval keeps a PowerShell process running most of the time in every open session, which
is enough to make Claude Code stutter or freeze on a busy machine. The timer shows whole minutes,
so 30 s loses nothing. `install.ps1` picks `pwsh` when it is installed.

## Adapts to width

The line is fitted to the terminal width (`$COLUMNS`). When it does not fit, the layout degrades step by step:

| Level | Change |
|-------|--------|
| 0 | full: 10-cell bars + reset times |
| 1 | drop reset times |
| 2 | 5-cell bars |
| 3 | percent only (no bars) |
| 4 | model shortened: `Sonnet 5.5` → `S5.5` |
| 5 | caveman badge shortened: `[C:U]` |
| 6 | drop model |
| 7 | drop caveman badge |
| 8 | drop `7d` |

## Options

Pass them after the script path in the `command`.

| PowerShell | bash | |
|------------|------|-|
| `-Width 80` / `-Width 60%` | `--width 80` / `--width 60%` | fit into N columns, or a percentage of the terminal width |
| `-Level N` | `--level N` | force a layout (0–8), no auto-fit |
| `-Ttl N` | `--ttl N` | prompt-cache TTL in minutes (also `CLAUDE_CACHE_TTL_MIN`) |
| `-Reserve N` | `--reserve N` | columns kept free at the right edge (default 4) |
| `-NoCaveman` | `--no-caveman` | never show the caveman badge |

`CLAUDE_CONFIG_DIR` is respected.

## Notes

- The cache countdown is `TTL − time since the transcript was last written`; each API request refreshes the cache, so it is an approximation.
- `statusline.ps1` is kept pure ASCII (glyphs are written as code points), so it works with or without a BOM.
- Neither script can block Claude Code: stdin is skipped when it is a terminal and abandoned if it is
  never closed, and `statusline.ps1` kills itself after 4 s if anything stalls. It also leaves the
  console code page untouched.
