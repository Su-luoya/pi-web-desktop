# Pi Web Desktop

> Unofficial native macOS companion for [`agegr/pi-web`](https://github.com/agegr/pi-web).

Pi Web Desktop is a macOS AppKit/WebKit shell that starts, monitors, and displays a local Pi Web service. It does not modify the upstream Pi Web web application.

## Status

This project is in early alpha. The first public binary will target Apple Silicon Macs running macOS 14 or later and will be ad-hoc signed, not notarized. The supported installation path currently requires the user to install Node.js, Pi, and `@agegr/pi-web` separately.

## Prerequisites

- Apple Silicon Mac
- macOS 14 or later
- Node.js `>=22.19.0` as required by the current upstream Pi Web package
- Pi CLI
- `@agegr/pi-web`

Example installation commands, subject to upstream changes:

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
npm install -g @agegr/pi-web
```

Review the upstream documentation and package metadata before installing or updating dependencies. Pi packages and extensions can execute code with the current user's permissions.

## Build from source

```bash
./Scripts/build.sh
open build/Pi-Web-Desktop.app
```

The current development build uses the system Swift compiler and produces an Apple Silicon app targeting macOS 14. The checked-in `PiWebDesktop.xcodeproj` (scheme `PiWebDesktop`, unhosted `PiWebDesktopTests` target) is built and tested with `xcodebuild` before the script rebuilds the same app.

Application identity and version have a single source: `Configuration/AppIdentity.xcconfig`. The current alpha is `0.1.0-alpha.1` (build `1`), bundle identifier `io.github.su-luoya.pi-web-desktop`, display name `Pi Web Desktop`, minimum system version `14.0`. `Scripts/build.sh` generates `build/Pi-Web-Desktop.app/Contents/Info.plist` from that file, and `PiWebDesktop.xcodeproj` inherits it as its base configuration, so the Xcode project, the tests and the script cannot drift apart.

Both builds ship the app icon resource as `Contents/Resources/ApplicationIcon.icns`. `Scripts/build.sh` also writes `CFBundleIconFile = ApplicationIcon` into the `Info.plist` it generates, while Xcode's generated `Info.plist` does not contain that key at all (Xcode does not generate it from `INFOPLIST_KEY_CFBundleIconFile`, so that setting is deliberately absent from the xcconfig). A development build produced by Xcode may therefore show the generic app icon; the published alpha artifact is the script build, which does set the key.

Verify the source of truth after any identity or version change:

```bash
./Scripts/build.sh
./Scripts/check-identity.sh
```

`Scripts/check-identity.sh` compares the xcconfig against the project file, each bundle's `Info.plist` and icon resource, and the local service defaults, and rejects private defaults (tailnet hostnames, CGNAT addresses, absolute home paths, fixed proxy endpoints). It accepts several bundle paths in one run, which is how CI checks the Xcode product and the script product together.

## Install the alpha app

```bash
./Scripts/install.sh
open "$HOME/Applications/Pi-Web-Desktop.app"
```

Early binaries are not notarized. macOS may require you to approve the app in Privacy & Security after opening it. Do not disable Gatekeeper globally.

## What it does

- Starts and monitors a locally installed Pi Web service.
- Embeds the service in a native WebKit window.
- Provides service controls, logs, diagnostics, uploads, downloads, external-link handling, find, and zoom.
- Uses loopback by default and does not enable remote listening in the current alpha baseline.
- Keeps service configuration in UserDefaults and runtime files in the standard Application Support and Logs directories.

## Scope and safety

- This is an unofficial companion app, not an upstream Pi Web distribution.
- The app does not bundle Node.js, Pi, or Pi Web.
- The app does not collect telemetry. Version checks, when implemented, will be disclosed and separately configurable.
- Do not expose an agent service to an untrusted network. Remote access requires authenticated encrypted transport and is not part of the current baseline.
- Do not put passwords, API keys, tokens, local hostnames, proxy credentials, or private logs in public issues.

## Public bootstrap checklist

This repository is an early alpha and is not affiliated with the upstream Pi Web maintainers.

- [ ] Review the current support matrix and release notes.
- [ ] Install Node.js, Pi, and `@agegr/pi-web` separately.
- [ ] Check the source before running build or install scripts.
- [ ] Keep Pi Web on loopback unless you have configured authenticated encrypted transport.
- [ ] Do not publish passwords, tokens, private hostnames, proxy credentials, or unsanitized logs.

## Project documents

- [Architecture](docs/architecture.md)
- [Development](docs/development.md)
- [Privacy](docs/privacy.md)
- [Releasing](docs/releasing.md)
- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)

## License

MIT. See [LICENSE](LICENSE).

