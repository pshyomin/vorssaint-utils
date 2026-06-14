# Contributing to Vorssaint

Thanks for the interest! This project aims to stay small, native and readable.

## Getting started

```sh
git clone https://github.com/vorssaint/vorssaint-utils.git
cd vorssaint-utils
./build.sh                         # build + assemble the bundle
./build/Vorssaint --selftest       # quick health check (SELFTEST OK)
./build.sh --install               # install into /Applications and launch
```

Requirements: macOS 14+, Apple Silicon, Xcode Command Line Tools. The build is
a plain `swiftc` invocation (see `build.sh`) — no Xcode project, no external
dependencies, reproducible by design. `Package.swift` exists so SwiftPM-aware
editors can index the code.

### Stable signing (optional)

By default `build.sh` signs ad-hoc, whose code hash changes every build — so
macOS re-prompts for Accessibility/Screen Recording after each rebuild. Run

```sh
./Tools/setup-signing.sh
```

once to create a free, self-signed identity (`Vorssaint Utils Signing`) in a
dedicated keychain. `build.sh` then signs local builds with it, giving them a
constant designated requirement so granted permissions persist across rebuilds.
It is a local convenience only and is never shown outside the keychain.

Official releases are different: CI signs them with an Apple **Developer ID**
(from the repo secrets `SIGNING_CERT_P12` / `SIGNING_CERT_PASSWORD`) and
**notarizes** and staples them (`Tools/notarize.sh`, secrets `NOTARY_API_KEY_P8`
/ `NOTARY_KEY_ID` / `NOTARY_ISSUER_ID`), so downloads open with no Gatekeeper
warning. `build.sh` prefers the Developer ID identity when present, with the
hardened runtime and `Resources/Vorssaint.entitlements`, and falls back to the
self-signed identity, then ad-hoc.

## Project layout

| Folder | Role |
|---|---|
| `Sources/Vorssaint/App` | App lifecycle and the menu bar status item |
| `Sources/Vorssaint/Core` | Localization, permissions, UserDefaults keys |
| `Sources/Vorssaint/Services` | All behavior: energy, monitor, scroll, switcher |
| `Sources/Vorssaint/UI` | SwiftUI views only — no business logic |
| `Sources/Vorssaint/Support` | `--selftest` and `--sensors` diagnostics |
| `Tools` | Icon generator and DMG packaging |

Conventions:

- **UI observes services; services never import SwiftUI.** Keep that boundary.
- Singletons are exposed as `Type.shared` and publish state with Combine
  (`ObservableObject` — no Observation macros; the project builds with the
  Command Line Tools).
- Comments explain *why*, not *what*. Keep them rare and useful.
- No new dependencies without prior discussion in an issue.

## Strings & translations

Every user-facing string lives in `Core/Localization.swift` as a field of the
`Strings` struct. Adding a field forces every language to provide it — the
compiler is the completeness check. To add a language: add a case to
`AppLanguage` and a `static let` extension of `Strings`.

## Sensors on new chips

Temperature mapping lives in `SystemMonitor.prepareSensorsIfNeeded()`:
CPU = `Tp…`/`Te…`, GPU = `Tg…`, battery = `TB0T…TB2T`. If a new Apple Silicon
generation renames keys, run:

```sh
./build/Vorssaint --sensors
```

and open a PR with the dump and the adjusted prefixes.

## Pull requests

1. One topic per PR, with a clear description of behavior before/after.
2. `./build.sh` must finish without warnings and `--selftest` must pass.
3. New user-facing text must land in **both** languages.
4. Match the style of the file you are editing.

## Releases (maintainers)

```sh
git tag v2.1.0 && git push origin v2.1.0
```

The `release` workflow builds the app, packages the DMG and attaches it to a
GitHub release automatically.
