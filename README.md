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

One line, pasted into a terminal. Nothing to clone.

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/rwhrsbh/claude-statusline/main/install.ps1 | iex
```

Linux / macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/rwhrsbh/claude-statusline/main/install.sh | bash
```

Then restart Claude Code. To update, run the same line again: it replaces the script and leaves your
`statusLine` entry as it is.

What the installer does:

- Downloads one file, `statusline.ps1` (Windows) or `statusline.sh` (Linux / macOS), into `~/.claude`
  (or `$CLAUDE_CONFIG_DIR`).
- Sets `statusLine` in `settings.json` to run it, with `refreshInterval: 30` so the cache timer keeps
  ticking while you are idle. Only that entry is changed.
- Keeps whatever it replaces, so the uninstaller can put it back:
  - `settings.json.bak-statusline`: a full copy of `settings.json` from before the install
  - `statusline.prev.json`: the `statusLine` you had before
  - `statusline.ps1.bak-statusline` / `statusline.sh.bak-statusline`: a different script of the same
    name that was already there
- On Windows the PowerShell version is always installed, even if you run the `curl … | bash` line from Git Bash.
- On Linux / macOS the script needs `jq` or `node`. If neither is installed, the installer says so and
  offers to install `jq` with your package manager (`apt-get`, `dnf`, `yum`, `pacman`, `zypper`, `apk`
  or `brew`). If you decline, nothing is changed. When there is no terminal to ask on (CI, a Docker build),
  it installs `jq` without asking, and stops without changing anything if that needs a `sudo` password.

## Uninstall

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/rwhrsbh/claude-statusline/main/uninstall.ps1 | iex
```

Linux / macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/rwhrsbh/claude-statusline/main/uninstall.sh | bash
```

- If `statusLine` is this statusline, it is removed and the one you had before the install is restored.
- If `statusLine` is something else, the uninstaller tells you and asks before removing it. With no
  terminal to ask on, it leaves it alone.
- The statusline script and `statusline.prev.json` are deleted; a script that the installer moved aside is
  put back. `settings.json.bak-statusline` is kept.

## From a clone

```bash
git clone https://github.com/rwhrsbh/claude-statusline
```

Running `.\install.ps1` or `./install.sh` from the clone installs the copy in that folder instead of
downloading it, which is the way to try local changes.

## Manual setup

Put `statusline.ps1` or `statusline.sh` anywhere and add this to `settings.json`:

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
so 30 s loses nothing. The installer picks `pwsh` when it is installed.

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

The installer sets none: the line already fits itself to the terminal width. To use one, add it after the
script path in the `command` in `settings.json`. Updating keeps your edited `command`.

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
