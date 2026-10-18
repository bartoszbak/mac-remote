import XCTest
import AppKit
import ApplicationServices
@testable import MacRemoteServer

final class KeyPressTypingTests: XCTestCase {

    func testLayoutMapCoversPrintableASCIIOnLatinLayouts() throws {
        let map = try XCTUnwrap(KeyboardLayoutMap.current())
        let letters = "abcdefghijklmnopqrstuvwxyz"
        for character in letters + letters.uppercased() + "0123456789 " {
            XCTAssertNotNil(map.stroke(for: character), "no key for \(character) on \(map.layoutID)")
        }
        // Uppercase needs Shift, lowercase doesn't.
        XCTAssertEqual(map.stroke(for: "a")?.shift, false)
        XCTAssertEqual(map.stroke(for: "A")?.shift, true)
        XCTAssertEqual(map.stroke(for: "a")?.keyCode, map.stroke(for: "A")?.keyCode)
    }

    func testMainRowIsPreferredOverKeypad() throws {
        let map = try XCTUnwrap(KeyboardLayoutMap.current())
        // Digits must come from the main row (key codes 18...29), not the keypad.
        for digit in "0123456789" {
            let code = try XCTUnwrap(map.stroke(for: digit)?.keyCode)
            XCTAssertTrue((18...29).contains(code) || map.stroke(for: digit)?.shift == true,
                          "\(digit) mapped to \(code)")
        }
    }

    /// Types into a focused NSSecureTextField in this process (Secure Event Input on) using
    /// real key presses. Events go only to this process, never to the frontmost app.
    @MainActor
    func testKeyPressesTypePasswordIntoSecureField() throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs Accessibility permission to post key events")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 60), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let field = NSSecureTextField(frame: NSRect(x: 10, y: 15, width: 340, height: 24))
        window.contentView?.addSubview(field)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        defer { window.orderOut(nil) }
        pumpEvents(until: { window.isKeyWindow }, timeout: 3)
        try XCTSkipUnless(window.isKeyWindow, "test window could not become key")

        let passwords = ["Abc123!@#xyz", "p4ss word \"quoted\" ~`[]{}", "Correct-Horse-Battery-Staple-42!-and-more"]
        let controller = InputController()
        for password in passwords {
            field.stringValue = ""
            let unmapped = controller.typeAsKeyPresses(password, interval: 2_000, target: .process(getpid()))
            XCTAssertTrue(unmapped.isEmpty, "unmapped: \(unmapped)")
            pumpEvents(until: { field.stringValue.count >= password.count }, timeout: 4)
            XCTAssertEqual(field.stringValue, password)
        }
    }

    /// The unlock sequence: password key presses then Return. Return must arrive last,
    /// stamped no earlier than the characters before it, with no modifiers held, and it
    /// must submit the field (fire its action) with the full password in it.
    @MainActor
    func testPasswordThenReturnSubmitsInOrderWithoutModifiers() throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs Accessibility permission to post key events")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 60), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let field = NSSecureTextField(frame: NSRect(x: 10, y: 15, width: 340, height: 24))
        let submit = SubmitRecorder()
        field.target = submit
        field.action = #selector(SubmitRecorder.submitted(_:))
        window.contentView?.addSubview(field)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        defer { window.orderOut(nil) }
        pumpEvents(until: { window.isKeyWindow }, timeout: 3)
        try XCTSkipUnless(window.isKeyWindow, "test window could not become key")

        var keyDowns: [(keyCode: UInt16, timestamp: TimeInterval, modifiers: NSEvent.ModifierFlags)] = []
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            keyDowns.append((event.keyCode, event.timestamp, event.modifierFlags.intersection(.deviceIndependentFlagsMask)))
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }

        // Ends with a Shift character, the case where a held modifier could leak into Return.
        let password = "Unlock-Me-42!"
        InputController().typePasswordAndSubmit(password, interval: 2_000, target: .process(getpid()))
        pumpEvents(until: { submit.value != nil }, timeout: 4)

        XCTAssertEqual(submit.value, password, "Return did not submit the full password")
        let returns = keyDowns.filter { $0.keyCode == 36 }
        XCTAssertEqual(returns.count, 1)
        let lastCharacter = try XCTUnwrap(keyDowns.last { $0.keyCode != 36 })
        let returnPress = try XCTUnwrap(returns.first)
        XCTAssertGreaterThanOrEqual(returnPress.timestamp, lastCharacter.timestamp, "Return stamped before the password")
        XCTAssertTrue(returnPress.modifiers.intersection([.shift, .option, .command, .control]).isEmpty,
                      "Return carried modifiers: \(returnPress.modifiers)")
    }

    /// Dispatches queued AppKit events (key events need NSApp.sendEvent, not just a run loop spin).
    @MainActor
    private func pumpEvents(until done: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }
}

/// Records what an NSSecureTextField held when its action fired (Return pressed).
private final class SubmitRecorder: NSObject {
    var value: String?
    @objc func submitted(_ sender: NSSecureTextField) { value = sender.stringValue }
}
