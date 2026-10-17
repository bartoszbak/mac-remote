import SwiftUI
import UIKit

/// Invisible first responder that receives raw keyboard input.
///
/// Conforming to `UIKeyInput` instead of hosting a text field means backspace arrives as
/// `deleteBackward()`, `hasText` can always be true so the keyboard never changes its
/// return key or dismisses itself, and no text is ever buffered on the phone. Hardware
/// keyboards deliver arrows, Escape, function keys and ⌘/⌃/⌥ shortcuts through
/// `pressesBegan`, which is mapped to Mac key codes here.
final class KeyInputUIView: UIView, UIKeyInput {

    var onText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    /// A key that must be sent as a virtual key code, with CGEvent modifier flags.
    var onKey: ((_ code: UInt16, _ flags: UInt64) -> Void)?

    // MARK: UIKeyInput

    var hasText: Bool { true }

    func insertText(_ text: String) {
        onText?(text)
    }

    func deleteBackward() {
        onDeleteBackward?()
    }

    // MARK: UITextInputTraits

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically: Bool = false

    override var canBecomeFirstResponder: Bool { true }

    // MARK: Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let mapped = Self.keyCode(for: key) else {
                unhandled.insert(press)
                continue
            }
            onKey?(mapped, Self.flags(from: key.modifierFlags))
        }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    /// Keys that cannot be expressed as text: navigation, function keys, and any key
    /// pressed with ⌘, ⌃ or ⌥ held.
    private static func keyCode(for key: UIKey) -> UInt16? {
        if let code = specialKeyCodes[key.keyCode] {
            return code
        }
        let shortcutModifiers: UIKeyModifierFlags = [.command, .control, .alternate]
        guard !key.modifierFlags.intersection(shortcutModifiers).isEmpty,
              let character = key.charactersIgnoringModifiers.first else { return nil }
        return KeyCodes.code(for: character)
    }

    private static let specialKeyCodes: [UIKeyboardHIDUsage: UInt16] = [
        .keyboardLeftArrow: KeyCodes.leftArrow,
        .keyboardRightArrow: KeyCodes.rightArrow,
        .keyboardUpArrow: KeyCodes.upArrow,
        .keyboardDownArrow: KeyCodes.downArrow,
        .keyboardEscape: KeyCodes.escape,
        .keyboardTab: KeyCodes.tab,
        .keyboardReturnOrEnter: KeyCodes.returnKey,
        .keyboardDeleteOrBackspace: KeyCodes.delete,
        .keyboardF1: KeyCodes.functionKey(1), .keyboardF2: KeyCodes.functionKey(2),
        .keyboardF3: KeyCodes.functionKey(3), .keyboardF4: KeyCodes.functionKey(4),
        .keyboardF5: KeyCodes.functionKey(5), .keyboardF6: KeyCodes.functionKey(6),
        .keyboardF7: KeyCodes.functionKey(7), .keyboardF8: KeyCodes.functionKey(8),
        .keyboardF9: KeyCodes.functionKey(9), .keyboardF10: KeyCodes.functionKey(10),
        .keyboardF11: KeyCodes.functionKey(11), .keyboardF12: KeyCodes.functionKey(12)
    ]

    static func flags(from modifiers: UIKeyModifierFlags) -> UInt64 {
        var flags: UInt64 = 0
        if modifiers.contains(.command) { flags |= KeyCodes.maskCommand }
        if modifiers.contains(.alternate) { flags |= KeyCodes.maskOption }
        if modifiers.contains(.control) { flags |= KeyCodes.maskControl }
        if modifiers.contains(.shift) { flags |= KeyCodes.maskShift }
        return flags
    }
}

/// SwiftUI wrapper. `isActive` shows or hides the keyboard and is set back to false when
/// the keyboard is dismissed by other means.
struct KeyInputView: UIViewRepresentable {
    @Binding var isActive: Bool
    var onText: (String) -> Void
    var onDeleteBackward: () -> Void
    var onKey: (_ code: UInt16, _ flags: UInt64) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: $isActive)
    }

    func makeUIView(context: Context) -> KeyInputUIView {
        let view = KeyInputUIView()
        view.isAccessibilityElement = false
        apply(to: view)
        context.coordinator.observe(view)
        return view
    }

    func updateUIView(_ uiView: KeyInputUIView, context: Context) {
        apply(to: uiView)
        let wantsFocus = isActive
        DispatchQueue.main.async {
            if wantsFocus, !uiView.isFirstResponder, uiView.window != nil {
                uiView.becomeFirstResponder()
            } else if !wantsFocus, uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
        }
    }

    private func apply(to view: KeyInputUIView) {
        view.onText = onText
        view.onDeleteBackward = onDeleteBackward
        view.onKey = onKey
    }

    final class Coordinator {
        private let isActive: Binding<Bool>
        private weak var view: KeyInputUIView?
        private var observer: NSObjectProtocol?

        init(isActive: Binding<Bool>) {
            self.isActive = isActive
        }

        func observe(_ view: KeyInputUIView) {
            self.view = view
            observer = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.view?.isFirstResponder != true else { return }
                if self.isActive.wrappedValue {
                    self.isActive.wrappedValue = false
                }
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

#Preview("Key input (invisible)") {
    struct Host: View {
        @State private var isActive = true
        @State private var log: [String] = []
        var body: some View {
            VStack {
                KeyInputView(isActive: $isActive,
                             onText: { log.append("text: \($0)") },
                             onDeleteBackward: { log.append("delete") },
                             onKey: { code, flags in log.append("key \(code) flags \(flags)") })
                    .frame(width: 0, height: 0)
                List(log.indices, id: \.self) { Text(log[$0]) }
                Button(isActive ? "Hide keyboard" : "Show keyboard") { isActive.toggle() }
            }
        }
    }
    return Host()
}
