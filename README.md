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

Windows: `.\install.ps1`  
Linux / macOS / Git Bash: `./install.sh`

This sets `statusLine` in `~/.claude/settings.json` (backup: `settings.json.bak-statusline`) with `refreshInterval: 5`,
so the cache timer keeps ticking while you are idle. Restart Claude Code afterwards.

Manual setup:

```json
"statusLine": {
  "type": "command",
  "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\statusline.ps1\"",
  "refreshInterval": 5
}
```

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
- `.ps1` must stay UTF-8 **with BOM**, otherwise Windows PowerShell 5.1 garbles `█ ░ │ ↻ ◷`.
