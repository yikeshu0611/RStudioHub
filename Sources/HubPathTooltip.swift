import AppKit
import ApplicationServices

enum HubPathTooltip {
    private static var panel: NSPanel?
    private static var label: NSTextField?

    static func show(
        _ text: String,
        near mouse: NSPoint = NSEvent.mouseLocation,
        toLeftOf anchor: NSRect? = nil
    ) {
        let tooltipPanel = panel ?? makePanel()
        let field = label ?? {
            let created = NSTextField(labelWithString: "")
            created.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            created.textColor = .labelColor
            created.lineBreakMode = .byTruncatingMiddle
            created.maximumNumberOfLines = 2
            created.preferredMaxLayoutWidth = 520
            label = created
            return created
        }()

        field.stringValue = text
        field.preferredMaxLayoutWidth = 520
        let fitting = field.sizeThatFits(NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude))

        let padding = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        let width = min(max(fitting.width + padding.left + padding.right, 120), 540)
        let height = fitting.height + padding.top + padding.bottom
        let frame = NSRect(x: 0, y: 0, width: width, height: height)

        if let content = tooltipPanel.contentView {
            content.frame = frame
            field.frame = NSRect(
                x: padding.left,
                y: padding.bottom,
                width: width - padding.left - padding.right,
                height: fitting.height
            )
            if field.superview !== content {
                content.subviews.forEach { $0.removeFromSuperview() }
                content.addSubview(field)
            }
        }

        position(tooltipPanel, size: frame.size, near: mouse, toLeftOf: anchor)
        // Assistive / max levels can sit above Dock menu chrome.
        tooltipPanel.orderFrontRegardless()
        panel = tooltipPanel
        label = field
    }

    private static func makePanel() -> NSPanel {
        let content = NSView(frame: .zero)
        content.wantsLayer = true
        content.layer?.cornerRadius = 6
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        content.layer?.borderWidth = 0.5

        let tooltipPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 28),
            styleMask: [.nonactivatingPanel, .borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        tooltipPanel.isFloatingPanel = true
        tooltipPanel.hidesOnDeactivate = false
        tooltipPanel.becomesKeyOnlyIfNeeded = true
        tooltipPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        tooltipPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .transient]
        tooltipPanel.backgroundColor = .clear
        tooltipPanel.hasShadow = true
        tooltipPanel.isOpaque = false
        tooltipPanel.ignoresMouseEvents = true
        tooltipPanel.animationBehavior = .none
        tooltipPanel.contentView = content
        return tooltipPanel
    }

    private static func position(
        _ panel: NSPanel,
        size: NSSize,
        near mouse: NSPoint,
        toLeftOf anchor: NSRect?
    ) {
        let gap: CGFloat = 10
        // Always place to the LEFT of the files list (or mouse), never to the right.
        let rightEdge: CGFloat
        if let anchor, anchor.width > 1 {
            rightEdge = anchor.minX - gap
        } else {
            rightEdge = mouse.x - gap
        }

        var origin = NSPoint(
            x: rightEdge - size.width,
            y: mouse.y - size.height / 2
        )

        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = max(visible.minX + 4, origin.x)
            if origin.x + size.width > rightEdge {
                origin.x = max(visible.minX + 4, rightEdge - size.width)
            }
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    static func hide() {
        panel?.orderOut(nil)
        // Keep panel instance for faster reuse while Dock menu is open.
        label?.stringValue = ""
    }

    static func tearDown() {
        panel?.orderOut(nil)
        panel = nil
        label = nil
    }
}
