# CLIProxyAPI compatibility sync

## Baseline

| Item | Audited value |
| --- | --- |
| Audit date | 2026-10-30 |
| Upstream repository | https://github.com/router-for-me/CLIProxyAPI |
| Local reference | `../CLIProxyAPI` |
| Upstream tag | `v8.0.47` |
| Upstream full commit | `90c447d3a8727d115aa7552ec93ce023736ed492` |
| Upstream commit date | `2026-10-29T07:03:21+08:00` |
| Previous audited upstream | `v7.3.11`, `ffe6ad3c5fcf0a5eedd2198cd2e04b0249dc5063` |
| Management web UI reference | `router-for-me/Cli-Proxy-API-Management-Center` `64b4f5aed19b8f791eb21eb9e785ea379ea05b44` (`v1.26.7-3`, 2026-10-26) |
| Cloud deployment version | The two configured deployments reported `v8.0.47` (`90c447d`, built 2026-10-29) and `v8.0.35` (`ae3ee3b`, built 2026-10-19) in unauthenticated management response headers |
| Scope | v8 management API adoption for operational endpoints, quota contracts aligned with the management web UI, and existing management features |

The user asked to pull all three repositories and adapt both native clients to the current gateway, starting from the known missing Antigravity Gemini 5h/weekly quota. The upstream branch was fast-forwarded to the revision above and then treated as a read-only reference. No upstream source or deployed proxy was changed.

## v8.0.47 sync (2026-10-30)

### Upstream delta

- 596 commits since `v7.3.11`. Upstream added a parallel `/v8/management` API (`internal/api/server_management_v8.go`, `docs/management-api-v8.md`, all used routes present since `v8.0.0`) and its `AGENTS.md` now marks `/v0/management` as deprecated and unmaintained. The v0 routes are still registered and the v0 JSON contracts used by this client are unchanged: v8-layout config files are loaded back into the legacy runtime structure, so v0 config GETs keep their keys.
- No new built-in provider. New cooldown reason `transient_rate_limit`. Management responses may be zstd/gzip compressed; URLSession negotiates and decodes them.
- The management web UI moved entirely to `/v8/management` and changed quota request identities: Antigravity Hub user agent (Cloud Code withholds newer models from clients below Hub 2.23.0), Grok CLI `1.0.46` (cli-chat-proxy rejects versions below `1.0.13` with HTTP 426, `internal/runtime/executor/helps/xai_version.go`), Claude CLI and codex-tui user agents.

### Client adaptation

- Operational endpoints moved to `/v8/management`: `credentials`, `credentials/models`, `credentials/download`, `credentials/refresh`, `requests/api-call`, `routing/model-definitions/<channel>`, and OAuth `oauth/auth-url?provider=`, `oauth/callback`, `oauth/status`, `oauth/session`. Claude's v8 login provider is `claude`; callback bodies are unchanged. A 404 from the credential list reports that v8.0.0 or later with the management API enabled is required.
- Config reads (`*-api-key`, `openai-compatibility`, `oauth-model-alias`, `oauth-excluded-models`, `routing/strategy`, `force-model-prefix`) and client `api-keys` management stay on `/v0/management` by decision: the v8 config tree stores provider keys as groups with per-key inheritance, which needs a separate parser migration.
- Antigravity requests use `antigravity/hub/2.23.0 darwin/arm64`. The current upstream payload has `Gemini Models` and `Claude and GPT models` groups with `5h`/`weekly` buckets; both feed the Gemini and Claude/GPT 5h/7d slots. A full 5h bucket is unusable while its group's weekly bucket is exhausted, and an account-card slot whose every bucket is unusable stays unusable.
- Grok uses client version `1.0.46`. Product usage rows are a breakdown of the shared weekly credits (used percentage only), not separate remaining allowances.
- Claude sends the Claude CLI user agent. Team organizations take precedence over personal plan flags; `iguana_necktie` is the Fable 5 weekly window unless a `limits[]` `weekly_scoped` Fable entry supersedes it; dollar-denominated `iguana_necktie` is the cloud session credit pool; other full dollar records become balance rows; extra usage is shown whether enabled or not, with status, spend/limit in its currency, and flags.
- Codex sends the codex-tui user agent and shows `credits.balance` (plain non-negative decimal) or unlimited credits.
- Kimi lists rolling limits, then the weekly summary, then `usages.limit_month_total`. Protobuf units (`TIME_UNIT_MINUTE`, missing unit = minutes, weeks) render correctly; `kimi.ai`/`kimi_ai` map to Kimi.ai and its host, `kimi.com` to Kimi.
- Meta quota is supported: the persisted `dca:` token from the downloaded credential (never the LLM key) is sent to `https://api.meta.ai/muse-code/key`. Only plan, rolling-window, and weekly usage are kept; error messages never include the response body, which echoes the API key and profile data. Missing `subs_usage` stays unknown.

### Unchanged contracts

- Bearer management authentication, `auth_index`, server-side `$TOKEN$` substitution, string `api-call` `data`/`body`, nested `status_code`, the Devin refresh contract (`name` and `auth_index`, decoding only `ok` and `auth.quota`), credential list fields, model queries by account ID, per-service settings and Keychain isolation, and the update protocol.
- No plugin, Home, quota-reset, Codex reset-credit consumption, or Grok paid-account inference probe was added.

### macOS delivery and validation

- Client starting commit: `59deed6557c1537cc0cb653ae81b0ba40d787615` (release `1.5.2`, build `11`). Release version: `1.6.0`, build `12`.
- Commands (full Xcode; sandbox and cache overrides as in earlier syncs):

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer CLANG_MODULE_CACHE_PATH=/tmp/cpa-swift-module-cache swift test --disable-sandbox --cache-path /tmp/cpa-swift-cache --config-path /tmp/cpa-swift-config --security-path /tmp/cpa-swift-security --scratch-path /tmp/cpa-macos-validation
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer CLANG_MODULE_CACHE_PATH=/tmp/cpa-swift-module-cache swift build -c release --product CPAStatusBar --disable-sandbox --cache-path /tmp/cpa-swift-cache --config-path /tmp/cpa-swift-config --security-path /tmp/cpa-swift-security --scratch-path /tmp/cpa-macos-validation
git diff --check
```

- 84 XCTest cases passed (76 before this sync), including the current Antigravity summary filling the Gemini and Claude/GPT slots with weekly-blocked 5h buckets, Meta request contract and DCA-token rejection, the old-server 404 error, Claude/Codex/Antigravity/Grok request identities, Claude Fable/credit-pool/dollar/Team parsing, Kimi protobuf units and monthly totals, Kimi.ai aliases, Codex credits, and v8 OAuth paths. The release `CPAStatusBar` build and `git diff --check` passed. Logs: `/tmp/cpa-macos-test.log`, `/tmp/cpa-macos-release-build.log`.
- [GitHub Actions run 40930117204](https://github.com/gaojunbin/CPA_macos/actions/runs/40930117204) passed all 84 XCTest cases and built the release from `4f8f2bd61999fa53f4fe9dba174e5f74b1462e8e`.
- The published [v1.6.0](https://github.com/gaojunbin/CPA_macos/releases/tag/v1.6.0) DMG and updater ZIP were downloaded and matched their SHA-256 checksums. `hdiutil verify`, strict recursive ad-hoc signature verification, both `arm64`/`x86_64` slices, bundle version `1.6.0`/`12`, and update protocol `1` were verified.
- Not verified: no authenticated request reached a deployment or provider in this sync (the Keychain authorization prompt for a read-only diagnostic was not approved), so the effect of the new identities on live Antigravity, Grok, Claude, Codex, and Meta responses, OAuth logins, installed-app behavior, update/relaunch, and Developer ID signing or notarization remain unverified.

## v7.3.11 provider sync (2026-09-21)

Endpoint paths in this section are the `/v0/management` paths of that sync; the v8.0.47 sync moved the operational ones to `/v8/management`.

### Provider adaptation

- Both native clients recognize Devin, Meta, and Kimi.ai as distinct providers and expose their authorization flows. Devin uses an authorization-code flow with a server-configured loopback port. Meta and Kimi.ai use device authorization, including user-code and expiry metadata.
- Preserve the complete Devin callback URL, validate its session state, poll until persistence succeeds, and cancel abandoned server sessions. A successful callback submission alone is not login success.
- Refresh exactly one Devin account with `POST /v0/management/auth-files/refresh`, providing `name` and `auth_index`. Decode only `ok` and `auth.quota`; credential metadata from the response is never retained in a snapshot.
- Display Devin plan and daily/weekly remaining percentages, reset times, server observation time, and provider-pool averages. Keep zero distinct from unknown; reject invalid percentages and discard windows whose reset time has passed. A missing timestamp stays visibly unknown. Refresh failures remain errors while preserving the previous dated observation.
- Keep passive quota observations separate from scheduler `cooldowns`. Neither zero remaining quota nor a model registration invents an account-wide cooldown or proves live model availability.
- Kimi.ai quota uses `https://api.kimi.ai/coding/v1/usages`; Kimi coding retains `https://api.kimi.com/coding/v1/usages`. This follows the shared coding API and upstream domain split; live Kimi.ai responses remain unverified.
- Meta account/model support does not claim an undocumented built-in quota endpoint. Add Meta and Grok API-key config channels to model/routing inventory, preserving aliases, duplicate routing targets, prefix policy, wildcard exclusions, and capability metadata.

### Contract references and preserved behavior

- OAuth: `internal/api/server_management.go`, `auth_files_devin_oauth.go`, `auth_files_provider_oauth.go`, and `docs/management-devin-oauth.md`.
- Devin quota: `internal/auth/devin/record.go`, `internal/runtime/executor/devin_executor.go`, and `auth_files_refresh.go`. `/quota/fetch` is a plugin/probe interface, not the built-in Devin refresh contract.
- Models: `sdk/cliproxy/service_models.go`, registry definitions, and the existing `auth-files/models` endpoint. Model queries continue using account IDs to disambiguate shared filenames.
- Management bearer authentication, server-side `$TOKEN$` substitution, string `api-call.data`/`body`, nested upstream `status_code`, API key operations, and per-service settings/Keychain isolation remain intact.
- The v7.3.10-to-v7.3.11 changes affect runtime translation, response streaming, schema normalization, and plugin usage metadata; the audited native management contracts remain unchanged.
- No plugin/Home administration or quota-reset controls were added. Live provider APIs, production credentials, cloud changes, and device acceptance are separate from fixture validation.

### macOS delivery and validation

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

## Grok zero-usage correction (2026-10-25)

- Client starting commit: `0acb4105bb7ad076c933eb8acbbd8beb181aa538`. The read-only upstream reference remains `v7.3.11`, `ffe6ad3c5fcf0a5eedd2198cd2e04b0249dc5063`.
- Read-only authenticated billing requests on 2026-10-24 reproduced a weekly period with an omitted usage scalar and a monthly response with both limit and usage equal to zero. No account identifiers or credentials are retained in fixtures.
- Decode omitted ProtoJSON usage scalars only within recognized weekly/product records and decode present empty xAI `Cent` messages as zero. Explicit null, invalid values, missing records, and request failures remain unknown or errors.
- Preserve `usedPercent`, usage text, amounts, and reset metadata in Grok dashboard cards. A zero monthly limit and zero usage display `已用 0.0%`; remaining quota and usability stay unknown because a zero budget does not establish available credit. Weekly cards retain the remaining-percentage convention and also show `已用 0.0%`.
- xAI documents the empty zero-valued `Cent` representation in its [billing implementation](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/extensions/billing.rs). Management endpoints, bearer authentication, server-side `$TOKEN$` substitution, other providers, settings, and the update protocol are unchanged.
- Release version: `1.5.2`, build `11`. Build and validation output is kept under `/tmp`; package verification and publication are separate from installed-app acceptance.
- The local Swift toolchain stalled during startup after a system restart. The release workflow runs the complete regression suite before packaging. Local and CI Swift builds use two jobs by default (`BUILD_JOBS` can override the native packager limit).
- [GitHub Actions run 40179641573](https://github.com/gaojunbin/CPA_macos/actions/runs/40179641573) passed all 76 XCTest cases, including five Grok zero/unknown/exhaustion regressions, and built the release from `8deafe332a05fcb41b401314a4d7a9510857bcb5`.
- The published DMG and updater ZIP were downloaded and matched their SHA-256 checksums. `hdiutil verify`, strict recursive signature verification, both `arm64`/`x86_64` slices, and bundle version `1.5.2`/`11` were verified. Installed-app behavior and update/relaunch were not exercised.

## Next sync

Compare `90c447d3a8727d115aa7552ec93ce023736ed492..HEAD` in the upstream reference and the management web UI after `64b4f5aed19b8f791eb21eb9e785ea379ea05b44`. Include newly introduced built-in providers, re-check the quota client identities (they track upstream release floors), and decide whether to move config reads to the v8 config tree before upstream removes `/v0/management`. Preserve accurate quota semantics, validate both native builds, and record live/cloud/distribution acceptance separately.
