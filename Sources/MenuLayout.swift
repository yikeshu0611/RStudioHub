import AppKit

enum MenuLayout {
    static let minWidth: CGFloat = 176
    static let maxWidth: CGFloat = 420

    static func preferredWidth(
        selectedTab: HubMenuTab,
        instances: [RStudioInstance],
        projects: [ProjectHistoryEntry]
    ) -> CGFloat {
        var width = minWidth

        width = max(width, actionButtonsWidth())
        width = max(width, shortcutRowWidth())

        switch selectedTab {
        case .current:
            width = max(width, currentTabContentWidth(instances: instances))
        case .project:
            width = max(width, projectTabContentWidth(projects: projects))
        }

        return min(ceil(width), maxWidth)
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func currentTabContentWidth(instances: [RStudioInstance]) -> CGFloat {
        let font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        let rowPadding: CGFloat = 18 + 12 + 6 + 6 + 20 + 10

        var width = textWidth("没有打开的 RStudio", font: font) + 36
        width = max(width, textWidth("⚠ 需要辅助功能权限", font: font) + 24)

        for instance in instances {
            let rowWidth = textWidth(instance.menuTitle, font: font) + rowPadding
            width = max(width, rowWidth)
        }

        return width
    }

    private static func projectTabContentWidth(projects: [ProjectHistoryEntry]) -> CGFloat {
        let font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        let rowPadding: CGFloat = 18 + 10 + 22 + 8

        var width = textWidth("没有历史项目", font: font) + 36
        for entry in projects {
            let rowWidth = textWidth(entry.name, font: font) + rowPadding
            width = max(width, rowWidth)
        }

        return width
    }

    private static func actionButtonsWidth() -> CGFloat {
        let font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        let labels = ["New R", "NewRproj", "quit R", "quit Hub"]
        let maxLabel = labels.map { textWidth($0, font: font) }.max() ?? 0
        let inset = MenuPillStyle.inset
        let spacing = MenuPillStyle.spacing
        return inset * 2 + maxLabel * 2 + spacing + 16
    }

    private static func shortcutRowWidth() -> CGFloat {
        let font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        let inset = ShortcutSettingsRowView.rowInset
        let left = textWidth(HubShortcutAction.openMenu.title, font: font)
        let shortcut = textWidth(ShortcutStore.displayString(for: .openMenu), font: font)
        let login = textWidth(LaunchAtLoginSettings.optionTitle, font: font) + 16 + 12
        return inset * 2 + left + shortcut + login + 36
    }
}
