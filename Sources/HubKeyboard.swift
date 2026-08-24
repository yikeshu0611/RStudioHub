import AppKit
import CoreGraphics

enum HubKeyboard {
    private static func eventSource() -> CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    static func postCommandComma() {
        postKey(0x2B, flags: .maskCommand) // ,
    }

    static func postCommandShiftP() {
        postKey(0x23, flags: [.maskCommand, .maskShift]) // P
    }

    static func postReturn() {
        postKey(0x24, flags: []) // Return
    }

    /// Type ASCII using virtual key codes — more reliable in Electron than unicode events.
    static func postText(_ text: String) {
        for character in text {
            guard let (keyCode, flags) = keyCodeForCharacter(character) else { continue }
            postKey(keyCode, flags: flags)
            usleep(12_000)
        }
    }

    /// Open RStudio command palette and run a command by name.
    static func runCommandPalette(query: String) {
        postCommandShiftP()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            postText(query)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                postReturn()
            }
        }
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = eventSource(),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func keyCodeForCharacter(_ character: Character) -> (CGKeyCode, CGEventFlags)? {
        if character == " " {
            return (0x31, [])
        }
        guard character.isASCII, let scalar = character.unicodeScalars.first else { return nil }

        let lower = Character(scalar).lowercased().first!
        guard let keyCode = keyCodeForLetter(lower) else { return nil }

        if character.isUppercase {
            return (keyCode, .maskShift)
        }
        return (keyCode, [])
    }

    private static func keyCodeForLetter(_ letter: Character) -> CGKeyCode? {
        switch letter {
        case "a": return 0x00
        case "b": return 0x0B
        case "c": return 0x08
        case "d": return 0x02
        case "e": return 0x0E
        case "f": return 0x03
        case "g": return 0x05
        case "h": return 0x04
        case "i": return 0x22
        case "j": return 0x26
        case "k": return 0x28
        case "l": return 0x25
        case "m": return 0x2E
        case "n": return 0x2D
        case "o": return 0x1F
        case "p": return 0x23
        case "q": return 0x0C
        case "r": return 0x0F
        case "s": return 0x01
        case "t": return 0x11
        case "u": return 0x20
        case "v": return 0x09
        case "w": return 0x0D
        case "x": return 0x07
        case "y": return 0x10
        case "z": return 0x06
        default: return nil
        }
    }
}
