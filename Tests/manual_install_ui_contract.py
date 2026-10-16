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
manual_status_start = status.find("return registrationInstallState(for: entry)")
if manual_status_start < 0 or "detections.first(where:" in status[manual_status_start:]:
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

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    raise SystemExit(1)

print("Manual install UI contract passed: per-registration status and actionable Codex install control.")
