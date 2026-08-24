import AppKit

enum HubDockMenuBuilder {
    /// Dock menus pad the right edge; the ✕ sits left of that padding.
    private static let closeZoneWidth: CGFloat = 72
    private static let titleTrailingPadding: CGFloat = 28

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
        items.append(makeUpdateItem(app: app))

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

    private static func rowTitle(marker: String, title: String, contentWidth: CGFloat, font: NSFont) -> String {
        let base = "\(marker)\(title)"
        let baseWidth = (base as NSString).size(withAttributes: [.font: font]).width
        let closeMark = "✕"
        let closeWidth = (closeMark as NSString).size(withAttributes: [.font: font]).width
        // Leave room on the right so ✕ aligns with the clickable close zone (not flush to menu edge).
        let usableWidth = contentWidth - titleTrailingPadding
        let gap = usableWidth - baseWidth - closeWidth
        let spaceWidth = max((" " as NSString).size(withAttributes: [.font: font]).width, 1)
        let spaces = max(2, Int(gap / spaceWidth))
        return base + String(repeating: " ", count: spaces) + closeMark
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
        let files = RStudioRecentFiles.allEntries()

        if files.isEmpty {
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

        if projects.isEmpty {
            let emptyItem = NSMenuItem(title: "没有历史项目", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for entry in projects {
                let item = NSMenuItem(
                    title: entry.name,
                    action: #selector(RStudioHubApp.dockOpenProject(_:)),
                    keyEquivalent: ""
                )
                item.target = app
                item.representedObject = entry.path
                submenu.addItem(item)
            }
        }

        let root = NSMenuItem(title: "历史项目", action: nil, keyEquivalent: "")
        root.submenu = submenu
        return root
    }

    private static func makeUpdateItem(app: RStudioHubApp) -> NSMenuItem {
        let item = NSMenuItem(
            title: HubUpdateService.menuTitle(),
            action: #selector(RStudioHubApp.dockCheckForUpdates(_:)),
            keyEquivalent: ""
        )
        item.target = app
        return item
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
