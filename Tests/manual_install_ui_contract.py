#!/usr/bin/env python3
"""Static guard for the per-registration manual-install UI wiring."""
from pathlib import Path
import sys


source = (Path(__file__).resolve().parents[1] / "Sources/main.swift").read_text(encoding="utf-8")
failures: list[str] = []

status_start = source.find("private func entryStatus(for entry: CLIEntry) -> String {")
status_end = source.find("\n    private func displayLocation", status_start)
status = source[status_start:status_end] if status_start >= 0 and status_end > status_start else ""
if "registrationInstallState" not in status:
    failures.append("manual status is not derived from this registration's installation state")
manual_status_start = status.find("let installState = registrationInstallState(for: entry)")
if manual_status_start < 0 or "authenticationUIState(for: entry)" not in status[manual_status_start:] or "detections.first(where:" in status[manual_status_start:]:
    failures.append("provider-wide discovery still changes a manual registration's status")

install_start = source.find("if let manualEntry = entry.manualEntry,\n                   manualEntry.provider == CLIProvider.codex.rawValue {\n                    let install = makeInstallButton")
install_end = source.find("\n                }\n                let separator", install_start)
install_row = source[install_start:install_end] if install_start >= 0 and install_end > install_start else ""
for expected, description in [
    ("install.target = self", "install button has no AppDelegate target"),
    ("#selector(installCLI(_:))", "install button has no real install action"),
    ("install.isEnabled = canInstall(manualEntry)", "install availability is not tied to the manual entry"),
]:
    if expected not in install_row:
        failures.append(description)
if "install.isEnabled = false" in install_row:
    failures.append("manual install button remains hard-disabled")

login_handler_start = source.find("@objc private func loginCLI(_ sender: NSButton) {")
login_handler_end = source.find("\n    private func showStoreFailure", login_handler_start)
login_handler = source[login_handler_start:login_handler_end] if login_handler_start >= 0 and login_handler_end > login_handler_start else ""
for expected, description in [
    ("entry.provider == CLIProvider.codex.rawValue", "login handler is not limited to a manual Codex registration"),
    ("service.registrationInstallStatus(for: entry) == .installed", "login can run before this UUID installation validates"),
    ("service.startAuthentication(for: entry)", "login handler does not use the isolated official CLI flow"),
    ("service.authenticationBrowserOpened(for: entry)", "login UI does not verify that the isolated Chrome profile opened"),
    ("process.terminate()", "login flow cannot be cancelled"),
    ("authenticationStatus(for: entry)", "successful process exit is not verified with isolated login status"),
]:
    if expected not in login_handler:
        failures.append(description)

awaiting_browser_start = login_handler.find("self.authenticationStates[entry.id] = .awaitingBrowser")
browser_marker_check = login_handler.find("service.authenticationBrowserOpened(for: entry)")
if browser_marker_check < 0 or awaiting_browser_start < 0 or browser_marker_check > awaiting_browser_start:
    failures.append("UI claims browser authentication is pending before Chrome confirms its isolated profile opened")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    raise SystemExit(1)

print("Manual install UI contract passed: per-registration install/login state and actionable Codex controls.")
