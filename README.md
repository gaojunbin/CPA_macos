# CPA

Native macOS menu bar monitor for CLIProxyAPI Codex/OpenAI account pool quotas plus web-matched Claude, Antigravity, Kimi, and Grok quota rows.

It reads the management API with the configured password, then refreshes each Codex account through:

- `GET /v0/management/auth-files`
- `POST /v0/management/api-call`
- Upstream target `https://chatgpt.com/backend-api/wham/usage`

Antigravity accounts are refreshed through the same management proxy with the web UI's `fetchAvailableModels` quota endpoint.
Claude, Kimi, and Grok accounts use the same upstream quota endpoints and response shapes as the management web UI.

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

Channels defined in the server's `config.yaml` — `openai-compatibility` providers (e.g. an "opencode" entry) and the `claude/codex/gemini/vertex-api-key` sections — are not OAuth accounts and never appear in the server's auth-files list, so earlier versions could not show them. The dashboard now lists each of them as its own provider section (tagged 配置渠道), with one row per configured API key (masked). Opening a row shows the channel's models (resolved from config), its base URL, and the config source; these credentials have no live quota, so no usage bars are shown.

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

When an account drops its login, re-authorize it without opening the web UI. The flow is fully manual (copy a link / paste the callback), so you can log in with **any browser**, not just the system default:

1. On the dashboard, click the **•••** button → **添加账号（OAuth 登录）**.
2. Pick a provider (Codex, Claude, Antigravity, Grok, or Kimi).
3. **复制授权链接**, open it in whichever browser you like, and log in.
4. For Codex / Claude / Antigravity / Grok: after login the browser is redirected to a `http://localhost:<port>/…` address (the page will look like it failed to load — that's expected). **Copy that whole address from the address bar, paste it into the app, and click 提交.** Kimi uses a device flow — just authorize in the browser and the app detects completion automatically.

How it works: the app requests the auth URL (`/v0/management/<provider>-auth-url`), you paste the callback back to `/v0/management/oauth-callback`, and it polls `/v0/management/get-auth-status` until done. The server performs the token exchange, so the app never handles account tokens. The popover stays open while you switch to the browser and back.

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
- Config-based channels are included too: each `openai-compatibility` provider appears under its own name (e.g. `opencode`) with its model aliases, and `claude/codex/gemini/vertex-api-key` sections appear as "… API Key" groups (tagged 配置渠道).
- The header shows the distinct model count and how many accounts were aggregated.
- Type in the search field to filter by model ID, display name, owner, or provider name.
- Click any model row to copy its model ID — handy when configuring clients that talk to the proxy.
- A `2/3`-style pill flags models only some of a provider's accounts can serve; a note appears if any account's model query failed.

How it works: the app lists auth files (`/v0/management/auth-files`), skips disabled ones, queries `/v0/management/auth-files/models?name=…` for each in parallel batches, and merges the results per provider. Config channels never appear in the auth-files list, so they are read from `/v0/management/openai-compatibility` (model aliases straight from config) and the four `…-api-key` sections (per-key `models` overrides, falling back to `/v0/management/model-definitions/<channel>` static defaults minus `excluded-models`).

## Build a macOS app bundle

No Xcode is required for the default app bundle:

```bash
Scripts/build_jxa_app.sh
open "dist/CPA.app"
```

There is also a native Swift/AppKit implementation. It requires the local Xcode/Command Line Tools license to be accepted:

```bash
Scripts/build_app.sh
open "dist/CPA.app"
```

The app runs as a menu bar accessory. Alongside monitoring, it can re-authorize accounts via OAuth and manage API keys for the connected service (see **Account & key management** above).

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
