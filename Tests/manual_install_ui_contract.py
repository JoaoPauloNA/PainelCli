#!/usr/bin/env python3
"""Static guard for the UUID-scoped Codex install/authentication UI."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/main.swift").read_text(encoding="utf-8")
installer = (root / "Sources/CLIInstaller.swift").read_text(encoding="utf-8")
failures: list[str] = []

remove_start = source.find("@objc private func removeCLI(_ sender: NSButton) {")
remove_end = source.find("\n    @objc private func installCLI", remove_start)
remove_handler = source[remove_start:remove_end] if remove_start >= 0 and remove_end > remove_start else ""
if "service.removeRegistration(entry:" not in remove_handler:
    failures.append("trash action removes a manual row without uninstalling its UUID-managed package")
remove_call = remove_handler.find("service.removeRegistration(entry:")
store_call = remove_handler.find("entryStore.remove(id:")
if store_call < 0 or remove_call < 0 or store_call < remove_call:
    failures.append("trash action does not sequence scoped uninstall before persistent row removal")
cancel_index = remove_handler.find('alert.addButton(withTitle: "Cancelar")')
destructive_index = remove_handler.find('alert.addButton(withTitle: "Remover definitivamente")')
if cancel_index < 0 or destructive_index < 0 or cancel_index > destructive_index or \
        'alert.runModal() == .alertSecondButtonReturn' not in remove_handler:
    failures.append("trash confirmation lacks a safe cancel default and a distinct destructive choice")
if "hasDestructiveAction = true" not in remove_handler or "Não pode ser desfeita" not in remove_handler:
    failures.append("trash confirmation does not clearly mark irreversible removal")
if "login local" not in remove_handler or "logout" not in remove_handler or "outros cadastros" not in remove_handler:
    failures.append("trash confirmation does not state local-auth scope or avoid remote logout claims")
if "listItems[sender.tag].manualEntry" not in remove_handler:
    failures.append("trash action is not restricted to manual registrations")
if "activeRemovalIDs.insert(entry.id)" not in remove_handler:
    failures.append("trash action does not serialize repeated UI clicks while deletion runs")
confirm_index = remove_handler.find("alert.runModal() == .alertSecondButtonReturn")
active_remove_index = remove_handler.find("activeRemovalIDs.insert(entry.id)")
if confirm_index < 0 or active_remove_index < confirm_index or \
        remove_handler.find("service.removeRegistration(entry:") < active_remove_index:
    failures.append("trash side effects can begin before the user chooses the destructive confirmation")
removal_start = installer.find("func removeRegistration(entry: CLIEntry, removeRecord: () throws -> Void) throws {")
removal_end = installer.find("\n    private func removeManagedPackageAndManifest", removal_start)
removal_service = installer[removal_start:removal_end] if removal_start >= 0 and removal_end > removal_start else ""
if "acquireRegistrationLock(for: entry)" not in removal_service or "symlinksStayInside(directory)" not in removal_service:
    failures.append("UUID deletion does not share the operation lock and reject symlink escapes")
if "removeRecord()" not in removal_service or removal_service.find("removeRecord()") < removal_service.find("!fileManager.fileExists"):
    failures.append("persistent row removal can occur before the UUID directory is confirmed absent")
if "func startAuthentication" in installer and "operationLock: operationLock" not in installer:
    failures.append("browser authentication does not hold the UUID lock for the active process lifetime")

row_start = source.find("if let manualEntry = entry.manualEntry,\n                   manualEntry.provider == CLIProvider.codex.rawValue ||")
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
uninstall_start = installer.find("func uninstall(entry: CLIEntry) throws")
uninstall_end = installer.find("func removeRegistration(entry: CLIEntry", uninstall_start)
uninstall_body = installer[uninstall_start:uninstall_end] if uninstall_start >= 0 and uninstall_end > uninstall_start else ""
logout_before_package = uninstall_body.find("logoutClaudeWhileLocked(for: entry)")
receipt_before_package = uninstall_body.find("writeClaudeCleanupReceipt(for: entry)")
package_removal = uninstall_body.find("removeManagedPackageAndManifest(for: entry)")
if not (0 <= logout_before_package < receipt_before_package < package_removal):
    failures.append("Claude uninstall does not verify logout and persist cleanup receipt before package removal")
if "service.logoutClaude(for: entry)" not in source or "service.startClaudeAuthentication(for: entry)" not in source:
    failures.append("Claude official auth login/logout are not wired to its UUID-scoped service")
if '"auth", "status", "--json"' not in installer or '"auth", "logout"' not in installer:
    failures.append("Claude status/logout do not use the documented noninteractive CLI commands")
if '"CLAUDE_CONFIG_DIR": paths.config.path' not in installer or "claude-config" not in installer:
    failures.append("Claude settings, credentials, and history are not assigned a UUID config directory")
if '@anthropic-ai/claude-code@latest' not in installer or '"--prefix"' not in installer:
    failures.append("Claude package install is not pinned to the owned local npm prefix")
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
if "O Claude Code executará o logout oficial neste UUID" not in source or \
        "o pacote e o cadastro serão mantidos" not in source:
    failures.append("Claude uninstall confirmation does not disclose verified logout and failure retention")
if "case .statusError" not in source or "state = .statusError" not in source:
    failures.append("indeterminate authentication status can be confused with signed-out state")
if 'method: "account/login/start", params: ["type": "chatgpt"]' not in installer:
    failures.append("browser OAuth is not the sole app-server login route")
if "CLIDeviceCode" in installer or "NSPasteboard" in source or 'title: "Código"' in source:
    failures.append("the removed device-code/clipboard UI route remains")
if 'open.standardError = FileHandle.nullDevice' not in installer:
    failures.append("authentication subprocess diagnostics could expose login flow output")

# BUG-PC-ACTION-UI-001: presentation-only contract; functional guards above stay mandatory.
for control in ["account", "remove", "install"]:
    if f"applyActionAppearance({control})" not in source:
        failures.append(f"{control} does not share the compact icon-only presentation")
if "button.imagePosition = .imageOnly" not in source:
    failures.append("shared action presentation does not enforce icons-only")
if 'actionSymbol = "shippingbox"' not in row:
    failures.append("uninstall is not visually distinct from removing a registration")
if 'remove.setAccessibilityValue(remove.isEnabled ? "Disponível" : "Inativo")' not in source:
    failures.append("disabled remove control can announce itself as available")

# BUG-PC-INSTALL-PROGRESS-001: loading must follow the existing operation state.
for expected, message in [
    ("install.isHidden = state == .installing", "busy installation still shows a static action icon"),
    ("if state == .installing {", "loading presentation is not conditional on the existing installation state"),
    ("makeInstallationProgress()", "busy installation has no native progress presentation"),
]:
    if expected not in row:
        failures.append(message)
if "progress.style = .spinning" not in source or "progress.startAnimation(nil)" not in source:
    failures.append("native indeterminate installation spinner is missing")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    raise SystemExit(1)

print("Manual install UI contract passed: icons-only scoped install, uninstall, browser login, and verified logout.")
