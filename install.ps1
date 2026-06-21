# install.ps1 — fetch the latest zcloud.exe, verify its checksum, drop it on
# PATH. Idempotent; safe to re-run to upgrade. Windows amd64 + arm64.
#
# Channels (via env):
#   $env:ZCLOUD_CHANNEL = 'stable'   # default — latest semver release
#   $env:ZCLOUD_CHANNEL = 'rolling'  # bleeding edge from main
#   $env:ZCLOUD_CHANNEL = 'v0.1.0'   # pin to a specific tag

$ErrorActionPreference = 'Stop'

$Repo    = 'zentring/zcloud'
$BinName = 'zcloud.exe'
$Channel = if ($env:ZCLOUD_CHANNEL) { $env:ZCLOUD_CHANNEL } else { 'stable' }

function Say($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# InvokeWithRetry runs $scriptBlock up to $Attempts times with exponential
# backoff. Used for every network call so a transient GitHub 504 (very
# common on releases/* endpoints) doesn't blow up the install. Returns the
# scriptBlock's result; rethrows the last exception only after exhausting
# the budget.
function InvokeWithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$Attempts = 4,
        [string]$Label = 'request'
    )
    $delay = 1
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            return & $ScriptBlock
        } catch {
            if ($i -eq $Attempts) {
                throw
            }
            Write-Host "  $Label attempt $i/$Attempts failed ($($_.Exception.Message.Split([Environment]::NewLine)[0])), retrying in ${delay}s" -ForegroundColor Yellow
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, 8)
        }
    }
}

# Get-RedirectTag resolves a /releases/latest URL to its tag via the 302 it
# returns, without touching api.github.com. PowerShell 5.1 throws on a 3xx when
# MaximumRedirection is 0 (Location lives on the exception's Response); 7+ hands
# the response back directly — read Location from whichever path we land on.
function Get-RedirectTag {
    param([string]$Url)
    try {
        $resp = Invoke-WebRequest -Uri $Url -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
    } catch {
        $resp = $_.Exception.Response
    }
    $loc = $null
    if ($resp) { try { $loc = $resp.Headers.Location } catch { $loc = $null } }
    if ($loc -is [array]) { $loc = $loc[0] }
    if ($loc -and $loc.AbsoluteUri) { $loc = $loc.AbsoluteUri }
    $loc = [string]$loc
    if ($loc -notmatch '/tag/([^/]+)/?$') { throw "no usable redirect from $Url (got '$loc')" }
    return $Matches[1]
}

$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'amd64' }
    'ARM64' { 'arm64' }
    default { throw "unsupported arch: $env:PROCESSOR_ARCHITECTURE" }
}

# Pin the tag up-front so every later URL skips GitHub's `latest/download`
# redirect resolver. For `stable` we resolve via two independent sources so a
# 504 on either keeps installs working: the JSON API first, then the web
# redirect on github.com — the same host the binary download uses, so if that's
# reachable the redirect resolves too. Rolling and explicit tags need no lookup.
$tag = switch ($Channel) {
    'stable' {
        Say 'Resolving latest stable release'
        $api = "https://api.github.com/repos/$Repo/releases/latest"
        try {
            $rel = InvokeWithRetry -Label 'release lookup' -ScriptBlock {
                Invoke-RestMethod -Uri $api -UseBasicParsing -Headers @{ 'User-Agent' = 'zcloud-installer' }
            }
            $rel.tag_name
        } catch {
            Write-Host '  API lookup failed; falling back to release redirect' -ForegroundColor Yellow
            $latest = "https://github.com/$Repo/releases/latest"
            InvokeWithRetry -Label 'release redirect' -ScriptBlock { Get-RedirectTag -Url $latest }
        }
    }
    'rolling' { 'rolling' }
    default   { $Channel }
}
$base = "https://github.com/$Repo/releases/download/$tag"

$asset    = "zcloud-windows-$arch.exe"
$url      = "$base/$asset"
$sumsUrl  = "$base/SHA256SUMS"

# %LOCALAPPDATA%\Programs\zcloud is the conventional per-user install root on
# Windows — no admin needed, survives reboots, easy to uninstall.
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\zcloud'
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

$dest = Join-Path $installDir $BinName
$tmp  = "$dest.tmp"

Say "Downloading $asset ($tag)"
try {
    InvokeWithRetry -Label 'binary download' -ScriptBlock {
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
    } | Out-Null
} catch {
    throw "download failed: $url`n$($_.Exception.Message)"
}

# SHA256 verification is best-effort: a network blip fetching the sums file
# must not block install, but a successful fetch with a mismatch has to
# abort. Two important details for the catch:
#
#   1. Use a bare catch (no type filter). Earlier we filtered on
#      [System.Net.WebException] which only exists in Windows PowerShell
#      5.1; PS 7+ wraps the same failure as
#      Microsoft.PowerShell.Commands.HttpResponseException, the filter
#      never matched, and $ErrorActionPreference=Stop killed the script.
#   2. Re-throw the literal "checksum mismatch" exception so the bare
#      catch still aborts when bytes are wrong (only network errors slip
#      through to the warning path).
try {
    $sumsRaw = InvokeWithRetry -Label 'SHA256SUMS' -ScriptBlock {
        (Invoke-WebRequest -Uri $sumsUrl -UseBasicParsing).Content
    }
    $expected = ($sumsRaw -split "`n" |
        Where-Object { $_ -match [Regex]::Escape($asset) } |
        ForEach-Object { ($_ -split '\s+')[0] } |
        Select-Object -First 1)
    if ($expected) {
        $actual = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
        if ($expected -ne $actual) {
            Remove-Item $tmp -Force
            throw "CHECKSUM_MISMATCH expected=$expected actual=$actual"
        }
        Say 'Checksum verified'
    }
} catch {
    if ($_.Exception.Message -match 'CHECKSUM_MISMATCH') {
        throw $_
    }
    Write-Host "WARNING: could not fetch / verify SHA256SUMS ($($_.Exception.Message.Split([Environment]::NewLine)[0])), skipping verification" -ForegroundColor Yellow
}

Move-Item -Force $tmp $dest
Say "Installed to $dest"

# Add to user PATH if missing. User scope avoids needing admin.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -split ';' -notcontains $installDir) {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$installDir", 'User')
    Write-Host ''
    Write-Host "Added $installDir to user PATH." -ForegroundColor Green
    Write-Host 'Open a new terminal for it to take effect.'
}

# Make the binary callable in *this* session immediately for the smoke test.
$env:Path = "$env:Path;$installDir"
try { & $dest version } catch { }
