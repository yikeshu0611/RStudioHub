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

    /// Queries to try in RStudio Command Palette (⌘⇧P), most specific first.
    var commandPaletteQueries: [String] {
        switch self {
        case .browseAddins:
            return ["Browse Addins", "Browse Addins...", "Addins"]
        case .modifyKeyboardShortcuts:
            return ["Modify Keyboard Shortcuts", "Keyboard Shortcuts"]
        case .editCodeSnippets:
            return ["Edit Code Snippets", "Code Snippets"]
        case .globalOptions:
            return ["Global Options"]
        }
    }
}

enum RStudioMenuBridge {
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            runAction(action)
        }
    }

    private static func runAction(_ action: RStudioToolsAction) {
        if action == .globalOptions {
            HubKeyboard.postCommandComma()
            ActivityLogger.shared.log("hub.toolsAction path=cmdComma action=\(action.hubMenuTitle)")
            return
        }

        // CGEvent keyboard — same mechanism as Global Options (⌘,).
        let query = action.commandPaletteQueries[0]
        ActivityLogger.shared.log("hub.toolsAction path=cgPalette query=\(query)")
        HubKeyboard.runCommandPalette(query: query)
    }
}