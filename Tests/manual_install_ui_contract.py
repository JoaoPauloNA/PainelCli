#!/usr/bin/env python3
"""Static guard for the per-registration manual-install UI wiring."""
from pathlib import Path
import sys


root = Path(__file__).resolve().parents[1]
source = (root / "Sources/main.swift").read_text(encoding="utf-8")
installer = (root / "Sources/CLIInstaller.swift").read_text(encoding="utf-8")
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
    ("service.startAuthentication(for: entry, mode: mode)", "login handler does not use the isolated official CLI app-server"),
    ("@objc private func loginCLIWithDeviceCode(_ sender: NSButton)", "device-code login is not an explicit alternative action"),
    ("service.openDeviceAuthenticationPage(", "login UI does not open the official device page in Safari"),
    ("process.terminate()", "login flow cannot be cancelled"),
    ("authenticationStatus(for: entry)", "successful process exit is not verified with isolated login status"),
]:
    if expected not in login_handler:
        failures.append(description)

awaiting_code_start = login_handler.find("self.authenticationStates[entry.id] = .awaitingUserCode(")
handoff_call = login_handler.find("handoff.handle(prompt: prompt")
if handoff_call < 0 or awaiting_code_start < 0 or handoff_call > awaiting_code_start:
    failures.append("UI displays a device code before the official Safari page is opened")

if "copyCode: self?.writeDeviceCodeToClipboard" not in login_handler:
    failures.append("device code is not copied to the clipboard during the active login handoff")
if "pasteboard.setString(code, forType: .string)" not in source:
    failures.append("device-code clipboard write is not wired to the system pasteboard")
if "CLIDeviceCodeHandoff" not in login_handler or "clipboardCopied: result.clipboardCopied" not in login_handler:
    failures.append("device-code handoff does not track a single clipboard-copy outcome")
if "pasteboard.string(forType:" in source or "pasteboard.readObjects" in source:
    failures.append("login flow reads clipboard contents")
if 'case .browser: return "chatgpt"' not in installer or 'case .deviceCode: return "chatgptDeviceCode"' not in installer:
    failures.append("browser OAuth is not the default account login mode with an explicit device-code alternative")
if "loginCLI(sender, mode: .browser)" not in login_handler or '"account/login/completed"' not in login_handler or 'params["loginId"] as? String == activeLoginID' not in login_handler:
    failures.append("primary browser login or same-attempt completion validation is missing")
if "copyCode(prompt.code)" not in installer or "openPage(prompt.verificationURL)" not in installer:
    failures.append("device-code handoff does not copy before opening the verification page")
elif installer.find("copyCode(prompt.code)") > installer.find("openPage(prompt.verificationURL)"):
    failures.append("device code is sent to Safari before the clipboard write")
for expected in ["Falha ao copiar. Digite o código no Safari:",
                 "Falha ao copiar e abrir a página. Digite o código manualmente:"]:
    if expected not in installer:
        failures.append("clipboard or browser failure does not preserve manual code recovery")

if '["app-server", "--stdio"]' not in installer or 'method: "account/login/start"' not in installer:
    failures.append("authentication does not use the official Codex app-server login contract")
if "open.standardError = FileHandle.nullDevice" not in installer:
    failures.append("authentication subprocess diagnostics could expose login flow output")
if '"/Applications/Safari.app"' not in installer or '"https://auth.openai.com/codex/device"' not in installer:
    failures.append("Safari launch is not bound to the official device URL")
if "session.output.fileHandleForReading" not in login_handler or "handle.availableData" not in login_handler:
    failures.append("device-code output reader can wait for a full buffer while the CLI waits for the user")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    raise SystemExit(1)

print("Manual install UI contract passed: per-registration install/login state, clipboard handoff, and actionable Codex controls.")
