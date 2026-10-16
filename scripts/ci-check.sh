#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/painelcli-ci.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

xcrun swiftc \
  "$repo_root/Sources/CLIEntryStore.swift" \
  "$repo_root/Sources/CLIInstaller.swift" \
  "$repo_root/Sources/main.swift" \
  -framework AppKit \
  -o "$temp_dir/PainelCli"

xcrun swiftc \
  "$repo_root/Sources/CLIEntryStore.swift" \
  "$repo_root/Sources/CLIInstaller.swift" \
  "$repo_root/Tests/main.swift" \
  -o "$temp_dir/PainelCliTests"

"$temp_dir/PainelCliTests"
python3 "$repo_root/Tests/manual_install_ui_contract.py"
python3 "$repo_root/Tests/cli_icon_contract.py"
python3 "$repo_root/Tests/cliproxy_contract.py"
echo "AppKit compile, isolated installer tests, UI contracts, icon contract, and CLIProxy contract passed. No real CLI or npm command was run."
