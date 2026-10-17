# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Generate Xcode project (requires Tuist: brew install tuist)
tuist generate

# Open workspace
open MacRemote.xcworkspace

# Build from command line
xcodebuild -workspace MacRemote.xcworkspace -scheme MacRemoteServer -configuration Debug build
xcodebuild -workspace MacRemote.xcworkspace -scheme MacRemoteClient -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16' build
```

## Architecture

MacRemote is a remote control app: **iOS Client** controls **macOS Server** over local network.

```
iOS Client ←→ TCP (JSON + 4-byte length prefix) ←→ macOS Server
                    Bonjour Discovery
```

### Key Components

**Shared/** - Protocol definitions shared between client and server
- `RemoteMessage.swift` - Client→Server messages (move, click, scroll, key, media)
- `NetworkConstants.swift` - Service type `_macremote._tcp`, port 5150 (plaintext) and 5151 (TLS-PSK), protocol version, TXT keys
- `PairingCrypto.swift` - Key agreement, HKDF derivations and proofs for pairing. Both apps must use it verbatim. See `docs/PAIRING_PROTOCOL.md`
- `WakeOnLAN.swift` - `NetworkInterfaceInfo` and magic-packet construction for waking the Mac. See `docs/WAKE_ON_LAN.md`

**MacRemoteServer/** - macOS menubar app (LSUIElement=true, no sandbox)
- `ServerManager.swift` - Single observable state for the UI: status, connected/paired devices, pairing session, activity. Runs two `NetworkServer`s: plaintext (discovery, pairing, legacy control) and TLS-PSK (paired devices)
- `NetworkServer.swift` - TCP/TLS server using `NWListener`; Bonjour via `NWListener.Service` with TXT record; optional TLS 1.2 PSK with one key per paired device; all state queue-confined, callbacks on main
- `PairedDeviceStore.swift` - Paired devices (id, name, PSK) in a 0600 JSON file under Application Support
- `NetworkInterfaces.swift` - Active `en*` interfaces with hardware/IPv4 addresses; `WakeSettings` reads `pmset -g` for Wake for network access
- `InputController.swift` - Mouse/keyboard injection via `CGEvent`. Cursor moves are relative to the real cursor position and clamped to the union of all displays
- `PermissionsMonitor.swift` - Polls Accessibility and Screen Recording permissions every second; deep-links to System Settings
- `AppSettings.swift` - UserDefaults-backed preferences, launch at login via `SMAppService`
- `AppCatalog.swift` - Scans app directories (incl. /System/Applications, Utilities, nested folders), skips background-only bundles, caches PNG icons on disk by bundle ID + version
- `Views/MenuBarView.swift` - Popover: status + switch, devices list, problem state, footer
- `Views/OnboardingView.swift` - First-run window: permissions with live polling, start, launch at login
- `Views/SettingsView.swift` - Settings scene (General, Devices, Security, Permissions, About)
- `Views/PairingView.swift` - "Pair a Device" window: code, countdown, outcome
- `Views/Components.swift` - Menu bar icon renderer (template `MenuBarIcon` asset + state badge), shared rows

**MacRemoteClient/** - iOS app
- `NetworkClient.swift` - TCP client using `NWConnection`
- `BonjourBrowser.swift` - Service discovery using `NWBrowser`
- `TrackpadView.swift` - Gesture handling for mouse control
- `RemoteControlView.swift` - Tab container with embedded keyboard input

### Message Framing

All TCP messages use 4-byte big-endian length prefix + JSON payload. See `MessageFrame` in RemoteMessage.swift. The same framing runs inside the TLS connection.

### Security model

- Pairing happens once per device over the plaintext port while the Mac shows a 6-digit code; it yields a per-device 32-byte pre-shared key.
- Paired devices connect to the TLS-PSK port (identity = device ID). Unpaired devices can only pair, or use legacy plaintext control while **Allow unencrypted connections** is on.
- Adding enum cases to `RemoteMessage`/`ServerMessage` is backward compatible on the wire (unknown cases fail to decode and are dropped), but every `switch` over them must stay exhaustive in both apps.

## Development Notes

- **Swift 6.0** configured in Tuist.swift
- **No external dependencies** - only Apple frameworks (Network, CoreGraphics, SwiftUI, AppKit)
- **Logging convention**: Print with bracketed prefix `[Server]`, `[Client]`, `[Bonjour]`
- **Thread safety**: Network/input use `.userInteractive` dispatch queues; UI updates dispatch to main

### macOS Server Requirements
- Accessibility permission required for CGEvent input injection (server refuses to start without it; onboarding handles the request)
- Screen Recording permission optional, needed only for screen sharing
- Never read Keychain secret data at launch: debug builds are ad-hoc signed, so every rebuild triggers a Keychain prompt. Check existence with attribute-only queries and read secrets on explicit user intent
- Hardened runtime enabled, sandbox disabled
- Network server/client entitlements

### iOS Client Requirements
- Local network permission (NSLocalNetworkUsageDescription in Info.plist)
- Bonjour service types declared (NSBonjourServices)

## Localization

User-facing strings must be localized in English and Spanish:
- `MacRemoteClient/Resources/Localizable.xcstrings` (keys are identifiers, e.g. `unlock_mac`)
- `MacRemoteServer/Resources/Localizable.xcstrings` (keys are the English source text; add an `es` entry for every new `Text`/`Button`/`Label` literal)

## Tests and CI

```bash
# macOS unit tests (framing, cursor clamping, settings, app catalog, loopback server)
xcodebuild -workspace MacRemote.xcworkspace -scheme MacRemoteServer -destination 'platform=macOS' test
```

Tests live in `MacRemoteServer/Tests/`. `.github/workflows/ci.yml` builds both apps and runs these tests on every push and pull request. Tuist expands source and resource globs at generation time, so run `tuist generate` after adding files.

## Release build and DMG

```bash
scripts/make-dmg.sh                          # Developer ID signed Release build + dist/MacRemote-<version>.dmg
NOTARY_PROFILE=<profile> scripts/make-dmg.sh # also notarize and staple
```

Signing uses team `TJ3ALYQV5G`. Prefer installing the signed Release build into /Applications: its identity is stable, so Accessibility, Screen Recording and Keychain grants survive rebuilds. Ad-hoc Debug builds get a new identity every time and lose those grants.

## Testing macOS Server Changes

When making changes to the macOS server (MacRemoteServer), after verifying the build succeeds:

```bash
# Build, copy to Applications, and launch
xcodebuild -workspace MacRemote.xcworkspace -scheme MacRemoteServer -configuration Debug build && \
cp -R ~/Library/Developer/Xcode/DerivedData/MacRemote-*/Build/Products/Debug/MacRemoteServer.app /Applications/ && \
open /Applications/MacRemoteServer.app
```

This ensures you test with the latest version running from Applications.

## Adding New Features

When adding new remote control actions:
1. Add case to `RemoteMessage` enum in `Shared/RemoteMessage.swift`
2. Handle the message in `ServerManager.handleMessage()`
3. Implement the action in `InputController.swift`
4. Add UI in the appropriate iOS view
5. Add localized strings for any user-facing text
