#!/usr/bin/env python3
"""Static contract for independent, loopback-only CLIProxy profiles."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/CLIProxy.swift").read_text(encoding="utf-8")
ui = (root / "Sources/main.swift").read_text(encoding="utf-8")
patch_text = (root / "Resources/CLIProxyAPI-loopback.patch").read_text(encoding="utf-8")
added_patch = "\n".join(line[1:] for line in patch_text.splitlines()
                          if line.startswith("+") and not line.startswith("+++"))
failures: list[str] = []

def require(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)

profile_store = source[source.index("struct CLIProxyProfileStore"):source.index("private extension JSONEncoder")]
manager = source[source.index("final class CLIProxyManager"):]
proxy_ui = ui[ui.index("private func renderCLIProxy(in body:"):ui.index("private func detectedAppearance(for target:")]
visible_refresh = ui[ui.index("private func refreshEntriesForVisibleSection()"):ui.index("private func invalidateAuthenticationCheck")]
show_proxy = ui[ui.index("@objc private func showCLIProxy()"):ui.index("@objc func openWindow()")]

require('"profiles.json"' in profile_store and '"instances"' not in profile_store,
        "CLIProxy keeps profile metadata in its own profile store")
require("CLIProxyProfile(provider: provider" in profile_store and "while used.contains(ordinal)" in profile_store,
        "CLIProxy creates its own UUIDs and smallest-free per-provider ordinals")
require("provider.supported" in profile_store and "var supported: Bool { self != .antigravity }" in source,
        "Antigravity remains unavailable in the CLIProxy catalog")
require("host: 127.0.0.1" in source and "allow-remote: false" in source and
        "disable-control-panel: true" in source and "auth-dir:" in source,
        "proxy configuration is loopback-only with a private UUID-scoped auth directory")
require("Bundle.main.url(forResource: \"CLIProxyAPI\"" in source and
        "validatesBundledEngine" in manager and "GitHubCLIProxyArtifactLoader" not in source,
        "runtime installs only the digest-verified app-bundled patched engine")
require("/v8/management/oauth/auth-url" not in source and 'route: "oauth/auth-url"' in source and
        'route: "oauth/status"' in source and 'route: "oauth/session"' in source and
        'route: "credentials"' in source,
        "management calls use the maintained v8 OAuth and credential routes")
require("flock(descriptor, LOCK_EX | LOCK_NB)" in source and "oauth-\\(provider).lock" in source,
        "fixed provider callback ports are serialized across profiles and app processes")
require("auth.openai.com" in source and "claude.ai" in source and
        "components.scheme?.lowercased() == \"https\"" in source,
        "OAuth URLs require HTTPS and the expected provider host")
require('($0["status"] as? String)?.lowercased() == "active"' in source and
        '($0["disabled"] as? Bool) != true' in source and
        '($0["unavailable"] as? Bool) != true' in source,
        "profile readiness reads the engine's active credential state rather than native CLIs")
require("try stop(profile: profile)" in manager and "processIdentityMatches(record)" in manager,
        "profile removal stops only its verified process")
require("currentCLIProxyReadyEntries" not in proxy_ui and "CLIEntry" not in proxy_ui and
        "entries" not in proxy_ui and "CLIProvider" not in proxy_ui and
        "cliProxyProfiles" in proxy_ui and "openCLIProxyCatalog" in proxy_ui,
        "CLIProxy UI uses only its own profile collection and catalog")
require("Antigravity" in proxy_ui and "Indisponível" in proxy_ui,
        "CLIProxy catalog explicitly disables Antigravity")
for action in ["prepareCLIProxyProfile", "activateCLIProxyProfile", "stopCLIProxyProfile",
               "loginCLIProxyProfile", "checkCLIProxyOAuth", "cancelCLIProxyOAuth",
               "removeCLIProxyProfile"]:
    require(f"@objc private func {action}" in ui, f"CLIProxy action {action} is wired")
require("reloadCLIProxyProfiles()" in show_proxy and "refreshCLIProxyStatuses()" in show_proxy and
        "reloadManualRegistrationsForCLIProxy" not in show_proxy,
        "opening CLIProxy loads and refreshes only its own collection")
require("selectedSettingsSection == .add" in visible_refresh and "cliProxyProfiles" not in visible_refresh,
        "native CLI refresh never populates the CLIProxy profile list")

require('net.LookupIP("localhost")' in added_patch and "address.IsLoopback()" in added_patch and
        "Serve(listener)" in added_patch and "0.0.0.0" not in added_patch and
        'http://localhost:%d' not in added_patch,
        "the upstream patch binds every OAuth listener to verified loopback addresses and preserves redirects")

# Visual contract: independent profile presentation must follow the compact actions pattern.
require("applyActionAppearance(button)" in proxy_ui and "button.toolTip =" in proxy_ui and
        "button.setAccessibilityLabel" in proxy_ui,
        "proxy actions use shared icon-only styling and accessible names")
require("proxyProviderAppearance" in proxy_ui and "identity.widthAnchor.constraint(equalToConstant: 150)" not in proxy_ui,
        "proxy provider identity stays recognizable and resizes with the list")
require("applyActionAppearance(remove)" in proxy_ui and "remove.contentTintColor = .systemRed" in proxy_ui,
        "proxy removal uses the shared compact red-trash presentation")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    raise SystemExit(1)

print("CLIProxy contract passed: separate profiles, patched engine, loopback OAuth, and profile actions.")
