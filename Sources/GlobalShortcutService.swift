import AppKit
import Carbon

final class GlobalShortcutService {
    static let shared = GlobalShortcutService()

    var onShortcutPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var isPaused = false
    private static let hotKeySignature: OSType = 0x4855_4231 // 'HUB1'

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(shortcutDidChange),
            name: .hubShortcutDidChange,
            object: nil
        )
    }

    func start() {
        installHotKeyHandler()
        registerCurrentShortcut()
    }

    func pauseHotKey() {
        isPaused = true
        unregisterHotKey()
    }

    func resumeHotKey() {
        isPaused = false
        registerCurrentShortcut()
    }

    @objc private func shortcutDidChange() {
        guard !isPaused else { return }
        registerCurrentShortcut()
    }

    private func installHotKeyHandler() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let error = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard error == noErr, hotKeyID.signature == GlobalShortcutService.hotKeySignature else {
                    return noErr
                }

                DispatchQueue.main.async {
                    GlobalShortcutService.shared.onShortcutPress?()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        if status != noErr {
            ActivityLogger.shared.log("shortcut.handlerInstallFailed status=\(status)")
        }
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func registerCurrentShortcut() {
        unregisterHotKey()

        let shortcut = ShortcutStore.resolvedShortcut(for: .openMenu)
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        var ref: EventHotKeyRef?

        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            carbonModifiers(from: shortcut.modifierFlags),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr {
            hotKeyRef = ref
            ActivityLogger.shared.log("shortcut.registered \(shortcut.displayString)")
        } else {
            ActivityLogger.shared.log("shortcut.registerFailed \(shortcut.displayString) status=\(status)")
        }
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }
}
