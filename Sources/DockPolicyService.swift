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
            reinforceHideSoon(pid: pid)
        }
    }

    static func noteProcessTerminated(pid: pid_t) {
        lldbHiddenPIDs.remove(Int(pid))
        pruneDylibPIDList()
    }

    /// New instance launched with dylib — hide Dock tile immediately.
    static func onNewInstanceLaunched(pid: pid_t) {
        markDylibInjected(pid: pid)
        if let path = RStudioWindowService.pendingProjectPath {
            RStudioWindowService.rememberProject(pid: pid, path: path)
            RStudioWindowService.pendingProjectPath = nil
        }
        hideInstanceFromDock(pid: pid)
        reinforceHideSoon(pid: pid)
        ActivityLogger.shared.log("dock.newInstance pid=\(pid) hide=immediate")
    }

    /// RStudio launched outside Hub (no dylib): hide only this process, once.
    static func onExternalInstanceLaunched(pid: pid_t) {
        hideInstanceFromDock(pid: pid)
        ActivityLogger.shared.log("dock.externalLaunch pid=\(pid) accessory=hide")
    }

    @discardableResult
    static func launchNewInstanceHiddenFromDock() -> Bool {
        guard let dylibPath, FileManager.default.fileExists(atPath: dylibPath) else {
            ActivityLogger.shared.log("launch.new fallback=open without dylib")
            return RStudioDiscovery.launchNewInstance()
        }

        beginLaunchGracePeriod()
        startLaunchHideWatch()
        // Blank "New R" must not inherit a previous project name.
        RStudioWindowService.pendingProjectPath = nil

        if launchViaDirectBinary(dylibPath: dylibPath, projectPath: nil) {
            ActivityLogger.shared.log("launch.new dylib=true mode=directBinary")
            return true
        }

        let appURL = URL(fileURLWithPath: RStudioDiscovery.appPath)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.environment = ["DYLD_INSERT_LIBRARIES": dylibPath]

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
            if let error {
                ActivityLogger.shared.log("launch.new workspaceFailed error=\(error.localizedDescription)")
                _ = launchNewViaOpenHidden(dylibPath: dylibPath)
                return
            }
            if let app {
                onNewInstanceLaunched(pid: app.processIdentifier)
            }
            ActivityLogger.shared.log("launch.new dylib=true activates=false")
        }
        return true
    }

    @discardableResult
    static func launchProjectHiddenFromDock(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else {
            ActivityLogger.shared.log("launch.project missing path=\(path)")
            return false
        }
        guard let dylibPath, FileManager.default.fileExists(atPath: dylibPath) else {
            ActivityLogger.shared.log("launch.project fallback=open without dylib path=\(path)")
            return NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }

        beginLaunchGracePeriod()
        startLaunchHideWatch()
        RStudioWindowService.pendingProjectPath = path

        if launchViaDirectBinary(dylibPath: dylibPath, projectPath: path) {
            ActivityLogger.shared.log("launch.project dylib=true mode=directBinary path=\(path)")
            return true
        }

        let appURL = URL(fileURLWithPath: RStudioDiscovery.appPath)
        let fileURL = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.environment = ["DYLD_INSERT_LIBRARIES": dylibPath]

        NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: config) { app, error in
            if let error {
                ActivityLogger.shared.log("launch.project workspaceFailed path=\(path) error=\(error.localizedDescription)")
                _ = launchProjectViaOpenHidden(path: path, dylibPath: dylibPath)
                return
            }
            if let app {
                onNewInstanceLaunched(pid: app.processIdentifier)
            }
            ActivityLogger.shared.log("launch.project dylib=true activates=false path=\(path)")
        }
        return true
    }

    /// Launch RStudio Mach-O directly so DockHide.dylib loads before NSApp starts.
    private static func launchViaDirectBinary(dylibPath: String, projectPath: String?) -> Bool {
        let binary = (RStudioDiscovery.appPath as NSString)
            .appendingPathComponent("Contents/MacOS/RStudio")
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            return false
        }

        let before = Set(RStudioDiscovery.runningApplications().map(\.processIdentifier))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        if let projectPath {
            process.arguments = [projectPath]
        }
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_INSERT_LIBRARIES"] = dylibPath
        // Keep LaunchServices from forcing a foreground activation.
        environment["__CFPREFERENCES_APPLICATION_IDENTIFIER"] = environment["__CFPREFERENCES_APPLICATION_IDENTIFIER"] ?? ""
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                hideNewestRStudio(excluding: before)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                hideNewestRStudio(excluding: before)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                hideNewestRStudio(excluding: before)
            }
            return true
        } catch {
            ActivityLogger.shared.log("launch.directBinary failed error=\(error.localizedDescription)")
            return false
        }
    }

    private static func hideNewestRStudio(excluding before: Set<pid_t>) {
        let apps = RStudioDiscovery.runningApplications()
        let newcomers = apps.filter { !before.contains($0.processIdentifier) }
        let target = newcomers.max(by: { $0.processIdentifier < $1.processIdentifier })
            ?? apps.max(by: { $0.processIdentifier < $1.processIdentifier })
        guard let target else { return }
        onNewInstanceLaunched(pid: target.processIdentifier)
    }

    private static var launchHideWatchGeneration = 0

    /// Rapidly hide any new RStudio Dock tiles during the first second after launch.
    private static func startLaunchHideWatch() {
        launchHideWatchGeneration += 1
        let generation = launchHideWatchGeneration
        let before = Set(RStudioDiscovery.runningApplications().map(\.processIdentifier))

        for step in 0..<20 {
            let delay = 0.05 * Double(step)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard generation == launchHideWatchGeneration else { return }
                for app in RStudioDiscovery.runningApplications()
                where !before.contains(app.processIdentifier) || step == 0 {
                    hideInstanceFromDock(pid: app.processIdentifier)
                }
            }
        }
    }

    private static func launchNewViaOpenHidden(dylibPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -g background, -j hidden — reduce Dock flash on launch.
        process.arguments = ["-n", "-g", "-j", "-a", RStudioDiscovery.appPath]
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_INSERT_LIBRARIES"] = dylibPath
        process.environment = environment
        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let app = newestRunningRStudio() {
                    onNewInstanceLaunched(pid: app.processIdentifier)
                    reinforceHideSoon(pid: app.processIdentifier)
                }
            }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let app = newestRunningRStudio() {
                    onNewInstanceLaunched(pid: app.processIdentifier)
                    reinforceHideSoon(pid: app.processIdentifier)
                }
            }
            return true
        } catch {
            ActivityLogger.shared.log("launch.project openFailed path=\(path) error=\(error.localizedDescription)")
            return false
        }
    }

    private static func reinforceHideSoon(pid: pid_t) {
        for delay in [0.0, 0.03, 0.08, 0.15, 0.3, 0.6] as [TimeInterval] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                hideInstanceFromDock(pid: pid)
            }
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
    /// Do not call TransformProcessType/showInDock — that flashes Dock and menu bar.
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
        if !isDylibInjected(pid: pid) {
            hideViaLldb(pid: pid)
        }
        postDarwinNotification(hideDockNotification)
    }

    private static func newestRunningRStudio() -> NSRunningApplication? {
        RStudioDiscovery.runningApplications().max(by: { $0.processIdentifier < $1.processIdentifier })
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
