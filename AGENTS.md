# CPA macOS agent instructions

Native macOS menu bar client (Swift Package Manager, Swift 5 language mode, macOS 13+).

## Scope and working rules

- This is a native client for remotely deployed CLIProxyAPI. Do not add Docker or embed the proxy server.
- Treat `../CLIProxyAPI` as a read-only upstream reference: do not edit, fetch, pull, checkout, or build into that directory during client compatibility work.
- Compatibility maintenance preserves existing features and displayed information. Do not add upstream features or providers unless explicitly requested.
- Communicate with the user in Chinese. Write code, comments, documentation, branches, and commit messages in English. Preserve the existing Chinese product UI.
- Keep functions focused and use the existing directory structure. Do not introduce version-suffixed replacements or commented-out code.
- Keep temporary scripts, build output, and logs under `/tmp`; do not commit one-off validation scripts.
- Preserve service profiles, per-service Keychain isolation, and existing settings. Edit symlinked configuration files in place.
- Management credentials and downloaded auth JSON must never appear in logs, fixtures, docs, or persisted snapshots. Use synthetic credentials for tests.

## Compatibility workflow

1. Read [CPA_SYNC.md](CPA_SYNC.md) for the last audited upstream tag and full commit, client starting commit, scope, and validation limits.
2. Inspect all working trees before changes. Compare the recorded upstream commit with the local upstream HEAD; do not assume the cloud deployment runs either version.
3. Check existing endpoints against upstream `internal/api/server_management.go` and `internal/api/handlers/management/`. Check config model resolution against `sdk/cliproxy/service_models.go` and field names against `internal/config/` and `internal/registry/`.
4. Preserve `Authorization: Bearer <management-key>`, `/v0/management`, `auth_index`, and server-side `$TOKEN$` substitution. The `api-call` request `data` and response `body` fields are JSON strings; the upstream HTTP status is nested in `status_code`.
5. Keep config model aliases, duplicate upstream routing targets, wildcard exclusions, prefix policy, display names, and capability metadata aligned. Fully excluded explicit models must stay empty, without falling back to defaults. Base-URL-only credentials remain valid.
6. Missing model runtime state is unknown. Current `quota`/`model_quotas` observations are not cooldown state. Neither model registration nor account `status: active` proves live quota availability. Low quota alone is not a connection-health failure.
7. Fix the corresponding existing behavior in the sibling client when applicable; preserve platform-specific feature scope.
8. Run relevant regression checks and the native build. Update this repository's `CPA_SYNC.md` with the exact upstream revision, changed and unchanged contracts, and actual evidence. Record cloud/device validation separately; do not invent an earlier sync baseline.

## Code map

- `Sources/CPAStatusCore/CLIProxyAPIClient.swift`: management networking, live quota requests, model/routing reads, OAuth and API key management.
- `Models.swift`, `UsageParser.swift`, `DashboardMetrics.swift`: account/model decoding, provider quota interpretation, and health summaries.
- `ConfigChannels.swift`, `ConfiguredModelMetadata.swift`, `RoutingModels.swift`: config models and routing metadata. Preserve metadata when generating prefixed model IDs.
- `Sources/CPAStatusBar/CPAStatusBarMain.swift`: AppKit dashboard, details, model pool, routing, service settings, OAuth, and API key UI.
- `Tests/CPAStatusCoreTests/`: persistent unit and request-contract regression tests.
- `JXA/CPAQuotaBar.jxa`: legacy lightweight fallback; it does not have native feature parity. Do not expand it as part of native maintenance.

## Build and verify

Run from this repository. Use a full Xcode installation for XCTest; inspect `xcode-select -p`. On the machine used for the current audit, Xcode is at `/Applications/Xcode-beta.app` (recheck on other machines).

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --scratch-path /tmp/cpa-macos-validation
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build -c release --product CPAStatusBar --scratch-path /tmp/cpa-macos-validation
git diff --check
```

To run the client from source:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift run CPAStatusBar
```

First setup takes the server URL and management password. The UI displays existing account health, live quota, models, and routing. The password stays in Keychain. `Scripts/build_app.sh` creates `dist/CPA.app`; packaging, installation, signing, and release publication are separate steps from source validation.
