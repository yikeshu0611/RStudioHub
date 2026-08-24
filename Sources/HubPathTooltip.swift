import AppKit

enum HubPathTooltip {
    private static var panel: NSPanel?

    static func show(_ text: String, near mouse: NSPoint = NSEvent.mouseLocation) {
        hide()

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = 520
        let fitting = label.sizeThatFits(NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude))

        let padding = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        let width = min(max(fitting.width + padding.left + padding.right, 120), 540)
        let height = fitting.height + padding.top + padding.bottom
        let frame = NSRect(x: 0, y: 0, width: width, height: height)

        let content = NSView(frame: frame)
        content.wantsLayer = true
        content.layer?.cornerRadius = 6
        content.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        content.layer?.borderWidth = 0.5

        label.frame = NSRect(
            x: padding.left,
            y: padding.bottom,
            width: width - padding.left - padding.right,
            height: fitting.height
        )
        content.addSubview(label)

        let tooltipPanel = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        tooltipPanel.isFloatingPanel = true
        tooltipPanel.hidesOnDeactivate = false
        tooltipPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 2)
        tooltipPanel.backgroundColor = NSColor.clear
        tooltipPanel.hasShadow = true
        tooltipPanel.contentView = content
        tooltipPanel.isOpaque = false

        var origin = NSPoint(x: mouse.x + 14, y: mouse.y - height - 8)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(origin.x, visible.maxX - width - 4)
            origin.x = max(origin.x, visible.minX + 4)
            origin.y = min(origin.y, visible.maxY - height - 4)
            origin.y = max(origin.y, visible.minY + 4)
        }
        tooltipPanel.setFrameOrigin(origin)
        tooltipPanel.orderFrontRegardless()
        panel = tooltipPanel
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
