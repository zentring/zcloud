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

# resolve_stable_tag prints the newest stable tag. It tries the JSON API first,
# then falls back to the web redirect on github.com — the same host the binary
# download uses, so if that's reachable the redirect resolves too. Either source
# surviving keeps `stable` installs working through a one-host 504. Prints the
# tag on stdout; returns non-zero only when both sources fail.
resolve_stable_tag() {
    api="https://api.github.com/repos/${REPO}/releases/latest"
    if rel="$(retry_curl -fsSL -H 'User-Agent: zcloud-installer' "$api" 2>/dev/null)"; then
        t="$(printf '%s' "$rel" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
        if [ -n "$t" ]; then printf '%s' "$t"; return 0; fi
    fi
    printf '  API lookup failed; falling back to release redirect\n' >&2
    latest="https://github.com/${REPO}/releases/latest"
    # -L follows the 302; %{url_effective} prints the final /releases/tag/<tag> URL.
    if loc="$(retry_curl -fsSL -o /dev/null -w '%{url_effective}' "$latest" 2>/dev/null)"; then
        t="$(printf '%s' "$loc" | sed -n 's#.*/releases/tag/\([^/]*\)$#\1#p')"
        if [ -n "$t" ]; then printf '%s' "$t"; return 0; fi
    fi
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
# redirect resolver. `stable` resolves via two independent sources (API, then
# web redirect) so a 504 on either doesn't tank the install.
case "$CHANNEL" in
    stable)
        say "Resolving latest stable release"
        tag="$(resolve_stable_tag)" \
            || die "could not resolve latest stable tag (API and redirect both failed)"
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
