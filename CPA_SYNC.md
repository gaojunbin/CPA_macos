# CLIProxyAPI compatibility sync

## Baseline

| Item | Audited value |
| --- | --- |
| Audit date | 2026-09-21 |
| Upstream repository | https://github.com/router-for-me/CLIProxyAPI |
| Local reference | `../CLIProxyAPI` |
| Upstream tag | `v7.3.11` |
| Upstream full commit | `ffe6ad3c5fcf0a5eedd2198cd2e04b0249dc5063` |
| Upstream commit date | `2026-09-21T22:38:13+08:00` |
| Previous audited upstream | `v7.3.10`, `a5ab69521f7b4e0f244836d0419da8fcd89408ea` |
| Cloud deployment version | Not inspected |
| Scope | Current built-in providers, native authorization, quota, models, and existing management features |

The user requested current provider support as well as existing-feature compatibility. The clean upstream branch was fast-forwarded to the revision above and then treated as a read-only reference. No upstream source or deployed proxy was changed.

## Provider adaptation

- Both native clients recognize Devin, Meta, and Kimi.ai as distinct providers and expose their authorization flows. Devin uses an authorization-code flow with a server-configured loopback port. Meta and Kimi.ai use device authorization, including user-code and expiry metadata.
- Preserve the complete Devin callback URL, validate its session state, poll until persistence succeeds, and cancel abandoned server sessions. A successful callback submission alone is not login success.
- Refresh exactly one Devin account with `POST /v0/management/auth-files/refresh`, providing `name` and `auth_index`. Decode only `ok` and `auth.quota`; credential metadata from the response is never retained in a snapshot.
- Display Devin plan and daily/weekly remaining percentages, reset times, server observation time, and provider-pool averages. Keep zero distinct from unknown; reject invalid percentages and discard windows whose reset time has passed. A missing timestamp stays visibly unknown. Refresh failures remain errors while preserving the previous dated observation.
- Keep passive quota observations separate from scheduler `cooldowns`. Neither zero remaining quota nor a model registration invents an account-wide cooldown or proves live model availability.
- Kimi.ai quota uses `https://api.kimi.ai/coding/v1/usages`; Kimi coding retains `https://api.kimi.com/coding/v1/usages`. This follows the shared coding API and upstream domain split; live Kimi.ai responses remain unverified.
- Meta account/model support does not claim an undocumented built-in quota endpoint. Add Meta and Grok API-key config channels to model/routing inventory, preserving aliases, duplicate routing targets, prefix policy, wildcard exclusions, and capability metadata.

## Contract references and preserved behavior

- OAuth: `internal/api/server_management.go`, `auth_files_devin_oauth.go`, `auth_files_provider_oauth.go`, and `docs/management-devin-oauth.md`.
- Devin quota: `internal/auth/devin/record.go`, `internal/runtime/executor/devin_executor.go`, and `auth_files_refresh.go`. `/quota/fetch` is a plugin/probe interface, not the built-in Devin refresh contract.
- Models: `sdk/cliproxy/service_models.go`, registry definitions, and the existing `auth-files/models` endpoint. Model queries continue using account IDs to disambiguate shared filenames.
- Management bearer authentication, server-side `$TOKEN$` substitution, string `api-call.data`/`body`, nested upstream `status_code`, API key operations, and per-service settings/Keychain isolation remain intact.
- The v7.3.10-to-v7.3.11 changes affect runtime translation, response streaming, schema normalization, and plugin usage metadata; the audited native management contracts remain unchanged.
- No plugin/Home administration or quota-reset controls were added. Live provider APIs, production credentials, cloud changes, and device acceptance are separate from fixture validation.

## macOS delivery and validation

- Client starting commit: `4ccb376eeeaf641641e7956e17f18773f7480f3a` (v1.4.0).
- Native release version: `1.5.0`, build `9`. The existing default-on GitHub updater, digest/size/signature checks, deferred installation, startup receipt, and rollback remain unchanged.
- 71 XCTest cases passed, including provider identification, Devin quota parsing and freshness, zero/invalid/unknown signals, callback-state rejection, account-scoped refresh, safe credential projection, cancellation, Kimi.ai domain routing, existing models, and updater regressions.
- Validation commands (full Xcode):

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer CLANG_MODULE_CACHE_PATH=/tmp/cpa-swift-module-cache swift test --disable-sandbox --cache-path /tmp/cpa-swift-cache --config-path /tmp/cpa-swift-config --security-path /tmp/cpa-swift-security --scratch-path /tmp/cpa-macos-validation
VERSION=1.5.0 Scripts/package_github_release.sh
git diff --check
```

- Test output: `/tmp/cpa-providers-macos-final.log`. SwiftPM nested sandbox/cache overrides accommodate the restricted local build environment; they do not relax its outer filesystem restrictions.
- Release packaging and public asset verification are tracked separately by GitHub Actions and the tagged Release. Developer ID signing, notarization, actual installed-app update/relaunch, and live-provider login/quota remain unverified.

## Next sync

Compare `ffe6ad3c5fcf0a5eedd2198cd2e04b0249dc5063..HEAD` in the upstream reference. Include newly introduced built-in providers in the audit, preserve accurate quota semantics, and validate both native builds. Record live/cloud/distribution acceptance separately.
