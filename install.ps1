# Points Claude Code's statusLine at statusline.ps1 in this folder (Windows).
# Usage: .\install.ps1 [-ScriptArgs '-Width 100'] [-Refresh 30]
# Backs up settings.json to settings.json.bak-statusline first.
param(
    [string]$ScriptArgs = '',
    [int]$Refresh = 30
)

$cfgDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$settings = Join-Path $cfgDir 'settings.json'
$script = Join-Path $PSScriptRoot 'statusline.ps1'

New-Item -ItemType Directory -Force $cfgDir | Out-Null
if (Test-Path $settings) {
    Copy-Item $settings "$settings.bak-statusline" -Force
    $json = Get-Content $settings -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    $json = [pscustomobject]@{}
}

# PowerShell 7 starts about twice as fast as Windows PowerShell 5.1, and the script
# is launched on every refresh.
$shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
$cmd = "$shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`""
if ($ScriptArgs) { $cmd += " $ScriptArgs" }
$sl = [pscustomobject]@{ type = 'command'; command = $cmd; refreshInterval = $Refresh }
$json | Add-Member -NotePropertyName statusLine -NotePropertyValue $sl -Force

[IO.File]::WriteAllText($settings, ($json | ConvertTo-Json -Depth 32), (New-Object Text.UTF8Encoding($false)))
Write-Host "statusLine set in $settings"
Write-Host "  $cmd"
Write-Host "Restart Claude Code to apply."
