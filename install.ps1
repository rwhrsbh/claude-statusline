# Installs the Claude Code statusline on Windows. No clone needed:
#
#   irm https://raw.githubusercontent.com/rwhrsbh/claude-statusline/main/install.ps1 | iex
#
# Puts statusline.ps1 into the Claude config folder (~/.claude, or $env:CLAUDE_CONFIG_DIR)
# and points "statusLine" in settings.json at it. Running it again updates the script.
# Whatever it replaces is kept so that uninstall.ps1 can put it back:
#   settings.json.bak-statusline   full copy of settings.json from before the install
#   statusline.prev.json           the previous "statusLine" value
#   statusline.ps1.bak-statusline  a different statusline.ps1 that was already there
#
# Everything runs inside a script block and never calls `exit`, because under
# `irm | iex` the code runs in the user's own shell session.
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $base = 'https://raw.githubusercontent.com/rwhrsbh/claude-statusline/main'
    $marker = 'Claude Code statusline \((PowerShell|bash)\): caveman badge'

    $cfgDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
    $settings = Join-Path $cfgDir 'settings.json'
    $target = Join-Path $cfgDir 'statusline.ps1'
    $prev = Join-Path $cfgDir 'statusline.prev.json'

    function IsOurScript($path) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        return [bool]((Get-Content -LiteralPath $path -TotalCount 5) -match $marker)
    }
    # True when the statusLine command runs this statusline (installed copy or a clone).
    function IsOurs($command) {
        if (-not $command) { return $false }
        $m = [regex]::Match($command, '"([^"]*statusline\.(?:ps1|sh))"')
        if (-not $m.Success) { $m = [regex]::Match($command, '(\S*statusline\.(?:ps1|sh))') }
        if (-not $m.Success) { return $false }
        $p = $m.Groups[1].Value -replace '^~', $HOME
        if (IsOurScript $p) { return $true }
        return ($p -eq $target -and -not (Test-Path -LiteralPath $p))
    }

    # settings.json is edited as text, touching only the "statusLine" entry, so the
    # rest of the file keeps its formatting. A tiny scanner finds the entry.
    function SkipWs($t, $i) { while ($i -lt $t.Length -and [char]::IsWhiteSpace($t[$i])) { $i++ }; return $i }
    function StrEnd($t, $i) {
        $i++
        while ($i -lt $t.Length) {
            if ($t[$i] -eq '\') { $i += 2; continue }
            if ($t[$i] -eq '"') { return $i + 1 }
            $i++
        }
        throw 'unterminated string'
    }
    function ValEnd($t, $i) {
        $c = $t[$i]
        if ($c -eq '"') { return StrEnd $t $i }
        if ($c -eq '{' -or $c -eq '[') {
            $d = 0
            while ($i -lt $t.Length) {
                $c = $t[$i]
                if ($c -eq '"') { $i = StrEnd $t $i; continue }
                if ($c -eq '{' -or $c -eq '[') { $d++ }
                elseif ($c -eq '}' -or $c -eq ']') { $d--; if ($d -eq 0) { return $i + 1 } }
                $i++
            }
            throw 'unterminated value'
        }
        while ($i -lt $t.Length -and ',}]'.IndexOf($t[$i]) -lt 0 -and -not [char]::IsWhiteSpace($t[$i])) { $i++ }
        return $i
    }
    function FindStatusLine($t) {
        $i = SkipWs $t 0
        if ($i -ge $t.Length -or $t[$i] -ne '{') { throw 'top level is not an object' }
        $r = @{ Found = $false; Open = $i; Close = -1; LastEnd = -1 }
        $i = SkipWs $t ($i + 1); $prevEnd = -1
        while ($true) {
            if ($i -ge $t.Length) { throw 'unterminated object' }
            if ($t[$i] -eq '}') { $r.Close = $i; break }
            if ($t[$i] -ne '"') { throw "unexpected character at offset $i" }
            $ks = $i; $ke = StrEnd $t $i
            $name = $t.Substring($ks + 1, $ke - $ks - 2)
            $i = SkipWs $t $ke
            if ($i -ge $t.Length -or $t[$i] -ne ':') { throw "expected ':' at offset $i" }
            $vs = SkipWs $t ($i + 1); $ve = ValEnd $t $vs
            $i = SkipWs $t $ve
            $comma = ($i -lt $t.Length -and $t[$i] -eq ',')
            if ($comma) { $i = SkipWs $t ($i + 1) }
            if ($name -ceq 'statusLine') {
                $r.Found = $true; $r.KeyStart = $ks; $r.ValStart = $vs; $r.ValEnd = $ve; $r.PrevEnd = $prevEnd
                $r.NextStart = if ($comma) { $i } else { -1 }
            }
            $prevEnd = $ve; $r.LastEnd = $ve
        }
        return $r
    }
    function SetStatusLine($t, $r, $value) {
        $nl = if ($t.Contains("`r`n")) { "`r`n" } else { "`n" }
        if ($r.Found) { return $t.Substring(0, $r.ValStart) + $value + $t.Substring($r.ValEnd) }
        if ($r.LastEnd -ge 0) { return $t.Substring(0, $r.LastEnd) + ",$nl  `"statusLine`": $value" + $t.Substring($r.LastEnd) }
        return $t.Substring(0, $r.Open) + "{$nl  `"statusLine`": $value$nl}" + $t.Substring($r.Close + 1)
    }

    try {
        New-Item -ItemType Directory -Force $cfgDir | Out-Null

        # Read and check settings.json before changing anything.
        $text = '{}'; $bom = $false
        if (Test-Path -LiteralPath $settings) {
            $bytes = [IO.File]::ReadAllBytes($settings)
            $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            $text = [IO.File]::ReadAllText($settings)
            if (-not $text.Trim()) { $text = '{}' }
        }
        try { $json = $text | ConvertFrom-Json; $found = FindStatusLine $text }
        catch { throw "$settings is not valid JSON ($($_.Exception.Message)). Nothing was changed." }
        $ours = IsOurs ([string]$json.statusLine.command)

        # Get the script: from this folder when run from a clone, otherwise download it.
        $tmp = "$target.tmp-statusline"
        $local = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'statusline.ps1' } else { '' }
        if ($local -and (Test-Path -LiteralPath $local)) {
            if ((Resolve-Path -LiteralPath $local).Path -ne $target) { Copy-Item -LiteralPath $local $tmp -Force } else { $tmp = '' }
        } else {
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
            Invoke-WebRequest -UseBasicParsing "$base/statusline.ps1" -OutFile $tmp
        }
        if ($tmp) {
            if (-not (IsOurScript $tmp)) { Remove-Item -LiteralPath $tmp -Force; throw "Downloaded file is not the statusline script. Nothing was changed." }
            if ((Test-Path -LiteralPath $target) -and -not (IsOurScript $target)) {
                Move-Item -LiteralPath $target "$target.bak-statusline" -Force
                Write-Host "Existing statusline.ps1 was not ours; kept as $target.bak-statusline"
            }
            Move-Item -LiteralPath $tmp $target -Force
        }

        # Remember what is being replaced, unless it is already this statusline.
        if (-not $ours) {
            if (Test-Path -LiteralPath $settings) { Copy-Item -LiteralPath $settings "$settings.bak-statusline" -Force }
            if ($found.Found) {
                [IO.File]::WriteAllText($prev, $text.Substring($found.ValStart, $found.ValEnd - $found.ValStart) + "`n", (New-Object Text.UTF8Encoding($false)))
                Write-Host "Replaced an existing statusLine; uninstall will restore it."
            } elseif (Test-Path -LiteralPath $prev) { Remove-Item -LiteralPath $prev -Force }
        }

        # PowerShell 7 starts about twice as fast as Windows PowerShell 5.1, and the
        # script is launched on every refresh.
        $shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
        $cmd = "$shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$target`""
        $cmdJson = '"' + ($cmd -replace '\\', '\\' -replace '"', '\"') + '"'
        $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $value = "{$nl    `"type`": `"command`",$nl    `"command`": $cmdJson,$nl    `"refreshInterval`": 30$nl  }"
        Write-Host "Statusline installed: $target"
        # An update leaves an existing entry alone, so options added to it by hand survive.
        $current = [string]$json.statusLine.command
        if ($ours -and $current.Contains($target)) {
            Write-Host "statusLine in $settings already runs it; left as it is."
        } else {
            $new = SetStatusLine $text $found $value
            try { $null = $new | ConvertFrom-Json } catch { throw "Could not update $settings safely. Nothing was changed in it." }
            [IO.File]::WriteAllText($settings, $new, (New-Object Text.UTF8Encoding($bom)))
            Write-Host "statusLine set in $settings"
            Write-Host "  $cmd"
        }
        Write-Host "Restart Claude Code to apply."
    } catch {
        Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}
