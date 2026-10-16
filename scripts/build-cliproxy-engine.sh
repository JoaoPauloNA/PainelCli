#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
version="v8.0.16"
commit="a2976eb8a303f11b4ea5177bce9f9ff752634dfc"
source_dir="${CLI_PROXY_SOURCE_DIR:-}"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/painelcli-cliproxy.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT

if ! command -v go >/dev/null 2>&1; then
    echo "Go 1.26+ is required to build the privately patched CLIProxyAPI engine." >&2
    echo "Install or select a Go toolchain, then rerun this script; it does not install one." >&2
    exit 2
fi
export GOTOOLCHAIN=local
go_version="$(go version | awk '{print $3}')"
if [[ ! "$go_version" =~ ^go1\.(2[6-9]|[3-9][0-9])\. ]]; then
    echo "Go 1.26+ is required; found $go_version." >&2
    exit 2
fi

if [[ -z "$source_dir" ]]; then
    git clone --quiet --filter=blob:none --no-checkout https://github.com/router-for-me/CLIProxyAPI.git "$temporary/source"
    git -C "$temporary/source" checkout --quiet --detach "$commit"
    source_dir="$temporary/source"
fi

actual_commit="$(git -C "$source_dir" rev-parse HEAD)"
if [[ "$actual_commit" != "$commit" ]]; then
    echo "Expected CLIProxyAPI $version at $commit; found $actual_commit." >&2
    exit 2
fi

cp -R "$source_dir" "$temporary/build"
git -C "$temporary/build" apply "$repo_root/Resources/CLIProxyAPI-loopback.patch"
mkdir -p "$repo_root/Resources"
go -C "$temporary/build" build -trimpath -buildvcs=false -ldflags='-s -w' -o "$repo_root/Resources/CLIProxyAPI" ./cmd/server
chmod 755 "$repo_root/Resources/CLIProxyAPI"
shasum -a 256 "$repo_root/Resources/CLIProxyAPI" | awk '{print $1}' > "$repo_root/Resources/CLIProxyAPI.sha256"
chmod 644 "$repo_root/Resources/CLIProxyAPI.sha256"
cp "$temporary/build/LICENSE" "$repo_root/Resources/CLIProxyAPI-LICENSE.txt"
echo "Built the private loopback-only CLIProxyAPI $version engine: $repo_root/Resources/CLIProxyAPI"
