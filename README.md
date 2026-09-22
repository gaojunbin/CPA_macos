<img src="Resources/AppIcon.svg" width="88" alt="CPA app icon">

# CPA for macOS

A menu bar companion for your self-hosted [CLIProxyAPI (CPA)](https://github.com/router-for-me/CLIProxyAPI). Connect to CPA running on your VPS and check account status, remaining quota, and reset times directly from your Mac.

## Features

- **Live account overview** — see accounts grouped by provider, remaining quota, and connection issues, with automatic refresh.
- **Account authorization** — start authorization directly from the app and follow the provider's browser sign-in, without repeatedly opening the CPA web console.
- **Multiple servers** — save your CPA connections and switch between them from the menu bar.
- **Models and API keys** — browse models and routing, and create, copy, or remove proxy API keys.
- **Automatic updates** — receive new macOS releases through the built-in updater.

## Supported services

Manage CPA accounts for **Claude Code, Codex, Devin, Antigravity, Grok, Kimi, Kimi.ai, and Meta**, plus model and channel information for Gemini, Vertex AI, and OpenAI-compatible providers.

Available features depend on your CPA server version and provider. Live quota is shown where the provider supports it; not every service exposes quota data.

## Get started

Requires **macOS 13 or later**, on Apple Silicon or Intel.

1. Download the DMG from [GitHub Releases](https://github.com/gaojunbin/CPA_macos/releases/latest) and drag CPA into Applications.
2. Open CPA from the menu bar and add your server's HTTPS address and management password.
3. View your accounts and quota, or start an account authorization from the dashboard menu.

Your server must allow remote management. Management passwords are stored in macOS Keychain. See [setup and first-launch help](docs/REFERENCE.md) if needed.

---

[iOS companion](https://github.com/gaojunbin/CPA_IOS) · [Detailed guide](docs/REFERENCE.md) · [Development](docs/DEVELOPMENT.md)
