import AppKit

final class ShortcutRecordingPanel: NSPanel {
    private let titleLabel = NSTextField(labelWithString: "设置打开菜单快捷键")
    private let hintLabel = NSTextField(labelWithString: "请按下快捷键…")
    private let currentLabel = NSTextField(labelWithString: "")

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        backgroundColor = NSColor.windowBackgroundColor
        appearance = NSAppearance(named: .aqua)

        titleLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 16, y: 62, width: 228, height: 18)

        hintLabel.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.frame = NSRect(x: 16, y: 40, width: 228, height: 16)

        currentLabel.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        currentLabel.alignment = .center
        currentLabel.frame = NSRect(x: 16, y: 18, width: 228, height: 18)

        contentView?.addSubview(titleLabel)
        contentView?.addSubview(hintLabel)
        contentView?.addSubview(currentLabel)

        updateCurrentShortcut()
    }

    func updateCurrentShortcut() {
        currentLabel.stringValue = ShortcutStore.displayString(for: .openMenu)
    }

    func showRecordingState() {
        hintLabel.stringValue = "支持 F 键或组合键（Esc 取消）"
        hintLabel.textColor = .controlAccentColor
    }

    func previewShortcut(_ shortcut: HubShortcut) {
        currentLabel.stringValue = shortcut.displayString
    }

    func showSaved(_ shortcut: HubShortcut) {
        hintLabel.stringValue = "已保存"
        hintLabel.textColor = .systemGreen
        currentLabel.stringValue = shortcut.displayString
    }

    func showCancelled() {
        hintLabel.stringValue = "已取消"
        hintLabel.textColor = .secondaryLabelColor
        updateCurrentShortcut()
    }

    func showFailed(_ message: String) {
        hintLabel.stringValue = message
        hintLabel.textColor = .systemRed
    }

    func present(near anchor: NSView?) {
        if let anchor {
            position(near: anchor)
        } else if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let panelSize = frame.size
            setFrameOrigin(NSPoint(
                x: visible.midX - panelSize.width / 2,
                y: visible.midY - panelSize.height / 2
            ))
        }

        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    func dismissPanel() {
        orderOut(nil)
    }

    private func position(near anchor: NSView) {
        guard let window = anchor.window else {
            centerOnMainScreen()
            return
        }

        window.layoutIfNeeded()
        let buttonFrame = anchor.convert(anchor.bounds, to: nil)
        let screen = window.screen ?? NSScreen.main
        guard let screen else {
            centerOnMainScreen()
            return
        }

        let visibleFrame = screen.visibleFrame
        let panelSize = frame.size
        var origin = NSPoint(
            x: buttonFrame.midX - panelSize.width / 2,
            y: buttonFrame.minY - panelSize.height - 6
        )
        origin.x = max(visibleFrame.minX + 8, min(origin.x, visibleFrame.maxX - panelSize.width - 8))
        origin.y = max(visibleFrame.minY + 8, origin.y)
        setFrameOrigin(origin)
    }

    private func centerOnMainScreen() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2
        ))
    }
}

enum ShortcutRecordingController {
    private static var panel: ShortcutRecordingPanel?
    private static var keyMonitor: Any?
    private static var reopenMenuAfterFinish = false

    static func begin(reopenMenu: Bool, anchor: NSView?) {
        end()
        reopenMenuAfterFinish = reopenMenu

        GlobalShortcutService.shared.pauseHotKey()

        let newPanel = ShortcutRecordingPanel()
        panel = newPanel
        newPanel.showRecordingState()
        newPanel.present(near: anchor)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event)
            return nil
        }

        NotificationCenter.default.post(name: .hubShortcutRecordingDidBegin, object: nil)
        ActivityLogger.shared.log("shortcut.recording.begin")
    }

    static func end() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        panel?.dismissPanel()
        panel?.close()
        panel = nil
        GlobalShortcutService.shared.resumeHotKey()
    }

    private static func handleKeyDown(_ event: NSEvent) {
        guard panel != nil else { return }

        if event.keyCode == 53 {
            finish(with: nil)
            return
        }

        let mods = HubShortcut.normalized(event.modifierFlags)
        guard HubShortcut.isValid(keyCode: event.keyCode, modifiers: event.modifierFlags) else {
            panel?.showFailed("请用 F 键或组合键")
            NSSound.beep()
            return
        }

        let shortcut = HubShortcut(keyCode: event.keyCode, modifiers: mods)
        panel?.previewShortcut(shortcut)
        ShortcutStore.set(shortcut, for: .openMenu)
        finish(with: shortcut)
    }

    private static func finish(with shortcut: HubShortcut?) {
        guard let panel else {
            end()
            return
        }

        NotificationCenter.default.post(name: .hubShortcutRecordingDidEnd, object: nil)

        if let shortcut {
            panel.showSaved(shortcut)
            NSSound.beep()
            ActivityLogger.shared.log("shortcut.recording.saved \(shortcut.displayString)")
        } else {
            panel.showCancelled()
            ActivityLogger.shared.log("shortcut.recording.cancelled")
        }

        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            panel.dismissPanel()
            panel.close()
            self.panel = nil
            GlobalShortcutService.shared.resumeHotKey()

            if reopenMenuAfterFinish {
                (NSApp.delegate as? RStudioHubApp)?.showMenuAfterShortcutRecording()
            }
        }
    }
}
