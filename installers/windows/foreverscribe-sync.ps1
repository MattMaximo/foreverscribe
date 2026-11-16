<#
ForeverScribe game-side sync agent (Windows). Ships SavedVariables to wherever your agent runs, and brings back the
route and AH prices your agent wrote (`foreverscribe route write`, `foreverscribe prices write`). The only things it
writes inside the WoW folder are Interface\AddOns\ForeverScribe_RouteNN\Route.lua (data-only route slots, read by
/fs go) and Interface\AddOns\ForeverScribe_Prices\Prices.lua (data-only price file); nothing else.

  foreverscribe-sync.ps1            one pass (ship anything new, retry the spool)
  foreverscribe-sync.ps1 -Watch     keep running: check every 10 s (what the logon task runs)

Settings: %LOCALAPPDATA%\ForeverScribe\game.json (written by install.ps1):
  wowDir, pushUrl + keyId (key in pairing.key), folderDest, extraSv (globs, default ForeverForge*.lua and Polestar.lua; matched in each
  accounts SavedVariables and every characters WTF\Account\<acct>\<realm>\<char>\SavedVariables)
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
    $c = @{ wowDir = "C:\Program Files (x86)\World of Warcraft\_forever_"; pushUrl = ""; keyId = ""; folderDest = ""; extraSv = @("ForeverForge*.lua", "Polestar.lua") }
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

function Sign([string]$key, [long]$ts, [string]$path, [byte[]]$body, [string]$method = "POST") {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $digest = Hex $sha.ComputeHash($body)
    $canon = "fs1`n$ts`n$method`n$path`n$digest"
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
    # $acct is "<acct>" or "<acct>/<realm>/<char>" (a per-character file); each folder name is percent-encoded
    $parts = $acct -split '/'
    $enc = ($parts | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
    $path = if ($name -eq "ForeverScribe.lua" -and $parts.Count -eq 1) { "/v1/sv/$enc" } else { "/v1/sv/$enc/$name" }
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

# ---- route slots (agent -> game) ----
# A slot file is data only: every line must be one of the shapes routes.py writes (strings without quotes or
# backslashes cannot break out), so a damaged or hostile file never puts code into the game.
$RouteLine = '^(-- [^\[].*|ForeverScribe_RouteData = (\{|nil)|\tv = [0-9]+,|\trev = "[A-Za-z0-9_.-]+",|\tname = "[^"\\]*",|\tcreated = [0-9]+,|\tstops = \{|\t\t\{ map = [0-9]+, x = [0-9.]+, y = [0-9.]+, r = [0-9]+, title = "[^"\\]*" \},|\t\},|\})?$'
$RouteState = Join-Path $Support "route-rev"

function Valid-Route([string]$text) {
    $lines = $text -split "`n"
    if (-not $lines[0].StartsWith("-- ForeverScribe route slot")) { return $false }
    if (-not ($lines -contains "ForeverScribe_RouteData = {")) { return $false }
    foreach ($l in $lines) { if ($l -cnotmatch $RouteLine) { return $false } }
    return $true
}

function Install-Route($c, [string]$text, [string]$from) {
    $text = $text -replace "`r", ""
    if (-not (Valid-Route $text)) { Log "route from $from ignored: not a ForeverScribe route slot file"; return }
    $rev = if ($text -match 'rev = "([A-Za-z0-9_.-]+)"') { $Matches[1] } else { "" }
    $addons = Join-Path $c.wowDir "Interface\AddOns"
    $n = 0
    foreach ($slot in Get-ChildItem $addons -Directory -Filter "ForeverScribe_Route??" -ErrorAction SilentlyContinue) {
        if (-not (Test-Path (Join-Path $slot.FullName "$($slot.Name).toc"))) { continue }
        $dest = Join-Path $slot.FullName "Route.lua"
        if ((Test-Path $dest) -and ((Get-Content $dest -Raw) -replace "`r", "") -ceq $text) { $n++; continue }
        [System.IO.File]::WriteAllText("$dest.tmp", $text, (New-Object System.Text.UTF8Encoding $false))
        Move-Item "$dest.tmp" $dest -Force
        $n++
    }
    if ($n -eq 0) { Log "route $rev from ${from}: no route slots in $addons (install ForeverScribe 0.5 and restart WoW)"; return }
    $prev = if (Test-Path $RouteState) { (Get-Content $RouteState -Raw).Trim() } else { "" }
    if ($prev -ne $rev) { Set-Content -Path $RouteState -Value $rev -NoNewline -Encoding ASCII; Log "route $rev from $from written to $n slots: press /fs go in game" }
}

function Route-Pickup($c) {
    if (-not (Test-Path (Join-Path $c.wowDir "Interface\AddOns"))) { return }
    if ($c.folderDest) {
        $f = Join-Path $c.folderDest "_route\Route.lua"
        if (Test-Path $f) { Install-Route $c (Get-Content $f -Raw) "synced folder" }
    }
    if ($c.pushUrl -and (Test-Path $KeyPath)) {
        $key = (Get-Content $KeyPath -Raw).Trim()
        $body = [System.Text.Encoding]::UTF8.GetBytes("route")
        $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $have = if (Test-Path $RouteState) { (Get-Content $RouteState -Raw).Trim() } else { "" }
        $headers = @{ "X-FS-Key" = [string]$c.keyId; "X-FS-Time" = "$ts"; "X-FS-Sig" = (Sign $key $ts "/v1/route" $body); "X-FS-Have" = $have }
        try {
            $r = Invoke-WebRequest -Uri ($c.pushUrl + "/v1/route") -Method Post -Body $body -Headers $headers `
                -ContentType "application/octet-stream" -TimeoutSec 15 -UseBasicParsing
            if ($r.StatusCode -eq 200) {
                $text = if ($r.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
                Install-Route $c $text "receiver"
            }
        } catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 403) { Log "receiver refused the route fetch (403): re-pair with: foreverscribe pair" }
        }
    }
}

# ---- prices (agent -> game) ----
# `foreverscribe prices write` makes Interface\AddOns\ForeverScribe_Prices\Prices.lua: data only, read by the game at
# login and /reload for the AH price tooltip. Same rules as a route slot: every line must match $PriceLine.
$PriceLine = '^(-- [^\[].*|ForeverScribe_PriceData = (\{|nil)|\t(v|captured|written|items) = [0-9]+,|\t(rev|market|label|other|source) = "[A-Za-z0-9 _.-]*",|\t[dp] = \{|\t\t\[[0-9]+\] = "[0-9,:;]*",|\t\},|\})?$'
$PriceStamp = Join-Path $Support "prices-checked"
$PriceEvery = 300   # ask the receiver at most every 5 minutes
$PriceMax = 1048576

function Valid-Prices([string]$text) {
    if ($text.Length -gt $PriceMax) { return $false }
    $lines = $text -split "`n"
    if (-not $lines[0].StartsWith("-- ForeverScribe prices")) { return $false }
    if (-not ($lines -contains "ForeverScribe_PriceData = {")) { return $false }
    if (-not $text.TrimEnd().EndsWith("}")) { return $false }
    foreach ($l in $lines) { if ($l -cnotmatch $PriceLine) { return $false } }
    return $true
}

function Price-Rev([string]$path) {
    if (-not (Test-Path $path)) { return "" }
    $m = Select-String -Path $path -Pattern '^\trev = "([A-Za-z0-9_.-]+)",$' -CaseSensitive | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value } else { return "" }
}

function Install-Prices($c, [string]$text, [string]$from) {
    $text = $text -replace "`r", ""
    $dir = Join-Path $c.wowDir "Interface\AddOns\ForeverScribe_Prices"
    if (-not (Test-Path (Join-Path $dir "ForeverScribe_Prices.toc"))) { return }
    $dest = Join-Path $dir "Prices.lua"
    if ((Test-Path $dest) -and ((Get-Content $dest -Raw) -replace "`r", "") -ceq $text) { return }
    if (-not (Valid-Prices $text)) { Log "prices from $from ignored: not a ForeverScribe price file"; return }
    [System.IO.File]::WriteAllText("$dest.tmp", $text, (New-Object System.Text.UTF8Encoding $false))
    Move-Item "$dest.tmp" $dest -Force
    Log "prices $(Price-Rev $dest) from $from written ($($text.Length) bytes): they load at your next login or /reload"
}

function Prices-Pickup($c) {
    $dir = Join-Path $c.wowDir "Interface\AddOns\ForeverScribe_Prices"
    if (-not (Test-Path (Join-Path $dir "ForeverScribe_Prices.toc"))) { return }
    if ($c.folderDest) {
        $f = Join-Path $c.folderDest "_prices\Prices.lua"
        if (Test-Path $f) { Install-Prices $c (Get-Content $f -Raw) "synced folder" }
    }
    if ($c.pushUrl -and (Test-Path $KeyPath)) {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $last = 0
        if (Test-Path $PriceStamp) { [long]::TryParse((Get-Content $PriceStamp -Raw).Trim(), [ref]$last) | Out-Null }
        $have = Price-Rev (Join-Path $dir "Prices.lua")
        if ($have -and ($now - $last) -lt $PriceEvery) { return }
        Set-Content -Path $PriceStamp -Value "$now" -NoNewline -Encoding ASCII
        $key = (Get-Content $KeyPath -Raw).Trim()
        $body = [System.Text.Encoding]::UTF8.GetBytes("prices")
        $headers = @{ "X-FS-Key" = [string]$c.keyId; "X-FS-Time" = "$now"; "X-FS-Sig" = (Sign $key $now "/v1/prices" $body); "X-FS-Have" = $have }
        try {
            $r = Invoke-WebRequest -Uri ($c.pushUrl + "/v1/prices") -Method Post -Body $body -Headers $headers `
                -ContentType "application/octet-stream" -TimeoutSec 60 -UseBasicParsing
            if ($r.StatusCode -eq 200) {
                $text = if ($r.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
                Install-Prices $c $text "receiver"
            }
        } catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 403) { Log "receiver refused the price fetch (403): re-pair with: foreverscribe pair" }
        }
    }
}

function Pass {
    $c = Load-Conf
    if (-not $c.pushUrl -and -not $c.folderDest) { if ($VerboseLog) { Log "no transport configured (local mode)" }; return }
    Route-Pickup $c
    Prices-Pickup $c
    $accounts = Join-Path $c.wowDir "WTF\Account"
    if ($c.pushUrl -and (Test-Path $SpoolDir)) {
        foreach ($s in Get-ChildItem $SpoolDir -Recurse -Filter *.lua -File) {
            # <spool>\<acct>\<file> or <spool>\<acct>\<realm>\<char>\<file>
            $rel = $s.Directory.FullName.Substring((Get-Item $SpoolDir).FullName.Length).TrimStart('\', '/')
            $acct = ($rel -split '[\\/]') -join '/'
            $src = Join-Path $accounts (($rel) + "\SavedVariables\$($s.Name)")
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
        # the same globs in every character's SavedVariables (Polestar's per-character PolestarCharDB)
        foreach ($realm in Get-ChildItem $a.FullName -Directory -ErrorAction SilentlyContinue) {
            if ($realm.Name -eq "SavedVariables") { continue }
            foreach ($ch in Get-ChildItem $realm.FullName -Directory -ErrorAction SilentlyContinue) {
                $csv = Join-Path $ch.FullName "SavedVariables"
                if (-not (Test-Path $csv)) { continue }
                foreach ($pat in @($c.extraSv)) {
                    if (-not $pat -or $pat -match '[\\/]') { continue }
                    foreach ($f in Get-ChildItem $csv -Filter $pat -File -ErrorAction SilentlyContinue) {
                        if ($f.Extension -eq ".lua") { Ship $c "$($a.Name)/$($realm.Name)/$($ch.Name)" $f.Name $f.FullName }
                    }
                }
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
