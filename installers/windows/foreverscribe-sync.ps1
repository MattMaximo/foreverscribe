<#
ForeverScribe game-side sync agent (Windows). Ships SavedVariables to wherever your agent runs.
Read-only towards the game: it never writes inside the WoW folder.

  foreverscribe-sync.ps1            one pass (ship anything new, retry the spool)
  foreverscribe-sync.ps1 -Watch     keep running: check every 10 s (what the logon task runs)

Settings: %LOCALAPPDATA%\ForeverScribe\game.json (written by install.ps1):
  wowDir, pushUrl + keyId (key in pairing.key), folderDest, extraSv (globs, default ForeverForge*.lua)
Pushes are signed with HMAC-SHA256 (same scheme as foreverscribe/auth.py). Failed pushes wait in
spool\ (newest copy per file) and are retried on every pass.
#>
param([switch]$Watch, [switch]$VerboseLog, [string]$Support = "")

$ErrorActionPreference = "Stop"
if (-not $Support) { $Support = Join-Path $env:LOCALAPPDATA "ForeverScribe" }
$ConfPath = Join-Path $Support "game.json"
$KeyPath = Join-Path $Support "pairing.key"
$LogPath = Join-Path $Support "sync.log"
$StateDir = Join-Path $Support "pushed"
$SpoolDir = Join-Path $Support "spool"

function Log([string]$msg) {
    $line = "{0} foreverscribe-sync {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    if ($VerboseLog) { Write-Host $line }
}

function Load-Conf {
    $c = @{ wowDir = "C:\Program Files (x86)\World of Warcraft\_forever_"; pushUrl = ""; keyId = ""; folderDest = ""; extraSv = @("ForeverForge*.lua") }
    if (Test-Path $ConfPath) {
        $j = Get-Content $ConfPath -Raw | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { $c[$p.Name] = $p.Value }
    }
    if ($env:FOREVERSCRIBE_WOW_DIR) { $c.wowDir = $env:FOREVERSCRIBE_WOW_DIR }
    if ($null -ne $env:FOREVERSCRIBE_PUSH_URL) { $c.pushUrl = $env:FOREVERSCRIBE_PUSH_URL }
    $c.pushUrl = ([string]$c.pushUrl).TrimEnd("/")
    return $c
}

function Hex([byte[]]$b) { return -join ($b | ForEach-Object { $_.ToString("x2") }) }

function Sign([string]$key, [long]$ts, [string]$path, [byte[]]$body) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $digest = Hex $sha.ComputeHash($body)
    $canon = "fs1`n$ts`nPOST`n$path`n$digest"
    $h = New-Object System.Security.Cryptography.HMACSHA256 (, [System.Text.Encoding]::UTF8.GetBytes($key))
    return Hex $h.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canon))
}

function Push-Once($c, [string]$path, [string]$file) {
    $body = [System.IO.File]::ReadAllBytes($file)
    $key = (Get-Content $KeyPath -Raw -ErrorAction SilentlyContinue)
    if (-not $key) { Log "no pairing key at $KeyPath (re-run install.ps1 -Pair <code>)"; return 2 }
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $headers = @{ "X-FS-Key" = [string]$c.keyId; "X-FS-Time" = "$ts"; "X-FS-Sig" = (Sign $key.Trim() $ts $path $body) }
    try {
        $r = Invoke-WebRequest -Uri ($c.pushUrl + $path) -Method Post -Body $body -Headers $headers `
            -ContentType "application/octet-stream" -TimeoutSec 30 -UseBasicParsing
        if ($r.StatusCode -eq 200 -or $r.StatusCode -eq 202) { return 0 }
        return 1
    } catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 403) { Log "receiver refused $path (403): key revoked or clock skew? re-pair with: foreverscribe pair"; return 2 }
        return 1
    }
}

function Push-File($c, [string]$acct, [string]$name, [string]$file) {
    if (-not $c.pushUrl) { return $false }
    $path = if ($name -eq "ForeverScribe.lua") { "/v1/sv/$acct" } else { "/v1/sv/$acct/$name" }
    for ($i = 1; $i -le 3; $i++) {
        $rc = Push-Once $c $path $file
        if ($rc -eq 0) { return $true }
        if ($rc -eq 2) { return $false }
        if ($i -lt 3) { Start-Sleep -Seconds ($i * 2) }
    }
    return $false
}

function Same([string]$a, [string]$b) {
    if (-not (Test-Path $a) -or -not (Test-Path $b)) { return $false }
    if ((Get-Item $a).Length -ne (Get-Item $b).Length) { return $false }
    return (Get-FileHash $a -Algorithm SHA256).Hash -eq (Get-FileHash $b -Algorithm SHA256).Hash
}

function Stable-Complete([string]$f) {
    for ($t = 0; $t -lt 15; $t++) {
        $a = Get-Item $f; Start-Sleep -Seconds 2; $b = Get-Item $f
        if ($a.Length -eq $b.Length -and $a.LastWriteTimeUtc -eq $b.LastWriteTimeUtc) {
            $fs = [System.IO.File]::Open($f, "Open", "Read", "ReadWrite")
            try {
                $n = [Math]::Min(64, $fs.Length); $fs.Seek(-$n, "End") | Out-Null
                $buf = New-Object byte[] $n; $fs.Read($buf, 0, $n) | Out-Null
            } finally { $fs.Close() }
            if (([System.Text.Encoding]::UTF8.GetString($buf)).Trim().EndsWith("}")) { return $true }
        }
    }
    return $false
}

function Ship($c, [string]$acct, [string]$name, [string]$src) {
    $pushed = Join-Path (Join-Path $StateDir $acct) $name
    $spooled = Join-Path (Join-Path $SpoolDir $acct) $name
    $needPush = [bool]$c.pushUrl -and -not (Same $src $pushed)
    $dest = $null; $needCopy = $false
    if ($c.folderDest) { $dest = Join-Path (Join-Path $c.folderDest $acct) $name; $needCopy = -not (Same $src $dest) }
    if (-not $needPush -and -not $needCopy) { return }
    if (-not (Stable-Complete $src)) { Log "skip $acct/$name: still changing or incomplete"; return }
    if ($needPush) {
        New-Item -ItemType Directory -Force -Path (Split-Path $pushed), (Split-Path $spooled) | Out-Null
        Copy-Item $src "$spooled.tmp" -Force; Move-Item "$spooled.tmp" $spooled -Force
        if (Push-File $c $acct $name $spooled) { Move-Item $spooled $pushed -Force; Log "pushed $acct/$name" }
        else { Log "push failed for $acct/$name (receiver unreachable?); kept in spool, retrying next pass" }
    }
    if ($needCopy) {
        New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
        Copy-Item $src "$dest.tmp" -Force; Move-Item "$dest.tmp" $dest -Force
        Log "copied $acct/$name to folder"
    }
}

function Pass {
    $c = Load-Conf
    if (-not $c.pushUrl -and -not $c.folderDest) { if ($VerboseLog) { Log "no transport configured (local mode)" }; return }
    $accounts = Join-Path $c.wowDir "WTF\Account"
    if ($c.pushUrl -and (Test-Path $SpoolDir)) {
        foreach ($s in Get-ChildItem $SpoolDir -Recurse -Filter *.lua -File) {
            $acct = $s.Directory.Name
            $src = Join-Path $accounts "$acct\SavedVariables\$($s.Name)"
            if ((Test-Path $src) -and -not (Same $src $s.FullName)) { continue }
            if (Push-File $c $acct $s.Name $s.FullName) {
                $dst = Join-Path (Join-Path $StateDir $acct) $s.Name
                New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
                Move-Item $s.FullName $dst -Force; Log "delivered spooled $acct/$($s.Name)"
            }
        }
    }
    if (-not (Test-Path $accounts)) { return }
    foreach ($a in Get-ChildItem $accounts -Directory) {
        $sv = Join-Path $a.FullName "SavedVariables"
        if (-not (Test-Path $sv)) { continue }
        $main = Join-Path $sv "ForeverScribe.lua"
        if (Test-Path $main) { Ship $c $a.Name "ForeverScribe.lua" $main }
        foreach ($pat in @($c.extraSv)) {
            if (-not $pat -or $pat -match '[\\/]') { continue }
            foreach ($f in Get-ChildItem $sv -Filter $pat -File -ErrorAction SilentlyContinue) {
                if ($f.Extension -eq ".lua") { Ship $c $a.Name $f.Name $f.FullName }
            }
        }
    }
}

New-Item -ItemType Directory -Force -Path $Support | Out-Null
if ($Watch) {
    Log "watching (every 10 s)"
    while ($true) {
        try { Pass } catch { Log "error: $($_.Exception.Message)" }
        Start-Sleep -Seconds 10
    }
} else {
    Pass
}
