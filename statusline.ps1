# Claude Code statusline (PowerShell): caveman badge | model | ctx | cache timer | 5h | 7d
#
# Adapts to the terminal width: picks the richest layout that fits (see $Levels).
# Options (all optional):
#   -Width 80      fit into 80 columns      -Width 60%   60% of the terminal width
#   -Level N       force a layout (0 = richest .. 8 = most compact), no auto-fit
#   -Ttl N         prompt-cache TTL in minutes (default: auto-detected, else 5)
#   -Reserve N     columns kept free at the right edge (default 4)
#   -NoCaveman     never show the caveman badge
#
# This runs every few seconds next to a live TUI, so it must be cheap and must never
# block: no cmdlets that pull in extra modules (ConvertFrom-Json alone costs ~400 ms
# in Windows PowerShell 5.1), no changes to the shared console's code page, and a
# hard watchdog that kills the process if anything stalls.
param(
    [string]$Width = '',
    [int]$Level = -1,
    [int]$Ttl = 0,
    [int]$Reserve = 4,
    [switch]$NoCaveman
)

# Watchdog: runs on a timer thread, so it fires even if the script is stuck in a
# blocking call (stdin that never closes, a stalled disk or network path).
try {
    $watchdog = [Threading.CancellationTokenSource]::new(4000)
    [void]$watchdog.Token.Register([Action][Delegate]::CreateDelegate([Action], [Diagnostics.Process]::GetCurrentProcess(), 'Kill'))
} catch {}

$Esc = [char]27
# Glyphs by code point, so the file stays ASCII and does not depend on a BOM.
$GFull = [string][char]0x2588; $GEmpty = [string][char]0x2591; $GSep = [string][char]0x2502
$GReset = [string][char]0x21BB; $GClock = [string][char]0x25F7
$Inv = [Globalization.CultureInfo]::InvariantCulture

# Stdin is read as raw bytes: setting [Console]::InputEncoding would change the code
# page of the console shared with Claude Code. If stdin is the keyboard, reading it
# would swallow the user's keystrokes, so it is skipped.
$raw = ''
if ([Console]::IsInputRedirected) {
    try {
        $stdin = [Console]::OpenStandardInput()
        $ms = [IO.MemoryStream]::new()
        $copy = $stdin.CopyToAsync($ms)
        if (-not $copy.Wait(1500)) { exit 0 }
        $raw = [Text.Encoding]::UTF8.GetString($ms.ToArray()).TrimStart([char]0xFEFF)
    } catch { $raw = '' }
}

# ---------------------------------------------------------------- JSON
# Only a handful of fields are needed, so they are pulled out with regexes instead
# of a full parse.
$JStr = '"(?:[^"\\]|\\.)*"'
function Obj($s, $key) {   # text of the object stored under "key" ('' if absent)
    $m = [regex]::Match($s, '"' + $key + '"\s*:\s*(\{(?>' + $JStr + '|[^{}"]+|(?<o>\{)|(?<-o>\}))*(?(o)(?!))\})')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}
function Num($s, $key) {   # number stored under "key" ($null if absent or null)
    $m = [regex]::Match($s, '"' + $key + '"\s*:\s*(-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)')
    if ($m.Success) { return [double]::Parse($m.Groups[1].Value, $Inv) }
    return $null
}
function Txt($s, $key) {   # string stored under "key" ('' if absent)
    $m = [regex]::Match($s, '"' + $key + '"\s*:\s*"((?:[^"\\]|\\.)*)"')
    if (-not $m.Success) { return '' }
    try { return [regex]::Unescape($m.Groups[1].Value) } catch { return $m.Groups[1].Value }
}
function ResetAt($s) {     # "resets_at": epoch number or ISO string
    $t = Txt $s 'resets_at'
    if ($t) { return $t }
    return Num $s 'resets_at'
}

# ---------------------------------------------------------------- helpers
function Paint($c, $t) { return "$Esc[38;5;${c}m$t$Esc[0m" }
function PctColor($p) { if ($p -ge 80) { 196 } elseif ($p -ge 50) { 214 } else { 78 } }
function Bar($pct, $w) {
    $n = [math]::Max(0, [math]::Min($w, [int][math]::Round($pct / 100 * $w)))
    return ($GFull * $n) + ($GEmpty * ($w - $n))
}
function Left($v) {
    if ($null -eq $v -or $v -eq '') { return '' }
    try {
        if ($v -is [string]) { $t = [DateTimeOffset]::Parse($v, $Inv) }
        elseif ($v -gt 1e11) { $t = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$v) }
        else { $t = [DateTimeOffset]::FromUnixTimeSeconds([long]$v) }
        $d = $t - [DateTimeOffset]::Now
    } catch { return '' }
    if ($d.TotalSeconds -le 0) { return '' }
    if ($d.TotalHours -ge 24) { return ('{0}d{1}h' -f [int]$d.Days, $d.Hours) }
    if ($d.TotalHours -ge 1) { return ('{0}h{1:00}m' -f [int][math]::Floor($d.TotalHours), $d.Minutes) }
    return ('{0}m' -f [int][math]::Ceiling($d.TotalMinutes))
}
function Seg($label, $pct, $reset, $o) {
    $body = "$label "
    if ($o.bar -gt 0) { $body += (Bar $pct $o.bar) + ' ' }
    $body += "$([int][math]::Round($pct))%"
    if ($o.reset) { $l = Left $reset; if ($l) { $body += " $GReset$l" } }
    return Paint (PctColor $pct) $body
}
function VisLen($s) { return ($s -replace "$Esc\[[0-9;]*m", '').Length }

# Prompt-cache TTL: -Ttl > $env:CLAUDE_CACHE_TTL_MIN > detected from the transcript
# (a non-zero ephemeral_1h_* means 60 min, ephemeral_5m_* means 5 min) > 5.
function Get-Ttl($path) {
    if ($Ttl -gt 0) { return $Ttl }
    if ($env:CLAUDE_CACHE_TTL_MIN -match '^\d+$') { return [int]$env:CLAUDE_CACHE_TTL_MIN }
    try {
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete')
        try {
            $n = [int][math]::Min($fs.Length, 400000)
            if ($n -gt 0) {
                [void]$fs.Seek(-$n, [IO.SeekOrigin]::End)
                $buf = [byte[]]::new($n)
                $r = $fs.Read($buf, 0, $n)
                $s = [Text.Encoding]::GetEncoding(28591).GetString($buf, 0, $r)
                $m = [regex]::Match($s, '"ephemeral_(1h|5m)_input_tokens":[1-9]', 'RightToLeft')
                if ($m.Success) {
                    if ($m.Groups[1].Value -eq '1h') { return 60 } else { return 5 }
                }
            }
        } finally { $fs.Dispose() }
    } catch {}
    return 5
}

# ---------------------------------------------------------------- data
$modelName = Txt (Obj $raw 'model') 'display_name'
$ctx = Num (Obj $raw 'context_window') 'used_percentage'
$fiveObj = Obj $raw 'five_hour'; $five = Num $fiveObj 'used_percentage'; $fiveReset = ResetAt $fiveObj
$sevenObj = Obj $raw 'seven_day'; $seven = Num $sevenObj 'used_percentage'; $sevenReset = ResetAt $sevenObj

$cacheTxt = ''; $cacheCol = 78
$tp = Txt $raw 'transcript_path'
if ($tp) {
    try {
        if ([IO.File]::Exists($tp)) {
            $ttlMin = Get-Ttl $tp
            $age = [DateTime]::UtcNow - [IO.File]::GetLastWriteTimeUtc($tp)
            $left = $ttlMin - $age.TotalMinutes
            if ($left -le 0) { $cacheCol = 240; $cacheTxt = 'cold' }
            else {
                $cacheCol = if ($left -le 1) { 196 } elseif ($left -le $ttlMin * 0.2) { 214 } else { 78 }
                $cacheTxt = ('{0}m' -f [int][math]::Ceiling($left))
            }
        }
    } catch {}
}

# Caveman badge: shown only when the caveman plugin is installed and active
# (its flag file exists). Skipped silently otherwise.
$cave = ''
if (-not $NoCaveman) {
    try {
        $cdir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { [IO.Path]::Combine($HOME, '.claude') }
        $fi = [IO.FileInfo]::new([IO.Path]::Combine($cdir, '.caveman-active'))
        if ($fi.Exists -and -not ($fi.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $fi.Length -le 64) {
            $m = ([IO.File]::ReadAllText($fi.FullName) -split "`n")[0].Trim().ToLowerInvariant() -replace '[^a-z0-9-]', ''
            if ($m -match '^(lite|full|ultra|wenyan(-lite|-full|-ultra)?|commit|review|compress)$') { $cave = $m }
        }
    } catch {}
}

function ShortModel($n) {
    $n = $n -replace '^Claude\s+', ''
    if (-not $n) { return '' }
    $v = [regex]::Match($n, '\d+(\.\d+)*').Value
    if ($v.Length -gt 3) { $v = $v.Substring($v.Length - 3) }
    return "$($n.Substring(0, 1))$v"
}

# ---------------------------------------------------------------- layouts
# bar = bar width (0 = percent only), reset = show reset time, model/cave = full|short|none, d7 = show 7d
$Levels = @(
    @{ bar = 10; reset = $true;  model = 'full';  cave = 'full';  d7 = $true  },
    @{ bar = 10; reset = $false; model = 'full';  cave = 'full';  d7 = $true  },
    @{ bar = 5;  reset = $false; model = 'full';  cave = 'full';  d7 = $true  },
    @{ bar = 0;  reset = $false; model = 'full';  cave = 'full';  d7 = $true  },
    @{ bar = 0;  reset = $false; model = 'short'; cave = 'full';  d7 = $true  },
    @{ bar = 0;  reset = $false; model = 'short'; cave = 'short'; d7 = $true  },
    @{ bar = 0;  reset = $false; model = 'none';  cave = 'short'; d7 = $true  },
    @{ bar = 0;  reset = $false; model = 'none';  cave = 'none';  d7 = $true  },
    @{ bar = 0;  reset = $false; model = 'none';  cave = 'none';  d7 = $false }
)

function Render($o) {
    $p = @()
    if ($cave -and $o.cave -ne 'none') {
        if ($o.cave -eq 'short') {
            $s = if ($cave -eq 'full') { 'C' } else { 'C:' + (($cave -split '-' | ForEach-Object { $_.Substring(0, 1) }) -join '').ToUpper() }
        } else {
            $s = if ($cave -eq 'full') { 'CAVEMAN' } else { 'CAVEMAN:' + $cave.ToUpper() }
        }
        $p += Paint 172 "[$s]"
    }
    if ($modelName -and $o.model -ne 'none') {
        $mn = if ($o.model -eq 'short') { ShortModel $modelName } else { $modelName }
        $p += Paint 110 $mn
    }
    if ($null -ne $ctx) { $p += Seg 'ctx' $ctx $null $o }
    if ($cacheTxt) { $p += Paint $cacheCol "$GClock $cacheTxt" }
    if ($null -ne $five) { $p += Seg '5h' $five $fiveReset $o }
    if ($o.d7 -and $null -ne $seven) { $p += Seg '7d' $seven $sevenReset $o }
    return ($p -join " $GSep ")
}

# ---------------------------------------------------------------- fit
$cols = 0
if ($env:COLUMNS -match '^\d+$') { $cols = [int]$env:COLUMNS }
if ($cols -le 0) { try { $cols = [Console]::WindowWidth } catch {} }
if ($cols -le 0) { try { $cols = $Host.UI.RawUI.WindowSize.Width } catch {} }

$avail = 0
if ($Width -match '^(\d+)%$') {
    $base = if ($cols -gt 0) { $cols } else { 120 }
    $avail = [int][math]::Floor($base * [int]$Matches[1] / 100)
} elseif ($Width -match '^\d+$') {
    $avail = [int]$Width
} elseif ($cols -gt 0) {
    $avail = $cols - $Reserve
}

$last = $Levels.Count - 1
if ($Level -ge 0) {
    $lv = [math]::Min($Level, $last)
    $out = Render $Levels[$lv]
} else {
    $lv = 0
    $out = Render $Levels[0]
    if ($avail -gt 0) {
        while ($lv -lt $last -and (VisLen $out) -gt $avail) { $lv++; $out = Render $Levels[$lv] }
    }
}

# Written as raw UTF-8 bytes when piped (the normal case), again to leave the shared
# console's code page alone. Only a manual run in a terminal goes through the console.
if ([Console]::IsOutputRedirected) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($out)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
} else {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    [Console]::Write($out)
}
