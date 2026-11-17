<#
ForeverScribe game-side sync agent (Windows). Ships SavedVariables to wherever your agent runs, and brings back the
route and AH prices your agent wrote (`foreverscribe route write`, `foreverscribe prices write`). The only things it
writes inside the WoW folder are Interface\AddOns\ForeverScribe_RouteNN\Route.lua (data-only route slots, read by
/fs go) and Interface\AddOns\ForeverScribe_Prices\Prices.lua (data-only price file); nothing else.

  foreverscribe-sync.ps1            one pass (ship anything new, retry the spool)
  foreverscribe-sync.ps1 -Watch     keep running: check every 10 s (what the logon task runs)

Settings: %LOCALAPPDATA%\ForeverScribe\game.json (written by install.ps1):
  wowDir, pushUrl + keyId (key in pairing.key), relayUrl + relayCh (upload token and encryption key in relay.key;
  fs2 codes, files are encrypted end to end before they leave this PC), folderDest, extraSv (globs, default ForeverForge*.lua and Polestar.lua; matched in each
  accounts SavedVariables and every characters WTF\Account\<acct>\<realm>\<char>\SavedVariables)
Pushes are signed with HMAC-SHA256 (same scheme as foreverscribe/auth.py). Failed pushes wait in
spool\ (newest copy per file) and are retried on every pass.
#>
param([switch]$Watch, [switch]$VerboseLog, [string]$Support = "",
      [string]$RelaySeal = "", [string]$RelayOpen = "", [string]$InFile = "", [string]$OutFile = "")

$ErrorActionPreference = "Stop"
# Windows PowerShell 5.1 may not offer TLS 1.2 by default; the hosted relay (https) needs it
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
if (-not $Support) { $Support = Join-Path $env:LOCALAPPDATA "ForeverScribe" }
$ConfPath = Join-Path $Support "game.json"
$KeyPath = Join-Path $Support "pairing.key"
$RelayKeyPath = Join-Path $Support "relay.key"
$RelayGot = Join-Path $Support "relay-got"
$LogPath = Join-Path $Support "sync.log"
$StateDir = Join-Path $Support "pushed"
$SpoolDir = Join-Path $Support "spool"

function Log([string]$msg) {
    $line = "{0} foreverscribe-sync {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    if ($VerboseLog) { Write-Host $line }
}

function Load-Conf {
    $c = @{ wowDir = "C:\Program Files (x86)\World of Warcraft\_forever_"; pushUrl = ""; keyId = ""; relayUrl = ""; relayCh = ""; folderDest = ""; extraSv = @("ForeverForge*.lua", "Polestar.lua") }
    if (Test-Path $ConfPath) {
        $j = Get-Content $ConfPath -Raw | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { $c[$p.Name] = $p.Value }
    }
    if ($env:FOREVERSCRIBE_WOW_DIR) { $c.wowDir = $env:FOREVERSCRIBE_WOW_DIR }
    if ($null -ne $env:FOREVERSCRIBE_PUSH_URL) { $c.pushUrl = $env:FOREVERSCRIBE_PUSH_URL }
    if ($null -ne $env:FOREVERSCRIBE_RELAY_URL) { $c.relayUrl = $env:FOREVERSCRIBE_RELAY_URL }
    if ($env:FOREVERSCRIBE_RELAY_CH) { $c.relayCh = $env:FOREVERSCRIBE_RELAY_CH }
    $c.pushUrl = ([string]$c.pushUrl).TrimEnd("/")
    $c.relayUrl = ([string]$c.relayUrl).TrimEnd("/")
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

# ---- relay transport (fs2): end-to-end encrypted blobs in a hosted mailbox. Same envelope as foreverscribe/relaycrypto.py:
# AES-256-CBC (PKCS7) + HMAC-SHA256 over channel, blob id, header and ciphertext (encrypt-then-MAC, checked first).
$script:Relay = $null
function Utf8([string]$s) { return , ([System.Text.Encoding]::UTF8.GetBytes($s)) }
function Join-Bytes([object[]]$parts) {
    $ms = New-Object System.IO.MemoryStream
    foreach ($p in $parts) { $ms.Write([byte[]]$p, 0, $p.Length) }
    return , $ms.ToArray()
}
function Hmac-Hex([string]$key, [byte[]]$data) {
    $h = New-Object System.Security.Cryptography.HMACSHA256 (, [System.Text.Encoding]::UTF8.GetBytes($key))
    return Hex $h.ComputeHash($data)
}
function Relay-Keys($c) {
    if ($script:Relay) { return $script:Relay }
    if (-not (Test-Path $RelayKeyPath)) { Log "no relay key at $RelayKeyPath (re-run install.ps1 -Pair <fs2 code>)"; return $null }
    $lines = @(Get-Content $RelayKeyPath | Where-Object { $_.Trim() })
    if ($lines.Count -lt 2 -or -not $c.relayCh) { Log "relay settings incomplete (re-run install.ps1 -Pair <fs2 code>)"; return $null }
    $h = New-Object System.Security.Cryptography.HMACSHA256 (, [System.Text.Encoding]::UTF8.GetBytes($lines[1].Trim()))
    $script:Relay = @{ token = $lines[0].Trim(); ch = [string]$c.relayCh; url = [string]$c.relayUrl
        ek = $h.ComputeHash((Utf8 "fs2 enc")); mk = (Hex $h.ComputeHash((Utf8 "fs2 mac"))) }
    return $script:Relay
}
function Relay-Bid($r, [string]$logical) { return (Hmac-Hex $r.mk (Utf8 "fs2 name|$logical")).Substring(0, 32) }
function Relay-Tag($r, [string]$bid, [byte[]]$body) { return Hmac-Hex $r.mk (Join-Bytes @((Utf8 "fs2|$($r.ch)|$bid`n"), $body)) }
function Gzip-Bytes([byte[]]$data) {
    $ms = New-Object System.IO.MemoryStream
    $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
    $gz.Write($data, 0, $data.Length); $gz.Close()
    return , $ms.ToArray()
}
function Gunzip-Bytes([byte[]]$data) {
    $gz = New-Object System.IO.Compression.GZipStream((New-Object System.IO.MemoryStream (, $data)), [System.IO.Compression.CompressionMode]::Decompress)
    $out = New-Object System.IO.MemoryStream
    $gz.CopyTo($out); $gz.Close()
    return , $out.ToArray()
}
function Aes-Cbc($r, [byte[]]$iv, [byte[]]$data, [bool]$decrypt) {
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $r.ek; $aes.IV = $iv
    $t = if ($decrypt) { $aes.CreateDecryptor() } else { $aes.CreateEncryptor() }
    try { return , $t.TransformFinalBlock($data, 0, $data.Length) } finally { $t.Dispose(); $aes.Dispose() }
}
function Relay-Seal($r, [string]$logical, [byte[]]$data) {
    $bid = Relay-Bid $r $logical
    $iv = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($iv)
    $hdr = [System.Text.Encoding]::ASCII.GetBytes("FS2E1" + ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()).ToString("D12") + (Hex $iv))
    $body = Join-Bytes @($hdr, (Aes-Cbc $r $iv (Join-Bytes @((Utf8 "$logical`n"), (Gzip-Bytes $data))) $false))
    return @{ bid = $bid; blob = (Join-Bytes @($body, [System.Text.Encoding]::ASCII.GetBytes((Relay-Tag $r $bid $body)))) }
}
function Relay-Open($r, [byte[]]$blob, [string]$bid, [string]$expected) {
    # the MAC is checked before anything is decrypted; returns the file bytes or $null
    if ($blob.Length -lt 130 -or [System.Text.Encoding]::ASCII.GetString($blob, 0, 5) -ne "FS2E1") { return $null }
    $body = New-Object byte[] ($blob.Length - 64); [Array]::Copy($blob, $body, $body.Length)
    $tag = [System.Text.Encoding]::ASCII.GetString($blob, $blob.Length - 64, 64).ToLowerInvariant()
    if ((Relay-Tag $r $bid $body) -ne $tag) { Log "relay blob failed authentication: ignored"; return $null }
    $ivHex = [System.Text.Encoding]::ASCII.GetString($blob, 17, 32)
    $iv = New-Object byte[] 16
    for ($i = 0; $i -lt 16; $i++) { $iv[$i] = [Convert]::ToByte($ivHex.Substring(2 * $i, 2), 16) }
    $ct = New-Object byte[] ($body.Length - 49); [Array]::Copy($body, 49, $ct, 0, $ct.Length)
    try { $plain = Aes-Cbc $r $iv $ct $true } catch { return $null }
    $nl = [Array]::IndexOf($plain, [byte]10)
    if ($nl -lt 1 -or [System.Text.Encoding]::UTF8.GetString($plain, 0, $nl) -cne $expected) { Log "relay blob is not ${expected}: ignored"; return $null }
    $gz = New-Object byte[] ($plain.Length - $nl - 1); [Array]::Copy($plain, $nl + 1, $gz, 0, $gz.Length)
    try { return , (Gunzip-Bytes $gz) } catch { return $null }
}
function Http-Code($err) { if ($err.Exception.Response) { return [int]$err.Exception.Response.StatusCode }; return 0 }

function Relay-Put($c, [string]$acct, [string]$name, [string]$file) {
    $r = Relay-Keys $c
    if (-not $r) { return 2 }
    $s = Relay-Seal $r "sv/$acct/$name" ([System.IO.File]::ReadAllBytes($file))
    try {
        $resp = Invoke-WebRequest -Uri "$($r.url)/v1/ch/$($r.ch)/files/up/$($s.bid)" -Method Put -Body $s.blob `
            -Headers @{ Authorization = "Bearer $($r.token)" } -ContentType "application/octet-stream" -TimeoutSec 120 -UseBasicParsing
        if ($resp.StatusCode -eq 200) { return 0 }
        return 1
    } catch {
        $code = Http-Code $_
        if ($code -eq 403 -or $code -eq 404) { Log "relay refused $acct/$name ($code): channel unpaired or relay redeployed. On your agent computer run: foreverscribe relay pair --force, then re-install here with the new code"; return 2 }
        if ($code -eq 413) { Log "relay refused $acct/${name}: too big even compressed"; return 2 }
        return 1
    }
}

function Relay-Pickup($c) {
    # one small poll per pass; fetch the route / price blob only when its seq moved and its addon is installed
    $addons = Join-Path $c.wowDir "Interface\AddOns"
    if (-not (Test-Path $addons)) { return }
    $r = Relay-Keys $c
    if (-not $r) { return }
    $auth = @{ Authorization = "Bearer $($r.token)" }
    try { $ev = Invoke-RestMethod -Uri "$($r.url)/v1/ch/$($r.ch)/events?since=0" -Headers $auth -TimeoutSec 20 -UseBasicParsing }
    catch {
        $code = Http-Code $_
        if ($code -eq 403 -or $code -eq 404) { Log "relay refused the poll ($code): channel unpaired or relay redeployed. On your agent computer run: foreverscribe relay pair --force" }
        return
    }
    $want = @{ (Relay-Bid $r "route") = "route"; (Relay-Bid $r "prices") = "prices" }
    New-Item -ItemType Directory -Force -Path $RelayGot | Out-Null
    foreach ($f in @($ev.files)) {
        if (-not $f -or -not ([string]$f.name).StartsWith("down/")) { continue }
        $b = ([string]$f.name).Substring(5)
        $name = $want[$b]
        if (-not $name) { continue }
        $gotFile = Join-Path $RelayGot $name
        [long]$have = 0
        if (Test-Path $gotFile) { [long]::TryParse((Get-Content $gotFile -Raw).Trim(), [ref]$have) | Out-Null }
        if ([long]$f.seq -le $have) { continue }
        if ($name -eq "prices" -and -not (Test-Path (Join-Path $addons "ForeverScribe_Prices\ForeverScribe_Prices.toc"))) { continue }
        if ($name -eq "route" -and -not (Get-ChildItem $addons -Directory -Filter "ForeverScribe_Route??" -ErrorAction SilentlyContinue)) { continue }
        $tmp = Join-Path $Support "relay-download.tmp"
        try { Invoke-WebRequest -Uri "$($r.url)/v1/ch/$($r.ch)/files/$($f.name)" -Headers $auth -OutFile $tmp -TimeoutSec 60 -UseBasicParsing }
        catch { continue }
        $bytes = [System.IO.File]::ReadAllBytes($tmp)
        $data = Relay-Open $r $bytes $b $name
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        if ($null -ne $data) {
            # the signed time inside the envelope must not go backwards: a relay can't roll us back to an older file
            [long]$ts = 0; [long]::TryParse([System.Text.Encoding]::ASCII.GetString($bytes, 5, 12), [ref]$ts) | Out-Null
            $tsFile = Join-Path $RelayGot "$name.t"
            [long]$last = 0
            if (Test-Path $tsFile) { [long]::TryParse((Get-Content $tsFile -Raw).Trim(), [ref]$last) | Out-Null }
            if ($ts -lt $last) { Log "relay offered an older $name than the one installed: ignored" }
            else {
                $text = [System.Text.Encoding]::UTF8.GetString($data)
                if ($name -eq "route") { Install-Route $c $text "relay" } else { Install-Prices $c $text "relay" }
                Set-Content -Path $tsFile -Value "$ts" -NoNewline -Encoding ASCII
            }
        }
        Set-Content -Path $gotFile -Value "$($f.seq)" -NoNewline -Encoding ASCII   # a bad file is not fetched again until a new one
    }
}

function Push-File($c, [string]$acct, [string]$name, [string]$file) {
    if ($c.relayUrl) {
        for ($i = 1; $i -le 3; $i++) {
            $rc = Relay-Put $c $acct $name $file
            if ($rc -eq 0) { return $true }
            if ($rc -eq 2) { return $false }
            if ($i -lt 3) { Start-Sleep -Seconds ($i * 2) }
        }
        return $false
    }
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
    $needPush = ([bool]$c.pushUrl -or [bool]$c.relayUrl) -and -not (Same $src $pushed)
    $dest = $null; $needCopy = $false
    if ($c.folderDest) { $dest = Join-Path (Join-Path $c.folderDest $acct) $name; $needCopy = -not (Same $src $dest) }
    if (-not $needPush -and -not $needCopy) { return }
    if (-not (Stable-Complete $src)) { Log "skip $acct/${name}: still changing or incomplete"; return }
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
    $script:Relay = $null   # re-read relay.key / game.json every pass: a re-install with a new code takes effect at once
    $c = Load-Conf
    if (-not $c.pushUrl -and -not $c.relayUrl -and -not $c.folderDest) { if ($VerboseLog) { Log "no transport configured (local mode)" }; return }
    Route-Pickup $c
    Prices-Pickup $c
    if ($c.relayUrl) { Relay-Pickup $c }
    $accounts = Join-Path $c.wowDir "WTF\Account"
    if (($c.pushUrl -or $c.relayUrl) -and (Test-Path $SpoolDir)) {
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
if ($RelaySeal -or $RelayOpen) {  # troubleshooting / tests: encrypt or decrypt one file with this install's relay key
    $r = Relay-Keys (Load-Conf)
    if (-not $r) { exit 1 }
    if ($RelaySeal) {
        $s = Relay-Seal $r $RelaySeal ([System.IO.File]::ReadAllBytes($InFile))
        [System.IO.File]::WriteAllBytes($OutFile, $s.blob); Write-Output $s.bid; exit 0
    }
    $d = Relay-Open $r ([System.IO.File]::ReadAllBytes($InFile)) (Relay-Bid $r $RelayOpen) $RelayOpen
    if ($null -eq $d) { exit 1 }
    [System.IO.File]::WriteAllBytes($OutFile, $d); exit 0
}
if ($Watch) {
    Log "watching (every 10 s)"
    while ($true) {
        try { Pass } catch { Log "error: $($_.Exception.Message)" }
        Start-Sleep -Seconds 10
    }
} else {
    Pass
}
