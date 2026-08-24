import AppKit
import ApplicationServices

enum RStudioToolsAction: String, CaseIterable {
    case browseAddins
    case modifyKeyboardShortcuts
    case editCodeSnippets
    case globalOptions

    var hubMenuTitle: String {
        switch self {
        case .browseAddins: return "Browse Addins"
        case .modifyKeyboardShortcuts: return "Modify Keyboard Shortcuts"
        case .editCodeSnippets: return "Edit Code Snippets"
        case .globalOptions: return "Global Options"
        }
    }

    var rstudioItemTitles: [String] {
        switch self {
        case .browseAddins:
            return [
                "browse addins", "browse addins…", "browse addins...",
                "浏览插件", "浏览插件…", "浏览 Addins",
            ]
        case .modifyKeyboardShortcuts:
            return [
                "modify keyboard shortcuts", "modify keyboard shortcuts…", "modify keyboard shortcuts...",
                "keyboard shortcuts", "keyboard shortcuts…",
                "修改键盘快捷键", "修改键盘快捷键…", "键盘快捷键",
            ]
        case .editCodeSnippets:
            return [
                "edit code snippets", "edit code snippets…", "edit code snippets...",
                "code snippets", "code snippets…",
                "编辑代码片段", "编辑代码片段…", "代码片段",
            ]
        case .globalOptions:
            return [
                "global options", "global options…", "global options...",
                "options", "options…",
                "全局选项", "全局选项…", "选项",
                "settings", "settings…", "preferences", "preferences…",
                "偏好设置", "偏好设置…", "设置", "设置…",
            ]
        }
    }
}

enum RStudioMenuBridge {
    private static let toolsMenuTitles = ["tools", "工具"]

    static func performToolsAction(_ action: RStudioToolsAction) {
        let instances = RStudioWindowService.instancesFast()
        guard !instances.isEmpty else {
            NSSound.beep()
            ActivityLogger.shared.log("hub.toolsAction noInstance action=\(action.hubMenuTitle)")
            return
        }

        let preferredPID = RStudioWindowService.preferredPID(for: instances)
        let target = instances.first(where: { $0.pid == preferredPID }) ?? instances[0]
        RStudioWindowService.activate(target)
        ActivityLogger.shared.log("hub.toolsAction action=\(action.hubMenuTitle) pid=\(target.pid)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            openToolsMenuThenItem(pid: target.pid, action: action)
        }
    }

    private static func openToolsMenuThenItem(pid: pid_t, action: RStudioToolsAction) {
        guard AccessibilityPermission.isGranted else {
            fallback(action: action)
            return
        }

        guard let toolsMenu = findTopMenu(pid: pid, titles: toolsMenuTitles) else {
            ActivityLogger.shared.log("hub.toolsAction toolsMenu=missing")
            fallback(action: action)
            return
        }

        // First try without opening (children sometimes already populated).
        if pressMatchingItem(in: toolsMenu, titles: action.rstudioItemTitles, menuName: "Tools") {
            return
        }

        AXUIElementPerformAction(toolsMenu, kAXPressAction as CFString)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if pressMatchingItem(in: toolsMenu, titles: action.rstudioItemTitles, menuName: "Tools") {
                return
            }
            // Global Options may live under the RStudio app menu / ⌘,.
            if action == .globalOptions,
               performAppMenuAction(pid: pid, itemTitles: action.rstudioItemTitles) {
                return
            }
            fallback(action: action)
        }
    }

    private static func fallback(action: RStudioToolsAction) {
        if action == .globalOptions {
            RStudioWindowService.postCommandCommaFallback()
        } else {
            ActivityLogger.shared.log("hub.toolsAction failed action=\(action.hubMenuTitle)")
            NSSound.beep()
        }
    }

    @discardableResult
    private static func pressMatchingItem(in menu: AXUIElement, titles: [String], menuName: String) -> Bool {
        let normalizedItems = Set(titles.map(normalizeTitle))
        for item in menuItemCandidates(from: menu) {
            guard let title = axString(item, kAXTitleAttribute as CFString) else { continue }
            if normalizedItems.contains(normalizeTitle(title)) {
                let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
                ActivityLogger.shared.log("hub.menuAction menu=\(menuName) item=\(title) err=\(err.rawValue)")
                return err == .success
            }
        }
        return false
    }

    private static func findTopMenu(pid: pid_t, titles: [String]) -> AXUIElement? {
        let normalizedTop = Set(titles.map(normalizeTitle))
        let appElement = AXUIElementCreateApplication(pid)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else {
            return nil
        }

        var menusRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &menusRef) == .success,
              let menus = menusRef as? [AXUIElement] else {
            return nil
        }

        return menus.dropFirst().first(where: { menu in
            guard let title = axString(menu, kAXTitleAttribute as CFString) else { return false }
            return normalizedTop.contains(normalizeTitle(title))
        })
    }

    @discardableResult
    static func performAppMenuAction(pid: pid_t, itemTitles: [String]) -> Bool {
        guard AccessibilityPermission.isGranted else { return false }

        let normalizedItems = Set(itemTitles.map(normalizeTitle))
        let appElement = AXUIElementCreateApplication(pid)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else {
            return false
        }

        var menusRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &menusRef) == .success,
              let menus = menusRef as? [AXUIElement] else {
            return false
        }

        let appMenu = menus.dropFirst().first(where: { menu in
            let title = axString(menu, kAXTitleAttribute as CFString)?.lowercased() ?? ""
            return title.contains("rstudio")
        }) ?? menus.dropFirst().first

        guard let appMenu else { return false }
        if pressMatchingItem(in: appMenu, titles: itemTitles, menuName: "RStudio") {
            return true
        }
        AXUIElementPerformAction(appMenu, kAXPressAction as CFString)
        return false
    }

    private static func menuItemCandidates(from menu: AXUIElement) -> [AXUIElement] {
        var itemsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &itemsRef) == .success,
              let topItems = itemsRef as? [AXUIElement] else {
            return []
        }
        if topItems.count == 1 {
            var nestedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(topItems[0], kAXChildrenAttribute as CFString, &nestedRef) == .success,
               let nested = nestedRef as? [AXUIElement], !nested.isEmpty {
                return nested
            }
        }
        return topItems
    }

    private static func normalizeTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
    }

    private static func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success,
              let value = rawValue as? String else {
            return nil
        }
        return value
    }
}
