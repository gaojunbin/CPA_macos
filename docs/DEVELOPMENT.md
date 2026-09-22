# Development and distribution

[Project overview](../README.md) · [Feature and integration reference](REFERENCE.md)

Read [AGENTS.md](../AGENTS.md) for contributor rules and the code map, and [CPA_SYNC.md](../CPA_SYNC.md) for the audited upstream revision and compatibility evidence. All commands below run from the repository root.

## Run from source

```sh
swift run CPAStatusBar
```

See [connection setup](REFERENCE.md#connection-setup) for the server URL and management password.

## Validation

Use a full Xcode installation. If it is not the active developer directory, set `DEVELOPER_DIR` to its `Contents/Developer` directory.

```sh
swift test --scratch-path /tmp/cpa-macos-validation
swift build -c release --product CPAStatusBar --scratch-path /tmp/cpa-macos-validation
git diff --check
```

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

The app runs as a menu bar accessory. On macOS 26 it uses native Liquid Glass cards (`NSGlassEffectView`); macOS 13–15 use a vibrancy fallback. Alongside monitoring, it can re-authorize accounts via OAuth, inspect upstream routing, and manage API keys for the connected service (see the [feature reference](REFERENCE.md)).

## Package for GitHub Releases

Create installable GitHub Release assets:

```bash
VERSION=1.5.1 Scripts/package_github_release.sh
```

The release files are written to `dist/github/`:

- `CPA-1.5.1-macOS.dmg` for drag-to-Applications installation
- `CPA-1.5.1-macOS.zip` as a fallback app bundle archive
- `CPA-1.5.1-macOS-SHA256.txt` for checksum verification

By default the package script builds universal arm64/x86_64 native bundles, including the installer helper. `VERSION` sets both the embedded app version and release filenames; a mismatch fails packaging. Build intermediates use `/tmp/cpa-macos-build`. Set `BUILD_DIR`, `DIST_DIR`, or `OUTPUT_DIR` to redirect outputs; set `ARCHS=arm64` for a local architecture-only build. To package the JXA fallback bundle instead:

```bash
APP_VARIANT=jxa VERSION=1.5.1 Scripts/package_github_release.sh
```

Pushing a tag like `v1.0.0` runs the Release workflow and uploads the same assets to the GitHub Release.

The local package is ad-hoc signed by default. For public distribution without Gatekeeper warnings, build with a Developer ID signing identity and notarize the release with Apple.

## App icon

The monochrome Confluence mark represents multiple upstream channels converging into one managed endpoint. The artwork uses pure black and white, a consistent rounded stroke, and a generous safe area. The editable SVG is the only drawing source; platform exports are rendered directly at each required size.

Regenerate the checked-in icon assets from this repository:

```sh
swift Scripts/generate_app_icon.swift
```

The macOS master is `Resources/AppIcon.svg`. The script exports `Resources/AppIcon.icns` with all 16–1024 px representations. The background has an inset rounded silhouette with transparent outer padding.
