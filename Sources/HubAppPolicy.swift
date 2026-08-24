import AppKit

enum HubAppPolicy {
    /// Show RStudioHub as a regular app with a Dock icon.
    static func showInDock() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
    }
}
