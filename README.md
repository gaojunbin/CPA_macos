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

On first launch, click the menu bar icon and configure:

- Web endpoint, for example `https://your-vps.example.com` or `http://127.0.0.1:8317`
- Management password
- Auto-refresh interval in minutes

The management password is stored in macOS Keychain.

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

The app runs as a menu bar accessory and does not manage or modify the account pool.

## Package for GitHub Releases

Create installable GitHub Release assets:

```bash
VERSION=1.0.0 Scripts/package_github_release.sh
```

The release files are written to `dist/github/`:

- `CPA-1.0.0-macOS.dmg` for drag-to-Applications installation
- `CPA-1.0.0-macOS.zip` as a fallback app bundle archive
- `CPA-1.0.0-macOS-SHA256.txt` for checksum verification

By default the package script uses the JXA app bundle because it does not require Xcode. To package the native Swift/AppKit bundle instead:

```bash
APP_VARIANT=native VERSION=1.0.0 Scripts/package_github_release.sh
```

Pushing a tag like `v1.0.0` runs the Release workflow and uploads the same assets to the GitHub Release.

The local package is ad-hoc signed by default. For public distribution without Gatekeeper warnings, build with a Developer ID signing identity and notarize the release with Apple.
