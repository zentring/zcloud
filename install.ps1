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

$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'amd64' }
    'ARM64' { 'arm64' }
    default { throw "unsupported arch: $env:PROCESSOR_ARCHITECTURE" }
}

$base = switch ($Channel) {
    'stable'  { "https://github.com/$Repo/releases/latest/download" }
    'rolling' { "https://github.com/$Repo/releases/download/rolling" }
    default   { "https://github.com/$Repo/releases/download/$Channel" }
}

$asset    = "zcloud-windows-$arch.exe"
$url      = "$base/$asset"
$sumsUrl  = "$base/SHA256SUMS"

# %LOCALAPPDATA%\Programs\zcloud is the conventional per-user install root on
# Windows — no admin needed, survives reboots, easy to uninstall.
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\zcloud'
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

$dest = Join-Path $installDir $BinName
$tmp  = "$dest.tmp"

Say "Downloading $asset ($Channel)"
try {
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
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
#      That's what the recent "504 Gateway Time-out" install failures
#      were really hitting.
#   2. Re-throw the literal "checksum mismatch" exception so the bare
#      catch still aborts when bytes are wrong (only network errors slip
#      through to the warning path).
try {
    $sumsRaw = (Invoke-WebRequest -Uri $sumsUrl -UseBasicParsing).Content
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
