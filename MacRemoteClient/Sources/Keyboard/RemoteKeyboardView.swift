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
///
/// Layout is built for the iOS keyboard being up: everything fits the screen width and
/// sits directly above the keyboard, in Liquid Glass keys on iOS 26.
struct RemoteKeyboardView: View {
    @ObservedObject var client: NetworkClient

    @State private var isKeyboardActive = false
    @State private var modifiers = ModifierState()
    /// Bumped on every key sent, to drive a light haptic.
    @State private var keyPresses = 0

    private let rowSpacing: CGFloat = 10

    var body: some View {
        VStack(spacing: rowSpacing) {
            KeyInputView(isActive: $isKeyboardActive,
                         onText: handleText,
                         onDeleteBackward: { sendKey(KeyCodes.delete) },
                         onKey: handleHardwareKey)
                .frame(width: 0, height: 0)

            Spacer(minLength: 0)

            if !client.isConnected {
                NotConnectedBadge()
            }

            Group {
                modifierRow
                if !isKeyboardActive {
                    Text(String(localized: "keyboard_modifiers_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                navigationBlock
                shortcutStrip
                functionStrip
            }
            .disabled(!client.isConnected)
            .opacity(client.isConnected ? 1 : 0.45)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: keyPresses)
        .animation(.snappy(duration: 0.2), value: isKeyboardActive)
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

    /// ⌘ ⌥ ⌃ ⇧ plus the show/hide keyboard button.
    private var modifierRow: some View {
        HStack(spacing: 8) {
            ModifierKeyButton(symbol: "⌘", name: String(localized: "keyboard_modifier_command"), mode: $modifiers.command)
            ModifierKeyButton(symbol: "⌥", name: String(localized: "keyboard_modifier_option"), mode: $modifiers.option)
            ModifierKeyButton(symbol: "⌃", name: String(localized: "keyboard_modifier_control"), mode: $modifiers.control)
            ModifierKeyButton(symbol: "⇧", name: String(localized: "keyboard_modifier_shift"), mode: $modifiers.shift)
            Button {
                isKeyboardActive.toggle()
            } label: {
                Image(systemName: isKeyboardActive ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 52, height: 52)
                    .keyGlass(in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isKeyboardActive ? String(localized: "keyboard_hide") : String(localized: "keyboard_show"))
        }
    }

    /// Esc/Tab, an inverted-T arrow cluster, Delete/Return — laid out like a Mac keyboard.
    private var navigationBlock: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(spacing: 8) {
                KeyButton(label: "esc") { sendKey(KeyCodes.escape) }
                KeyButton(label: "tab", icon: "arrow.right.to.line") { sendKey(KeyCodes.tab) }
            }

            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Color.clear.frame(width: 44, height: 44)
                    KeyButton(icon: "chevron.up", name: String(localized: "keyboard_key_up"), width: 44) { sendKey(KeyCodes.upArrow) }
                    Color.clear.frame(width: 44, height: 44)
                }
                GridRow {
                    KeyButton(icon: "chevron.left", name: String(localized: "keyboard_key_left"), width: 44) { sendKey(KeyCodes.leftArrow) }
                    KeyButton(icon: "chevron.down", name: String(localized: "keyboard_key_down"), width: 44) { sendKey(KeyCodes.downArrow) }
                    KeyButton(icon: "chevron.right", name: String(localized: "keyboard_key_right"), width: 44) { sendKey(KeyCodes.rightArrow) }
                }
            }

            VStack(spacing: 8) {
                KeyButton(icon: "delete.left", name: String(localized: "keyboard_key_delete")) { sendKey(KeyCodes.delete) }
                KeyButton(icon: "return", name: String(localized: "keyboard_key_return"), prominent: true) { sendKey(KeyCodes.returnKey) }
            }
        }
    }

    /// Common Mac shortcuts as labelled chips; scrolls sideways.
    private var shortcutStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MacShortcut.all) { shortcut in
                    ShortcutChip(shortcut: shortcut) {
                        sendShortcut(shortcut.keyCode, flags: shortcut.flags)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    /// F1–F12 as small chips; scrolls sideways.
    private var functionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(1...12, id: \.self) { number in
                    Button {
                        sendKey(KeyCodes.functionKey(number))
                    } label: {
                        Text("F\(number)")
                            .font(.subheadline.weight(.medium).monospacedDigit())
                            .frame(minWidth: 40, minHeight: 34)
                            .padding(.horizontal, 4)
                            .keyGlass(in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
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
        keyPresses += 1
    }

    /// Fixed shortcuts combine their own flags with any armed modifiers, so ⇧ then ⌘Z is ⌘⇧Z.
    private func sendShortcut(_ code: UInt16, flags: UInt64) {
        client.keyPress(code: code, flags: flags | modifiers.flags)
        modifiers.consume()
        keyPresses += 1
    }

    /// Hardware keyboard keys carry their own physical modifiers; add the on-screen ones too.
    private func handleHardwareKey(code: UInt16, flags: UInt64) {
        client.keyPress(code: code, flags: flags | modifiers.flags)
        modifiers.consume()
    }
}

// MARK: - Buttons

/// Modifier key with three states: off, armed for the next key (tinted glass), locked
/// (tinted glass with a lock). Tap toggles armed; hold locks.
struct ModifierKeyButton: View {
    let symbol: String
    let name: String
    @Binding var mode: ModifierState.Mode

    var body: some View {
        VStack(spacing: 1) {
            Text(symbol)
                .font(.title3.weight(.semibold))
            Text(name)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .foregroundStyle(mode == .off ? Color.primary : Color.white)
        .keyGlass(tinted: mode != .off, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if mode == .locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            mode = mode == .off ? .sticky : .off
        }
        .onLongPressGesture(minimumDuration: 0.4) {
            mode = .locked
        }
        .sensoryFeedback(.selection, trigger: mode)
        .animation(.snappy(duration: 0.15), value: mode)
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(mode == .off ? "" : String(localized: "keyboard_modifier_active"))
    }
}

/// A special key: text, a symbol, or both. Fills the width it is given unless `width` is set.
struct KeyButton: View {
    var label: String? = nil
    var icon: String? = nil
    var name: String? = nil
    var width: CGFloat? = nil
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.body.weight(.semibold))
                }
                if let label {
                    Text(label)
                        .font(.subheadline.weight(.medium))
                }
            }
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(width: width, height: 44)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .keyGlass(tinted: prominent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name ?? label ?? "")
    }
}

/// A Mac shortcut offered as a one-tap chip.
struct MacShortcut: Identifiable {
    let id: String
    let title: String
    let icon: String
    let keyCode: UInt16
    let flags: UInt64

    static let all: [MacShortcut] = [
        MacShortcut(id: "copy", title: String(localized: "keyboard_shortcut_copy"), icon: "doc.on.doc",
                    keyCode: KeyCodes.c, flags: KeyCodes.maskCommand),
        MacShortcut(id: "paste", title: String(localized: "keyboard_shortcut_paste"), icon: "doc.on.clipboard",
                    keyCode: KeyCodes.v, flags: KeyCodes.maskCommand),
        MacShortcut(id: "cut", title: String(localized: "keyboard_shortcut_cut"), icon: "scissors",
                    keyCode: KeyCodes.x, flags: KeyCodes.maskCommand),
        MacShortcut(id: "undo", title: String(localized: "keyboard_shortcut_undo"), icon: "arrow.uturn.backward",
                    keyCode: KeyCodes.z, flags: KeyCodes.maskCommand),
        MacShortcut(id: "redo", title: String(localized: "keyboard_shortcut_redo"), icon: "arrow.uturn.forward",
                    keyCode: KeyCodes.z, flags: KeyCodes.maskCommand | KeyCodes.maskShift),
        MacShortcut(id: "selectAll", title: String(localized: "keyboard_shortcut_select_all"), icon: "selection.pin.in.out",
                    keyCode: KeyCodes.a, flags: KeyCodes.maskCommand),
        MacShortcut(id: "find", title: String(localized: "keyboard_shortcut_find"), icon: "magnifyingglass",
                    keyCode: KeyCodes.code(for: "f") ?? 3, flags: KeyCodes.maskCommand),
        MacShortcut(id: "spotlight", title: String(localized: "keyboard_key_spotlight"), icon: "sparkle.magnifyingglass",
                    keyCode: KeyCodes.space, flags: KeyCodes.maskCommand),
        MacShortcut(id: "switchApp", title: String(localized: "keyboard_shortcut_switch_app"), icon: "square.on.square",
                    keyCode: KeyCodes.tab, flags: KeyCodes.maskCommand),
        MacShortcut(id: "close", title: String(localized: "keyboard_shortcut_close"), icon: "xmark.square",
                    keyCode: KeyCodes.code(for: "w") ?? 13, flags: KeyCodes.maskCommand)
    ]
}

/// Icon and title in a glass capsule.
struct ShortcutChip: View {
    let shortcut: MacShortcut
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(shortcut.title, systemImage: shortcut.icon)
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .keyGlass(in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Shown above the keys while no Mac is connected.
private struct NotConnectedBadge: View {
    var body: some View {
        Label(String(localized: "not_connected"), systemImage: "bolt.horizontal")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .keyGlass(in: Capsule())
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
        KeyButton(label: "esc") {}
        KeyButton(icon: "chevron.left", name: "Left", width: 44) {}
        KeyButton(icon: "return", name: "Return", prominent: true) {}
    }
    .padding()
}
