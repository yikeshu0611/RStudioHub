import AppKit
import Foundation
import ServiceManagement

enum LaunchAtLoginSettings {
    private static let preferenceKey = "launchAtLogin.requested"

    static let optionTitle = "开机启动"

    static var isSupported: Bool {
        if #available(macOS 13.0, *) {
            return true
        }
        return false
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                return true
            case .notRegistered, .notFound:
                return false
            @unknown default:
                return UserDefaults.standard.bool(forKey: preferenceKey)
            }
        }
        return UserDefaults.standard.bool(forKey: preferenceKey)
    }

    static func syncOnLaunch() {
        guard #available(macOS 13.0, *) else { return }
        guard UserDefaults.standard.bool(forKey: preferenceKey) else { return }
        guard !isEnabled else { return }
        _ = setEnabled(true)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard isSupported else {
            NSSound.beep()
            showUnsupportedAlert()
            return false
        }

        guard #available(macOS 13.0, *) else { return false }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            UserDefaults.standard.set(enabled, forKey: preferenceKey)
            ActivityLogger.shared.log("launchAtLogin.\(enabled ? "enabled" : "disabled")")

            if enabled, SMAppService.mainApp.status == .requiresApproval {
                ActivityLogger.shared.log("launchAtLogin.requiresApproval")
            }

            NotificationCenter.default.post(name: .hubLaunchAtLoginDidChange, object: nil)
            return true
        } catch {
            ActivityLogger.shared.log("launchAtLogin.failed error=\(error.localizedDescription)")
            NSSound.beep()
            return false
        }
    }

    private static func showUnsupportedAlert() {
        let alert = NSAlert()
        alert.messageText = "无法设置开机启动"
        alert.informativeText = "此功能需要 macOS 13 或更高版本。"
        alert.alertStyle = .informational
        alert.runModal()
    }
}

extension Notification.Name {
    static let hubLaunchAtLoginDidChange = Notification.Name("RStudioHub.launchAtLoginDidChange")
}
