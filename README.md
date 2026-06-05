# zcloud

The command-line tool for the [Zentring Cloud](https://console.zentring.net) platform. Manage compute, networking, DNS and other resources from your terminal.

This repository hosts the **public binary distribution** — the source lives elsewhere. Releases are mirrored here automatically on every push to `main` (rolling prereleases) and on tag (stable releases).

## Install

**Linux / macOS**

```bash
curl -fsSL https://raw.githubusercontent.com/zentring/zcloud/main/install.sh | sh
```

**Windows (PowerShell)**

```powershell
iwr -useb https://raw.githubusercontent.com/zentring/zcloud/main/install.ps1 | iex
```

The script auto-detects OS + architecture, verifies SHA256, drops the binary in a per-user location, and ensures it's on PATH.

To pin a version or grab the rolling build:

```bash
ZCLOUD_CHANNEL=v0.6.0 curl -fsSL .../install.sh | sh   # specific tag
ZCLOUD_CHANNEL=rolling curl -fsSL .../install.sh | sh  # latest main
```

## First-run

```bash
zcloud login                 # opens a browser to authorize
zcloud whoami                # confirm you're connected
zcloud paas service list     # list your Zentring RUN services
zcloud console paas-xxx      # open an interactive shell into a pod
zcloud --help                # full command tree
```

The CLI auto-detects your OS language; set `ZCLOUD_LANG=en-US` or `zh-TW` to override. Run `zcloud config set language zh-TW` to persist.

## Direct download

If the install scripts aren't your style, grab a binary from the [latest release](https://github.com/zentring/zcloud/releases/latest):

```
zcloud-linux-amd64
zcloud-linux-arm64
zcloud-darwin-amd64
zcloud-darwin-arm64
zcloud-windows-amd64.exe
SHA256SUMS
```

Permanent stable URL (always resolves to the most recent tagged release):

```
https://github.com/zentring/zcloud/releases/latest/download/zcloud-<os>-<arch>[.exe]
```

## Issues

CLI bugs / feature requests go through the Zentring support channel — this repo only hosts binaries.
