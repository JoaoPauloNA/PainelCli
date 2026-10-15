# PainelCli

PainelCli is an experimental native macOS AppKit app for keeping a local list of Codex CLI, Claude Code, and Gemini CLI registrations. Registrations are separate from installation state. The app supports duplicate registrations, removes one selected record at a time, and assigns stable per-provider numbers.

**Status: development. No production version has been approved.** Version 0.0.0.11 is the current development baseline. The `develop` branch contains the app; `main` contains production policy and remains without an approved app release. A production promotion requires passing technical checks and João's explicit functional acceptance. Promotion happens through a pull request; CI does not tag, publish, or deploy a release.

## Build and test

Requirements: macOS, Xcode Command Line Tools, Swift, and Python 3. Run `python3 scripts/build-open.py` to compile the app, keep the current and previous local bundles, and open the app. Run `scripts/ci-check.sh` to compile the AppKit executable and run the isolated store/installer test suite without opening the app. GitHub Actions runs the same check on macOS for pushes and pull requests to `main` and `develop`.

The test suite uses temporary synthetic files and a simulated installer. It never runs `npm install` or installs a CLI.

## CLI installation limits

Installing a CLI is an explicit action in the app. Node.js and npm must already be available. PainelCli uses a fixed package for each provider, the public npm registry, and a per-provider prefix under `~/Library/Application Support/PainelCli/Installations`. It does not install Node.js or npm, request administrator privileges, edit shell startup files, configure accounts, or pass arbitrary environment variables to npm. npm package lifecycle scripts run with the current user's permissions. The UI detects known executables and prevents an installation attempt when one is already found.

Gemini CLI's upstream project announced that individual free, Google AI Pro, and Google AI Ultra accounts stopped receiving service on 18 June 2026; Enterprise Gemini Code Assist and API-key access were reported as unaffected. Installing the npm package does not guarantee service access.

## Branches and production policy

- `develop`: active development; the repository's default branch.
- `main`: production policy and approved production source only. It currently contains no approved app version.
- Promote with a pull request from `develop` after CI passes and João explicitly accepts the app's functionality. No stable release, tag, or deployment is created automatically. Branch rules protect `main` from deletion and force-push and require CI and a pull request; they do not require another person to approve an owner-operated change.

Provider names are used only to identify integrations. See [TRADEMARKS.md](TRADEMARKS.md). Third-party logos are not included in the public repository or app bundle. Apache-2.0 applies to the repository's code and does not grant rights to third-party names or marks.

See [LICENSE](LICENSE) for Apache License 2.0.
