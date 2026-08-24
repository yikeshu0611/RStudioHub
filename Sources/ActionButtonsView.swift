import AppKit

enum MenuPillStyle {
    static let cornerRadius: CGFloat = 6
    static let inset: CGFloat = 10
    static let spacing: CGFloat = 4
    static let pillHeight: CGFloat = 22

    static func drawPill(
        in rect: NSRect,
        title: String,
        highlighted: Bool,
        enabled: Bool,
        fontSize: CGFloat = NSFont.smallSystemFontSize
    ) {
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        if !enabled {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.2).setFill()
        } else if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
        } else {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
        }
        path.fill()

        let text = title as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: fontSize),
            .foregroundColor: pillTextColor(highlighted: highlighted, enabled: enabled),
        ]
        let textSize = text.size(withAttributes: attributes)
        let textPoint = NSPoint(
            x: rect.midX - textSize.width / 2,
            y: rect.midY - textSize.height / 2
        )
        text.draw(at: textPoint, withAttributes: attributes)
    }

    private static func pillTextColor(highlighted: Bool, enabled: Bool) -> NSColor {
        if !enabled {
            return .secondaryLabelColor
        }
        return highlighted ? .alternateSelectedControlTextColor : .labelColor
    }
}

final class ActionButtonsView: NSView {
    static var rowWidth: CGFloat { MenuRowHoverView.menuWidth }
    static let rowHeight: CGFloat = MenuPillStyle.inset * 2 + MenuPillStyle.pillHeight * 2 + MenuPillStyle.spacing

    private struct ButtonSpec {
        let title: String
        let enabled: Bool
        let action: () -> Void
        var rect: NSRect = .zero
    }

    private var buttons: [ButtonSpec] = []
    private var hoveredIndex: Int?
    private var trackingArea: NSTrackingArea?

    init(
        onNewR: @escaping () -> Void,
        onNewRproj: @escaping () -> Void,
        onQuitAllR: @escaping () -> Void,
        onQuitHub: @escaping () -> Void,
        quitAllEnabled: Bool
    ) {
        buttons = [
            ButtonSpec(title: "New R", enabled: true, action: onNewR),
            ButtonSpec(title: "NewRproj", enabled: true, action: onNewRproj),
            ButtonSpec(title: "quit R", enabled: quitAllEnabled, action: onQuitAllR),
            ButtonSpec(title: "quit Hub", enabled: true, action: onQuitHub),
        ]
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: Self.rowHeight))
        layoutButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func layoutButtons() {
        let inset = MenuPillStyle.inset
        let spacing = MenuPillStyle.spacing
        let pillHeight = MenuPillStyle.pillHeight
        let pillWidth = (Self.rowWidth - inset * 2 - spacing) / 2
        let topY = Self.rowHeight - inset - pillHeight
        let bottomY = inset

        let frames = [
            NSRect(x: inset, y: topY, width: pillWidth, height: pillHeight),
            NSRect(x: inset + pillWidth + spacing, y: topY, width: pillWidth, height: pillHeight),
            NSRect(x: inset, y: bottomY, width: pillWidth, height: pillHeight),
            NSRect(x: inset + pillWidth + spacing, y: bottomY, width: pillWidth, height: pillHeight),
        ]

        for index in buttons.indices {
            buttons[index].rect = frames[index]
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredIndex(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let fontSize = NSFont.systemFontSize
        for (index, button) in buttons.enumerated() {
            MenuPillStyle.drawPill(
                in: button.rect,
                title: button.title,
                highlighted: hoveredIndex == index,
                enabled: button.enabled,
                fontSize: fontSize
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let index = buttons.firstIndex(where: { $0.rect.contains(location) && $0.enabled }) else {
            return
        }

        let action = buttons[index].action
        let closesMenu = index != 2
        action()
        if closesMenu {
            enclosingMenuItem?.menu?.cancelTracking()
        }
    }

    private func updateHover(at location: NSPoint) {
        let index = buttons.firstIndex { $0.rect.contains(location) && $0.enabled }
        setHoveredIndex(index)
    }

    private func setHoveredIndex(_ index: Int?) {
        guard hoveredIndex != index else { return }
        hoveredIndex = index
        needsDisplay = true
    }
}
