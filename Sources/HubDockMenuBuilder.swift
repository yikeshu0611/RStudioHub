import AppKit

enum HubDockMenuBuilder {
    /// Dock menus pad the right edge; treat this strip as the ✕ hit zone.
    private static let closeZoneWidth: CGFloat = 110
    private static let titleTrailingPadding: CGFloat = 28

    /// Updated continuously while the Dock menu is open.
    private(set) static var lastMouseInCloseZone = false

    static func makeItems(instances: [RStudioInstance], app: RStudioHubApp) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        if !AccessibilityPermission.isGranted {
            let permissionItem = NSMenuItem(
                title: "⚠ 需要辅助功能权限",
                action: #selector(RStudioHubApp.openAccessibilitySettings),
                keyEquivalent: ""
            )
            permissionItem.target = app
            items.append(permissionItem)
            items.append(.separator())
        }

        items.append(contentsOf: makeInstanceItems(instances: instances, app: app))
        items.append(.separator())
        items.append(contentsOf: makeActionItems(instances: instances, app: app))
        items.append(.separator())
        items.append(makeFileSubmenu(app: app))
        items.append(makeProjectSubmenu(app: app))

        return items
    }

    private static func makeInstanceItems(instances: [RStudioInstance], app: RStudioHubApp) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        if instances.isEmpty {
            let emptyItem = NSMenuItem(title: "没有打开的 RStudio", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            items.append(emptyItem)
            return items
        }

        let font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        let contentWidth = dockContentWidth(for: instances, font: font)

        for instance in instances {
            let marker = instance.isActive ? "● " : "○ "
            let item = NSMenuItem(
                title: rowTitle(marker: marker, title: instance.menuTitle, contentWidth: contentWidth, font: font),
                action: #selector(RStudioHubApp.dockInstanceRowAction(_:)),
                keyEquivalent: ""
            )
            item.target = app
            item.representedObject = NSNumber(value: instance.pid)
            item.toolTip = "点击名称切换 · 点击右侧 ✕ 关闭"
            items.append(item)
        }

        return items
    }

    private static func dockContentWidth(for instances: [RStudioInstance], font: NSFont) -> CGFloat {
        var maxTextWidth: CGFloat = 160
        for instance in instances {
            let marker = instance.isActive ? "● " : "○ "
            let text = "\(marker)\(instance.menuTitle)" as NSString
            let width = text.size(withAttributes: [.font: font]).width
            maxTextWidth = max(maxTextWidth, width)
        }
        return min(max(maxTextWidth + closeZoneWidth + 8, MenuLayout.minWidth), MenuLayout.maxWidth)
    }

    /// Plain title only — Dock strips attributed backgrounds/attachments.
    private static func rowTitle(
        marker: String,
        title: String,
        contentWidth: CGFloat,
        font: NSFont
    ) -> String {
        let closeMark = "✕"
        let base = "\(marker)\(title)"
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let baseWidth = (base as NSString).size(withAttributes: attrs).width
        let markWidth = (closeMark as NSString).size(withAttributes: attrs).width
        let spaceWidth = max((" " as NSString).size(withAttributes: attrs).width, 1)
        let usableWidth = contentWidth - titleTrailingPadding
        let gap = usableWidth - baseWidth - markWidth
        let spaces = max(2, Int(gap / spaceWidth))
        return base + String(repeating: " ", count: spaces) + closeMark
    }

    /// Call while Dock menu is open (hover / click) so ✕ hits are sticky until the action runs.
    static func updateCloseZoneTracking(mouse: NSPoint = NSEvent.mouseLocation) {
        let inZone = isCloseZone(at: mouse)
        if inZone {
            lastMouseInCloseZone = true
        } else if NSEvent.pressedMouseButtons == 0 {
            // Only clear when not dragging a click, so mouse-down-in-zone stays armed.
            lastMouseInCloseZone = false
        }
    }

    static func consumeCloseZoneClick() -> Bool {
        let result = lastMouseInCloseZone || isCloseZone()
        lastMouseInCloseZone = false
        return result
    }

    static func resetCloseZoneTracking() {
        lastMouseInCloseZone = false
    }

    private static func isCloseZone(at mouse: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard let frame = menuFrameContaining(mouse) else { return false }
        let localX = mouse.x - frame.minX
        let zone = max(closeZoneWidth, frame.width * 0.32)
        return localX >= frame.width - zone
    }

    private static func menuFrameContaining(_ mouse: NSPoint) -> CGRect? {
        for window in NSApp.windows where window.isVisible {
            let frame = window.frame
            guard frame.width >= 120, frame.width <= 700, frame.height >= 40, frame.height < 900 else { continue }
            if NSMouseInRect(mouse, frame, false) {
                return frame
            }
        }

        let cgMouse = quartzPoint(from: mouse)
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        var best: CGRect?
        for info in windowList {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"],
                  let y = bounds["Y"],
                  let width = bounds["Width"],
                  let height = bounds["Height"] else {
                continue
            }

            let quartzRect = CGRect(x: x, y: y, width: width, height: height)
            guard quartzRect.contains(cgMouse) else { continue }
            guard isMenuPopupWindow(info) else { continue }
            guard width >= 120, width <= 700, height >= 40, height < 900 else { continue }

            let cocoa = cocoaRect(fromQuartz: quartzRect)
            if let current = best {
                if cocoa.height > current.height {
                    best = cocoa
                }
            } else {
                best = cocoa
            }
        }
        return best
    }

    private static func cocoaRect(fromQuartz rect: CGRect) -> CGRect {
        guard let screen = NSScreen.screens.first(where: {
            let cocoaY = $0.frame.maxY - rect.maxY
            let candidate = NSRect(x: rect.minX, y: cocoaY, width: rect.width, height: rect.height)
            return $0.frame.intersects(candidate)
        }) ?? NSScreen.main else {
            return NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        }
        let cocoaY = screen.frame.maxY - rect.maxY
        return NSRect(x: rect.minX, y: cocoaY, width: rect.width, height: rect.height)
    }

    private static let menuItemHeight: CGFloat = 24
    private static let menuVerticalPadding: CGFloat = 12
    private static let submenuHeightTolerance: CGFloat = 24

    private(set) static var dockFilePaths: [String] = []
    private(set) static var dockProjectPaths: [String] = []
    private(set) static var dockToolsItemCount: Int = RStudioToolsAction.allCases.count
    static weak var fileSubmenu: NSMenu?
    static weak var projectSubmenu: NSMenu?
    static var openDockSubmenuKind: DockSubmenuKind?

    static func filePathAtMouse(_ mouse: NSPoint = NSEvent.mouseLocation) -> String? {
        filePathAtMouseViaSubmenuKind(mouse) ?? {
            guard !dockFilePaths.isEmpty else { return nil }
            guard let rect = dockSubmenuWindow(at: mouse, itemCount: dockFilePaths.count) else { return nil }
            let index = rowIndex(in: rect, mouse: mouse)
            guard index >= 0, index < dockFilePaths.count else { return nil }
            return dockFilePaths[index]
        }()
    }

    enum DockSubmenuKind {
        case files
        case projects
        case tools
    }

    private static func expectedSubmenuHeight(itemCount: Int) -> CGFloat {
        CGFloat(itemCount) * menuItemHeight + menuVerticalPadding
    }

    private static func isMenuPopupWindow(_ info: [String: Any]) -> Bool {
        if let layer = info[kCGWindowLayer as String] as? Int, layer >= 20 {
            return true
        }
        if let owner = info[kCGWindowOwnerName as String] as? String {
            return owner == "Dock" || owner == "Window Server" || owner == "RStudioHub"
        }
        return false
    }

    private static func dockSubmenuWindow(at mouse: NSPoint, itemCount: Int) -> CGRect? {
        guard itemCount > 0 else { return nil }
        let expectedHeight = expectedSubmenuHeight(itemCount: itemCount)
        let cgMouse = quartzPoint(from: mouse)

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for info in windowList {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"],
                  let y = bounds["Y"],
                  let width = bounds["Width"],
                  let height = bounds["Height"] else {
                continue
            }

            let rect = CGRect(x: x, y: y, width: width, height: height)
            guard rect.contains(cgMouse) else { continue }
            guard isMenuPopupWindow(info) else { continue }
            guard width >= 120, width <= 700 else { continue }
            guard abs(height - expectedHeight) <= submenuHeightTolerance else { continue }
            return rect
        }

        return nil
    }

    private static func rowIndex(in window: CGRect, mouse: NSPoint) -> Int {
        let cgMouse = quartzPoint(from: mouse)
        let localY = cgMouse.y - window.minY
        return Int((localY - menuVerticalPadding / 2) / menuItemHeight)
    }

    private static func identifySubmenuKind(windowHeight: CGFloat) -> DockSubmenuKind? {
        let tolerance = submenuHeightTolerance
        var matches: [DockSubmenuKind] = []

        if !dockFilePaths.isEmpty,
           abs(windowHeight - expectedSubmenuHeight(itemCount: dockFilePaths.count)) <= tolerance {
            matches.append(.files)
        }
        if !dockProjectPaths.isEmpty,
           abs(windowHeight - expectedSubmenuHeight(itemCount: dockProjectPaths.count)) <= tolerance {
            matches.append(.projects)
        }
        if dockToolsItemCount > 0,
           abs(windowHeight - expectedSubmenuHeight(itemCount: dockToolsItemCount)) <= tolerance {
            matches.append(.tools)
        }

        if matches.count == 1 {
            return matches[0]
        }
        return nil
    }

    private static func filePathAtMouseViaSubmenuKind(_ mouse: NSPoint = NSEvent.mouseLocation) -> String? {
        let cgMouse = quartzPoint(from: mouse)
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for info in windowList {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"],
                  let y = bounds["Y"],
                  let width = bounds["Width"],
                  let height = bounds["Height"] else {
                continue
            }

            let rect = CGRect(x: x, y: y, width: width, height: height)
            guard rect.contains(cgMouse) else { continue }
            guard isMenuPopupWindow(info) else { continue }
            guard width >= 120, width <= 700, height >= 28, height < 900 else { continue }
            guard identifySubmenuKind(windowHeight: height) == .files else { continue }

            let index = rowIndex(in: rect, mouse: mouse)
            guard index >= 0, index < dockFilePaths.count else { return nil }
            return dockFilePaths[index]
        }

        return nil
    }

    private static func quartzPoint(from cocoaPoint: NSPoint) -> CGPoint {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(cocoaPoint, $0.frame, false) })
                ?? NSScreen.main else {
            return CGPoint(x: cocoaPoint.x, y: cocoaPoint.y)
        }
        let topY = screen.frame.maxY
        return CGPoint(x: cocoaPoint.x, y: topY - cocoaPoint.y)
    }

    private static func makeFileSubmenu(app: RStudioHubApp) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.delegate = app
        fileSubmenu = submenu
        let files = RStudioRecentFiles.allEntries()
        dockFilePaths = files.map(\.path)

        if files.isEmpty {
            dockFilePaths = []
            let emptyItem = NSMenuItem(title: "没有历史文件", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for entry in files {
                let item = NSMenuItem(
                    title: entry.name,
                    action: #selector(RStudioHubApp.dockOpenFile(_:)),
                    keyEquivalent: ""
                )
                item.target = app
                item.representedObject = entry.path
                item.toolTip = entry.path
                submenu.addItem(item)
            }
        }

        let root = NSMenuItem(title: "历史文件", action: nil, keyEquivalent: "")
        root.submenu = submenu
        return root
    }

    private static func makeProjectSubmenu(app: RStudioHubApp) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.delegate = app
        projectSubmenu = submenu
        let projects = ProjectHistoryStore.shared.allEntries()
        dockProjectPaths = projects.compactMap(\.path)

        if projects.isEmpty {
            dockProjectPaths = []
            let emptyItem = NSMenuItem(title: "没有历史项目", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for entry in projects {
                guard let path = entry.path else { continue }
                let item = NSMenuItem(
                    title: entry.name,
                    action: #selector(RStudioHubApp.dockOpenProject(_:)),
                    keyEquivalent: ""
                )
                item.target = app
                item.representedObject = path
                item.toolTip = entry.path ?? entry.name
                submenu.addItem(item)
            }
        }

        let root = NSMenuItem(title: "历史项目", action: nil, keyEquivalent: "")
        root.submenu = submenu
        return root
    }

    private static func makeActionItems(instances: [RStudioInstance], app: RStudioHubApp) -> [NSMenuItem] {
        let newR = NSMenuItem(
            title: "新建 R",
            action: #selector(RStudioHubApp.launchNewRStudio),
            keyEquivalent: ""
        )
        newR.target = app

        let newRproj = NSMenuItem(
            title: "新建 Rproj",
            action: #selector(RStudioHubApp.dockCreateNewRproj),
            keyEquivalent: ""
        )
        newRproj.target = app

        let quitAll = NSMenuItem(
            title: "关闭所有 RStudio",
            action: #selector(RStudioHubApp.quitAllRStudio),
            keyEquivalent: ""
        )
        quitAll.target = app
        quitAll.isEnabled = !instances.isEmpty

        return [newR, newRproj, quitAll]
    }
}
