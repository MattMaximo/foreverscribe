<#
ForeverScribe game-side installer for Windows (the PC that plays WoW: Forever).

  .\install.ps1 -AddonOnly                 same PC as your agent: just the addon
  .\install.ps1 -Pair fs1.xxxx             agent on another computer: push over HTTP (code from `foreverscribe pair`)
  .\install.ps1 -Pair fs2.xxxx             agent anywhere: through a hosted relay (code from `foreverscribe relay pair`)
  .\install.ps1 -Folder "D:\Dropbox\ForeverScribe"   agent elsewhere: copy into a synced folder
  (-Pair and -Folder can be combined)
Options: -WowDir DIR   -Remind MINUTES   -Extra "ForeverForge*.lua","Polestar.lua"   -DryRun   -Uninstall
Run from PowerShell:  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Pair fs1.xxxx
Touches only: Interface\AddOns\ForeverScribe(_Live, _Prices, _Route01-10), %LOCALAPPDATA%\ForeverScribe\, the "ForeverScribe Sync"
scheduled task (at logon, your user, no admin). Undo with -Uninstall.
#>
param(
    [string]$Pair = "", [string]$Folder = "", [string]$WowDir = "", [int]$Remind = -1,
    [string[]]$Extra = @("ForeverForge*.lua", "Polestar.lua"), [switch]$AddonOnly, [switch]$DryRun, [switch]$Uninstall
)
$ErrorActionPreference = "Stop"
# Windows PowerShell 5.1 may not offer TLS 1.2 by default; the hosted relay (https) needs it
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Kit = if (Test-Path (Join-Path $Here "addon")) { $Here } else { (Resolve-Path (Join-Path $Here "..\..")).Path }
$Support = Join-Path $env:LOCALAPPDATA "ForeverScribe"
$TaskName = "ForeverScribe Sync"
$Manifest = Join-Path $Support "install-manifest.json"
$AddonDirs = @("ForeverScribe", "ForeverScribe_Live", "ForeverScribe_Prices") + (1..10 | ForEach-Object { "ForeverScribe_Route{0:D2}" -f $_ })

function Say([string]$m) { Write-Host $m }
function Do-It([string]$what, [scriptblock]$action) { if ($DryRun) { Say "  [dry-run] $what" } else { & $action } }

function Find-Wow {
    if ($WowDir) { return $WowDir }
    $cands = @("C:\Program Files (x86)\World of Warcraft\_forever_", "C:\Program Files\World of Warcraft\_forever_",
               "D:\World of Warcraft\_forever_", "D:\Games\World of Warcraft\_forever_")
    foreach ($c in $cands) { if (Test-Path (Join-Path $c "Interface")) { return $c } }
    return $cands[0]
}

if ($Uninstall) {
    $wow = Find-Wow
    if (Test-Path $Manifest) { $m = Get-Content $Manifest -Raw | ConvertFrom-Json; if ($m.wowDir) { $wow = $m.wowDir } } else { $m = $null }
    Do-It "remove scheduled task '$TaskName'" {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }
    }
    foreach ($d in $AddonDirs) {
        $target = Join-Path $wow "Interface\AddOns\$d"
        if ((Test-Path (Join-Path $Support "installed-$d")) -and (Test-Path $target)) { Do-It "remove $target" { Remove-Item $target -Recurse -Force } }
        if ($m -and $m."backup_$d" -and (Test-Path $m."backup_$d")) { Do-It "restore $d" { Move-Item $m."backup_$d" $target } }
    }
    Do-It "remove $Support" { if (Test-Path $Support) { Remove-Item $Support -Recurse -Force } }
    Say "ForeverScribe uninstalled. Restart WoW to unload the addon."
    exit 0
}

$wow = Find-Wow
$addons = Join-Path $wow "Interface\AddOns"
if (-not (Test-Path $addons)) { Say "AddOns folder not found: $addons"; Say "Pass -WowDir '<...>\World of Warcraft\_forever_'."; exit 1 }
foreach ($d in $AddonDirs) {
    if (-not (Test-Path (Join-Path $Kit "addon\$d\$d.toc"))) { Say "Kit is incomplete: missing addon\$d"; exit 1 }
}

$pushUrl = ""; $keyId = ""; $key = ""; $relayUrl = ""; $relayCh = ""; $relayToken = ""
if ($Pair) {
    $Pair = $Pair.Trim()
    if (-not ($Pair.StartsWith("fs1.") -or $Pair.StartsWith("fs2."))) { Say "That isn't a ForeverScribe pairing code (it starts with fs1. or fs2.)"; exit 2 }
    $b = $Pair.Substring(4).Replace("-", "+").Replace("_", "/")
    while ($b.Length % 4 -ne 0) { $b += "=" }
    try { $j = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)) | ConvertFrom-Json }
    catch { Say "Pairing code is damaged; copy it again."; exit 2 }
    $key = [string]$j.k
    if ($Pair.StartsWith("fs1.")) {
        $pushUrl = ([string]$j.u).TrimEnd("/"); $keyId = [string]$j.i
        if (-not $pushUrl -or -not $keyId -or -not $key) { Say "Pairing code is damaged; copy it again."; exit 2 }
    } else {
        $relayUrl = ([string]$j.u).TrimEnd("/"); $relayCh = [string]$j.c; $relayToken = [string]$j.t
        if (-not $relayUrl -or -not $relayToken -or -not $key -or $relayCh -cnotmatch '^[0-9a-f]{32}$') { Say "Pairing code is damaged; copy it again."; exit 2 }
    }
}
if (-not $AddonOnly -and -not $pushUrl -and -not $relayUrl -and -not $Folder) {
    Say "Choose how the files reach your agent:"
    Say "  same PC:            .\install.ps1 -AddonOnly"
    Say "  another computer:   .\install.ps1 -Pair <code from 'foreverscribe pair' or 'foreverscribe relay pair'>   and/or   -Folder <synced folder>"
    exit 2
}
if (Get-Process -Name "Wow*" -ErrorAction SilentlyContinue) { Say "Note: WoW is running. Fully quit and restart it to load new addons." }

$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$man = [ordered]@{ installedAt = $ts; wowDir = $wow; version = "0.9.0" }
if (Test-Path $Manifest) {
    $old = Get-Content $Manifest -Raw | ConvertFrom-Json
    foreach ($p in $old.PSObject.Properties) { if ($p.Name -like "backup_*") { $man[$p.Name] = $p.Value } }
}
Do-It "create $Support" { New-Item -ItemType Directory -Force -Path $Support | Out-Null }

# A new pairing must get every file once, even ones unchanged since they were delivered elsewhere.
if ($Pair -and (Test-Path (Join-Path $Support "pushed"))) {
    if (-not $DryRun) { Remove-Item -Recurse -Force (Join-Path $Support "pushed") }
    Say "   new pairing: every file is sent once again"
}

Say "1) Addon -> $addons"
foreach ($d in $AddonDirs) {
    $target = Join-Path $addons $d
    if (Test-Path $target) {
        if (Test-Path (Join-Path $Support "installed-$d")) { Do-It "replace $target" { Remove-Item $target -Recurse -Force } }
        else {
            $bk = Join-Path $Support "backup-$ts\$d"
            Do-It "back up existing $d to $bk" { New-Item -ItemType Directory -Force -Path (Split-Path $bk) | Out-Null; Move-Item $target $bk }
            $man["backup_$d"] = $bk
        }
    }
    Do-It "copy addon\$d -> $target" { Copy-Item (Join-Path $Kit "addon\$d") $target -Recurse -Force; New-Item -ItemType File -Force -Path (Join-Path $Support "installed-$d") | Out-Null }
}
if ($Remind -ge 0) {
    Say "   save reminder: $(if ($Remind -eq 0) { 'off' } else { "every $Remind min without a /reload" })"
    Do-It "write Defaults.lua" {
        Set-Content -Path (Join-Path $addons "ForeverScribe\Defaults.lua") -Encoding ASCII -Value @(
            "-- Written by install.ps1. /scribe remind <min>|off in game overrides it.",
            "ForeverScribe_Defaults = {", "`tsaveReminderMinutes = $Remind,", "}")
    }
}

if ($AddonOnly) {
    Do-It "remove sync task if present" { if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false } }
    Do-It "write manifest" { $man | ConvertTo-Json | Set-Content $Manifest -Encoding UTF8 }
    Say ""; Say "Done (addon only). Your agent reads $wow\WTF directly: run 'foreverscribe setup --mode local' there."
    Say "Next: restart WoW, enable ForeverScribe at character select, log in, /scribe status, /reload."
    exit 0
}

Say "2) Sync agent -> $Support"
$conf = [ordered]@{ wowDir = $wow; pushUrl = $pushUrl; keyId = $keyId; relayUrl = $relayUrl; relayCh = $relayCh; folderDest = $Folder; extraSv = @($Extra) }
Do-It "write game.json (push $(if ($pushUrl) { $pushUrl } else { 'off' }), relay $(if ($relayUrl) { $relayUrl } else { 'off' }), folder $(if ($Folder) { $Folder } else { 'off' }))" {
    Copy-Item (Join-Path $Kit "installers\windows\foreverscribe-sync.ps1") (Join-Path $Support "foreverscribe-sync.ps1") -Force
    $conf | ConvertTo-Json | Set-Content (Join-Path $Support "game.json") -Encoding UTF8
    if ($keyId) {
        $kp = Join-Path $Support "pairing.key"
        Set-Content -Path $kp -Value $key -NoNewline -Encoding ASCII
        icacls $kp /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
    }
    if ($relayUrl) {
        $rk = Join-Path $Support "relay.key"
        Set-Content -Path $rk -Value "$relayToken`n$key`n" -NoNewline -Encoding ASCII
        icacls $rk /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
        $got = Join-Path $Support "relay-got"
        if (Test-Path $got) { Remove-Item $got -Recurse -Force }   # a new channel starts from zero
    }
    if ($Folder) { New-Item -ItemType Directory -Force -Path $Folder | Out-Null }
}
Do-It "register scheduled task '$TaskName' (at logon, runs hidden, your user only)" {
    $ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $arg = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $Support 'foreverscribe-sync.ps1')`" -Watch"
    $action = New-ScheduledTaskAction -Execute $ps -Argument $arg
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "ForeverScribe: ship WoW SavedVariables to your agent" -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
}
Do-It "write manifest" { $man | ConvertTo-Json | Set-Content $Manifest -Encoding UTF8 }

if ($pushUrl -and -not $DryRun) {
    Say "3) Checking the receiver at $pushUrl"
    $body = [System.Text.Encoding]::UTF8.GetBytes("check")
    $tsec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $sha = -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash($body) | ForEach-Object { $_.ToString("x2") })
    $hm = New-Object System.Security.Cryptography.HMACSHA256 (, [System.Text.Encoding]::UTF8.GetBytes($key))
    $sig = -join ($hm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("fs1`n$tsec`nPOST`n/v1/auth-check`n$sha")) | ForEach-Object { $_.ToString("x2") })
    try {
        Invoke-WebRequest -Uri "$pushUrl/v1/auth-check" -Method Post -Body $body -UseBasicParsing -TimeoutSec 10 `
            -Headers @{ "X-FS-Key" = $keyId; "X-FS-Time" = "$tsec"; "X-FS-Sig" = $sig } | Out-Null
        Say "   receiver OK, pairing key accepted"
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 403) {
            Say "   receiver reachable but it refused the key: run 'foreverscribe pair' again and re-install with the new code"
        } else { Say "   receiver not reachable right now. Files wait in the spool and go out once it is." }
    }
}

if ($relayUrl -and -not $DryRun) {
    Say "3) Checking the relay at $relayUrl"
    try {
        Invoke-WebRequest -Uri "$relayUrl/v1/ch/$relayCh/events?since=0" -Headers @{ Authorization = "Bearer $relayToken" } `
            -UseBasicParsing -TimeoutSec 15 | Out-Null
        Say "   relay OK, channel found (files are encrypted on this PC before they leave it)"
    } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($code -eq 403 -or $code -eq 404) { Say "   relay reachable but it doesn't know this channel: run 'foreverscribe relay pair --force' on your agent computer and re-install with the new code" }
        else { Say "   relay not reachable right now. Files wait in the spool and go out once it is." }
    }
}

Say ""
Say "Done. Next: fully quit and restart WoW, check 'ForeverScribe' is enabled at character select,"
Say "log in, /scribe status, then /reload. Your agent sees it within a minute ('foreverscribe summary')."
Say "Routes: when your agent writes one, press /fs go (bind it under Keybindings > AddOns > ForeverScribe)."
Say "AH prices: if your agent has them on, item tooltips show them after the next login or /reload (/scribe tooltip)."
Say "Undo everything with: powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall"
