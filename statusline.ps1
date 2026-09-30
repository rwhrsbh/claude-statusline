# Claude Code statusline (PowerShell): caveman badge | model | ctx | cache timer | 5h | 7d
#
# Adapts to the terminal width: picks the richest layout that fits (see $Levels).
# Options (all optional):
#   -Width 80      fit into 80 columns      -Width 60%   60% of the terminal width
#   -Level N       force a layout (0 = richest .. 8 = most compact), no auto-fit
#   -Ttl N         prompt-cache TTL in minutes (default: auto-detected, else 5)
#   -Reserve N     columns kept free at the right edge (default 4)
#   -NoCaveman     never show the caveman badge
param(
    [string]$Width = '',
    [int]$Level = -1,
    [int]$Ttl = 0,
    [int]$Reserve = 4,
    [switch]$NoCaveman
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$Esc = [char]27

$raw = [Console]::In.ReadToEnd()
try { $j = $raw | ConvertFrom-Json } catch { $j = $null }

# ---------------------------------------------------------------- helpers
function Paint($c, $t) { return "$Esc[38;5;${c}m$t$Esc[0m" }
function PctColor($p) { if ($p -ge 80) { 196 } elseif ($p -ge 50) { 214 } else { 78 } }
function Bar($pct, $w) {
    $n = [math]::Max(0, [math]::Min($w, [int][math]::Round($pct / 100 * $w)))
    return ('█' * $n) + ('░' * ($w - $n))
}
function Left($v) {
    if ($null -eq $v -or $v -eq '') { return '' }
    try {
        if ($v -is [string]) { $t = [DateTimeOffset]::Parse($v) }
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
    if ($o.reset) { $l = Left $reset; if ($l) { $body += " ↻$l" } }
    return Paint (PctColor $pct) $body
}
function VisLen($s) { return ($s -replace "$Esc\[[0-9;]*m", '').Length }

# Prompt-cache TTL: -Ttl > $env:CLAUDE_CACHE_TTL_MIN > detected from the transcript
# (a non-zero ephemeral_1h_* means 60 min, ephemeral_5m_* means 5 min) > 5.
function Get-Ttl($path) {
    if ($Ttl -gt 0) { return $Ttl }
    if ($env:CLAUDE_CACHE_TTL_MIN -match '^\d+$') { return [int]$env:CLAUDE_CACHE_TTL_MIN }
    try {
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            $n = [int][math]::Min($fs.Length, 400000)
            if ($n -gt 0) {
                [void]$fs.Seek(-$n, [IO.SeekOrigin]::End)
                $buf = New-Object byte[] $n
                $r = $fs.Read($buf, 0, $n)
                $s = [Text.Encoding]::GetEncoding(28591).GetString($buf, 0, $r)
                $m = [regex]::Matches($s, '"ephemeral_(1h|5m)_input_tokens":[1-9]')
                if ($m.Count -gt 0) {
                    if ($m[$m.Count - 1].Groups[1].Value -eq '1h') { return 60 } else { return 5 }
                }
            }
        } finally { $fs.Dispose() }
    } catch {}
    return 5
}

# ---------------------------------------------------------------- data
$modelName = ''; $ctx = $null; $five = $null; $seven = $null
$cacheTxt = ''; $cacheCol = 78
if ($j) {
    if ($j.model.display_name) { $modelName = [string]$j.model.display_name }
    $ctx = $j.context_window.used_percentage
    if ($j.rate_limits) { $five = $j.rate_limits.five_hour; $seven = $j.rate_limits.seven_day }
    $tp = $j.transcript_path
    if ($tp -and (Test-Path -LiteralPath $tp)) {
        $ttl = Get-Ttl $tp
        $age = (Get-Date) - (Get-Item -LiteralPath $tp).LastWriteTime
        $left = $ttl - $age.TotalMinutes
        if ($left -le 0) { $cacheCol = 240; $cacheTxt = 'cold' }
        else {
            $cacheCol = if ($left -le 1) { 196 } elseif ($left -le $ttl * 0.2) { 214 } else { 78 }
            $cacheTxt = ('{0}m' -f [int][math]::Ceiling($left))
        }
    }
}

# Caveman badge: shown only when the caveman plugin is installed and active
# (its flag file exists). Skipped silently otherwise.
$cave = ''
if (-not $NoCaveman) {
    $cdir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
    $flag = Join-Path $cdir '.caveman-active'
    try {
        $it = Get-Item -LiteralPath $flag -Force -ErrorAction Stop
        if (-not ($it.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $it.Length -le 64) {
            $m = ([string](Get-Content -LiteralPath $flag -TotalCount 1)).Trim().ToLowerInvariant() -replace '[^a-z0-9-]', ''
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
# bar = bar width (0 = percent only), reset = show "↻time", model/cave = full|short|none, d7 = show 7d
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
    if ($cacheTxt) { $p += Paint $cacheCol "◷ $cacheTxt" }
    if ($five -and $null -ne $five.used_percentage) { $p += Seg '5h' $five.used_percentage $five.resets_at $o }
    if ($o.d7 -and $seven -and $null -ne $seven.used_percentage) { $p += Seg '7d' $seven.used_percentage $seven.resets_at $o }
    return ($p -join ' │ ')
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
[Console]::Write($out)
