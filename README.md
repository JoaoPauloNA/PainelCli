# PainelCli

PainelCli is an experimental native macOS AppKit app that discovers Codex CLI, Claude Code, Gemini CLI, and Antigravity CLI while keeping a separate list of manual registrations. Discovery checks executable files in the running app's `PATH`, common macOS/user locations, the ChatGPT-bundled Codex path, and legacy PainelCli-managed paths. Antigravity uses the official `agy` executable; Gemini CLI remains a distinct detection target and is never relabeled as Antigravity. Discovery never runs a CLI or authenticates and is not a universal inventory.

The compact list has two groups: **Instalações detectadas** displays unnumbered installation names, with visible but disabled account and trash controls and no active delete or hide actions; **Cadastros manuais** displays per-provider numbered registrations with a remove action. Manual ordinals start at zero independently for each provider, and new registrations take the smallest unused ordinal. Automatic rows follow the current filesystem inventory and have stable identities per target/discovery path; they never occupy manual ordinals. Adding a catalog entry always creates a manual registration, even when an installation of the same provider is already visible. Removing a manual registration never suppresses an automatic discovery or uninstalls a CLI. Legacy automatic registrations and hidden-discovery metadata are migrated by the store snapshot API. Manual IDs are preserved; legacy manual ordinals are compacted once per provider in their previous ordinal order.

The manual-registration catalog is exactly CodexCLI, ClaudeCLI, and Antigravity CLI. Selecting a catalog item records metadata only. CodexCLI installs and authenticates per registration through the official CLI, with a UUID-scoped package directory, `CODEX_HOME`, and credential file. The account button is enabled only for an installed manual Codex registration. Login status is confirmed with `codex login status` in that instance and requires a private `auth.json`; CLI discovery never enables login. Claude and Antigravity installation/login remain unavailable. Legacy GeminiCLI registrations migrate to Antigravity only when no real Gemini executable is detected and the migrated ordinal does not collide; otherwise they remain intact and the app asks for an explicit decision.

**Status: development. No production version has been approved.** Version 0.0.0.27 is the current development baseline. The `develop` branch contains the app; `main` contains production policy and remains without an approved app release. A production promotion requires passing technical checks and the project owner's explicit functional acceptance. Promotion happens through a pull request; CI does not tag, publish, or deploy a release.

## Build and test

Requirements: macOS, Xcode Command Line Tools, Swift, and Python 3. Run `python3 scripts/build-open.py` to compile the app, keep the current and previous local bundles, and open the app. Run `scripts/ci-check.sh` to compile the AppKit executable and run the isolated store/installer test suite without opening the app. GitHub Actions runs the same check on macOS for pushes and pull requests to `main` and `develop`.

The test suite uses temporary synthetic files and an injected npm runner to verify per-registration paths, isolated config/auth storage, correct status, concurrency, and failure handling. It never runs a real CLI, npm installer, or login flow.

## CLI installation limits

Codex installation uses the official `@openai/codex` npm package in a local prefix under a directory keyed by registration UUID. Each install receives a private child `HOME`, `CODEX_HOME`, npm cache and npm config files; the Codex home selects `cli_auth_credentials_store = "file"`, which stores auth under that instance's `CODEX_HOME/auth.json`. PainelCli never changes the host's `HOME`, `CODEX_HOME`, `~/.codex`, npm config, or credentials. Installation runs asynchronously, uses a fixed argument list and an isolated staging directory, and is reported successful only after the executable and UUID-bound manifest validate. Login uses the official Codex app-server authentication contract in a credential-free allowlisted environment. The normal ChatGPT browser OAuth flow is the primary login action and opens its validated official auth URL in Safari. A separate, explicit “Código” action selects device-code authentication; PainelCli copies only that active synthetic-or-runtime code to the system clipboard before opening the fixed verification page, and reports copy failures with manual-entry instructions. It never reads or logs clipboard contents or auth URLs. PainelCli checks local/MDM policy before login and confirms authentication only when the isolated CLI status succeeds and a private regular `auth.json` exists in that UUID's Codex home. Claude and Antigravity stay unsupported and have no install or login controls.

The catalog no longer creates GeminiCLI registrations. Existing GeminiCLI registration metadata is migrated only under the safe conditions described above; the app does not read, copy, or alter Gemini or Antigravity credentials/configuration. Codex installation and its per-registration file credential setting follow the [Codex CLI quickstart](https://developers.openai.com/codex/cli) and [configuration reference](https://developers.openai.com/codex/config-reference#cli_auth_credentials_store).

## Branches and production policy

- `develop`: active development; the repository's default branch.
- `main`: production policy and approved production source only. It currently contains no approved app version.
- Promote with a pull request from `develop` after CI passes and the project owner explicitly accepts the app's functionality. No stable release, tag, or deployment is created automatically. Branch rules protect `main` from deletion and force-push and require CI and a pull request; they do not require another person to approve an owner-operated change.

Provider names are used only to identify integrations. See [TRADEMARKS.md](TRADEMARKS.md). Third-party logos are not included in the public repository or app bundle. Apache-2.0 applies to the repository's code and does not grant rights to third-party names or marks.

See [LICENSE](LICENSE) for Apache License 2.0.

## Detected-row presentation

Detected installations display only their unnumbered name, centered vertically, with no status subtitle. Discovery details remain available as a tooltip and accessibility help. Each detected target uses a distinct native SF Symbol: Codex — `chevron.left.forwardslash.chevron.right` (blue); Claude — `text.bubble` (orange); Gemini CLI — `sparkles` (purple); Antigravity CLI — `arrow.up.circle` (teal). These are system-provided identification cues, not official provider logos. No third-party brand asset is bundled or distributed. Source: https://developer.apple.com/sf-symbols/ . Account controls are disabled for all rows; automatic trash controls are disabled; manual registrations remain removable.

Disabled account/install/trash controls use the semantic macOS disabled-control gray; manual removal remains enabled.

Rows show two native symbols: CLI identity followed by origin (`desktopcomputer` for external discoveries; `app` for managed installations or manual registrations). Tooltips distinguish a manual registration from its UUID-scoped installation status. Installation is never inferred from a provider-wide discovery; login is not inferred from an install.
