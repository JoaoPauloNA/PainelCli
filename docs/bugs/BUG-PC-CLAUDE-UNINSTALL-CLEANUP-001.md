# BUG-PC-CLAUDE-UNINSTALL-CLEANUP-001 — Claude credential outlived managed package uninstall

BUG_ID: BUG-PC-CLAUDE-UNINSTALL-CLEANUP-001.
PROJECT: PainelCli.
STATUS: fixed in development build `0.0.0.32`; user account/browser/Keychain retest remains pending.
SNAPSHOT_BEFORE: `develop`, commit `071a698`, bundle `0.0.0.31`.
SCOPE: manual ClaudeCLI transition from installed to uninstalled to permanently removed.
SEVERITY: P1 for completion — a successful app uninstall removed the only managed binary able to call official logout, while later trash correctly refused to remove its config and row.

## Contract and root cause

Anthropic documents that `CLAUDE_CONFIG_DIR` scopes settings, credentials, session history, and plugins; on macOS it keys the encrypted Keychain entry to that config directory, and a session using another `CLAUDE_CONFIG_DIR` reads another entry. It also documents that Claude Code manages `.credentials.json` through login/logout. The old PainelCli uninstall deleted the managed package without first logging out. Consequently, trash could not run the supported credential operation and either left an orphan row/data tree or would have had to use an unsupported generic Keychain lookup.

The fix uses only the managed Claude executable and official `claude auth logout` with the exact UUID `CLAUDE_CONFIG_DIR`. It requires a fresh `auth status --json` response for the same config directory with `authMethod: "none"`. It then writes a private receipt bound to registration UUID and config path before removing the package. Later trash validates that receipt before deleting the UUID tree and row without reinstalling. Any logout, status, or receipt-write failure retains the package and row. If a package disappears outside PainelCli without a receipt, trash fails closed; it does not inspect or query Keychain items by generic service name.

Official sources: [Authentication and credential management](https://code.claude.com/docs/en/authentication) documents directory-keyed macOS Keychain scope and CLI login/logout management; [CLI reference](https://code.claude.com/docs/en/cli-reference) documents the supported auth commands.

## Regression and evidence

EXPECTED: Desinstalar asks for confirmation that Claude will locally log out and require login after reinstall, verifies logout while its package is available, and records cleanup proof. Lixeira after successful uninstall removes config, receipt, package residue, and row without reinstall. Unverified transitions retain the row and config.
BEFORE_FIX: synthetic runner test failed on `0.0.0.31` with exit 133 because uninstall did not invoke logout; the old flow could not pass the installed → uninstalled → trash scenario.
AFTER_FIX: `scripts/ci-check.sh` covers successful transition, simulated logout failure (package/row retained), trash without reinstall after success, and a package-missing/no-receipt state (row/config retained until managed repair). Full test result recorded in `DadosTeste/2084-PainelCli-ClaudeCLI-UUID-20261016/cleanup-transition-report.txt`.
TEST_LIMITS: only synthetic npm/CLI/status runners and a fake Keychain effect represented by the synthetic CLI auth state; no real npm, Claude CLI, Keychain, account, browser, login/logout, or model request executed.
RETEST: João must confirm real Claude.ai login, UUID-scoped status and logout, and Safari behavior manually. Keychain scope is based on current official documentation; no Keychain service identifier is assumed.
