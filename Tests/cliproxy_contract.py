#!/usr/bin/env python3
"""Static contract for the manual, UUID-verified CLIProxy-ready list."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/main.swift").read_text(encoding="utf-8")
store = (root / "Sources/CLIEntryStore.swift").read_text(encoding="utf-8")
failures: list[str] = []

def block(start: str, end: str, text: str = source) -> str:
    first = text.find(start)
    last = text.find(end, first + len(start)) if first >= 0 else -1
    return text[first:last] if first >= 0 and last > first else ""

proxy_renderer = block("private func renderCLIProxy(in body: NSView)",
                       "private func addCLIProxyEmptyMessage")
ready_filter = block("enum CLIProxyReadiness", "struct CLIEntryStore", store)
current_ready = block("private func currentCLIProxyReadyEntries()", "private func cliSymbol()")
status_refresh = block("private func refreshAuthenticationStatuses(forceIDs:",
                        "private func beginCLIProxyStatusRefresh")
proxy_refresh = block("private func beginCLIProxyStatusRefresh()", "private func refreshCLIProxySnapshotIfVisible")
manual_reload = block("private func reloadManualRegistrationsForCLIProxy()", "@objc private func removeCLI")
show_proxy = block("@objc private func showCLIProxy()", "@objc func openWindow()")

for text, message in [
    ("currentCLIProxyReadyEntries()", "CLIProxy rows are not derived from current installation state"),
    (".loading", "CLIProxy screen lacks a loading state"),
    ("case .loaded", "CLIProxy screen lacks a resolved state"),
    ("storageUnavailable", "CLIProxy screen lacks a storage failure state"),
    ("Nenhuma CLI manual está instalada e autenticada", "CLIProxy empty state is unclear"),
]:
    if text not in proxy_renderer:
        failures.append(message)
if "automaticInstallations" in proxy_renderer or "detections" in proxy_renderer or "listItems" in proxy_renderer:
    failures.append("CLIProxy presentation mixes detected or global installations into its list")
if "entryStore.load()" not in manual_reload or "detectedInstallations" in manual_reload:
    failures.append("opening CLIProxy reads global executable discovery instead of manual records only")
if "reloadManualRegistrationsForCLIProxy()" not in show_proxy or "beginCLIProxyStatusRefresh()" not in show_proxy:
    failures.append("opening CLIProxy does not refresh its manual rows and isolated statuses")
if "CLIProxyReadiness.readyEntries" not in current_ready or "entry.origin == .manual" not in ready_filter or \
        "entry.provider == CLIProvider.codex.rawValue" not in ready_filter or \
        "entry.provider == CLIProvider.claude.rawValue" not in ready_filter or \
        "installedIDs.contains(entry.id)" not in ready_filter or \
        "authenticationStates[entry.id] == .authenticated" not in ready_filter:
    failures.append("readiness filter does not require manual Codex/Claude, installed UUID, and confirmed authentication")
if "CLIProvider.antigravity.rawValue" in ready_filter:
    failures.append("Antigravity is included despite its deferred authentication support")
if "registrationInstallStatus(for: $0) == .installed" not in proxy_refresh or \
        "authenticationProcesses[$0.id]?.isRunning != true" not in proxy_refresh:
    failures.append("status refresh does not require an installed, idle managed registration")
if "service.authenticationStatus(for: entry)" not in status_refresh or \
        "service.claudeAuthenticationStatus(for: entry)" not in status_refresh or \
        "entry.provider == CLIProvider.claude.rawValue" not in status_refresh:
    failures.append("status refresh does not use the provider's existing UUID-isolated contract")
if "agy" in status_refresh or "Antigravity" in status_refresh or "keychain" in status_refresh.lower():
    failures.append("CLIProxy status refresh attempts unsupported Antigravity or credential-store inspection")
if "authenticationCheckRevisions[entry.id] == revision" not in status_refresh:
    failures.append("late status responses can restore a stale authenticated snapshot")

for selector, method_name in [
    ("@objc private func removeCLI", "remove"),
    ("@objc private func installCLI", "install"),
    ("@objc private func loginCLI", "login"),
    ("@objc private func logoutCLI", "logout"),
    ("@objc private func uninstallCLI", "uninstall"),
]:
    next_selector = source.find("@objc private func ", source.find(selector) + len(selector))
    first = source.find(selector)
    handler = source[first:next_selector] if first >= 0 and next_selector > first else ""
    if "invalidateAuthenticationCheck(for: entry.id)" not in handler:
        failures.append(f"{method_name} does not invalidate an older per-UUID status result")
    if method_name in {"remove", "install", "logout", "uninstall"} and \
            "refreshCLIProxySnapshotIfVisible()" not in handler:
        failures.append(f"{method_name} does not refresh the visible CLIProxy snapshot after completion")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    raise SystemExit(1)

print("CLIProxy contract passed: manual UUIDs only, installed and authenticated, stale results rejected.")
