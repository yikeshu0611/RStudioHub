import AppKit

final class DockFileMenuRowView: NSView {
    static let rowHeight: CGFloat = 22

    init(name: String, path: String, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.rowHeight))
        setup(name: name, width: width)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(name: String, width: CGFloat) {
        let titleField = NSTextField(labelWithString: "")
        titleField.frame = NSRect(x: 18, y: 2, width: width - 26, height: Self.rowHeight - 4)
        titleField.stringValue = name
        titleField.font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.isBezeled = false
        titleField.drawsBackground = false
        addSubview(titleField)
    }
}
