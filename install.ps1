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

# SHA256 verification is best-effort: missing SHA256SUMS shouldn't block
# install, but a mismatch must abort.
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
            throw "checksum mismatch — expected $expected, got $actual"
        }
        Say 'Checksum verified'
    }
} catch [System.Net.WebException] {
    Write-Host 'WARNING: could not fetch SHA256SUMS, skipping verification' -ForegroundColor Yellow
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
