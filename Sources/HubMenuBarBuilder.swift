import AppKit

enum HubMenuBarBuilder {
    static func install(on app: RStudioHubApp) {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "RStudioHub")
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 RStudioHub", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 RStudioHub", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let toolsItem = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        mainMenu.addItem(toolsItem)
        let toolsMenu = NSMenu(title: "Tools")
        toolsItem.submenu = toolsMenu

        for action in RStudioToolsAction.allCases {
            let item = NSMenuItem(
                title: action.hubMenuTitle,
                action: #selector(RStudioHubApp.hubToolsMenuAction(_:)),
                keyEquivalent: ""
            )
            item.target = app
            item.representedObject = action.rawValue
            toolsMenu.addItem(item)
        }

        NSApp.mainMenu = mainMenu
        ActivityLogger.shared.log("hub.menuBar installed tools=\(RStudioToolsAction.allCases.count)")
    }
}
