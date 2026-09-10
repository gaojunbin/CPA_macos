# CPA

Compatibility baseline and audit evidence: [CPA_SYNC.md](CPA_SYNC.md). Contributor instructions: [AGENTS.md](AGENTS.md).

Native macOS menu bar monitor for CLIProxyAPI OAuth pools, upstream balances, and model routing across Codex/OpenAI, Claude, Antigravity, Grok/xAI, Kimi, and config-based providers.

It reads the management API with the configured password, then refreshes each Codex account through:

- `GET /v0/management/auth-files`
- `POST /v0/management/api-call`
- Upstream target `https://chatgpt.com/backend-api/wham/usage`

Antigravity accounts use the management web UI's current `retrieveUserQuotaSummary` groups/buckets contract plus `loadCodeAssist` subscription metadata, with the legacy model-map endpoint retained as a fallback.
Claude and Kimi use the same upstream quota endpoints and response shapes as the management web UI. Grok merges weekly credit/product usage with monthly and on-demand billing data using the current CLI request headers.

The menu bar and top card show only the healthy account/channel ratio (`7/7`, `6/7`, …), while each OAuth provider keeps its own compact ratio. Provider quota summaries are equal-weight account-pool averages: Codex and Claude use 5h/7d, Antigravity separates Gemini and Claude/GPT 5h/7d, and Grok uses weekly/monthly credits. Dashboard account cards keep only those provider-specific headline rows; full quota windows remain available in account detail.

CLIProxyAPI replaces `Bearer $TOKEN$` server-side, so the app never needs account tokens.

## Run

```bash
swift run CPAStatusBar
```

On first launch, click the menu bar icon and add your first service:

- Name (optional, defaults to the host)
- Web endpoint, for example `https://your-vps.example.com` or `http://127.0.0.1:8317`
- Management password
- Auto-refresh interval in minutes

The management password is stored in macOS Keychain. You can add more services and switch between them at any time (see **Multiple services**).

## Config-based channels on the dashboard (配置渠道)

Channels defined in the server's `config.yaml` — `openai-compatibility` providers (e.g. an "opencode" entry) and the `claude/codex/gemini/interactions/vertex-api-key` sections — are not OAuth accounts and never appear in the server's auth-files list, so earlier versions could not show them. The dashboard now lists each of them as its own provider section (tagged 配置渠道), with one row per configured API key (masked). Opening a row shows the channel's models (resolved from config), its base URL, and the config source; these credentials have no live quota, so no usage bars are shown.

## Multiple services

The app can connect to multiple CLIProxyAPI services ("号池" / pools) and switch between them instantly. Services are fully independent and never share data.

- The dashboard title doubles as a switcher: click the current service name to pick another service, or choose **管理服务… (Manage services)**.
- **Manage services** lists every service; click one to edit it, or **添加服务 (Add service)** to create another. Each service keeps its own endpoint, management password, and refresh interval.
- Each service's management password is stored separately in the macOS Keychain, keyed per service.
- The menu bar shows the quota of the currently selected service. Switching shows that service's last-loaded data instantly while a fresh refresh runs in the background.
- Upgrading from a single-service build automatically migrates your existing connection into the first service.

## Account & key management (账号与密钥管理)

Beyond monitoring, the dashboard can manage the connected service directly, so routine account/key chores no longer require the CLIProxyAPI web console.

### Copy an account email (复制邮箱)

Open an account's detail screen, then click the account name at the top (or the **邮箱 / ChatGPT Account ID / 账号标识** rows) to copy that value to the clipboard. A brief "已复制" toast confirms the copy.

### OAuth login from the menu bar (OAuth 登录)

When an account drops its login, re-authorize it without opening the web UI. The flow is browser-independent: copy the authorization link, then either paste the loopback callback or finish the provider's device flow, so you can log in with **any browser**, not just the system default:

1. On the dashboard, click the **•••** button → **添加账号（OAuth 登录）**.
2. Pick a provider (Codex, Claude, Antigravity, Grok, or Kimi).
3. **复制授权链接**, open it in whichever browser you like, and log in.
4. For Codex / Claude / Antigravity: after login the browser is redirected to a `http://localhost:<port>/…` address (the page will look like it failed to load — that's expected). **Copy that whole address from the address bar, paste it into the app, and click 提交.** Grok/xAI and Kimi use device flows — authorize in the browser and the app detects completion automatically.

How it works: the app requests the auth URL (`/v0/management/<provider>-auth-url`) and polls `/v0/management/get-auth-status` until done. Redirect-based providers also send your pasted URL to `/v0/management/oauth-callback`; device-flow providers need no callback. The server performs the token exchange, so the app never handles account tokens. The popover stays open while you switch to the browser and back.

> The loopback callback URL works even when CLIProxyAPI runs on a remote VPS — you're only relaying the URL the provider handed your browser, and the server completes the exchange.

### API key management (API 密钥)

Click **•••** → **API 密钥…** to view the current service's API keys (`/v0/management/api-keys`). You can:

- **🎲 生成随机密钥并复制** — one click creates a strong random key, saves it, and copies it to the clipboard.
- Add a specific key by typing it and clicking **添加**.
- Copy any key, or delete one (with an inline confirmation).

Keys are shown masked; copying always copies the full value.

### Supported model list (模型列表)

Click **•••** → **模型列表…** to see every model the current service can actually serve right now — the menu bar equivalent of the proxy's `/v1/models`, but fetched with just the management key (no inference API key needed).

- Models are grouped by provider (Codex, Claude, Gemini, …) and deduplicated across that provider's accounts.
- Config-based channels are included too: each `openai-compatibility` provider appears under its own name (e.g. `opencode`) with its model aliases, and `claude/codex/gemini/interactions/vertex-api-key` sections appear as "… API Key" groups (tagged 配置渠道).
- The header shows the distinct model count and how many accounts were aggregated.
- Type in the search field to filter by model ID, display name, owner, or provider name.
- Click any model row to copy its model ID — handy when configuring clients that talk to the proxy.
- A `2/3`-style pill flags models only some of a provider's accounts can serve; a note appears if any account's model query failed.
- Where the server returns capability metadata, rows compactly show context/output limits, thinking, multimodal input/output, and Web Search support.

How it works: the app lists auth files (`/v0/management/auth-files`), skips disabled or unavailable ones, queries `/v0/management/auth-files/models?name=…` for each in parallel batches, and merges the results per provider. Config channels never appear in the auth-files list, so they are read from `/v0/management/openai-compatibility` (model aliases straight from config) and the supported `…-api-key` sections (per-key `models` overrides, falling back to `/v0/management/model-definitions/<channel>` static defaults minus `excluded-models`).

### Upstream model routing (上游模型路由)

The branch button in the dashboard opens a menu-bar-native routing view. It shows:

- global `round-robin` / `fill-first` strategy and `force-model-prefix` policy;
- OAuth `name → alias` mappings, including `fork` and `force-mapping` flags;
- account-local OAuth aliases, exclusions, prefixes, priorities, Grok official-API mode, proxy, and notes;
- repeated aliases as multi-upstream routing pools instead of silently deduplicating them;
- config-channel prefixes, priorities, base URLs, exclusions, credential counts, and advertised model counts;
- `interactions-api-key` alongside Codex, Claude, Gemini, Vertex, and OpenAI-compatible channels.

The routing view reads `/v0/management/oauth-model-alias`, `/oauth-excluded-models`, `/force-model-prefix`, `/routing/strategy`, auth-file models, and config-channel endpoints. For file-backed OAuth accounts it temporarily downloads the auth JSON only while opening this screen, extracts the routing fields, and immediately discards the raw credential payload. Tokens and identity claims are never retained or displayed; proxy userinfo, query strings, and fragments are removed before entering the UI snapshot.

## Build a macOS app bundle

The recommended native Swift/AppKit build contains the Liquid Glass dashboard, OAuth quota panels, and upstream routing view. It requires the local Xcode/Command Line Tools license to be accepted:

```bash
Scripts/build_app.sh
open "dist/CPA.app"
```

For systems that only need the lightweight legacy menu and cannot build Swift, a JXA compatibility bundle is also available:

```bash
Scripts/build_jxa_app.sh
open "dist/CPA.app"
```

The app runs as a menu bar accessory. On macOS 26 it uses native Liquid Glass cards (`NSGlassEffectView`); macOS 13–15 use a vibrancy fallback. Alongside monitoring, it can re-authorize accounts via OAuth, inspect upstream routing, and manage API keys for the connected service (see **Account & key management** above).

## Package for GitHub Releases

Create installable GitHub Release assets:

```bash
VERSION=1.0.0 Scripts/package_github_release.sh
```

The release files are written to `dist/github/`:

- `CPA-1.0.0-macOS.dmg` for drag-to-Applications installation
- `CPA-1.0.0-macOS.zip` as a fallback app bundle archive
- `CPA-1.0.0-macOS-SHA256.txt` for checksum verification

By default the package script uses the native Swift/AppKit bundle, matching `Scripts/build_app.sh`. To package the JXA fallback bundle instead:

```bash
APP_VARIANT=jxa VERSION=1.0.0 Scripts/package_github_release.sh
```

Pushing a tag like `v1.0.0` runs the Release workflow and uploads the same assets to the GitHub Release.

The local package is ad-hoc signed by default. For public distribution without Gatekeeper warnings, build with a Developer ID signing identity and notarize the release with Apple.
