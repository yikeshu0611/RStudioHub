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

    static func postText(_ text: String) {
        guard let source = eventSource() else { return }
        for scalar in text.unicodeScalars {
            var chars = [UniChar(scalar.value)]
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &chars)
                keyDown.post(tap: .cghidEventTap)
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                keyUp.post(tap: .cghidEventTap)
            }
        }
    }

    /// Open RStudio command palette and run a command by name.
    static func runCommandPalette(query: String, completion: (() -> Void)? = nil) {
        postCommandShiftP()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            postText(query)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                postReturn()
                completion?()
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
}
