#!/bin/sh
# install.sh — fetch the latest zcloud binary, verify its checksum, drop it on
# PATH. Idempotent; safe to re-run to upgrade. Linux + macOS, amd64 + arm64.
#
# Channels (via env):
#   ZCLOUD_CHANNEL=stable   # default — latest semver release
#   ZCLOUD_CHANNEL=rolling  # bleeding edge from main
#   ZCLOUD_CHANNEL=v0.1.0   # pin to a specific tag

set -eu

REPO="zentring/zcloud"
BIN_NAME="zcloud"
CHANNEL="${ZCLOUD_CHANNEL:-stable}"

die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }

require() {
    command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

require curl
require uname

# retry_curl runs curl with the given args up to 4 times with exponential
# backoff. Every release/api hit goes through this because GitHub's
# `releases/latest/*` redirect resolver occasionally returns 504; without
# retry a single CDN hiccup tanks the install.
retry_curl() {
    delay=1
    i=1
    max=4
    while [ "$i" -le "$max" ]; do
        if curl --connect-timeout 15 --max-time 120 "$@"; then
            return 0
        fi
        if [ "$i" -eq "$max" ]; then
            return 1
        fi
        printf '  attempt %d/%d failed, retrying in %ds\n' "$i" "$max" "$delay" >&2
        sleep "$delay"
        delay=$(( delay * 2 ))
        [ "$delay" -gt 8 ] && delay=8
        i=$(( i + 1 ))
    done
    return 1
}

case "$(uname -s)" in
    Linux)  os="linux"  ;;
    Darwin) os="darwin" ;;
    *) die "unsupported OS: $(uname -s) — try downloading a binary from https://github.com/${REPO}/releases" ;;
esac

case "$(uname -m)" in
    x86_64|amd64)   arch="amd64" ;;
    arm64|aarch64)  arch="arm64" ;;
    *) die "unsupported arch: $(uname -m)" ;;
esac

# Resolve a concrete tag so subsequent URLs skip the `releases/latest/download`
# redirect resolver. That resolver is the recurring 504 source on stable
# installs; the per-tag URL pattern doesn't go through it.
case "$CHANNEL" in
    stable)
        say "Resolving latest stable release"
        api="https://api.github.com/repos/${REPO}/releases/latest"
        rel="$(retry_curl -fsSL -H 'User-Agent: zcloud-installer' "$api" 2>/dev/null)" \
            || die "could not resolve latest tag from ${api}"
        tag="$(printf '%s' "$rel" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
        [ -n "$tag" ] || die "release lookup returned no tag_name"
        ;;
    rolling) tag="rolling" ;;
    *)       tag="$CHANNEL" ;;
esac
base="https://github.com/${REPO}/releases/download/${tag}"

asset="zcloud-${os}-${arch}"
url="${base}/${asset}"
sums_url="${base}/SHA256SUMS"

# Pick a writable install location without escalating unless we have to.
if [ -w "/usr/local/bin" ]; then
    install_dir="/usr/local/bin"
elif [ "$(id -u)" -eq 0 ]; then
    install_dir="/usr/local/bin"
else
    install_dir="${HOME}/.local/bin"
    mkdir -p "$install_dir"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp" "${tmp}.sums" 2>/dev/null || true' EXIT INT TERM

say "Downloading ${asset} (${tag})"
if ! retry_curl -fSL --progress-bar "$url" -o "$tmp"; then
    die "download failed: ${url}"
fi

# SHA256 verification is best-effort: missing SHA256SUMS shouldn't block install
# (some pinned tags might predate the bundle), but a mismatch must abort.
if retry_curl -fsSL "$sums_url" -o "${tmp}.sums" 2>/dev/null; then
    expected="$(awk -v a="$asset" '$2 == a || $2 == "*"a { print $1 }' "${tmp}.sums")"
    if [ -n "$expected" ]; then
        if command -v sha256sum >/dev/null 2>&1; then
            actual="$(sha256sum "$tmp" | awk '{print $1}')"
        else
            actual="$(shasum -a 256 "$tmp" | awk '{print $1}')"
        fi
        [ "$expected" = "$actual" ] || die "checksum mismatch — expected $expected, got $actual"
        say "Checksum verified"
    fi
fi

dest="${install_dir}/${BIN_NAME}"
mv "$tmp" "$dest"
chmod +x "$dest"
trap - EXIT
say "Installed to ${dest}"

case ":${PATH}:" in
    *":${install_dir}:"*) ;;
    *)
        printf '\nNOTE: %s is not in your PATH.\n' "$install_dir"
        printf 'Add this line to your shell rc (~/.bashrc, ~/.zshrc, etc.):\n\n'
        printf '    export PATH="%s:$PATH"\n\n' "$install_dir"
        ;;
esac

"$dest" version 2>/dev/null || true
