import Foundation
import Carbon.HIToolbox
import CoreGraphics

/// Maps characters to the physical key (plus Shift/Option) that types them on the Mac's
/// current keyboard layout.
///
/// The lock screen ignores the text attached to synthetic key events and reads the key
/// code instead, so a password has to be typed as real key presses. Characters the layout
/// cannot produce in one keystroke (dead-key accents, emoji) are not in the map.
struct KeyboardLayoutMap {

    struct Stroke: Equatable {
        let keyCode: CGKeyCode
        let shift: Bool
        let option: Bool
    }

    private(set) var strokes: [Character: Stroke] = [:]
    let layoutID: String

    /// Keypad keys produce the same characters as the main keys; prefer the main keys.
    private static let keypadKeyCodes: Set<CGKeyCode> = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]

    /// Modifier combinations to try, fewest first, as UCKeyTranslate modifier states.
    private static let modifierSets: [(shift: Bool, option: Bool)] = [(false, false), (true, false), (false, true), (true, true)]

    /// Builds the map for the current keyboard layout, or nil if it has no Unicode layout data.
    static func current() -> KeyboardLayoutMap? {
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        guard let source,
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue() as Data
        let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        let layoutID = idPointer.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "unknown"
        return KeyboardLayoutMap(layoutData: layoutData, layoutID: layoutID)
    }

    init(layoutData: Data, layoutID: String) {
        self.layoutID = layoutID
        let keyboardType = UInt32(LMGetKbdType())
        layoutData.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for modifiers in Self.modifierSets {
                var state: UInt32 = 0
                if modifiers.shift { state |= UInt32(shiftKey >> 8) }
                if modifiers.option { state |= UInt32(optionKey >> 8) }
                for keyCode in CGKeyCode(0)..<CGKeyCode(128) where !Self.keypadKeyCodes.contains(keyCode) {
                    guard let character = Self.translate(layout, keyCode: keyCode, modifierState: state, keyboardType: keyboardType),
                          strokes[character] == nil else { continue }
                    strokes[character] = Stroke(keyCode: keyCode, shift: modifiers.shift, option: modifiers.option)
                }
            }
        }
    }

    func stroke(for character: Character) -> Stroke? {
        strokes[character]
    }

    /// The single printable character a key produces, or nil for dead keys and controls.
    private static func translate(_ layout: UnsafePointer<UCKeyboardLayout>, keyCode: CGKeyCode,
                                  modifierState: UInt32, keyboardType: UInt32) -> Character? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifierState, keyboardType,
                                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
        guard status == noErr, deadKeyState == 0, length > 0 else { return nil }
        let string = String(utf16CodeUnits: chars, count: length)
        guard string.count == 1, let character = string.first,
              !character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return character
    }
}
