import AppKit

final class ShortcutSettingsRowView: MenuRowHoverView {
    static let rowInset: CGFloat = 6
    private static let pillHeight: CGFloat = 18
    static let rowHeight: CGFloat = rowInset * 2 + pillHeight

    private enum HitZone {
        case shortcut
        case login
    }

    private let action: HubShortcutAction
    private var pillRect = NSRect.zero
    private var shortcutHitRect = NSRect.zero
    private var loginHitRect = NSRect.zero
    private var hoveredZone: HitZone?

    init(action: HubShortcutAction = .openMenu) {
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: Self.menuWidth, height: Self.rowHeight))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredZone = nil
        setHovered(false)
        needsDisplay = true
    }

    private func updateHover(at point: NSPoint) {
        let zone: HitZone?
        if loginHitRect.contains(point) {
            zone = .login
        } else if shortcutHitRect.contains(point) {
            zone = .shortcut
        } else {
            zone = nil
        }

        hoveredZone = zone
        setHovered(zone != nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = Self.rowInset
        pillRect = NSRect(
            x: inset,
            y: inset,
            width: bounds.width - inset * 2,
            height: Self.pillHeight
        )

        layoutHitRects()

        let path = NSBezierPath(
            roundedRect: pillRect,
            xRadius: MenuPillStyle.cornerRadius,
            yRadius: MenuPillStyle.cornerRadius
        )
        NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
        path.fill()

        if hoveredZone == .shortcut {
            highlightRect(shortcutHitRect)
        } else if hoveredZone == .login {
            highlightRect(loginHitRect)
        }

        let font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        let textColor = NSColor.labelColor
        let highlightTextColor = NSColor.alternateSelectedControlTextColor
        let attrs: (Bool) -> [NSAttributedString.Key: Any] = { highlighted in
            [
                .font: font,
                .foregroundColor: highlighted ? highlightTextColor : textColor,
            ]
        }

        let leftY = pillRect.midY - (action.title as NSString).size(withAttributes: attrs(false)).height / 2
        (action.title as NSString).draw(
            at: NSPoint(x: pillRect.minX + 10, y: leftY),
            withAttributes: attrs(hoveredZone == .shortcut)
        )

        let shortcutText = ShortcutStore.displayString(for: action)
        let shortcutSize = (shortcutText as NSString).size(withAttributes: attrs(false))
        let shortcutX = loginHitRect.minX - shortcutSize.width - 12
        (shortcutText as NSString).draw(
            at: NSPoint(x: shortcutX, y: pillRect.midY - shortcutSize.height / 2),
            withAttributes: attrs(hoveredZone == .shortcut)
        )

        guard LaunchAtLoginSettings.isSupported, !loginHitRect.isEmpty else { return }

        NSColor.separatorColor.setStroke()
        let lineX = loginHitRect.minX + 4
        let line = NSBezierPath()
        line.move(to: NSPoint(x: lineX, y: pillRect.minY + 3))
        line.line(to: NSPoint(x: lineX, y: pillRect.maxY - 3))
        line.lineWidth = 1
        line.stroke()

        let loginTitle = LaunchAtLoginSettings.optionTitle
        let loginSize = (loginTitle as NSString).size(withAttributes: attrs(false))
        let loginTextX = loginHitRect.maxX - loginSize.width - 16
        (loginTitle as NSString).draw(
            at: NSPoint(x: loginTextX, y: pillRect.midY - loginSize.height / 2),
            withAttributes: attrs(hoveredZone == .login)
        )

        drawCheckbox(
            in: NSRect(x: loginHitRect.maxX - 14, y: pillRect.midY - 6, width: 12, height: 12),
            enabled: LaunchAtLoginSettings.isEnabled,
            highlighted: hoveredZone == .login,
            available: true
        )
    }

    private func layoutHitRects() {
        let font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        let loginWidth: CGFloat
        if LaunchAtLoginSettings.isSupported {
            let loginTitle = LaunchAtLoginSettings.optionTitle
            let loginTextWidth = (loginTitle as NSString).size(withAttributes: [.font: font]).width
            loginWidth = loginTextWidth + 16 + 14
        } else {
            loginWidth = 0
        }

        if loginWidth > 0 {
            loginHitRect = NSRect(
                x: pillRect.maxX - loginWidth - 6,
                y: pillRect.minY,
                width: loginWidth + 6,
                height: pillRect.height
            )
        } else {
            loginHitRect = .zero
        }

        shortcutHitRect = NSRect(
            x: pillRect.minX,
            y: pillRect.minY,
            width: loginWidth > 0 ? max(0, loginHitRect.minX - pillRect.minX) : pillRect.width,
            height: pillRect.height
        )
    }

    private func highlightRect(_ rect: NSRect) {
        let clip = rect.intersection(pillRect)
        guard !clip.isEmpty else { return }
        let path = NSBezierPath(roundedRect: clip, xRadius: 4, yRadius: 4)
        NSColor.selectedContentBackgroundColor.setFill()
        path.fill()
    }

    private func drawCheckbox(in rect: NSRect, enabled: Bool, highlighted: Bool, available: Bool) {
        let boxPath = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        if !available {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        } else if enabled {
            NSColor.controlAccentColor.setFill()
        } else {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.5).setFill()
        }
        boxPath.fill()

        if enabled && available {
            let check = "✓" as NSString
            let checkAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 9),
                .foregroundColor: highlighted ? NSColor.alternateSelectedControlTextColor : NSColor.white,
            ]
            let checkSize = check.size(withAttributes: checkAttrs)
            check.draw(
                at: NSPoint(x: rect.midX - checkSize.width / 2, y: rect.midY - checkSize.height / 2),
                withAttributes: checkAttrs
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        if loginHitRect.contains(location) {
            _ = LaunchAtLoginSettings.setEnabled(!LaunchAtLoginSettings.isEnabled)
            needsDisplay = true
            return
        }

        if shortcutHitRect.contains(location) {
            enclosingMenuItem?.menu?.cancelTracking()
            DispatchQueue.main.async {
                (NSApp.delegate as? RStudioHubApp)?.beginShortcutRecording(reopenMenu: true)
            }
        }
    }
}

extension Notification.Name {
    static let hubShortcutRecordingDidBegin = Notification.Name("RStudioHub.shortcutRecordingDidBegin")
    static let hubShortcutRecordingDidEnd = Notification.Name("RStudioHub.shortcutRecordingDidEnd")
}
