# CLIProxyAPI compatibility sync

## Baseline

| Item | Audited value |
| --- | --- |
| Audit date | 2026-09-10 |
| Upstream repository | https://github.com/router-for-me/CLIProxyAPI |
| Read-only local reference | `../CLIProxyAPI` |
| Upstream tag | `v7.2.155` |
| Upstream full commit | `7fac6b15bcfe5ea55c18c9eaec8e5b7e6457d974` |
| Upstream commit date | `2026-09-09T01:33:09+08:00` |
| Previous explicitly recorded upstream baseline | None found; the old client commit dates do not establish an upstream version |
| Cloud deployment version | Not inspected; do not infer it from this local checkout |
| Sync scope | Existing native-client features and information only |

This is a source compatibility audit of the exact local revision above, not a claim that it is the latest public release or that the cloud deployment has been upgraded. The upstream working tree and HEAD were unchanged. Publishing these client changes to GitHub does not upgrade the cloud deployment or install a client binary. Release packaging and installation are separate steps.

## Shared corrections

- Account model requests now use the unique backend auth ID in the existing `name` query parameter. Virtual accounts sharing a filename no longer query the same account model list.
- Config model synthesis now retains `display-name`, positive `max-context-length`, configured thinking capabilities, and compatibility-channel input/output modalities.
- Prefix expansion preserves the model's display name, description, token limits, modalities, web-search flag, and thinking capabilities instead of rebuilding a partial model object.
- `excluded-models` applies to explicit aliases as well as default models, before prefix expansion. When all explicit models are excluded, the result remains empty. Duplicate upstream targets sharing a surviving alias remain separate routing entries.
- A backend error status or explicit last error no longer counts as a healthy account merely because a quota request succeeded. Low remaining quota alone still does not change connection health.

## Contract review

| Existing surface | Upstream source and result |
| --- | --- |
| Management access | `internal/api/server_management.go` and `handlers/management/handler.go`: existing `/v0/management` paths and bearer management authentication remain compatible. Home mode is not a supported management target. |
| Accounts and identity | `handlers/management/auth_files.go`: `files`, stable `id`, `auth_index`, names, provider, status, disabled/unavailable, counters, recent requests, subscription claims and timestamps still decode. Model lookup uses the backend account ID; file download still uses the filename. |
| Passive quota observations | `auth_files.go` now exposes `quota.observed_at/signals` and `model_quotas`. These are not scheduler state; do not reinterpret them as cooldowns or as live quota windows. Existing direct quota queries remain the source of live usage. |
| Account models | `GetAuthFileModels` currently returns `id`, optional `display_name`, `type`, and `owned_by`. Rich capabilities and per-model runtime state are not guaranteed by this endpoint. Registration does not prove present request availability. |
| Quota request proxy | `handlers/management/api_tools.go`: POST JSON still uses `auth_index`, `method`, `url`, `header`, and optional string `data`; response `status_code` and string `body` remain compatible. `$TOKEN$` is resolved on the server. No inference requests or reset-credit consumption were added. |
| Config inventory | Existing OpenAI-compatible, Codex, Claude, Gemini, Interactions, and Vertex sections remain readable. Additional `auth-index` and other unused fields do not break parsing. Base-URL-only credentials were already accepted by the client and are covered by regression fixtures. |
| Model defaults and aliases | `sdk/cliproxy/service_models.go`, `internal/config/config_types.go`, and `internal/registry/model_registry.go`: config metadata, explicit/default selection, alias exclusions, prefix policy, and first-alias model deduplication were checked. |
| Routing | OAuth alias/exclusion paths, file-backed routing metadata, strategy, and force-prefix paths remain compatible. `weighted-round-robin` and unknown strategy strings are already displayed verbatim; no strategy editor or weight controls were added. |
| API keys | `handlers/management/config_lists.go`: GET/PATCH/DELETE remain compatible; append still uses `old == new`, deletion uses `value`. Checked through source and synthetic client requests, without changing cloud keys. |
| Provider quota parsers | Existing Codex, Claude, Antigravity, Kimi, and Grok request/response fixtures pass. Provider-hosted quota APIs are separate from CPA's management contract; their live availability and returned shapes were not verified against real accounts. |

## Deliberate scope limits

- No new xAI API-key channel, plugin/Home controls, session/harness features, request-retry controls, OAuth flows on iOS, or other upstream feature additions.
- No cloud configuration changes, real OAuth login, real credential/key mutation, production quota requests, or deployment changes.
- A local source/build check does not establish cloud connectivity, physical-device behavior, signed distribution, or successful provider quota retrieval.

## macOS record

- Client starting revision: `862ec7eef05076eecca186445db06e80df1a05a1` (`v1.3.0`, 2026-07-12).
- The explicit-model exclusion bug previously left blocked models in the model pool and routing view. Default-model capability metadata was also discarded during synthesis; both are fixed.
- Existing native OAuth URL, device-flow metadata, callback relay, status polling, and API-key contracts remain unchanged.
- The JXA fallback's management paths and envelope fields were inspected. It remains a legacy quota monitor with a smaller feature set; native quota-provider parity and live JXA behavior were not certified by this audit.

## Validation

Run from `CPA_macos`:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --scratch-path /tmp/cpa-macos-validation
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build -c release --product CPAStatusBar --scratch-path /tmp/cpa-macos-validation
git diff --check
```

- 52 XCTest cases passed, including shared-filename account model lookups, current config contracts, full/partial exclusions, duplicate aliases, metadata preservation, keyless credentials, backend errors, and passive quota observations.
- Native `CPAStatusBar` Release build passed. Binary output: `/tmp/cpa-macos-validation/release/CPAStatusBar`.
- No live menu-bar/cloud acceptance or installer/release packaging was performed.

## Next sync

Read `AGENTS.md`, then compare `7fac6b15bcfe5ea55c18c9eaec8e5b7e6457d974..HEAD` in the read-only upstream checkout, focusing on the sources above. Replace this baseline only after rechecking existing contracts and rerunning relevant client validation. Record the actual cloud revision separately if it is inspected.
