import AppKit

enum HubMenuTab: String, CaseIterable {
    case current = "Current"
    case project = "Project"
}

final class MenuTabBarView: NSView {
    static var rowWidth: CGFloat { MenuRowHoverView.menuWidth }
    static let rowHeight: CGFloat = 30

    private let selectedTab: HubMenuTab
    private let onSelect: (HubMenuTab) -> Void
    private var tabRects: [HubMenuTab: NSRect] = [:]

    init(selectedTab: HubMenuTab, onSelect: @escaping (HubMenuTab) -> Void) {
        self.selectedTab = selectedTab
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: Self.rowHeight))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let tabs = HubMenuTab.allCases
        let inset: CGFloat = 10
        let spacing: CGFloat = 4
        let tabWidth = (bounds.width - inset * 2 - spacing) / CGFloat(tabs.count)
        let tabHeight: CGFloat = 22
        let tabY = (bounds.height - tabHeight) / 2

        tabRects.removeAll()
        for (index, tab) in tabs.enumerated() {
            let rect = NSRect(
                x: inset + CGFloat(index) * (tabWidth + spacing),
                y: tabY,
                width: tabWidth,
                height: tabHeight
            )
            tabRects[tab] = rect

            let isSelected = tab == selectedTab
            MenuPillStyle.drawPill(in: rect, title: tab.rawValue, highlighted: isSelected, enabled: true)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        for (tab, rect) in tabRects where rect.contains(location) {
            if tab != selectedTab {
                onSelect(tab)
            }
            return
        }
    }
}

