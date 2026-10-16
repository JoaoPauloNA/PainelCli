#!/usr/bin/env python3
"""Static guard for the UUID-scoped Codex install/authentication UI."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/main.swift").read_text(encoding="utf-8")
installer = (root / "Sources/CLIInstaller.swift").read_text(encoding="utf-8")
failures: list[str] = []

row_start = source.find("if let manualEntry = entry.manualEntry,\n                   manualEntry.provider == CLIProvider.codex.rawValue {")
row_end = source.find("\n                }\n                let separator", row_start)
row = source[row_start:row_end] if row_start >= 0 and row_end > row_start else ""
for expected, message in [
    ("state == .installed", "installed UUID state is not distinguished in its action row"),
    ("#selector(uninstallCLI(_:))", "installed UUID action does not invoke scoped uninstall"),
    ("canUninstall(manualEntry)", "uninstall availability is not scoped to the registration"),
    ("#selector(installCLI(_:))", "noninstalled UUID action does not invoke install"),
    ("setAccessibilityLabel", "install actions lack accessibility labels"),
    ("install.toolTip", "install actions lack explanatory tooltips"),
]:
    if expected not in row:
        failures.append(message)
if 'NSButton(title: "Instalar"' in source or 'title: "Código"' in source:
    failures.append("install controls are not icons-only or the removed Code route remains visible")
if "service.uninstall(entry: entry)" not in source or "service.logout(for: entry)" not in source:
    failures.append("UUID-scoped uninstall and logout service operations are not wired")
if "service.startAuthentication(for: entry)" not in source:
    failures.append("login does not use the isolated browser-based app-server flow")
if "logoutCLI(_:)" not in source or "authState == .authenticated" not in source:
    failures.append("authenticated state does not expose the logout action")
if "A CLI não confirmou a saída" not in source or "authenticationStatus(for: entry)" not in source:
    failures.append("logout failures are not followed by an isolated status verification")
if "Sair deste cadastro?" not in source or "Isso não revoga a sessão remotamente" not in source:
    failures.append("logout confirmation does not explain local credential scope")
if "Somente o pacote gerenciado por este UUID será removido" not in source or "serão preservados" not in source:
    failures.append("uninstall confirmation does not explain package/data scope")
if "case .statusError" not in source or "state = .statusError" not in source:
    failures.append("indeterminate authentication status can be confused with signed-out state")
if 'method: "account/login/start", params: ["type": "chatgpt"]' not in installer:
    failures.append("browser OAuth is not the sole app-server login route")
if "CLIDeviceCode" in installer or "NSPasteboard" in source or 'title: "Código"' in source:
    failures.append("the removed device-code/clipboard UI route remains")
if 'open.standardError = FileHandle.nullDevice' not in installer:
    failures.append("authentication subprocess diagnostics could expose login flow output")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    raise SystemExit(1)

print("Manual install UI contract passed: icons-only scoped install, uninstall, browser login, and verified logout.")
