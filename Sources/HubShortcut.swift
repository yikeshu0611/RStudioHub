import AppKit

enum HubShortcutAction: String, CaseIterable {
    case openMenu

    var title: String {
        switch self {
        case .openMenu:
            return "打开菜单"
        }
    }

    var settingsKey: String {
        "shortcut.\(rawValue)"
    }
}

struct HubShortcut: Codable, Equatable {
    static let modifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    let keyCode: UInt16
    let modifierRawValue: UInt

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        modifierRawValue = Self.normalized(modifiers).rawValue
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierRawValue)
    }

    static func normalized(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(modifierMask)
    }

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
             105, 107, 113, 106, 64, 79, 80:
            return true
        default:
            return false
        }
    }

    static func isValid(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        !normalized(modifiers).isEmpty || isFunctionKey(keyCode)
    }

    func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        return Self.normalized(event.modifierFlags) == Self.normalized(modifierFlags)
    }

    var displayString: String {
        var parts: [String] = []
        let mods = modifierFlags
        if mods.contains(.control) { parts.append("⌃") }
        if mods.contains(.option) { parts.append("⌥") }
        if mods.contains(.shift) { parts.append("⇧") }
        if mods.contains(.command) { parts.append("⌘") }
        parts.append(Self.keyDisplayName(for: keyCode))
        return parts.joined()
    }

    static let defaultOpenMenu = HubShortcut(
        keyCode: 46,
        modifiers: [.control, .option]
    )

    private static func keyDisplayName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64: return "F17"
        case 79: return "F18"
        case 80: return "F19"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "Esc"
        default:
            if let scalar = keyCodeToCharacter(keyCode) {
                return String(scalar).uppercased()
            }
            return "Key\(keyCode)"
        }
    }

    private static func keyCodeToCharacter(_ keyCode: UInt16) -> UnicodeScalar? {
        let table: [UInt16: UInt32] = [
            0: 0x41, 1: 0x53, 2: 0x44, 3: 0x46, 4: 0x48, 5: 0x47, 6: 0x5A, 7: 0x58,
            8: 0x43, 9: 0x56, 11: 0x42, 12: 0x51, 13: 0x57, 14: 0x45, 15: 0x52, 16: 0x59,
            17: 0x54, 31: 0x4F, 32: 0x55, 34: 0x49, 35: 0x50, 37: 0x4C, 38: 0x4A, 40: 0x4B,
            45: 0x4E, 46: 0x4D,
        ]
        guard let code = table[keyCode] else { return nil }
        return UnicodeScalar(code)
    }
}

enum ShortcutStore {
    private static let defaults = UserDefaults.standard

    static func shortcut(for action: HubShortcutAction) -> HubShortcut? {
        guard let data = defaults.data(forKey: action.settingsKey),
              let shortcut = try? JSONDecoder().decode(HubShortcut.self, from: data) else {
            return nil
        }
        return shortcut
    }

    static func resolvedShortcut(for action: HubShortcutAction) -> HubShortcut {
        switch action {
        case .openMenu:
            return shortcut(for: action) ?? .defaultOpenMenu
        }
    }

    static func set(_ shortcut: HubShortcut?, for action: HubShortcutAction) {
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: action.settingsKey)
        } else {
            defaults.removeObject(forKey: action.settingsKey)
        }
        NotificationCenter.default.post(name: .hubShortcutDidChange, object: action)
    }

    static func displayString(for action: HubShortcutAction) -> String {
        resolvedShortcut(for: action).displayString
    }
}

extension Notification.Name {
    static let hubShortcutDidChange = Notification.Name("RStudioHub.shortcutDidChange")
}
