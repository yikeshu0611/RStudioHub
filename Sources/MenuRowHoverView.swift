import AppKit

class MenuRowHoverView: NSView {
    static let minMenuWidth: CGFloat = MenuLayout.minWidth
    static let maxMenuWidth: CGFloat = MenuLayout.maxWidth

    private static var currentMenuWidth: CGFloat = MenuLayout.minWidth
    static var menuWidth: CGFloat { currentMenuWidth }

    static func applyWidth(selectedTab: HubMenuTab, instances: [RStudioInstance]) {
        currentMenuWidth = MenuLayout.preferredWidth(
            selectedTab: selectedTab,
            instances: instances,
            projects: ProjectHistoryStore.shared.allEntries()
        )
    }

    private(set) var isHovered = false
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
        hoverStateDidChange(hovered)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        let highlightRect = bounds.insetBy(dx: 6, dy: 1)
        let path = NSBezierPath(roundedRect: highlightRect, xRadius: 4, yRadius: 4)
        NSColor.selectedContentBackgroundColor.setFill()
        path.fill()
    }

    func hoverStateDidChange(_ hovered: Bool) {}
}
