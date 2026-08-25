import AppKit
import ApplicationServices

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
            guard frame.width >= 120, frame.width <= 1400, frame.height >= 40, frame.height < 900 else { continue }
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
            guard width >= 120, width <= 1400, height >= 40, height < 900 else { continue }

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
    /// Dock menu chrome varies by macOS version / scaling — keep relatively tight to avoid
    /// mistaking the root Dock menu for the files submenu.
    private static let submenuHeightTolerance: CGFloat = 40

    private(set) static var dockFilePaths: [String] = []
    private(set) static var dockProjectPaths: [String] = []
    private(set) static var dockToolsItemCount: Int = RStudioToolsAction.allCases.count
    static weak var fileSubmenu: NSMenu?
    static weak var projectSubmenu: NSMenu?
    static var openDockSubmenuKind: DockSubmenuKind?

    /// Last known on-screen files-list frame (Quartz), kept briefly for stable hover/positioning.
    private static var cachedFilesFrameQuartz: CGRect?
    private static var cachedFilesFrameAt: TimeInterval = 0

    static func resetFilesFrameCache() {
        cachedFilesFrameQuartz = nil
        cachedFilesFrameAt = 0
    }

    private static func rememberFilesFrame(_ rect: CGRect) {
        cachedFilesFrameQuartz = rect
        cachedFilesFrameAt = Date.timeIntervalSinceReferenceDate
    }

    private static func looksLikeFilesMenu(height: CGFloat, itemCount: Int) -> Bool {
        guard itemCount > 0 else { return false }
        let expected = expectedSubmenuHeight(itemCount: itemCount)
        return abs(height - expected) <= submenuHeightTolerance
    }

    /// On-screen Dock/menu popup windows (Quartz bounds).
    private static func onScreenMenuWindows() -> [CGRect] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        var result: [CGRect] = []
        for info in windowList {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"],
                  let y = bounds["Y"],
                  let width = bounds["Width"],
                  let height = bounds["Height"] else {
                continue
            }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            guard isMenuPopupWindow(info) else { continue }
            guard width >= 80, width <= 1400, height >= 28, height < 900 else { continue }
            result.append(rect)
        }
        return result
    }

    static func filePathAtMouse(_ mouse: NSPoint = NSEvent.mouseLocation) -> String? {
        guard !dockFilePaths.isEmpty else { return nil }
        guard let rect = filesListWindowContaining(mouse) else { return nil }
        rememberFilesFrame(rect)
        let index = rowIndex(in: rect, mouse: mouse, itemCount: dockFilePaths.count)
        guard index >= 0, index < dockFilePaths.count else { return nil }
        return dockFilePaths[index]
    }

    /// Path under the cursor — only when the cursor is inside the files list window.
    static func filePathForHover(mouse: NSPoint = NSEvent.mouseLocation) -> String? {
        guard isMouseInsideFilesSubmenu(mouse: mouse) else { return nil }

        if let path = filePathFromAccessibility(mouse: mouse) {
            return path
        }
        return filePathAtMouse(mouse)
    }

    /// True only when the history-files submenu is on-screen and the cursor is inside it.
    static func isMouseInsideFilesSubmenu(mouse: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard !dockFilePaths.isEmpty else { return false }
        // Root Dock menu alone must never qualify — need parent + files submenu.
        guard onScreenMenuWindows().count >= 2 else { return false }
        guard let rect = filesListWindowContaining(mouse) else { return false }
        openDockSubmenuKind = .files
        rememberFilesFrame(rect)
        return true
    }

    /// Files-list window under the cursor (tight height match). Never returns the root menu.
    private static func filesListWindowContaining(_ mouse: NSPoint) -> CGRect? {
        let expected = expectedSubmenuHeight(itemCount: dockFilePaths.count)
        let cgMouse = quartzPoint(from: mouse)
        let menus = onScreenMenuWindows().filter { $0.contains(cgMouse) }
        // Prefer the window whose height is closest to the files list.
        let ranked = menus
            .map { (rect: $0, score: abs($0.height - expected)) }
            .filter { $0.score <= submenuHeightTolerance }
            .sorted { $0.score < $1.score }
        return ranked.first?.rect
    }

    /// Resolve hovered Dock menu item via Accessibility (works when NSMenu highlight does not).
    private static func filePathFromAccessibility(mouse: NSPoint) -> String? {
        guard AccessibilityPermission.isGranted, !dockFilePaths.isEmpty else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        let candidates: [CGPoint] = [
            quartzPoint(from: mouse),
            CGPoint(x: mouse.x, y: mouse.y), // some systems report cocoa-space here
        ]

        for point in candidates {
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(
                systemWide,
                Float(point.x),
                Float(point.y),
                &element
            ) == .success,
                  let start = element,
                  let menuItem = axClosestMenuItem(from: start),
                  let rawTitle = axString(menuItem, kAXTitleAttribute as String),
                  !rawTitle.isEmpty else {
                continue
            }

            let title = normalizeMenuTitle(rawTitle)
            let titleFolded = title.lowercased()

            if let index = axMenuItemIndex(menuItem),
               index >= 0,
               index < dockFilePaths.count {
                let path = dockFilePaths[index]
                let name = URL(fileURLWithPath: path).lastPathComponent
                if name.caseInsensitiveCompare(title) == .orderedSame
                    || displayPath(path).caseInsensitiveCompare(title) == .orderedSame
                    || titleFolded.hasSuffix(name.lowercased()) {
                    return path
                }
            }

            let matches = dockFilePaths.filter {
                let name = URL(fileURLWithPath: $0).lastPathComponent
                let shown = displayPath($0)
                return name.caseInsensitiveCompare(title) == .orderedSame
                    || shown.caseInsensitiveCompare(title) == .orderedSame
                    || titleFolded.hasSuffix(name.lowercased())
            }
            if let only = matches.count == 1 ? matches[0] : nil {
                return only
            }
            if matches.count > 1, let index = axMenuItemIndex(menuItem),
               index >= 0, index < dockFilePaths.count,
               matches.contains(dockFilePaths[index]) {
                return dockFilePaths[index]
            }
            if let first = matches.first {
                return first
            }
        }
        return nil
    }

    /// Strip legacy "name · path" titles down to the filename.
    private static func normalizeMenuTitle(_ title: String) -> String {
        if let range = title.range(of: "  ·  ") {
            return String(title[..<range.lowerBound])
        }
        if let range = title.range(of: " · ") {
            return String(title[..<range.lowerBound])
        }
        return title
    }

    private static func axClosestMenuItem(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<10 {
            guard let el = current else { return nil }
            if let role = axString(el, kAXRoleAttribute as String),
               role == (kAXMenuItemRole as String) {
                return el
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parentRef else {
                return nil
            }
            current = (parentRef as! AXUIElement)
        }
        return nil
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else {
            return nil
        }
        return value as? String
    }

    private static func axMenuItemIndex(_ element: AXUIElement) -> Int? {
        var parentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
              let parentRef else {
            return nil
        }
        let parent = parentRef as! AXUIElement

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        for (index, child) in children.enumerated() {
            if CFEqual(child, element) {
                return index
            }
        }
        return nil
    }

    /// When we know the files submenu is open, map mouse Y to a row without strict height match.
    private static func pathFromOpenFilesSubmenu(_ mouse: NSPoint) -> String? {
        guard !dockFilePaths.isEmpty else { return nil }
        guard openDockSubmenuKind == .files || fileSubmenu?.highlightedItem != nil else { return nil }
        guard let rect = locateFilesSubmenuWindow(mouse: mouse) else { return nil }
        let cocoa = cocoaRect(fromQuartz: rect).insetBy(dx: -4, dy: -4)
        guard NSMouseInRect(mouse, cocoa, false) else { return nil }
        let index = rowIndex(in: rect, mouse: mouse, itemCount: dockFilePaths.count)
        guard index >= 0, index < dockFilePaths.count else { return nil }
        return dockFilePaths[index]
    }

    /// Best on-screen files-list window that contains the cursor (for path + hit-test).
    private static func locateFilesSubmenuWindow(mouse: NSPoint) -> CGRect? {
        filesListWindowContaining(mouse).map {
            rememberFilesFrame($0)
            return $0
        }
    }

    /// Frame for positioning the tooltip: live window under cursor, else short-lived cache.
    static func filesSubmenuFrame(mouse: NSPoint = NSEvent.mouseLocation) -> NSRect? {
        guard !dockFilePaths.isEmpty else { return nil }
        if let quartz = locateFilesSubmenuWindow(mouse: mouse) {
            return cocoaRect(fromQuartz: quartz)
        }
        if openDockSubmenuKind == .files,
           let cached = cachedFilesFrameQuartz,
           Date.timeIntervalSinceReferenceDate - cachedFilesFrameAt < 0.35 {
            return cocoaRect(fromQuartz: cached)
        }
        return nil
    }

    /// Like menuWindowContaining, but require height close to the files submenu.
    private static func menuWindowMatchingFilesHeight(containing mouse: NSPoint) -> CGRect? {
        guard !dockFilePaths.isEmpty else { return nil }
        guard let rect = menuWindowContaining(mouse, preferringItemCount: dockFilePaths.count) else {
            return nil
        }
        guard looksLikeFilesMenu(height: rect.height, itemCount: dockFilePaths.count) else { return nil }
        return rect
    }

    /// On-screen menu window whose height matches the files list, preferring near the mouse.
    private static func anyFilesSubmenuWindowNear(_ mouse: NSPoint) -> CGRect? {
        guard !dockFilePaths.isEmpty else { return nil }
        let expectedHeight = expectedSubmenuHeight(itemCount: dockFilePaths.count)
        let cgMouse = quartzPoint(from: mouse)
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        var best: (rect: CGRect, score: CGFloat)?
        for info in windowList {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"],
                  let y = bounds["Y"],
                  let width = bounds["Width"],
                  let height = bounds["Height"] else {
                continue
            }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            guard isMenuPopupWindow(info) else { continue }
            guard width >= 80, width <= 1400 else { continue }
            guard looksLikeFilesMenu(height: height, itemCount: dockFilePaths.count) else { continue }
            let heightScore = abs(height - expectedHeight)
            let dx = abs(rect.midX - cgMouse.x)
            let dy = abs(rect.midY - cgMouse.y)
            let score = heightScore + dx * 0.15 + dy * 0.05
            if let current = best {
                if score < current.score { best = (rect, score) }
            } else {
                best = (rect, score)
            }
        }
        return best?.rect
    }

    private static func anyFilesSubmenuWindow() -> CGRect? {
        anyFilesSubmenuWindowNear(NSEvent.mouseLocation)
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

    private static func menuWindowContaining(
        _ mouse: NSPoint,
        preferringItemCount: Int
    ) -> CGRect? {
        let cgMouse = quartzPoint(from: mouse)
        let preferredHeight = expectedSubmenuHeight(itemCount: preferringItemCount)

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        var best: (rect: CGRect, score: CGFloat)?
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
            guard width >= 80, width <= 1400, height >= 28, height < 900 else { continue }

            let score = abs(height - preferredHeight)
            if let current = best {
                if score < current.score {
                    best = (rect, score)
                }
            } else {
                best = (rect, score)
            }
        }
        return best?.rect
    }

    private static func dockSubmenuWindow(at mouse: NSPoint, itemCount: Int) -> CGRect? {
        guard itemCount > 0 else { return nil }
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
            guard width >= 80, width <= 1400 else { continue }
            guard looksLikeFilesMenu(height: height, itemCount: itemCount) else { continue }
            rememberFilesFrame(rect)
            return rect
        }

        return nil
    }

    private static func rowIndex(in window: CGRect, mouse: NSPoint, itemCount: Int? = nil) -> Int {
        let count = max(itemCount ?? dockFilePaths.count, 1)
        let cgMouse = quartzPoint(from: mouse)
        let pad: CGFloat = 4
        let usable = max(window.height - pad * 2, 1)
        let rowH = usable / CGFloat(count)
        let localY = cgMouse.y - window.minY - pad
        let idx = Int(floor(localY / max(rowH, 1)))
        return max(0, min(count - 1, idx))
    }

    static func inferOpenSubmenuKindIfNeeded() {
        // Do NOT infer `.files` from geometry — the root Dock menu is often misclassified
        // and then shows the path popup while hovering「隐藏」/「新建 R」. `.files` is set
        // only in menuWillOpen for the history-files submenu.
        if openDockSubmenuKind != nil { return }
        guard onScreenMenuWindows().count >= 2 else { return }

        let mouse = NSEvent.mouseLocation
        let cgMouse = quartzPoint(from: mouse)
        for rect in onScreenMenuWindows() where rect.contains(cgMouse) {
            if let kind = identifySubmenuKind(windowHeight: rect.height), kind != .files {
                openDockSubmenuKind = kind
                return
            }
        }
    }

    private static func identifySubmenuKind(windowHeight: CGFloat) -> DockSubmenuKind? {
        var matches: [DockSubmenuKind] = []

        if !dockFilePaths.isEmpty,
           looksLikeFilesMenu(height: windowHeight, itemCount: dockFilePaths.count) {
            matches.append(.files)
        }
        if !dockProjectPaths.isEmpty,
           looksLikeFilesMenu(height: windowHeight, itemCount: dockProjectPaths.count) {
            matches.append(.projects)
        }
        if dockToolsItemCount > 0,
           looksLikeFilesMenu(height: windowHeight, itemCount: dockToolsItemCount) {
            matches.append(.tools)
        }

        if matches.count == 1 {
            return matches[0]
        }
        if let open = openDockSubmenuKind, matches.contains(open) {
            return open
        }
        // Prefer files when both files and projects match by count (common).
        if matches.contains(.files) {
            return .files
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
            guard width >= 80, width <= 1400, height >= 28, height < 900 else { continue }
            guard identifySubmenuKind(windowHeight: height) == .files else { continue }

            rememberFilesFrame(rect)
            let index = rowIndex(in: rect, mouse: mouse, itemCount: dockFilePaths.count)
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
        // Filenames only in the list; full path shown by HubPathTooltip on the LEFT.
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

    static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    /// Cocoa-space frame of the on-screen「历史文件」submenu, if found.
    // (Implemented above as filesSubmenuFrame.)

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
