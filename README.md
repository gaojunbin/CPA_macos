# CLIProxyAPI Pool Monitor

Native macOS menu bar monitor for CLIProxyAPI Codex/OpenAI account pool quotas.

It reads the management API with the configured password, then refreshes each Codex account through:

- `GET /v0/management/auth-files`
- `POST /v0/management/api-call`
- Upstream target `https://chatgpt.com/backend-api/wham/usage`

CLIProxyAPI replaces `Bearer $TOKEN$` server-side, so the app never needs account tokens.

## Run

```bash
swift run CPAStatusBar
```

On first launch, click the menu bar icon and configure:

- Web endpoint, for example `https://your-vps.example.com` or `http://127.0.0.1:8317`
- Management password
- Auto-refresh interval in minutes

The management password is stored in macOS Keychain.

## Build a macOS app bundle

No Xcode is required for the default app bundle:

```bash
Scripts/build_jxa_app.sh
open "dist/CLIProxyAPI Pool Monitor.app"
```

There is also a native Swift/AppKit implementation. It requires the local Xcode/Command Line Tools license to be accepted:

```bash
Scripts/build_app.sh
open "dist/CLIProxyAPI Pool Monitor.app"
```

The app runs as a menu bar accessory and does not manage or modify the account pool.
