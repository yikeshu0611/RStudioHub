import AppKit

final class ProjectMenuRowView: MenuRowHoverView {
    static var rowWidth: CGFloat { MenuRowHoverView.menuWidth }
    static let rowHeight: CGFloat = 22

    private let entry: ProjectHistoryEntry
    private let onOpen: (ProjectHistoryEntry) -> Void
    private let titleField = NSTextField(labelWithString: "")

    init(entry: ProjectHistoryEntry, onOpen: @escaping (ProjectHistoryEntry) -> Void) {
        self.entry = entry
        self.onOpen = onOpen
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: Self.rowHeight))
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        let leftInset: CGFloat = 18
        let rightInset: CGFloat = 10

        titleField.stringValue = entry.name
        titleField.frame = NSRect(x: leftInset, y: 2, width: Self.rowWidth - leftInset - rightInset, height: Self.rowHeight - 4)
        titleField.font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.toolTip = entry.path ?? entry.name
        titleField.isBezeled = false
        titleField.drawsBackground = false
        addSubview(titleField)
    }

    override func hoverStateDidChange(_ hovered: Bool) {
        titleField.textColor = hovered ? .alternateSelectedControlTextColor : .labelColor
    }

    override func mouseDown(with event: NSEvent) {
        onOpen(entry)
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
