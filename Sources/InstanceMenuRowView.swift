import AppKit

final class InstanceMenuRowView: MenuRowHoverView {
    static var rowWidth: CGFloat { MenuRowHoverView.menuWidth }
    static let rowHeight: CGFloat = 22

    private let instance: RStudioInstance
    private let onActivate: (RStudioInstance) -> Void
    private let onClose: (pid_t) -> Void

    private let dotView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let closeBackground = NSView()
    private let closeView = NSImageView()
    private var closeHitRect = NSRect.zero

    init(
        instance: RStudioInstance,
        onActivate: @escaping (RStudioInstance) -> Void,
        onClose: @escaping (pid_t) -> Void
    ) {
        self.instance = instance
        self.onActivate = onActivate
        self.onClose = onClose
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: Self.rowHeight))
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        let dotSize: CGFloat = 12
        let closeSize: CGFloat = 20
        let leftInset: CGFloat = 18
        let rightInset: CGFloat = 8

        dotView.frame = NSRect(x: leftInset, y: (Self.rowHeight - dotSize) / 2, width: dotSize, height: dotSize)
        dotView.image = instance.isActive ? Self.activeDotImage : Self.blankDotImage
        dotView.imageScaling = .scaleProportionallyDown
        addSubview(dotView)

        closeHitRect = NSRect(
            x: Self.rowWidth - rightInset - closeSize - 4,
            y: 1,
            width: closeSize + 8,
            height: Self.rowHeight - 2
        )
        closeBackground.frame = closeHitRect
        closeBackground.wantsLayer = true
        closeBackground.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        closeBackground.layer?.cornerRadius = 4
        addSubview(closeBackground)

        closeView.frame = NSRect(
            x: closeHitRect.midX - closeSize / 2,
            y: closeHitRect.midY - closeSize / 2,
            width: closeSize,
            height: closeSize
        )
        closeView.image = Self.closeImage
        closeView.imageScaling = .scaleProportionallyDown
        closeView.contentTintColor = .labelColor
        closeView.toolTip = "关闭此实例"
        addSubview(closeView)

        let titleX = leftInset + dotSize + 6
        let titleWidth = closeHitRect.minX - titleX - 4
        titleField.frame = NSRect(x: titleX, y: 2, width: titleWidth, height: Self.rowHeight - 4)
        titleField.stringValue = instance.menuTitle
        titleField.font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.isBezeled = false
        titleField.drawsBackground = false
        addSubview(titleField)
    }

    override func hoverStateDidChange(_ hovered: Bool) {
        titleField.textColor = hovered ? .alternateSelectedControlTextColor : .labelColor
        dotView.contentTintColor = hovered ? .alternateSelectedControlTextColor : nil
        if hovered {
            closeBackground.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.28).cgColor
            closeView.contentTintColor = .alternateSelectedControlTextColor
        } else {
            closeBackground.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
            closeView.contentTintColor = .labelColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if closeHitRect.contains(location) {
            onClose(instance.pid)
            return
        }
        enclosingMenuItem?.menu?.cancelTracking()
        onActivate(instance)
    }

    private static let dotSize = NSSize(width: 12, height: 12)

    private static let blankDotImage: NSImage = {
        NSImage(size: dotSize)
    }()

    private static let activeDotImage: NSImage = {
        if let symbol = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
            let image = symbol.withSymbolConfiguration(config) ?? symbol
            image.size = dotSize
            image.isTemplate = true
            return image
        }
        return blankDotImage
    }()

    private static let closeImage: NSImage? = {
        let symbol = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭")
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let image = symbol?.withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }()
}
