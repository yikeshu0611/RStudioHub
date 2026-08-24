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

    /// Text to search in RStudio Command Palette (Cmd+Shift+P).
    var commandPaletteQuery: String {
        switch self {
        case .browseAddins: return "Browse Addins"
        case .modifyKeyboardShortcuts: return "Modify Keyboard Shortcuts"
        case .editCodeSnippets: return "Edit Code Snippets"
        case .globalOptions: return "Global Options"
        }
    }

    /// Nested path under Tools for AppleScript fallback (Browse Addins lives under Addins).
    var toolsMenuPath: [String] {
        switch self {
        case .browseAddins:
            return ["Addins", "Browse Addins…"]
        case .modifyKeyboardShortcuts:
            return ["Modify Keyboard Shortcuts…"]
        case .editCodeSnippets:
            return ["Edit Code Snippets…"]
        case .globalOptions:
            return ["Global Options…"]
        }
    }

    var rstudioItemTitles: [String] {
        toolsMenuPath.flatMap { item in
            let base = item
                .replacingOccurrences(of: "…", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return [base.lowercased(), item.lowercased()]
        }
    }
}

enum RStudioMenuBridge {
    private static let toolsMenuTitles = ["tools", "工具"]
    private static var appleScriptBusy = false

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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            runAction(action, pid: target.pid)
        }
    }

    private static func runAction(_ action: RStudioToolsAction, pid: pid_t) {
        if action == .globalOptions {
            RStudioWindowService.postCommandCommaFallback()
            ActivityLogger.shared.log("hub.toolsAction path=cmdComma action=\(action.hubMenuTitle)")
            return
        }

        if openViaCommandPalette(action: action) {
            ActivityLogger.shared.log("hub.toolsAction path=commandPalette action=\(action.hubMenuTitle)")
            return
        }

        if openViaPromotedMenu(action: action, pid: pid) {
            ActivityLogger.shared.log("hub.toolsAction path=promotedMenu action=\(action.hubMenuTitle)")
            return
        }

        ActivityLogger.shared.log("hub.toolsAction failed action=\(action.hubMenuTitle)")
        NSSound.beep()
    }

    /// Command palette works even when RStudio hides its menu bar (accessory policy).
    private static func openViaCommandPalette(action: RStudioToolsAction) -> Bool {
        let query = escapeAppleScript(action.commandPaletteQuery)
        let script = """
        tell application "RStudio" to activate
        delay 0.25
        tell application "System Events"
            tell process "RStudio"
                set frontmost to true
                keystroke "p" using {command down, shift down}
                delay 0.4
                keystroke "\(query)"
                delay 0.2
                key code 36
            end tell
        end tell
        """
        return runAppleScript(script)
    }

    /// Temporarily show RStudio in Dock so the menu bar exists, then click Tools items.
    private static func openViaPromotedMenu(action: RStudioToolsAction, pid: pid_t) -> Bool {
        ProcessTransform.showInDock(pid: pid)
        DockPolicyService.promoteTargetForFocus(pid: pid)
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])

        let variants = menuPathVariants(for: action)
        var ok = false
        for path in variants {
            let menuChain = buildMenuAppleScript(path: path)
            let script = """
            tell application "RStudio" to activate
            delay 0.35
            tell application "System Events"
                tell process "RStudio"
                    set frontmost to true
                    \(menuChain)
                end tell
            end tell
            """
            if runAppleScript(script) {
                ok = true
                break
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            DockPolicyService.restoreTargetHiddenFromDock(pid: pid)
        }
        return ok
    }

    private static func menuPathVariants(for action: RStudioToolsAction) -> [[String]] {
        switch action {
        case .browseAddins:
            return [
                ["Addins", "Browse Addins…"],
                ["Addins", "Browse Addins..."],
                ["Addins", "Browse Addins"],
            ]
        case .modifyKeyboardShortcuts:
            return [
                ["Modify Keyboard Shortcuts…"],
                ["Modify Keyboard Shortcuts..."],
                ["Modify Keyboard Shortcuts"],
            ]
        case .editCodeSnippets:
            return [
                ["Edit Code Snippets…"],
                ["Edit Code Snippets..."],
                ["Edit Code Snippets"],
            ]
        case .globalOptions:
            return [
                ["Global Options…"],
                ["Global Options..."],
                ["Global Options"],
            ]
        }
    }

    private static func buildMenuAppleScript(path: [String]) -> String {
        guard !path.isEmpty else { return "" }
        if path.count == 1 {
            let leaf = escapeAppleScript(path[0])
            return "click menu item \"\(leaf)\" of menu \"Tools\" of menu bar item \"Tools\" of menu bar 1"
        }

        var chain = "menu \"Tools\" of menu bar item \"Tools\" of menu bar 1"
        for index in 0..<(path.count - 1) {
            let name = escapeAppleScript(path[index])
            chain = "menu \"\(name)\" of menu item \"\(name)\" of \(chain)"
        }
        let leaf = escapeAppleScript(path[path.count - 1])
        let parent = escapeAppleScript(path[path.count - 2])
        return "click menu item \"\(leaf)\" of menu \"\(parent)\" of menu item \"\(escapeAppleScript(path[0]))\" of menu \"Tools\" of menu bar item \"Tools\" of menu bar 1"
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> Bool {
        guard !appleScriptBusy else { return false }
        appleScriptBusy = true
        defer { appleScriptBusy = false }

        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        script?.executeAndReturnError(&error)
        if let error {
            ActivityLogger.shared.log("hub.appleScript failed error=\(error)")
            return false
        }
        return true
    }

    private static func escapeAppleScript(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // Legacy AX helpers kept for diagnostics; menu bar is usually unavailable under accessory policy.
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
