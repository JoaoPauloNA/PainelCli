# Antigravity CLI installation and isolation contract

PainelCli can install, uninstall, and permanently remove an Antigravity CLI registration without starting the CLI or changing authentication. This contract describes what the app validates and the boundary that prevents the registration from being presented as an isolated Antigravity account.

## Official installation source

Google's [Antigravity CLI repository](https://github.com/google-antigravity/antigravity-cli) and [CLI quickstart](https://antigravity.google/docs/getting-started?tab=cli) document the macOS installer at `https://antigravity.google/cli/install.sh`, with the CLI normally placed at `~/.local/bin/agy`. The app does not execute that shell installer. It reads the current architecture-specific manifest from Google's release service:

`https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/darwin_arm64.json`

or

`https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/darwin_amd64.json`.

The current official installer source selects the release URL and SHA-512 from this manifest, downloads the artifact from `storage.googleapis.com/antigravity-public/antigravity-cli/`, checks the SHA-512, and extracts the `antigravity` member from a `.tar.gz` bundle. PainelCli performs the same manifest, host/path, and checksum checks. It stages the downloaded archive and executable under the registration UUID, extracts only that named member, sets private permissions, writes a UUID/provider/version/architecture/checksum receipt, and publishes the installation atomically. Manifest versions and hashes are fetched dynamically; the app does not pin a release version or retain a copy of an old artifact.

The shell installer also runs `agy install --dir <directory>` after copying the binary. This app intentionally omits that handoff: install, trash, and status validation never execute `agy`. Google's docs mention `--skip-aliases` and `--skip-path`, but the current installer script source inspected for this implementation does not accept those switches; PainelCli does not pass undocumented arguments or run the global shell setup. It also does not call npm or modify `~/.local/bin`, shell profiles, or other UUIDs.

## Per-UUID files and runtime boundary

Each manual Antigravity registration owns `Application Support/PainelCli/Registrations/<UUID>/installation`. The managed executable is `installation/package/bin/agy`; the version receipt is `installation/install.json`. The UUID also owns a private `home`, `xdg/config`, `xdg/cache`, `xdg/data`, and `tmp` tree. These locations are the HOME, XDG, and temporary environment that a future explicitly implemented Antigravity runtime must use. The current app does not launch this runtime.

The current UI leaves the Antigravity account button disabled and reports that login is unavailable at this stage. It does not query `agy auth`, open a browser, synthesize an account state, or copy credentials. Uninstall deletes the binary and receipt while retaining the UUID's other data. Trash deletes that UUID's directory and registration row. Neither operation logs out or touches the global CLI, another UUID, or the system credential store.

## Authentication limit

Google's [authentication guide](https://antigravity.google/docs/install?tab=cli) describes one unified authentication layer across the Antigravity app, CLI, IDEs, and SDK, stored in the operating system's native keyring. It documents `/logout` as purging auth profiles from the system keyring. It does not document a per-UUID keyring namespace or credential-store override that PainelCli can rely on. Its documented `~/.gemini/antigravity-cli/settings.json` API-key path can be directed into the UUID HOME, but this does not isolate the unified OS keyring. Google also documents automatic CLI updates, so a future launch flow must constrain any updater to the UUID binary before it can be called safely.

Consequently, private HOME/XDG paths protect filesystem state but do **not** establish account isolation. This version has no login, status, or logout action, and it must not be described as supporting independent Antigravity accounts per UUID. Account support requires a documented provider mechanism that isolates every credential store, or a separately reviewed design that makes shared system-keyring effects explicit and acceptable.

## Verification boundary

Automated tests inject synthetic manifests, archive bytes, and a fake `tar` runner. They check UUID separation, official artifact host/path validation, SHA-512 mismatch rejection, failed extraction and same-UUID retry, retained per-UUID data, and that a discovered global `agy` is unchanged. The tests never contact Google's release service, download a real package, execute `agy`, access Keychain, or start authentication. A real installation and functional smoke test remain a user acceptance step.

Official references:

- [Antigravity CLI repository and installer source](https://github.com/google-antigravity/antigravity-cli)
- [CLI quickstart](https://antigravity.google/docs/getting-started?tab=cli)
- [Authentication and installation guide](https://antigravity.google/docs/install?tab=cli)
