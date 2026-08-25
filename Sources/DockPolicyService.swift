import AppKit
import Foundation

enum DockPolicyService {
    private static let regularPolicy = 0
    private static let accessoryPolicy = 1
    private static let allowActivateNotification = CFNotificationName("com.zhangjing.RStudioHub.allowActivate" as CFString)
    private static let hideDockNotification = CFNotificationName("com.zhangjing.RStudioHub.hideDock" as CFString)
    private static let dylibPIDDefaultsKey = "dylibInjectedPIDs"
    private static var suppressReinforceUntil: Date?
    private static var lldbHiddenPIDs: Set<Int> = []
    private static var trackedNewInstancePIDs: Set<pid_t> = []

    static var dylibPath: String? {
        Bundle.main.path(forResource: "DockHide", ofType: "dylib")
    }

    static func isInLaunchGracePeriod() -> Bool {
        if let until = suppressReinforceUntil {
            return Date() < until
        }
        return false
    }

    static func isDylibInjected(pid: pid_t) -> Bool {
        dylibInjectedPIDs().contains(Int(pid))
    }

    /// Initial hub startup: lldb legacy instances only; dylib swizzle already hides injected ones.
    static func hideAllFromDock() {
        guard !isInLaunchGracePeriod() else { return }
        hideLegacyInstancesOnly()
        ActivityLogger.shared.log("dock.hideAll legacyOnly running=[\(runningPIDSummary())]")
    }

    /// When switching to a non-RStudio app: hide legacy instances once (no periodic polling).
    static func reinforceHideFromDock() {
        guard !isInLaunchGracePeriod() else {
            ActivityLogger.shared.log("dock.reinforce skipped=launchGrace")
            return
        }
        hideLegacyInstancesOnly()
        ActivityLogger.shared.log("dock.reinforce legacyOnly running=[\(runningPIDSummary())]")
    }

    static func beginLaunchGracePeriod(seconds: TimeInterval = 15) {
        suppressReinforceUntil = Date().addingTimeInterval(seconds)
        ActivityLogger.shared.log("dock.launchGrace begin seconds=\(seconds)")
    }

    static func handleRStudioLaunch(pid: pid_t) {
        hideInstanceFromDock(pid: pid)

        if isInLaunchGracePeriod() {
            markDylibInjected(pid: pid)
            ActivityLogger.shared.log("dock.launchGrace markDylib pid=\(pid)")
        }
    }

    static func noteProcessTerminated(pid: pid_t) {
        lldbHiddenPIDs.remove(Int(pid))
        trackedNewInstancePIDs.remove(pid)
        pruneDylibPIDList()
    }

    /// New instance launched with dylib — hide Dock tile immediately.
    static func onNewInstanceLaunched(pid: pid_t, activate: Bool = false) {
        guard trackedNewInstancePIDs.insert(pid).inserted else { return }

        markDylibInjected(pid: pid)
        if let path = RStudioWindowService.pendingProjectPath {
            RStudioWindowService.rememberProject(pid: pid, path: path)
            RStudioWindowService.pendingProjectPath = nil
        }
        hideInstanceFromDock(pid: pid)
        RStudioWindowService.noteLaunching(pid: pid)
        ActivityLogger.shared.log("dock.newInstance pid=\(pid) hide=immediate activate=\(activate)")

        if activate {
            RStudioWindowService.activateForNewLaunch(pid: pid)
        }
    }

    /// RStudio launched outside Hub (no dylib): hide only this process, once.
    static func onExternalInstanceLaunched(pid: pid_t) {
        hideInstanceFromDock(pid: pid)
        ActivityLogger.shared.log("dock.externalLaunch pid=\(pid) accessory=hide")
    }

    @discardableResult
    static func launchNewInstanceHiddenFromDock(activateWhenReady: Bool = false) -> Bool {
        guard let dylibPath, FileManager.default.fileExists(atPath: dylibPath) else {
            ActivityLogger.shared.log("launch.new fallback=open without dylib")
            return RStudioDiscovery.launchNewInstance()
        }

        beginLaunchGracePeriod()
        RStudioWindowService.pendingProjectPath = nil

        if launchViaDirectBinary(dylibPath: dylibPath, projectPath: nil, activateWhenReady: activateWhenReady) {
            ActivityLogger.shared.log("launch.new dylib=true mode=directBinary activate=\(activateWhenReady)")
            return true
        }

        let appURL = URL(fileURLWithPath: RStudioDiscovery.appPath)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = activateWhenReady
        config.environment = ["DYLD_INSERT_LIBRARIES": dylibPath]

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
            if let error {
                ActivityLogger.shared.log("launch.new workspaceFailed error=\(error.localizedDescription)")
                _ = launchNewViaOpenHidden(dylibPath: dylibPath, activateWhenReady: activateWhenReady)
                return
            }
            if let app {
                onNewInstanceLaunched(pid: app.processIdentifier, activate: activateWhenReady)
            }
            ActivityLogger.shared.log("launch.new dylib=true activates=\(activateWhenReady)")
        }
        return true
    }

    @discardableResult
    static func launchProjectHiddenFromDock(at path: String) -> Bool {
        return openProjectInNewWindow(at: path)
    }

    /// Replace the current RStudio session: quit focused instance, then open the project.
    @discardableResult
    static func openProjectInCurrentWindow(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else {
            ActivityLogger.shared.log("open.project.replace missing path=\(path)")
            return false
        }

        let instances = RStudioWindowService.instancesFast()
        if let pid = RStudioWindowService.preferredPID(for: instances) {
            ActivityLogger.shared.log("open.project.replace quitCurrent pid=\(pid) path=\(path)")
            RStudioDiscovery.quit(pid: pid)
            RStudioWindowService.removeCachedInstance(pid: pid)
            DockPolicyService.noteProcessTerminated(pid: pid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                _ = openProjectInNewWindow(at: path)
            }
            return true
        }

        ActivityLogger.shared.log("open.project.replace noInstance path=\(path)")
        return openProjectInNewWindow(at: path)
    }

    /// Open project in a brand-new RStudio instance (hidden from Dock).
    @discardableResult
    static func openProjectInNewWindow(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else {
            ActivityLogger.shared.log("launch.project missing path=\(path)")
            return false
        }
        guard let dylibPath, FileManager.default.fileExists(atPath: dylibPath) else {
            ActivityLogger.shared.log("launch.project fallback=open without dylib path=\(path)")
            return NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }

        beginLaunchGracePeriod()
        RStudioWindowService.pendingProjectPath = path

        if launchViaDirectBinary(dylibPath: dylibPath, projectPath: path, activateWhenReady: true) {
            ActivityLogger.shared.log("launch.project dylib=true mode=directBinary path=\(path)")
            return true
        }

        let appURL = URL(fileURLWithPath: RStudioDiscovery.appPath)
        let fileURL = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = true
        config.environment = ["DYLD_INSERT_LIBRARIES": dylibPath]

        NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: config) { app, error in
            if let error {
                ActivityLogger.shared.log("launch.project workspaceFailed path=\(path) error=\(error.localizedDescription)")
                _ = launchProjectViaOpenHidden(path: path, dylibPath: dylibPath)
                return
            }
            if let app {
                onNewInstanceLaunched(pid: app.processIdentifier, activate: true)
            }
            ActivityLogger.shared.log("launch.project dylib=true activates=true path=\(path)")
        }
        return true
    }

    /// Launch RStudio Mach-O directly so DockHide.dylib loads before NSApp starts.
    private static func launchViaDirectBinary(
        dylibPath: String,
        projectPath: String?,
        activateWhenReady: Bool
    ) -> Bool {
        let binary = (RStudioDiscovery.appPath as NSString)
            .appendingPathComponent("Contents/MacOS/RStudio")
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        if let projectPath {
            process.arguments = [projectPath]
        }
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_INSERT_LIBRARIES"] = dylibPath
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let pid = process.processIdentifier
            DispatchQueue.main.async {
                onNewInstanceLaunched(pid: pid, activate: activateWhenReady)
            }
            return true
        } catch {
            ActivityLogger.shared.log("launch.directBinary failed error=\(error.localizedDescription)")
            return false
        }
    }

    private static func watchForNewInstance(excluding before: Set<pid_t>, activate: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            for attempt in 0..<40 {
                if attempt > 0 {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                let newcomers = RStudioDiscovery.runningApplications()
                    .filter { !before.contains($0.processIdentifier) }
                guard let target = newcomers.max(by: { $0.processIdentifier < $1.processIdentifier }) else {
                    continue
                }
                DispatchQueue.main.async {
                    onNewInstanceLaunched(pid: target.processIdentifier, activate: activate)
                }
                return
            }
        }
    }

    private static func launchNewViaOpenHidden(dylibPath: String, activateWhenReady: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-g", "-j", "-a", RStudioDiscovery.appPath]
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_INSERT_LIBRARIES"] = dylibPath
        process.environment = environment
        do {
            try process.run()
            let before = Set(RStudioDiscovery.runningApplications().map(\.processIdentifier))
            watchForNewInstance(excluding: before, activate: activateWhenReady)
            return true
        } catch {
            ActivityLogger.shared.log("launch.new openFailed error=\(error.localizedDescription)")
            return false
        }
    }

    private static func launchProjectViaOpenHidden(path: String, dylibPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-g", "-j", "-a", RStudioDiscovery.appPath, path]
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_INSERT_LIBRARIES"] = dylibPath
        process.environment = environment
        do {
            try process.run()
            let before = Set(RStudioDiscovery.runningApplications().map(\.processIdentifier))
            watchForNewInstance(excluding: before, activate: true)
            return true
        } catch {
            ActivityLogger.shared.log("launch.project openFailed path=\(path) error=\(error.localizedDescription)")
            return false
        }
    }

    static func markDylibInjected(pid: pid_t) {
        var pids = dylibInjectedPIDs()
        pids.insert(Int(pid))
        UserDefaults.standard.set(Array(pids), forKey: dylibPIDDefaultsKey)
    }

    private static var restoreHiddenGeneration = 0
    private static let focusPIDPath = "/tmp/com.zhangjing.RStudioHub.focusPID"

    /// Fallback only: briefly allow Regular policy inside the target process (via dylib).
    static func promoteTargetForFocus(pid: pid_t) {
        writeFocusPID(pid)
        postDarwinNotification(allowActivateNotification)
        ActivityLogger.shared.log("dock.promoteTarget pid=\(pid) allowOnly=true")
    }

    static func restoreTargetHiddenFromDock(pid: pid_t? = nil) {
        restoreHiddenGeneration += 1
        let generation = restoreHiddenGeneration
        let targetPID = pid
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard generation == restoreHiddenGeneration else { return }
            clearFocusPID()
            if let targetPID {
                hideInstanceFromDock(pid: targetPID)
            }
            for app in RStudioDiscovery.runningApplications() {
                hideInstanceFromDock(pid: app.processIdentifier)
            }
            ActivityLogger.shared.log("dock.restoreTargetHidden")
        }
    }

    private static func writeFocusPID(_ pid: pid_t) {
        try? String(pid).write(toFile: focusPIDPath, atomically: true, encoding: .utf8)
    }

    private static func clearFocusPID() {
        try? FileManager.default.removeItem(atPath: focusPIDPath)
    }

    private static func postDarwinNotification(_ name: CFNotificationName) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            name,
            nil,
            nil,
            true
        )
    }

    /// Accessory policy hides Dock only; menu bar stays when RStudio is frontmost.
    private static func hideInstanceFromDock(pid: pid_t) {
        if isDylibInjected(pid: pid) {
            postDarwinNotification(hideDockNotification)
            return
        }
        hideViaLldb(pid: pid)
        postDarwinNotification(hideDockNotification)
    }

    private static func hideLegacyInstancesOnly() {
        for app in RStudioDiscovery.runningApplications() {
            let pid = app.processIdentifier
            if !dylibInjectedPIDs().contains(Int(pid)) {
                hideViaLldb(pid: pid)
            }
        }
    }

    private static func pruneDylibPIDList() {
        let running = Set(RStudioDiscovery.runningApplications().map { Int($0.processIdentifier) })
        let pruned = dylibInjectedPIDs().intersection(running)
        UserDefaults.standard.set(Array(pruned), forKey: dylibPIDDefaultsKey)
        lldbHiddenPIDs = lldbHiddenPIDs.intersection(running)
        trackedNewInstancePIDs = trackedNewInstancePIDs.intersection(Set(running.map { pid_t($0) }))
    }

    private static func dylibInjectedPIDs() -> Set<Int> {
        let stored = UserDefaults.standard.array(forKey: dylibPIDDefaultsKey) as? [Int] ?? []
        return Set(stored)
    }

    private static func hideViaLldb(pid: pid_t) {
        let pidInt = Int(pid)
        guard !lldbHiddenPIDs.contains(pidInt) else { return }
        guard !dylibInjectedPIDs().contains(pidInt) else { return }

        lldbHiddenPIDs.insert(pidInt)

        DispatchQueue.global(qos: .utility).async {
            guard NSRunningApplication(processIdentifier: pid) != nil else {
                lldbHiddenPIDs.remove(pidInt)
                return
            }

            setActivationPolicyViaLldb(pid: pid, policy: accessoryPolicy)
        }
    }

    private static func setActivationPolicyViaLldb(pid: pid_t, policy: Int) {
        guard NSRunningApplication(processIdentifier: pid) != nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lldb")
        process.arguments = [
            "-p", String(pid),
            "--batch",
            "-o",
            "expr (void)[(id)[NSClassFromString(\"NSApplication\") sharedApplication] setActivationPolicy:\(policy)]",
            "-o", "quit",
        ]
        do {
            try process.run()
            process.waitUntilExit()
            ActivityLogger.shared.log("lldb.policy pid=\(pid) policy=\(policy) exit=\(process.terminationStatus)")
        } catch {
            ActivityLogger.shared.log("lldb.policy failed pid=\(pid) policy=\(policy) error=\(error.localizedDescription)")
        }
    }

    private static func runningPIDSummary() -> String {
        RStudioDiscovery.runningApplications()
            .map { String($0.processIdentifier) }
            .joined(separator: ",")
    }
}
