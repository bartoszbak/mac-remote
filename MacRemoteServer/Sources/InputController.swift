import Foundation
import CoreGraphics
import AppKit

// Media key constants from IOKit/hidsystem/ev_keymap.h
private let NX_KEYTYPE_PLAY: Int32 = 16
private let NX_KEYTYPE_NEXT: Int32 = 17
private let NX_KEYTYPE_PREVIOUS: Int32 = 18
private let NX_KEYTYPE_SOUND_UP: Int32 = 0
private let NX_KEYTYPE_SOUND_DOWN: Int32 = 1
private let NX_KEYTYPE_MUTE: Int32 = 7
private let NX_KEYTYPE_BRIGHTNESS_UP: Int32 = 2
private let NX_KEYTYPE_BRIGHTNESS_DOWN: Int32 = 3

/// Controls mouse and keyboard input on macOS using the CGEvent API.
///
/// Cursor movement is always relative to where the cursor *actually* is, so the
/// remote cursor continues from wherever the physical mouse left it. Positions
/// are clamped to the union of all active displays in global display coordinates
/// (top-left origin), the same space `CGEvent.location` and `CGDisplayBounds` use.
final class InputController {

    enum UnlockOutcome {
        case posted
        case screenNotLocked
        case failed
    }

    /// Shared event source with local-event suppression disabled so a posted move
    /// never swallows the ones that follow it.
    private let eventSource: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    private var leftButtonDown = false
    private var rightButtonDown = false

    /// Fractional movement that did not amount to a whole pixel yet.
    private var subpixelRemainder = CGPoint.zero

    // MARK: - Cursor

    /// Current cursor location in global display coordinates.
    var cursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Bounds of every active display in global display coordinates.
    static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return [CGDisplayBounds(CGMainDisplayID())]
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return [CGDisplayBounds(CGMainDisplayID())]
        }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Returns `point` if it lies on any display, otherwise the nearest point that does.
    static func clamp(_ point: CGPoint, to displays: [CGRect]) -> CGPoint {
        guard !displays.isEmpty else { return point }
        if displays.contains(where: { $0.contains(point) }) {
            return point
        }
        var best = point
        var bestDistance = CGFloat.infinity
        for rect in displays {
            let x = min(max(point.x, rect.minX), rect.maxX - 1)
            let y = min(max(point.y, rect.minY), rect.maxY - 1)
            let distance = hypot(x - point.x, y - point.y)
            if distance < bestDistance {
                bestDistance = distance
                best = CGPoint(x: x, y: y)
            }
        }
        return best
    }

    // MARK: - Mouse Movement

    func moveMouse(dx: Double, dy: Double) {
        let current = cursorLocation

        // Carry sub-pixel remainders so slow, precise movements are not lost.
        let wantedX = dx + subpixelRemainder.x
        let wantedY = dy + subpixelRemainder.y
        let stepX = wantedX.rounded(.towardZero)
        let stepY = wantedY.rounded(.towardZero)
        subpixelRemainder = CGPoint(x: wantedX - stepX, y: wantedY - stepY)
        guard stepX != 0 || stepY != 0 else { return }

        let target = Self.clamp(CGPoint(x: current.x + stepX, y: current.y + stepY),
                                to: Self.activeDisplayBounds())

        let type: CGEventType
        let button: CGMouseButton
        if leftButtonDown {
            type = .leftMouseDragged
            button = .left
        } else if rightButtonDown {
            type = .rightMouseDragged
            button = .right
        } else {
            type = .mouseMoved
            button = .left
        }

        guard let event = CGEvent(mouseEventSource: eventSource,
                                  mouseType: type,
                                  mouseCursorPosition: target,
                                  mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(target.x - current.x))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(target.y - current.y))
        event.post(tap: .cghidEventTap)
    }

    /// Moves the cursor to an absolute position in global display coordinates.
    func moveMouse(to point: CGPoint) {
        let target = Self.clamp(point, to: Self.activeDisplayBounds())
        guard let event = CGEvent(mouseEventSource: eventSource,
                                  mouseType: leftButtonDown ? .leftMouseDragged : .mouseMoved,
                                  mouseCursorPosition: target,
                                  mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Mouse Clicks

    func click(button: RemoteMessage.MouseButton) {
        postClick(button: button, clickCount: 1)
    }

    func doubleClick(button: RemoteMessage.MouseButton) {
        postClick(button: button, clickCount: 1)
        usleep(50_000)
        postClick(button: button, clickCount: 2)
    }

    private func postClick(button: RemoteMessage.MouseButton, clickCount: Int) {
        let (downType, upType, cgButton) = mouseEventTypes(for: button)
        let position = cursorLocation

        guard let down = CGEvent(mouseEventSource: eventSource, mouseType: downType,
                                 mouseCursorPosition: position, mouseButton: cgButton),
              let up = CGEvent(mouseEventSource: eventSource, mouseType: upType,
                               mouseCursorPosition: position, mouseButton: cgButton) else { return }

        down.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        up.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        down.post(tap: .cghidEventTap)
        usleep(10_000)
        up.post(tap: .cghidEventTap)
    }

    func mouseDown(button: RemoteMessage.MouseButton) {
        let (downType, _, cgButton) = mouseEventTypes(for: button)
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: downType,
                                  mouseCursorPosition: cursorLocation, mouseButton: cgButton) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
        setButtonState(button, down: true)
    }

    func mouseUp(button: RemoteMessage.MouseButton) {
        let (_, upType, cgButton) = mouseEventTypes(for: button)
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: upType,
                                  mouseCursorPosition: cursorLocation, mouseButton: cgButton) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
        setButtonState(button, down: false)
    }

    /// Releases any button the remote left pressed, e.g. when the client disconnects mid-drag.
    func releaseAllButtons() {
        if leftButtonDown { mouseUp(button: .left) }
        if rightButtonDown { mouseUp(button: .right) }
    }

    private func setButtonState(_ button: RemoteMessage.MouseButton, down: Bool) {
        switch button {
        case .left: leftButtonDown = down
        case .right: rightButtonDown = down
        }
    }

    // MARK: - Scrolling

    func scroll(dx: Double, dy: Double) {
        let event = CGEvent(scrollWheelEvent2Source: eventSource,
                            units: .pixel,
                            wheelCount: 2,
                            wheel1: Int32((-dy * 10).rounded()),
                            wheel2: Int32((-dx * 10).rounded()),
                            wheel3: 0)
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    func keyEvent(code: UInt16, down: Bool, flags: UInt64) {
        guard let event = CGEvent(keyboardEventSource: eventSource,
                                  virtualKey: code,
                                  keyDown: down) else { return }
        event.flags = CGEventFlags(rawValue: flags)
        event.post(tap: .cghidEventTap)
    }

    /// Types arbitrary Unicode text regardless of the Mac's keyboard layout.
    func typeText(_ text: String) {
        typeCharacters(text, interval: 0)
    }

    /// Where synthetic events go. `.hid` is the real input stream (what the lock screen
    /// reads); `.process` delivers to one app only, which tests use so keystrokes can
    /// never land in whatever app is in front.
    enum EventTarget {
        case hid
        case process(pid_t)
    }

    private func post(_ event: CGEvent, to target: EventTarget) {
        switch target {
        case .hid: event.post(tap: .cghidEventTap)
        case .process(let pid): event.postToPid(pid)
        }
    }

    /// Types text as real key presses (key code + Shift/Option) on the current keyboard
    /// layout, holding modifier keys down around each character like a person would.
    /// Needed for the lock screen, which ignores text attached to synthetic events.
    /// Characters the layout cannot type in one keystroke fall back to a text event.
    /// - Returns: the characters that had no key on this layout.
    @discardableResult
    func typeAsKeyPresses(_ text: String, interval: useconds_t = 20_000, target: EventTarget = .hid) -> [Character] {
        let map = KeyboardLayoutMap.current()
        var unmapped: [Character] = []
        let shiftKey: CGKeyCode = 56
        let optionKey: CGKeyCode = 58

        func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
            guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down) else { return }
            event.flags = flags
            post(event, to: target)
        }

        for character in text {
            guard let stroke = map?.stroke(for: character) else {
                unmapped.append(character)
                var utf16 = Array(String(character).utf16)
                if let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
                   let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) {
                    down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                    up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                    post(down, to: target)
                    post(up, to: target)
                }
                usleep(interval)
                continue
            }

            var flags: CGEventFlags = []
            if stroke.shift {
                flags.insert(.maskShift)
                key(shiftKey, down: true, flags: flags)
            }
            if stroke.option {
                flags.insert(.maskAlternate)
                key(optionKey, down: true, flags: flags)
            }
            key(stroke.keyCode, down: true, flags: flags)
            key(stroke.keyCode, down: false, flags: flags)
            if stroke.option {
                flags.remove(.maskAlternate)
                key(optionKey, down: false, flags: flags)
            }
            if stroke.shift {
                flags.remove(.maskShift)
                key(shiftKey, down: false, flags: flags)
            }
            usleep(interval)
        }
        if !unmapped.isEmpty {
            print("[InputController] \(unmapped.count) character(s) have no key on layout \(map?.layoutID ?? "unknown")")
        }
        return unmapped
    }

    /// Posts one key press per Unicode scalar, each carrying just that character.
    ///
    /// One character per event matters: macOS truncates the string attached to a single
    /// key event (about 20 UTF-16 units), and secure fields such as the lock screen do not
    /// reliably take several characters from one event. Verified against a focused
    /// NSSecureTextField with Secure Event Input on.
    /// - Parameter interval: pause between characters, for receivers that drop fast input.
    private func typeCharacters(_ text: String, interval: useconds_t) {
        for scalar in text.unicodeScalars {
            var utf16 = Array(String(scalar).utf16)
            guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else { continue }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            if interval > 0 { usleep(interval) }
        }
    }

    // MARK: - Media Controls

    func mediaAction(_ action: RemoteMessage.MediaAction) {
        let keyCode: Int32
        switch action {
        case .playPause: keyCode = NX_KEYTYPE_PLAY
        case .nextTrack: keyCode = NX_KEYTYPE_NEXT
        case .previousTrack: keyCode = NX_KEYTYPE_PREVIOUS
        case .volumeUp: keyCode = NX_KEYTYPE_SOUND_UP
        case .volumeDown: keyCode = NX_KEYTYPE_SOUND_DOWN
        case .mute: keyCode = NX_KEYTYPE_MUTE
        case .brightnessUp: keyCode = NX_KEYTYPE_BRIGHTNESS_UP
        case .brightnessDown: keyCode = NX_KEYTYPE_BRIGHTNESS_DOWN
        }
        postMediaKeyEvent(keyCode: keyCode)
    }

    private func postMediaKeyEvent(keyCode: Int32) {
        func doKey(down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: (down ? 0xa00 : 0xb00))
            let data1 = Int((keyCode << 16) | (down ? 0xa00 : 0xb00))
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) else { return }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
        doKey(down: true)
        doKey(down: false)
    }

    // MARK: - System Actions

    func systemAction(_ action: RemoteMessage.SystemAction) {
        switch action {
        case .lock:
            lockScreen()
        }
    }

    private func lockScreen() {
        // Ctrl+Cmd+Q is the system lock-screen shortcut.
        let keyQ: UInt16 = 12
        let flags = CGEventFlags([.maskCommand, .maskControl])
        guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: keyQ, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: keyQ, keyDown: false) else {
            print("[InputController] Failed to create lock screen key events")
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        print("[InputController] Lock screen command executed")
    }

    /// Whether the login window / screen lock is currently showing.
    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool { return locked }
        if let locked = session["CGSSessionScreenIsLocked"] as? Int { return locked != 0 }
        return false
    }

    /// Posts HID-level events to type the password into the lock screen.
    /// Refuses to do anything unless the screen is actually locked, so the password
    /// can never end up in a document or chat window.
    func unlockScreen(password: String) -> UnlockOutcome {
        guard !password.isEmpty else { return .failed }
        guard Self.isScreenLocked else {
            print("[InputController] Unlock refused: screen is not locked")
            return .screenNotLocked
        }

        // Wake the display and reveal the password field. Shift is harmless if the
        // field is already visible, unlike Space which would type a character.
        guard let wakeDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 56, keyDown: true),
              let wakeUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 56, keyDown: false) else {
            return .failed
        }
        wakeDown.post(tap: .cghidEventTap)
        wakeUp.post(tap: .cghidEventTap)
        usleep(700_000)

        guard Self.isScreenLocked else { return .screenNotLocked }

        let unmapped = typePasswordAndSubmit(password)
        if !unmapped.isEmpty {
            print("[InputController] Unlock may fail: password has characters with no key on this layout")
        }
        print("[InputController] Remote unlock events posted")
        return .posted
    }

    /// Types `password` as real key presses (the lock screen reads key codes and ignores
    /// attached text), then presses Return.
    ///
    /// Return is created at the moment it is sent. An event is stamped when it is created,
    /// and a Return created before the password would arrive stamped *earlier* than the
    /// characters it follows; the lock screen drops such an out-of-order event, leaving
    /// the password typed but never submitted. It also carries no modifier flags.
    @discardableResult
    func typePasswordAndSubmit(_ password: String, interval: useconds_t = 20_000,
                               target: EventTarget = .hid) -> [Character] {
        let unmapped = typeAsKeyPresses(password, interval: interval, target: target)
        usleep(150_000)
        let returnKey: CGKeyCode = 36
        if let down = CGEvent(keyboardEventSource: eventSource, virtualKey: returnKey, keyDown: true) {
            down.flags = []
            post(down, to: target)
        }
        usleep(15_000)
        if let up = CGEvent(keyboardEventSource: eventSource, virtualKey: returnKey, keyDown: false) {
            up.flags = []
            post(up, to: target)
        }
        return unmapped
    }

    // MARK: - Screen Info

    var screenSize: CGSize {
        CGDisplayBounds(CGMainDisplayID()).size
    }

    // MARK: - App Launcher

    func launchApp(bundleId: String) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            print("[InputController] App not found: \(bundleId)")
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
            if let error {
                print("[InputController] Failed to launch \(bundleId): \(error)")
            } else {
                print("[InputController] Launched \(app?.localizedName ?? bundleId)")
            }
        }
        return true
    }

    // MARK: - Private Helpers

    private func mouseEventTypes(for button: RemoteMessage.MouseButton) -> (CGEventType, CGEventType, CGMouseButton) {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseUp, .left)
        case .right: return (.rightMouseDown, .rightMouseUp, .right)
        }
    }
}
