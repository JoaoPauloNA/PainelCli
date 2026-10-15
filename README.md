# PainelCli — production policy

This is the production branch. It currently contains governance documentation only: **no PainelCli application version has been approved for production**. The application source is maintained on `develop`, which is the repository default branch.

Promotion requires all of the following:

1. The macOS build and isolated test workflow passes for a pull request from `develop` to `main`.
2. The project owner explicitly accepts the app's functional behavior after user testing.
3. The reviewed pull request is merged intentionally.

No tag, release, deployment, or production promotion happens automatically. Branch rules require a pull request and CI and prevent force-push and deletion. No second-person approval is required for the sole owner.

The repository code is licensed under [Apache License 2.0](LICENSE). Third-party names and marks remain with their owners; see [TRADEMARKS.md](TRADEMARKS.md).
