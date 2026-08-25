import AppKit

enum HubDockMenuBuilder {
    /// Dock menus pad the right edge; the ✕ sits left of that padding.
    private static let closeZoneWidth: CGFloat = 72
    private static let titleTrailingPadding: CGFloat = 28
    private static let newWindowMark = "↗"

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
            item.representedObject = DockInstanceRowRef(pid: instance.pid)
            item.toolTip = "点击名称切换，点击右侧 ✕ 关闭"
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

    private static func rowTitle(
        marker: String,
        title: String,
        contentWidth: CGFloat,
        font: NSFont,
        trailingMark: String = "✕"
    ) -> String {
        let base = "\(marker)\(title)"
        let baseWidth = (base as NSString).size(withAttributes: [.font: font]).width
        let markWidth = (trailingMark as NSString).size(withAttributes: [.font: font]).width
        let usableWidth = contentWidth - titleTrailingPadding
        let gap = usableWidth - baseWidth - markWidth
        let spaceWidth = max((" " as NSString).size(withAttributes: [.font: font]).width, 1)
        let spaces = max(2, Int(gap / spaceWidth))
        return base + String(repeating: " ", count: spaces) + trailingMark
    }

    private static let menuItemHeight: CGFloat = 24
    private static let menuVerticalPadding: CGFloat = 12
    private static let submenuHeightTolerance: CGFloat = 24

    private(set) static var dockFilePaths: [String] = []
    private(set) static var dockProjectPaths: [String] = []
    private(set) static var dockToolsItemCount: Int = RStudioToolsAction.allCases.count

    /// Dock menus do not call `menuWillHighlight`; resolve hovered file path from submenu geometry.
    static func filePathAtMouse(_ mouse: NSPoint = NSEvent.mouseLocation) -> String? {
        filePathAtMouseViaSubmenuKind(mouse) ?? {
            guard !dockFilePaths.isEmpty else { return nil }
            guard let rect = dockSubmenuWindow(at: mouse, itemCount: dockFilePaths.count) else { return nil }
            let index = rowIndex(in: rect, mouse: mouse)
            guard index >= 0, index < dockFilePaths.count else { return nil }
            return dockFilePaths[index]
        }()
    }

    private enum DockSubmenuKind {
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
            return owner == "Dock" || owner == "Window Server"
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

    /// Right-side action zone (close ✕ or new-window ↗).
    static func isRightZoneClick(event: NSEvent?) -> Bool {
        isCloseClick(event: event)
    }

    /// Detect close by mouse X against the actual menu window (Dock menus are not in NSApp.windows).
    static func isCloseClick(event: NSEvent?) -> Bool {
        let mouse = NSEvent.mouseLocation

        if let window = resolveAppMenuWindow(event: event, mouse: mouse) {
            let localX = mouse.x - window.frame.minX
            return localX >= window.frame.width - closeZoneWidth
        }

        return isCloseClickViaScreenWindow(mouse: mouse)
    }

    private static func resolveAppMenuWindow(event: NSEvent?, mouse: NSPoint) -> NSWindow? {
        if let window = event?.window, NSMouseInRect(mouse, window.frame, false) {
            return window
        }

        return NSApp.windows.first { window in
            window.isVisible
                && window.frame.width >= 120
                && window.frame.height >= 40
                && NSMouseInRect(mouse, window.frame, false)
        }
    }

    private static func isCloseClickViaScreenWindow(mouse: NSPoint) -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        let cgMouse = quartzPoint(from: mouse)

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
            guard width >= 140, height >= 40, height < 900 else { continue }

            let localX = cgMouse.x - rect.minX
            return localX >= width - closeZoneWidth
        }

        return false
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
        let projects = ProjectHistoryStore.shared.allEntries()
        dockProjectPaths = projects.compactMap(\.path)

        if projects.isEmpty {
            dockProjectPaths = []
            let emptyItem = NSMenuItem(title: "没有历史项目", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            let font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
            let contentWidth = dockProjectContentWidth(for: projects, font: font)
            for entry in projects {
                let item = NSMenuItem(
                    title: projectRowTitle(name: entry.name, contentWidth: contentWidth, font: font),
                    action: #selector(RStudioHubApp.dockProjectRowAction(_:)),
                    keyEquivalent: ""
                )
                item.target = app
                item.representedObject = DockProjectRowRef(path: entry.path ?? entry.name)
                item.toolTip = "点击名称：关闭当前 RStudio 后打开；点击右侧 ↗：新窗口打开"
                submenu.addItem(item)
            }
        }

        let root = NSMenuItem(title: "历史项目", action: nil, keyEquivalent: "")
        root.submenu = submenu
        return root
    }

    private static func dockProjectContentWidth(for projects: [ProjectHistoryEntry], font: NSFont) -> CGFloat {
        var maxTextWidth: CGFloat = 120
        for entry in projects {
            let width = (entry.name as NSString).size(withAttributes: [.font: font]).width
            maxTextWidth = max(maxTextWidth, width)
        }
        return min(max(maxTextWidth + closeZoneWidth + 8, MenuLayout.minWidth), MenuLayout.maxWidth)
    }

    private static func projectRowTitle(name: String, contentWidth: CGFloat, font: NSFont) -> String {
        rowTitle(marker: "", title: name, contentWidth: contentWidth, font: font, trailingMark: newWindowMark)
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

final class DockInstanceRowRef: NSObject {
    let pid: pid_t

    init(pid: pid_t) {
        self.pid = pid
    }
}

final class DockProjectRowRef: NSObject {
    let path: String

    init(path: String) {
        self.path = path
    }
}
