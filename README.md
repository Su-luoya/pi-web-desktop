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

The current development build uses the system Swift compiler and produces an Apple Silicon app targeting macOS 14. A standard Xcode project and test target are planned for the first alpha milestone.

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

