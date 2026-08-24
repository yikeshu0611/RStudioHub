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
    private static let createNewProjectQueries = [
        "Create a New Project",
        "Create a New Project...",
        "New Project",
    ]

    static func createNewProject() -> Bool {
        let instances = RStudioWindowService.instancesFast()
        if instances.isEmpty {
            if !DockPolicyService.launchNewInstanceHiddenFromDock() {
                ActivityLogger.shared.log("hub.createProject launchFailed")
                return false
            }
            ActivityLogger.shared.log("hub.createProject launchNewThenPalette")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                runCreateNewProjectPalette()
            }
            return true
        }

        runCreateNewProjectPalette()
        return true
    }

    private static func runCreateNewProjectPalette() {
        let instances = RStudioWindowService.instancesFast()
        guard !instances.isEmpty else {
            NSSound.beep()
            ActivityLogger.shared.log("hub.createProject noInstance")
            return
        }

        let preferredPID = RStudioWindowService.preferredPID(for: instances)
        let target = instances.first(where: { $0.pid == preferredPID }) ?? instances[0]
        RStudioWindowService.activate(target)
        ActivityLogger.shared.log("hub.createProject pid=\(target.pid)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSRunningApplication(processIdentifier: target.pid)?
                .activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                let query = createNewProjectQueries[0]
                ActivityLogger.shared.log("hub.createProject path=cgPalette query=\(query)")
                HubKeyboard.runCommandPalette(query: query)
            }
        }
    }

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
            // Hub menu click leaves Hub frontmost — activate RStudio again before keys.
            NSRunningApplication(processIdentifier: target.pid)?
                .activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                runAction(action)
            }
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