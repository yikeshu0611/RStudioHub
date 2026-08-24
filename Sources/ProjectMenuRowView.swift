import AppKit

final class ProjectMenuRowView: MenuRowHoverView {
    static var rowWidth: CGFloat { MenuRowHoverView.menuWidth }
    static let rowHeight: CGFloat = 22

    private let entry: ProjectHistoryEntry
    private let onOpenCurrent: (ProjectHistoryEntry) -> Void
    private let onOpenNew: (ProjectHistoryEntry) -> Void
    private let titleField = NSTextField(labelWithString: "")
    private let newWindowView = NSImageView()
    private var newWindowHitRect = NSRect.zero

    init(
        entry: ProjectHistoryEntry,
        onOpenCurrent: @escaping (ProjectHistoryEntry) -> Void,
        onOpenNew: @escaping (ProjectHistoryEntry) -> Void
    ) {
        self.entry = entry
        self.onOpenCurrent = onOpenCurrent
        self.onOpenNew = onOpenNew
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: Self.rowHeight))
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        let iconSize: CGFloat = 18
        let leftInset: CGFloat = 18
        let rightInset: CGFloat = 8

        newWindowHitRect = NSRect(
            x: Self.rowWidth - rightInset - iconSize,
            y: (Self.rowHeight - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
        newWindowView.frame = newWindowHitRect
        newWindowView.image = Self.newWindowImage
        newWindowView.imageScaling = .scaleProportionallyDown
        newWindowView.toolTip = "在新窗口中打开"
        addSubview(newWindowView)

        let titleWidth = newWindowHitRect.minX - leftInset - 4
        titleField.frame = NSRect(x: leftInset, y: 2, width: titleWidth, height: Self.rowHeight - 4)
        titleField.stringValue = entry.name
        titleField.font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.toolTip = (entry.path ?? entry.name) + "\n点击在当前窗口打开（会先关闭当前 RStudio）"
        titleField.isBezeled = false
        titleField.drawsBackground = false
        addSubview(titleField)
    }

    override func hoverStateDidChange(_ hovered: Bool) {
        titleField.textColor = hovered ? .alternateSelectedControlTextColor : .labelColor
        newWindowView.contentTintColor = hovered ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        enclosingMenuItem?.menu?.cancelTracking()
        if newWindowHitRect.contains(location) {
            onOpenNew(entry)
        } else {
            onOpenCurrent(entry)
        }
    }

    private static let newWindowImage: NSImage? = {
        let symbol = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: "在新窗口中打开")
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let image = symbol?.withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }()
}
