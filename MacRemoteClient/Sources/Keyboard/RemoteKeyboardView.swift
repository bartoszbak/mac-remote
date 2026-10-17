import SwiftUI

/// Which modifiers apply to the next key. Tap a modifier to arm it for one key,
/// long-press to lock it until tapped again.
struct ModifierState: Equatable {
    enum Mode { case off, sticky, locked }

    var command: Mode = .off
    var option: Mode = .off
    var control: Mode = .off
    var shift: Mode = .off

    var isEmpty: Bool {
        command == .off && option == .off && control == .off && shift == .off
    }

    /// CGEvent flags for the armed modifiers.
    var flags: UInt64 {
        var flags: UInt64 = 0
        if command != .off { flags |= KeyCodes.maskCommand }
        if option != .off { flags |= KeyCodes.maskOption }
        if control != .off { flags |= KeyCodes.maskControl }
        if shift != .off { flags |= KeyCodes.maskShift }
        return flags
    }

    /// Clears one-shot modifiers after a key has used them. Locked ones stay.
    mutating func consume() {
        if command == .sticky { command = .off }
        if option == .sticky { option = .off }
        if control == .sticky { control = .off }
        if shift == .sticky { shift = .off }
    }

    mutating func clear() {
        self = ModifierState()
    }
}

/// Keyboard tab: an invisible `UIKeyInput` responder plus modifier and special keys.
///
/// Plain typing goes to the Mac as Unicode text, so any language or emoji works. When a
/// modifier is armed, characters are sent as key codes with the modifier flags instead,
/// which is what shortcuts like ⌘⇧T or ⌥→ need.
struct RemoteKeyboardView: View {
    @ObservedObject var client: NetworkClient

    @State private var isKeyboardActive = false
    @State private var modifiers = ModifierState()

    var body: some View {
        VStack(spacing: 16) {
            KeyInputView(isActive: $isKeyboardActive,
                         onText: handleText,
                         onDeleteBackward: { sendKey(KeyCodes.delete) },
                         onKey: handleHardwareKey)
                .frame(width: 0, height: 0)

            Spacer(minLength: 0)

            statusCard

            modifierRow

            VStack(spacing: 10) {
                navigationRow
                shortcutRow
                functionRow
            }

            Spacer(minLength: 0)
        }
        .padding()
        .onAppear {
            // Give the tab switch a moment to settle before presenting the keyboard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isKeyboardActive = true
            }
        }
        .onDisappear {
            isKeyboardActive = false
            modifiers.clear()
        }
    }

    // MARK: - Sections

    private var statusCard: some View {
        VStack(spacing: 12) {
            if client.isConnected {
                Image(systemName: isKeyboardActive ? "keyboard" : "keyboard.badge.ellipsis")
                    .font(.system(size: 48))
                    .foregroundStyle(isKeyboardActive ? .blue : .secondary)
                Text(isKeyboardActive
                     ? String(localized: "keyboard_type_below")
                     : String(localized: "keyboard_tap_to_activate"))
                    .font(.headline)
                    .foregroundStyle(isKeyboardActive ? .primary : .secondary)
            } else {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(String(localized: "not_connected"))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(Color(.systemGray6))
        .cornerRadius(20)
        .contentShape(Rectangle())
        .onTapGesture {
            isKeyboardActive.toggle()
        }
    }

    private var modifierRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                ModifierKeyButton(symbol: "⌘", name: String(localized: "keyboard_modifier_command"), mode: $modifiers.command)
                ModifierKeyButton(symbol: "⌥", name: String(localized: "keyboard_modifier_option"), mode: $modifiers.option)
                ModifierKeyButton(symbol: "⌃", name: String(localized: "keyboard_modifier_control"), mode: $modifiers.control)
                ModifierKeyButton(symbol: "⇧", name: String(localized: "keyboard_modifier_shift"), mode: $modifiers.shift)
            }
            Text(String(localized: "keyboard_modifiers_hint"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var navigationRow: some View {
        HStack(spacing: 10) {
            KeyButton(label: "Esc") { sendKey(KeyCodes.escape) }
            KeyButton(label: "Tab") { sendKey(KeyCodes.tab) }
            KeyButton(icon: "arrow.left", name: String(localized: "keyboard_key_left")) { sendKey(KeyCodes.leftArrow) }
            KeyButton(icon: "arrow.down", name: String(localized: "keyboard_key_down")) { sendKey(KeyCodes.downArrow) }
            KeyButton(icon: "arrow.up", name: String(localized: "keyboard_key_up")) { sendKey(KeyCodes.upArrow) }
            KeyButton(icon: "arrow.right", name: String(localized: "keyboard_key_right")) { sendKey(KeyCodes.rightArrow) }
            Spacer(minLength: 0)
            KeyButton(icon: "delete.left", name: String(localized: "keyboard_key_delete")) { sendKey(KeyCodes.delete) }
            KeyButton(icon: "return", name: String(localized: "keyboard_key_return")) { sendKey(KeyCodes.returnKey) }
        }
    }

    private var shortcutRow: some View {
        HStack(spacing: 10) {
            KeyButton(label: "⌘C") { sendShortcut(KeyCodes.c, flags: KeyCodes.maskCommand) }
            KeyButton(label: "⌘V") { sendShortcut(KeyCodes.v, flags: KeyCodes.maskCommand) }
            KeyButton(label: "⌘X") { sendShortcut(KeyCodes.x, flags: KeyCodes.maskCommand) }
            KeyButton(label: "⌘Z") { sendShortcut(KeyCodes.z, flags: KeyCodes.maskCommand) }
            KeyButton(label: "⌘A") { sendShortcut(KeyCodes.a, flags: KeyCodes.maskCommand) }
            KeyButton(label: "⌘␣", name: String(localized: "keyboard_key_spotlight")) {
                sendShortcut(KeyCodes.space, flags: KeyCodes.maskCommand)
            }
            Spacer(minLength: 0)
        }
    }

    private var functionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(1...12, id: \.self) { number in
                    KeyButton(label: "F\(number)") { sendKey(KeyCodes.functionKey(number)) }
                }
            }
        }
    }

    // MARK: - Input handling

    private func handleText(_ text: String) {
        switch text {
        case "\n":
            sendKey(KeyCodes.returnKey)
        case "\t":
            sendKey(KeyCodes.tab)
        default:
            if modifiers.isEmpty {
                client.typeText(text)
            } else {
                // Shortcuts need virtual key codes. Characters without a code are dropped.
                for character in text {
                    guard let code = KeyCodes.code(for: character) else { continue }
                    var flags = modifiers.flags
                    if character.isUppercase || KeyCodes.shiftCharacters.contains(character) {
                        flags |= KeyCodes.maskShift
                    }
                    client.keyPress(code: code, flags: flags)
                }
                modifiers.consume()
            }
        }
    }

    /// Special and shortcut keys arm with the on-screen modifiers.
    private func sendKey(_ code: UInt16) {
        client.keyPress(code: code, flags: modifiers.flags)
        modifiers.consume()
    }

    /// Fixed shortcuts combine their own flags with any armed modifiers, so ⇧ then ⌘Z is ⌘⇧Z.
    private func sendShortcut(_ code: UInt16, flags: UInt64) {
        client.keyPress(code: code, flags: flags | modifiers.flags)
        modifiers.consume()
    }

    /// Hardware keyboard keys carry their own physical modifiers; add the on-screen ones too.
    private func handleHardwareKey(code: UInt16, flags: UInt64) {
        client.keyPress(code: code, flags: flags | modifiers.flags)
        modifiers.consume()
    }
}

// MARK: - Buttons

/// Modifier key with three states: off, armed for the next key, locked.
struct ModifierKeyButton: View {
    let symbol: String
    let name: String
    @Binding var mode: ModifierState.Mode

    var body: some View {
        VStack(spacing: 2) {
            Text(symbol)
                .font(.title3.weight(.medium))
            Text(name)
                .font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .foregroundStyle(mode == .off ? Color.primary : Color.white)
        .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if mode == .locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            mode = mode == .off ? .sticky : .off
        }
        .onLongPressGesture(minimumDuration: 0.4) {
            mode = .locked
        }
        .animation(.easeOut(duration: 0.12), value: mode)
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(mode == .off ? "" : String(localized: "keyboard_modifier_active"))
    }

    private var background: Color {
        switch mode {
        case .off: return Color(.systemGray5)
        case .sticky: return .blue
        case .locked: return .indigo
        }
    }
}

/// A plain special key or shortcut.
struct KeyButton: View {
    var label: String? = nil
    var icon: String? = nil
    var name: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let icon {
                    Image(systemName: icon)
                } else if let label {
                    Text(label)
                }
            }
            .font(.system(.body, design: .rounded, weight: .medium))
            .frame(minWidth: 44, minHeight: 44)
            .background(Color(.systemGray5))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name ?? label ?? "")
    }
}

// MARK: - Previews

#Preview("Keyboard") {
    RemoteKeyboardView(client: .preview())
}

#Preview("Keyboard, not connected") {
    RemoteKeyboardView(client: .preview(connected: false))
}

#Preview("Modifier keys") {
    struct Host: View {
        @State private var state = ModifierState(command: .sticky, option: .off, control: .locked, shift: .off)
        var body: some View {
            HStack(spacing: 10) {
                ModifierKeyButton(symbol: "⌘", name: "Command", mode: $state.command)
                ModifierKeyButton(symbol: "⌥", name: "Option", mode: $state.option)
                ModifierKeyButton(symbol: "⌃", name: "Control", mode: $state.control)
                ModifierKeyButton(symbol: "⇧", name: "Shift", mode: $state.shift)
            }
            .padding()
        }
    }
    return Host()
}

#Preview("Key buttons") {
    HStack {
        KeyButton(label: "Esc") {}
        KeyButton(icon: "arrow.left", name: "Left") {}
        KeyButton(label: "⌘C") {}
    }
    .padding()
}
