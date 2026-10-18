# MacRemote Improvement Plan

_Assessment date: 2026-10-17. Based on a full read of the codebase at commit `aa12885`._

_Progress: `[x]` done, `[~]` partially done. Branch `mac-app-redesign` holds the Mac-side work from Phases 1, 2, 3 and 6._

## Summary

The foundations are right. Network.framework, ScreenCaptureKit, VideoToolbox and SwiftUI are the correct building blocks, so no rewrite is needed. What makes the app feel rough is the layer on top: the input model, the transport, the connection lifecycle, and the complete lack of authentication. All of it can be fixed incrementally, one phase at a time.

Estimated total effort: five to six weeks for one developer. Phases 2 and 3 deliver most of the perceived quality jump. Phase 2 should come first because the current build is unsafe to leave running on a shared network.

---

## Part 1: Where it lacks

### 1.1 Security (critical)

| Issue | Where | Impact |
|---|---|---|
| No authentication on the TCP connection. Any device on the LAN can connect and inject mouse, keyboard, app launches and lock commands. | `MacRemoteServer/Sources/NetworkServer.swift`, `ServerManager.setupServerCallbacks()` | Full remote control of the Mac by anyone on the same Wi-Fi. |
| Plaintext JSON on the wire. No TLS. | `Shared/RemoteMessage.swift` (`MessageFrame`) | Keystrokes are sniffable. |
| 4-byte length prefix is trusted blindly. | `NetworkServer.receiveMessage(from:)`, `NetworkClient.startReceiving()` | A single malicious frame requests a multi-gigabyte allocation. |
| Unlock types the password and Return into whatever has focus. It never checks that the screen is actually locked. | `InputController.unlockScreen(password:)` | Password can be typed into a chat window or terminal. The "wake" keystroke also types a space when not locked. |
| Only the unlock path has any protection (HMAC challenge). Everything else is open. | `ServerManager.handleUnlock(signature:from:)` | Inconsistent security model. |

### 1.2 Mouse and trackpad

| Issue | Where | Impact |
|---|---|---|
| Cursor is moved with `CGWarpMouseCursorPosition` and no `mouseMoved` event is posted. | `InputController.moveMouse(dx:dy:)` | Apps receive no hover, no tooltips, no drag feedback, no cursor shape changes. |
| Cursor position is captured once at init and never resynced. | `InputController.init()` | After touching the physical mouse, the remote cursor jumps back to a stale position. |
| Bounds are clamped to `NSScreen.main` only. | `InputController.moveMouse(dx:dy:)` | Cannot reach a second display. |
| No acceleration curve; fixed sensitivity of 1.5. | `TrackpadView.swift` | Either too slow for long travel or too twitchy for precision. |
| Every single tap waits 300 ms to rule out a double-tap. | `TrackpadView.handleDragEnd()` | Every click feels laggy. |
| No drag gesture. `mouseDown` / `mouseUp` exist in the protocol but nothing on the client sends them. | `TrackpadView.swift` | Cannot drag windows, select text, or drag-and-drop. |
| No two-finger scroll on the main pad; a separate 70 pt "Scroll" strip is used instead. | `ScrollTrackpadView` | Unnatural, and takes screen space. |
| `MagnificationGesture` is an empty stub. | `TrackpadView.swift` line 54 | Dead code, no pinch-to-zoom. |
| No right-click gesture; right click is a dedicated button. | `RemoteControlView.mouseButtons` | Slow and unlike a real trackpad. |
| Scroll posts `Int32(-dy * 10)` pixel units with no phase or momentum. | `InputController.scroll(dx:dy:)` | Scrolling feels stepped and stops dead. |
| Trackpad surface is small. It is locked to a 4:3 box with `.aspectRatio(4/3, contentMode: .fit)` and shares the tab with a scroll strip and two mouse buttons, so on a tall phone the pad is a fraction of the screen. | `TrackpadView.body`, `RemoteControlView.trackpadTab` | Short travel, frequent finger lifts, cramped feel. |
| **Bug: cursor gets stuck or snaps to the middle of the Mac screen.** Four contributing causes are visible in the code: (a) `currentPosition` is set once in `init()` and never resynced, so once the physical mouse moves the remote cursor snaps back to the stale point; (b) clamping uses `NSScreen.main.frame.width/height` from origin 0, ignoring the screen's origin, so on multi-display or non-primary main screens the clamp pins the cursor to the wrong region; (c) the trackpad tab lives inside a `.page` style `TabView`, which steals horizontal drags, so the cursor freezes on the x axis mid-gesture; (d) `CGWarpMouseCursorPosition` posts no event, so after a warp the system's local-event suppression interval can swallow subsequent moves. | `InputController.init()`, `InputController.moveMouse(dx:dy:)`, `RemoteControlView.body` (`.tabViewStyle(.page)`) | Cursor appears frozen or teleports to screen center; the most visible defect in daily use. |

### 1.3 Keyboard

| Issue | Where | Impact |
|---|---|---|
| Characters are mapped to US-layout virtual key codes. Anything not in the table is silently dropped. | `KeyCodes.code(for:)` in `KeyboardView.swift` | Accented letters, ñ, emoji and non-Latin scripts never arrive. The app ships a Spanish localization yet cannot type Spanish. |
| Backspace cannot be detected because the hidden `TextField` is cleared after every character. | `DirectKeyboardView.handleTextChange(from:to:)` | Only the dedicated Delete button deletes. |
| Autocorrect and autocapitalization are not disabled on the hidden field. | `DirectKeyboardView` | iOS mutates text before it is sent. |
| Modifiers cannot be held; only fixed combos (⌘C, ⌘V, ⌘Z). | `DirectKeyboardView` | Cannot do ⌘⇧T, ⌥→, ⌃C, etc. |
| `unlockScreen` already uses `keyboardSetUnicodeString`, which is the right API, but normal typing does not. | `InputController.swift` | Inconsistent; the correct approach exists in the file. |

### 1.4 Transport and streaming

| Issue | Where | Impact |
|---|---|---|
| Every finger movement is its own JSON message on a Nagle-enabled TCP socket. | `NetworkClient.send(_:)`, `NetworkServer.start(port:)` | Latency spikes and bursty delivery. |
| Video frames are H.264 wrapped in JSON with base64 `Data`. | `ServerMessage.screenFrame`, `ScreenFrame` | ~33 % bandwidth overhead and JSON parsing per frame. |
| Frame decode is dispatched to the main thread. | `NetworkClient.startReceiving()` → `handleMessage` → `ScreenViewModel.decodeFrame` | Main thread stalls at 30 fps. |
| Decoded frame goes CVPixelBuffer → CIImage → CGImage → UIImage → SwiftUI `Image`. | `VideoDecoder.createDecompressionSession()`, `ScreenView.screenDisplay(in:)` | Slowest possible render path; high CPU and battery use. |
| Touch on the screen view is relative, not absolute. | `ScreenView.handleDrag(value:in:imageSize:)` | Tapping a button on the image does not click that button. |
| Only `content.displays.first` is captured. | `ScreenCaptureManager.startStreaming(quality:)` | No multi-monitor support. |
| Quality cannot be changed mid-stream. | `ScreenView.swift` | Must stop and restart. |
| Decoder first creates a placeholder format description without SPS/PPS, which fails, then rebuilds on the first keyframe. | `VideoDecoder.setupDecoder(width:height:)` | Works by accident; wasted session creation. |

### 1.5 Connection lifecycle

| Issue | Where | Impact |
|---|---|---|
| No auto-reconnect and no remembered Mac. | `NetworkClient.swift`, `MacRemoteClientApp.swift` | Manual reconnect on every launch and every drop. |
| `ping` exists in the protocol but is never sent. | `RemoteMessage.ping` | Dead connections are not detected. |
| Modal connection sheet appears on every launch. | `MacRemoteClientApp.onAppear` | Friction before every use. |
| On a receive error the server returns and stops reading but keeps the connection in `connections`. | `NetworkServer.receiveMessage(from:)` | Zombie connections; wrong client count. |
| `connections` array is mutated on the network queue and read from the main actor. | `NetworkServer.swift` | Data race. |
| Server uses deprecated `NetService` when `NWListener.Service` can advertise directly. | `BonjourAdvertiser.swift` | Extra file and deprecated API for no benefit. |
| Server does not auto-start on launch; requires a click in the popover. | `ServerManager.init()`, `MacRemoteServerApp.swift` | Extra step every time the Mac restarts. |

### 1.6 Project hygiene

| Issue | Where |
|---|---|
| Zero tests, no CI. | repo root |
| `KeyboardView.swift` (the `KeyboardView` struct) is never referenced. Only `KeyCodes` from that file is used. | `MacRemoteClient/Sources/KeyboardView.swift` |
| `ScreenView.handleDragEnd` contains a no-op branch. | `ScreenView.swift` |
| Seven hardcoded English `Text("...")` literals on iOS plus `MediaButton` labels ("Vol -", "Play/Pause", "Bright +"). Entire Mac popover is unlocalized. | `RemoteControlView.swift`, `TrackpadView.swift`, `ConnectionView.swift`, `MacRemoteServerApp.swift` |
| `SWIFT_VERSION` is 5.9 in both `Project.swift` files but 6.0 in `Tuist/Config.swift`. Build emits main-actor isolation warnings. | `MacRemoteServer/Project.swift`, `MacRemoteClient/Project.swift`, `ServerManager.swift`, `ScreenCaptureManager.swift` |
| `Tuist/Config.swift` is deprecated; Tuist wants `Tuist.swift` at root. | `Tuist/Config.swift` |
| iPad is a declared destination but there is no iPad or landscape layout. | `MacRemoteClient/Project.swift` |
| Six-icon segmented picker with no labels acts as the tab bar. | `RemoteControlView.swift` |
| Protocol has no version or handshake. Adding an enum case breaks old peers with a silent decode error. | `Shared/RemoteMessage.swift` |
| App discovery scans only the top level of `/Applications` and `~/Applications`. Misses `/System/Applications`, `Utilities`, and nested folders. Re-encodes every icon as PNG on every request. | `InputController.getInstalledApps()` |
| `NSImage` drawing happens off the main thread in `getInstalledApps`. | `InputController.resizeAndEncodeIcon(_:size:)` called from a global queue in `ServerManager` |

### 1.7 Mac menu bar UI and onboarding

| Issue | Where | Impact |
|---|---|---|
| The popover shows everything at once: status, permission warnings, errors, the full Remote Unlock setup with a password field, the pairing key, Start/Stop and Quit. Nothing is collapsed or contextual. | `MacRemoteServerApp.swift` (`MenuBarView`) | Cluttered 320 pt panel; the one action the user needs (Start) is buried below a password field. |
| A `SecureField` for the Mac login password lives permanently in the menu bar popover. | `MenuBarView` | Sensitive setup mixed with everyday status. Easy to mis-tap; looks untrustworthy. |
| The pairing key is displayed in full, always, in monospace, with a Copy button. | `MenuBarView` | Secret material permanently on screen whenever the popover opens. |
| No onboarding. First launch drops the user into the popover with an orange warning and an "Open Settings" button. Screen Recording permission is never explained or requested up front, so screen sharing fails later with an error on the phone. | `MenuBarView`, `ServerManager.checkPermissions()` | High abandonment at first run; permission errors surface at the wrong time and on the wrong device. |
| Permission state is only refreshed when the user presses "Refresh". | `ServerManager.checkPermissions()` | The user grants access in System Settings and comes back to a stale warning. |
| Menu bar icon has two states only (running / not running). | `MacRemoteServerApp.body` | No indication of connected clients, streaming, or permission problems at a glance. |
| No Settings window, no About, no keyboard shortcut to toggle the server. | `MacRemoteServerApp.swift` | Everything is forced into the popover. |

---

## Part 2: The plan

Each phase ships independently and is verifiable before the next starts. Effort estimates assume one developer working full time.

### Phase 1: Foundations (1–2 days)

Goal: a safe base to refactor on.

- [x] Add `MacRemoteServerTests` (done, 27 tests) and `MacRemoteClientTests` (pending) targets in Tuist. Start with `MessageFrame` encode/decode round-trip tests and `KeyCodes` tests.
- [x] Add a GitHub Actions workflow that runs `tuist generate` and builds both schemes.
- [ ] Align `SWIFT_VERSION` to 6.0 everywhere and fix the main-actor isolation warnings in `ServerManager` and `ScreenCaptureManager`.
- [x] Make `NetworkServer` thread-safe: confine `connections` to its queue or make it an actor.
- [x] Rename `Tuist/Config.swift` → `Tuist.swift`.
- [ ] Delete `KeyboardView` struct (keep `KeyCodes` in its own file), the `MagnificationGesture` stub, and the no-op in `ScreenView.handleDragEnd`.
- [x] Add a `hello(version:)` client message and `welcome(version:)` server reply.
- [ ] Localize every remaining string on iOS and the Mac popover. Add a Mac `Localizable.xcstrings`.

### Phase 2: Security (3–4 days)

Goal: only paired devices can talk to the Mac, and the traffic is encrypted.

- [x] **Pairing flow.** Both halves done (see `docs/PAIRING_PROTOCOL.md`): 6-digit code for 60 s, X25519 key agreement with HKDF-derived keys, code proven by HMAC, one attempt per code. iOS pairs from Settings.
- [x] **TLS with pre-shared keys.** Mac listener on port+1 with one PSK per paired device; iOS connects in plaintext and upgrades to TLS once `welcome` identifies a paired Mac.
- [x] **Refuse all input from unpaired devices.** No pairing, no connection: the plaintext port only pairs; there is no opt-out.
- [x] **Frame length cap.** Reject any frame larger than a configurable limit (e.g. 16 MB for video, 64 KB for control) and close the connection.
- [x] **Paired devices list** in Settings → Devices with Rename and Forget; connected devices show a lock for encrypted links.
- [x] **Lock-state check before unlock.** Read `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]` and refuse to type the password unless the screen is locked. Drop the "wake with Space" keystroke in favour of a harmless key (e.g. Shift) or `IOPMAssertionDeclareUserActivity`.
- [x] Reuse the new shared key for the unlock HMAC. The legacy 64-character pairing key is removed on both sides.

### Phase 3: Input that feels native (4–5 days)

Goal: the trackpad and keyboard feel like a real Mac trackpad and keyboard.

**Client trackpad**
- [ ] Replace the SwiftUI `DragGesture` trackpad with a `UIViewRepresentable` hosting a custom `UIView` that handles raw `UITouch` events for true multitouch.
- [ ] Gestures: one-finger move; tap = instant click (no 300 ms wait; send click count so the Mac sets `mouseEventClickState`); two-finger drag = scroll with momentum; two-finger tap = right click; three-finger drag or tap-tap-hold = drag with `mouseDown`/`mouseUp`; pinch = ⌘+/⌘−.
- [ ] Acceleration curve (e.g. `delta * (1 + speed * k)`) with a sensitivity slider in Settings.
- [ ] Haptic feedback on click, right click, and drag start/end.
- [ ] **Full-bleed trackpad.** The entire background of the trackpad tab becomes the tracking surface, edge to edge, with no aspect-ratio lock. Remove `.aspectRatio(4/3, contentMode: .fit)` and the fixed-height scroll strip.
- [ ] **Floating controls above the pad.** Left/right click, modifier toggles and any future buttons sit in an overlay layer on top of the surface (a `ZStack` with the pad at the bottom). Touches that begin on a button are consumed by the button and never reach the pad. Buttons are translucent, pinned to the bottom edge, and can be hidden with a swipe-down so the pad can be 100 % of the screen.
- [ ] Remove the separate scroll strip and the inline Left/Right buttons; scrolling is two-finger and right click is two-finger tap, with the floating buttons as a fallback.
- [ ] **Stop the page swipe from stealing drags.** Switch `RemoteControlView` away from `.tabViewStyle(.page)` (or disable swipe navigation while on the trackpad tab) so horizontal finger movement always reaches the pad. This is cause (c) of the stuck-cursor bug.

**Server input**
- [x] **Fix the stuck/snapping cursor.** Resync `currentPosition` from `NSEvent.mouseLocation` (or `CGEvent(source: nil).location`) at the start of every move so the remote cursor continues from wherever the cursor actually is. This is cause (a).
- [x] Clamp against the union of all `NSScreen.screens` frames in global display coordinates, honouring each screen's origin, instead of `0...NSScreen.main.width/height`. This is cause (b).
- [x] Set `CGEventSource(stateID: .combinedSessionState).localEventsSuppressionInterval = 0` (or use `CGEventSourceSetLocalEventsFilterDuringSuppressionState`) so warps and posted moves never suppress each other. This is cause (d).
- [x] Add a regression test that feeds a sequence of deltas across a simulated two-display layout and asserts the cursor never leaves the union of the screens and never jumps more than the delta.
- [x] Post real `.mouseMoved` / `.leftMouseDragged` `CGEvent`s with `mouseEventDeltaX/Y` set instead of warping.
- [ ] Scroll with `.pixel` units and set `scrollWheelEventScrollPhase` / `momentumPhase` so apps apply inertia.

**Keyboard**
- [ ] Add `RemoteMessage.text(String)` and inject it with `keyboardSetUnicodeString` on the Mac. This makes typing layout- and language-independent.
- [ ] Replace the hidden `TextField` with a `UIKeyInput`-conforming view so `deleteBackward()` is received directly and `hasText` can lie to keep the keyboard open.
- [ ] Sticky modifier keys (⌘ ⌥ ⌃ ⇧) that combine with the next key or arrow.
- [ ] Disable autocorrect, autocapitalization, smart quotes and predictive text on the input view.

**Transport**
- [x] Set `NWProtocolTCP.Options().noDelay = true` on both ends.
- [ ] Coalesce mouse deltas on the client to one message per display frame (`CADisplayLink`).

### Phase 4: Connection you never think about (2 days)

- [~] **Wake the Mac from sleep.** Mac sends `wakeInfo` (hardware addresses, broadcast, Wake-for-network-access state) and surfaces the Energy setting in Settings and onboarding. iOS: Wake button + automatic magic packet on failed reconnect (see `docs/WAKE_ON_LAN.md`).
- [ ] Persist the last connected Mac (service name + device ID) and auto-connect on launch when it is discovered.
- [ ] Reconnect with exponential backoff on drop; keep browsing in the background.
- [ ] Send `ping` every 5 s; treat two missed `pong`s as a dead connection on both sides.
- [x] Clean teardown: on any receive error, cancel the connection and remove it from `connections`.
- [ ] Replace the modal connection sheet with a non-blocking status banner and a Macs list reachable from the toolbar.

### Phase 5: Screen sharing done right (4–5 days)

- [ ] **Binary framing for video.** Add a one-byte message type to the frame header. Control messages stay JSON; video frames are raw H.264 with a fixed binary header (width, height, pts, keyframe flag). No base64.
- [ ] Decode on a dedicated queue, never on main.
- [ ] Render with `AVSampleBufferDisplayLayer` (zero-copy) instead of UIImage conversion. Delete the CIContext path.
- [ ] Map taps and drags on the image to absolute Mac screen coordinates. Add `RemoteMessage.moveTo(x:y:)`.
- [ ] Pinch to zoom and two-finger pan on the remote image; one-finger stays as pointer.
- [~] Display picker populated from `SCShareableContent.displays` (done as a Mac Settings option; an in-stream picker on iOS still pending).
- [ ] Mid-stream quality change via `VTSessionSetProperty` on the live compression session.
- [ ] HEVC option (`kCMVideoCodecType_HEVC`) with fallback to H.264 when the client cannot decode it.
- [ ] Adaptive bitrate: lower it when send completions start lagging.
- [ ] Fix `VideoDecoder` to wait for the first SPS/PPS before creating a session.

### Phase 6: Mac app redesign, onboarding and polish (4–5 days)

Goal: the Mac app looks and behaves like a first-class macOS menu bar utility. Show only what the user needs now; reveal more when there is intent.

**Design principles for the menu bar popover**
- Progressive disclosure. The default view answers one question: "Is my Mac reachable from my phone?" Everything else is one click deeper.
- One primary action at a time. Start when stopped, nothing when running and healthy, Fix when something is wrong.
- Secrets are never displayed by default. Passwords are entered in a dedicated sheet, pairing codes are shown only during an active pairing window and expire.
- Errors and warnings replace content; they are not stacked on top of it.
- Native materials and controls: `MenuBarExtra` with `.window` style, system fonts, `Form` and `Section` for settings, SF Symbols with semantic colours.

**Menu bar icon states**
- [x] Idle (server stopped): slashed antenna, monochrome.
- [x] Running, no clients: antenna, monochrome.
- [x] Running, clients connected: antenna with a small badge or filled variant; tooltip shows "1 device connected".
- [ ] Streaming: display symbol or animated dot.
- [x] Needs attention (permission missing, port in use): antenna with an orange badge.

**Popover layout (default state)**
- [x] Header row: Mac name, status pill ("Reachable", "Stopped", "Needs permission"), and a single toggle switch to start/stop the server. No separate Start/Stop button.
- [~] Devices section, shown only when the server is running (done for *connected* devices; paired devices arrive with Phase 2): a list of paired devices with a green dot for connected ones and "last seen" for others. Hover reveals a `…` menu with Forget. Empty state: "No devices paired yet · Pair a device" as a single link.
- [x] Activity line, shown only when relevant: "Streaming to Bart's iPhone · 1080p" or "Unlock sent 2 min ago".
- [x] Footer: `Pair a device…`, `Settings…` (⌘,), and a `⋯` menu holding About, Check for Updates, Quit (⌘Q). Quit is not a primary button.
- [x] Problem state replaces the body: one icon, one sentence, one button. Examples: "Accessibility access is required to control the mouse and keyboard. → Grant Access"; "Port 5150 is already in use. → Choose Another Port".

**Pairing sheet (triggered by intent)**
- [x] `Pair a device…` opens a compact window with a large 6-digit code, a 60 s countdown ring, and the instruction "Open MacRemote on your iPhone and enter this code". The code is never shown anywhere else. Closes itself on success with a checkmark.

**Remote Unlock (moved out of the popover)**
- [x] Lives in Settings → Security as a single toggle. Turning it on presents a modal sheet explaining what is stored and where, with the `SecureField`. The password is never visible again after saving; the UI shows "Enabled · Password stored in Keychain" with a Change… and Disable button.
- [ ] The separate pairing key copy/paste flow is removed; unlock reuses the device pairing from Phase 2.

**Settings window (⌘,)**
- [x] General: Launch at login, Start server automatically, Mac name as shown on the phone, Port.
- [x] Devices: paired devices table with Forget and Rename; a "Pair a device…" button.
- [ ] Security: Remote Unlock toggle (above), "Require pairing for new devices" (always on, informational), option to auto-lock when the last device disconnects.
- [x] Screen Sharing: default quality, which display to share, show cursor.
- [x] About: version, link to repository, acknowledgements.

**Onboarding (first launch and whenever a required permission is missing)**
- [x] A dedicated onboarding window, not the popover, opened automatically on first launch and reachable later from Settings → "Run setup again".
- [x] Step 1 — Welcome: one sentence on what MacRemote does and a single Continue button.
- [x] Step 2 — Accessibility: explain in plain language why it is needed ("to move the mouse and type on your behalf"), one `Open System Settings` button that deep-links to Privacy & Security → Accessibility, and a live status indicator. The app polls `AXIsProcessTrusted()` once per second and the step completes itself with a checkmark the moment access is granted. No Refresh button.
- [x] Step 3 — Screen Recording: same pattern, deep-link to Privacy & Security → Screen Recording, polling `CGPreflightScreenCaptureAccess()` / `SCShareableContent`. Clearly marked "Optional · needed for Screen Sharing" with a Skip link, so a user who only wants the trackpad is not blocked.
- [~] Step 4 — Local Network (folded into the Start step; the listener start triggers the prompt): on macOS 15+ trigger the Local Network prompt by starting the listener, explain why, and detect the result.
- [x] Step 5 — Start & Pair: start the server, show the 6-digit pairing code inline, and wait for the first device. Completes with "You're all set" and closes to the menu bar.
- [x] Each step has a progress indicator at the top and Back/Continue at the bottom. Continue is disabled until the step is satisfied or skipped.
- [x] If a previously granted permission is later revoked (e.g. after an app rebuild changes the code-signing identity), the menu bar icon switches to the attention state and the popover's problem state offers "Fix" which opens the relevant onboarding step directly.
- [x] Permission checks run on launch and poll every second, never only on a manual button press.

**Behaviour**
- [x] Auto-start the server on launch when all required permissions are granted.
- [x] Launch at login via `SMAppService.mainApp`, exposed as a toggle in Settings and offered once at the end of onboarding.
- [x] Replace `BonjourAdvertiser` + `NetService` with `NWListener.service = NWListener.Service(name:type:)`.
- [ ] Global shortcut to toggle the server (configurable, default ⌃⌥⌘R).
- [x] Localize the whole Mac app (new `Localizable.xcstrings` in the server target).

**App launcher backend**
- [x] (`AppCatalog`) Move `getInstalledApps` icon rendering to the main actor or use `NSImage.cgImage(forProposedRect:context:hints:)` safely off-main. Cache icons by bundle ID + version on disk.
- [x] Scan `/System/Applications`, `/Applications/Utilities`, and one level of nested folders. Use `NSWorkspace.shared.urlsForApplications(...)` where available.
- [ ] Add running apps section (`NSWorkspace.runningApplications`) with switch-to and quit.

### Phase 7: iOS polish and features (3–5 days)

- [ ] Real `TabView` with labelled tabs; collapse six tabs to four (Trackpad, Screen, Keyboard, More).
- [ ] iPad and landscape layouts (trackpad left, keyboard/media right).
- [ ] Presentation mode: large ← → buttons, B for blank, timer, and a laser-pointer mode on the screen view.
- [ ] Volume slider backed by a new `RemoteMessage.setVolume(Float)` using CoreAudio on the Mac.
- [ ] Now Playing display via AppleScript to Music/Spotify on the Mac (`ServerMessage.nowPlaying`).
- [ ] App Intents: "Lock my Mac", "Play/Pause", "Launch <app>" for Siri, Shortcuts and the Action button.
- [ ] Settings screen: sensitivity, haptics, scroll direction, stream quality default.
- [ ] Icon cache on the client keyed by bundle ID so the Apps tab renders instantly.

---

## Part 3: Order and milestones

| Milestone | Phases | Outcome |
|---|---|---|
| M1: Safe | 1 + 2 | Can be left running on any network. Tests and CI exist. |
| M2: Feels good | 3 + 4 | Trackpad and keyboard are as good as a Bluetooth peripheral. Connection is invisible. |
| M3: Looks good | 5 | Screen sharing is smooth, absolute, multi-display. |
| M4: Complete | 6 + 7 | Redesigned Mac menu bar app with onboarding, polished iOS app with headline features. |

Start with Phase 1 and Phase 2 together on a `security` branch. Phase 3 is the biggest UX win and should follow immediately.

## Part 4: Explicit non-goals for now

- Internet / relay connectivity (Tailscale or iCloud relay). LAN-only keeps the security model simple.
- Audio streaming.
- File transfer.
- Apple Watch app.

These can be revisited after M4.
