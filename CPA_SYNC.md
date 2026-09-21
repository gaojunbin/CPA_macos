# CLIProxyAPI compatibility sync

## Baseline

| Item | Audited value |
| --- | --- |
| Audit date | 2026-09-21 |
| Upstream repository | https://github.com/router-for-me/CLIProxyAPI |
| Local reference | `../CLIProxyAPI` |
| Upstream tag | `v7.3.10` |
| Upstream full commit | `a5ab69521f7b4e0f244836d0419da8fcd89408ea` |
| Upstream commit date | `2026-09-21T04:13:44+08:00` |
| Previous audited upstream | `v7.2.155`, `7fac6b15bcfe5ea55c18c9eaec8e5b7e6457d974` |
| Cloud deployment version | Not inspected |
| Scope | Preserve existing native-client features and information |

The user explicitly requested refreshing upstream. Its clean `main` branch was fetched and fast-forwarded to `origin/main` at the revision above, then treated as a read-only reference. No upstream source was edited. This does not upgrade any deployed proxy or prove live provider connectivity.

## Adaptation

- Decode the current `cooldowns` snapshot, including credential/model scope, model key, reason, and fractional RFC3339 retry deadlines. Show current restrictions in existing detail/model views.
- Keep `cooldowns: null` or a missing field unknown. An empty array means no reported retry timers; it does not prove model availability. Ignore expired or malformed retry deadlines, and do not retain synthetic stale model restrictions.
- Keep credential-wide restrictions separate from partial model restrictions. A partial model cooldown does not make the entire account unhealthy. Explicit account failures and disablement still take precedence.
- Keep passive `quota.signals` and `model_quotas` separate from scheduler cooldowns and live provider quota requests.
- Preserve existing model aliases, duplicate upstream routes, exclusions, prefixes, display/capability metadata, and base-URL-only configuration channels.

## Contract audit

| Existing surface | Current result |
| --- | --- |
| Management access | `/v0/management` paths and bearer management authentication remain compatible; reviewed `internal/api/server_management.go` and management handlers. |
| Account list | `auth_files.go` adds `observed_at` and `cooldowns`. Pagination is opt-in via `page`/`page_size`; clients continue requesting the complete list without pagination parameters. Identity remains the backend `id` with `auth_index`. |
| Runtime state | `sdk/cliproxy/auth/cooldown_view.go` defines retry restrictions, not overall availability. The list handler reconciles account status with active credential/model gates. Home/disk-only state can return null cooldowns. |
| Account models | `GetAuthFileModels` still returns registered model IDs and optional display/type/owner metadata. Model lookup uses the backend account ID in `name`; credential-file download uses the filename. Missing runtime status stays unknown. |
| Quota proxy | `api_tools.go` preserves string `data`, nested `status_code`, and string response `body`. `$TOKEN$` remains server-resolved; missing credentials/tokens now fail explicitly with HTTP 400. Existing error handling accepts that failure. |
| Config/model inventory | Existing OpenAI-compatible, Codex, Claude, Gemini, Interactions, and Vertex GET contracts remain compatible. `service_models.go` and config types preserve current alias/exclusion/prefix rules. New internal catalog capabilities do not justify inventing runtime model availability. |
| Routing and API keys | OAuth aliases/exclusions, strategy, force-prefix, file routing metadata, and GET/PATCH/DELETE key contracts remain compatible. No cloud mutations were performed. |
| macOS OAuth | Existing Codex/Claude/Antigravity callback and xAI/Kimi device flows remain supported. `/kimi-auth-url` retains the default Kimi coding flow; the new Kimi.ai route is separate. |

No new Meta, Devin, Kimi.ai, plugin/Home, discovery, quota-reset, or credential-refresh controls were added. Existing provider quota fixtures remain the validation source; live provider APIs and production credentials were not exercised.

## macOS delivery

- Client starting revision: `7014cd34bf5ed1136ce4736269634b3146176353` (`v1.3.1`).
- Added native application updates from `gaojunbin/CPA_macos` GitHub Releases, enabled by default with a six-hour check interval and manual controls.
- Downloads require the release asset SHA-256 digest and size. Installation verifies version, identity, signature, OS, architecture, and updater metadata; Developer ID installations also require the same signing team.
- Installation waits for the popover and editing/login/key screens to be inactive. The helper waits for CPA to exit, preserves the old bundle, relaunches the replacement, and requires a startup receipt. Replacement/startup failure restores the old bundle.
- Native packaging defaults to arm64/x86_64 and includes the helper. The default application version is `1.4.0`, build `8`; explicit release versions are embedded into the bundle and checked against artifact names.
- Existing installations through 1.3.1 require one manual installation to gain this feature. Release publication is tracked by the tagged commit, GitHub Actions run, and GitHub Release assets; it does not replace the user's installed CPA.

## Validation

Run from `CPA_macos` with full Xcode:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --scratch-path /tmp/cpa-macos-validation
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer DIST_DIR=/tmp/cpa-macos-package BUILD_DIR=/tmp/cpa-macos-release OUTPUT_DIR=/tmp/cpa-macos-package/github Scripts/package_github_release.sh
git diff --check
```

- 62 XCTest cases passed, including scoped/null/empty/expired cooldowns, stable version selection, draft/prerelease/downgrade rejection, foreign or unverified assets, checksum mismatch, HTTP failure, path traversal, replacement, and rollback.
- The final test run used `--disable-sandbox --cache-path /tmp/cpa-swift-cache --config-path /tmp/cpa-swift-config --security-path /tmp/cpa-swift-security` and `CLANG_MODULE_CACHE_PATH=/tmp/cpa-swift-module-cache` because nested SwiftPM sandbox setup and home-directory caches were restricted in the task environment. The outer filesystem restrictions remained in force.
- Universal native Release build and packaging passed. ZIP and DMG SHA-256 checks, `hdiutil verify`, `codesign --verify --deep --strict`, both executable architectures, and macOS 13 minimum metadata passed. Artifacts are under `/tmp/cpa-macos-package/github/`.
- A temporary client fetched GitHub's actual latest release (1.3.1) and downloaded its ZIP through `AppUpdateClient`; size and SHA-256 verification passed. It did not install that older release.
- An isolated signed fixture passed the production unpack/identity/version/signature/OS/architecture checks. The production helper completed readiness, parent-exit handling, and replacement. LaunchServices returned `kLSNoExecutableErr`; the helper restored the old bundle and cleaned staging. Successful LaunchServices relaunch/startup receipt remains unverified in this environment; the success transaction is covered by a unit test.
- The local validation above does not establish live cloud/menu-bar acceptance, Developer ID signing, notarization, or an actual installed-client update. Release publication and downloaded-asset verification are separate distribution evidence.

## Next sync

Compare `a5ab69521f7b4e0f244836d0419da8fcd89408ea..HEAD` in the upstream reference. Recheck these contracts, update both clients where behavior is shared, and record actual cloud/distribution acceptance separately.
