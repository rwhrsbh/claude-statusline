# Removes the Claude Code statusline on Windows:
#
#   irm https://raw.githubusercontent.com/rwhrsbh/claude-statusline/main/uninstall.ps1 | iex
#
# - "statusLine" in settings.json: if it is this statusline, it is removed and the
#   one that was there before the install is put back. If it is someone else's, you
#   are asked first (and it is left alone when there is nobody to ask).
# - statusline.ps1 / statusline.sh and statusline.prev.json are deleted; a
#   statusline script that the install had moved aside is put back.
# - settings.json.bak-statusline is left in place.
#
# Everything runs inside a script block and never calls `exit`, because under
# `irm | iex` the code runs in the user's own shell session.
& {
    $ErrorActionPreference = 'Stop'
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
    # $true / $false, or $null when there is nobody to ask.
    function Ask($question) {
        if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { return $null }
        try { $a = Read-Host "$question [y/N]" } catch { return $null }
        return ($a -match '^\s*(y|yes)\s*$')
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
    function RemoveStatusLine($t, $r) {
        if ($r.NextStart -ge 0) { return $t.Remove($r.KeyStart, $r.NextStart - $r.KeyStart) }
        if ($r.PrevEnd -ge 0) { return $t.Remove($r.PrevEnd, $r.ValEnd - $r.PrevEnd) }
        return $t.Remove($r.KeyStart, $r.ValEnd - $r.KeyStart)
    }

    try {
        if (Test-Path -LiteralPath $settings) {
            $bytes = [IO.File]::ReadAllBytes($settings)
            $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            $text = [IO.File]::ReadAllText($settings)
            if (-not $text.Trim()) { $text = '{}' }
            try { $json = $text | ConvertFrom-Json; $found = FindStatusLine $text }
            catch { throw "$settings is not valid JSON ($($_.Exception.Message)). Nothing was changed." }

            $new = $null
            if (-not $found.Found) {
                Write-Host "No statusLine in $settings."
            } elseif (IsOurs ([string]$json.statusLine.command)) {
                $old = if (Test-Path -LiteralPath $prev) { [IO.File]::ReadAllText($prev).Trim() } else { '' }
                if ($old) {
                    $new = $text.Substring(0, $found.ValStart) + $old + $text.Substring($found.ValEnd)
                    Write-Host "statusLine restored to what it was before the install."
                } else {
                    $new = RemoveStatusLine $text $found
                    Write-Host "statusLine removed from $settings."
                }
            } else {
                Write-Host "The statusLine in $settings is not this statusline:"
                Write-Host "  $($json.statusLine.command)"
                $answer = Ask 'Remove it anyway?'
                if ($answer) {
                    $new = RemoveStatusLine $text $found
                    Write-Host "statusLine removed from $settings."
                } elseif ($null -eq $answer) {
                    Write-Host "Nobody to ask, so it was left as it is."
                } else {
                    Write-Host "Left as it is."
                }
            }
            if ($null -ne $new) {
                try { $null = $new | ConvertFrom-Json } catch { throw "Could not update $settings safely. Nothing was changed." }
                [IO.File]::WriteAllText($settings, $new, (New-Object Text.UTF8Encoding($bom)))
            }
        } else {
            Write-Host "No $settings."
        }

        foreach ($ext in 'ps1', 'sh') {
            $f = Join-Path $cfgDir "statusline.$ext"
            if (IsOurScript $f) { Remove-Item -LiteralPath $f -Force; Write-Host "Deleted $f" }
            if ((Test-Path -LiteralPath "$f.bak-statusline") -and -not (Test-Path -LiteralPath $f)) {
                Move-Item -LiteralPath "$f.bak-statusline" $f
                Write-Host "Put back your own $f"
            }
        }
        if (Test-Path -LiteralPath $prev) { Remove-Item -LiteralPath $prev -Force }
        if (Test-Path -LiteralPath "$settings.bak-statusline") { Write-Host "Kept $settings.bak-statusline (settings from before the install)." }
        Write-Host "Restart Claude Code to apply."
    } catch {
        Write-Host "Uninstall failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}
