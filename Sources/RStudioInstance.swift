import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class RStudioInstance: NSObject {
    let pid: pid_t
    let title: String
    let isActive: Bool

    init(pid: pid_t, title: String, isActive: Bool) {
        self.pid = pid
        self.title = title
        self.isActive = isActive
    }

    var projectName: String? {
        Self.projectName(from: title)
    }

    var menuTitle: String {
        if let name = projectName {
            return "\(name) (\(pid))"
        }
        return "RStudio (\(pid))"
    }

    static func projectName(from rawTitle: String) -> String? {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".Rproj") {
            return URL(fileURLWithPath: trimmed).deletingPathExtension().lastPathComponent
        }
        let cleaned = trimmed
            .replacingOccurrences(of: " - RStudio", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "RStudio" {
            return nil
        }
        if cleaned.hasPrefix("RStudio (") {
            return nil
        }
        return cleaned
    }
}

enum RStudioDiscovery {
    static let bundleIdentifier = "com.rstudio.desktop"
    static let appPath = "/Applications/RStudio.app"

    static func runningApplications() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
            .sorted { $0.processIdentifier < $1.processIdentifier }
    }

    static func activePID() -> pid_t? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == bundleIdentifier,
              !front.isTerminated else {
            return nil
        }
        return front.processIdentifier
    }

    @discardableResult
    static func launchNewInstance() -> Bool {
        guard FileManager.default.fileExists(atPath: appPath) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-a", appPath]
        do {
            try process.run()
            return true
        } catch {
            NSLog("RStudioHub: open failed: \(error.localizedDescription)")
            return false
        }
    }

    static func quit(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    static func quitAll() {
        for app in runningApplications() {
            app.terminate()
        }
    }

    static func forceQuitAll() {
        for app in runningApplications() {
            app.forceTerminate()
        }
    }
}

enum AccessibilityPermission {
    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    static func ensure(prompt: Bool) -> Bool {
        if isGranted {
            return true
        }
        guard prompt else { return false }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

enum RStudioWindowService {
    private static let cacheQueue = DispatchQueue(label: "com.zhangjing.RStudioHub.InstanceCache", qos: .userInitiated)
    private static var cachedInstances: [RStudioInstance] = []
    private static var titleByPID: [pid_t: String] = [:]
    static var pendingProjectPath: String?
    private static var lastFocusedPID: pid_t?
    private static let lastFocusedPIDKey = "lastFocusedRStudioPID"

    static func restoreFocusedPID() {
        guard let stored = UserDefaults.standard.object(forKey: lastFocusedPIDKey) as? Int else { return }
        let pid = pid_t(stored)
        let running = RStudioDiscovery.runningApplications().map(\.processIdentifier)
        guard running.contains(pid) else {
            UserDefaults.standard.removeObject(forKey: lastFocusedPIDKey)
            return
        }
        lastFocusedPID = pid
    }

    static func noteFocused(pid: pid_t) {
        lastFocusedPID = pid
        UserDefaults.standard.set(Int(pid), forKey: lastFocusedPIDKey)
    }

    /// PID shown with the dot — last user-focused instance, else frontmost RStudio.
    private static func highlightedPID(for apps: [NSRunningApplication]) -> pid_t? {
        let running = Set(apps.map(\.processIdentifier))

        if let last = lastFocusedPID, running.contains(last) {
            return last
        }

        if let front = RStudioDiscovery.activePID(), running.contains(front) {
            return front
        }

        if let stored = UserDefaults.standard.object(forKey: lastFocusedPIDKey) as? Int {
            let pid = pid_t(stored)
            if running.contains(pid) {
                lastFocusedPID = pid
                return pid
            }
            UserDefaults.standard.removeObject(forKey: lastFocusedPIDKey)
        }

        return nil
    }

    /// Instant menu list — never blocks on lsof / sysctl / AX probes.
    static func instancesFast() -> [RStudioInstance] {
        let apps = RStudioDiscovery.runningApplications()
        let markedPID = highlightedPID(for: apps)
        let instances = apps.map { app in
            let pid = app.processIdentifier
            let title = titleByPID[pid]
                ?? cachedInstances.first(where: { $0.pid == pid })?.title
                ?? ""
            return RStudioInstance(
                pid: pid,
                title: title,
                isActive: pid == markedPID
            )
        }
        return RStudioInstance.sortedByName(instances)
    }

    /// Same as `instancesFast` — Dock menu must open instantly.
    static func instancesForMenu() -> [RStudioInstance] {
        instancesFast()
    }

    /// Resolve missing project titles off the main thread so the next menu open is accurate.
    static func warmTitlesInBackground() {
        cacheQueue.async {
            let detailed = fetchInstancesDetailed()
            DispatchQueue.main.async {
                for instance in detailed {
                    if RStudioInstance.projectName(from: instance.title) != nil {
                        rememberTitle(pid: instance.pid, title: instance.title)
                    }
                }
                cachedInstances = detailed.map { instance in
                    let title = titleByPID[instance.pid] ?? instance.title
                    return RStudioInstance(pid: instance.pid, title: title, isActive: instance.isActive)
                }
            }
        }
    }

    static func rememberTitle(pid: pid_t, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, RStudioInstance.projectName(from: trimmed) != nil else { return }
        titleByPID[pid] = trimmed
    }

    static func rememberProject(pid: pid_t, path: String) {
        rememberTitle(pid: pid, title: path)
    }

    static func invalidateCache() {
        cachedInstances = []
        // Keep titleByPID so Dock menu still shows project names.
        RStudioSessionProjects.invalidateCache()
    }

    static func clearCachedInstances() {
        cachedInstances = []
    }

    static func removeCachedInstance(pid: pid_t) {
        cachedInstances.removeAll { $0.pid == pid }
        titleByPID.removeValue(forKey: pid)
        RStudioSessionProjects.removeCached(mainPID: pid)
        if lastFocusedPID == pid {
            lastFocusedPID = nil
            UserDefaults.standard.removeObject(forKey: lastFocusedPIDKey)
        }
    }

    static func refreshInstances(completion: (([RStudioInstance]) -> Void)? = nil) {
        cacheQueue.async {
            let instances = fetchInstancesDetailed()
            DispatchQueue.main.async {
                cachedInstances = instances
                completion?(instances)
            }
        }
    }

    private static func fetchInstancesDetailed() -> [RStudioInstance] {
        let apps = RStudioDiscovery.runningApplications()
        guard !apps.isEmpty else { return [] }
        let markedPID = highlightedPID(for: apps)

        if AccessibilityPermission.isGranted {
            return RStudioInstance.sortedByName(apps.map { app in
                instanceForProcess(pid: app.processIdentifier, isActive: app.processIdentifier == markedPID)
            })
        }

        return RStudioInstance.sortedByName(apps.map { app in
            RStudioInstance(
                pid: app.processIdentifier,
                title: resolveTitle(for: app.processIdentifier),
                isActive: app.processIdentifier == markedPID
            )
        })
    }

    static func activateActiveInstance() {
        let instances = instancesFast()
        guard !instances.isEmpty else {
            NSSound.beep()
            return
        }

        let preferredPID = lastFocusedPID ?? RStudioDiscovery.activePID()
        let target: RStudioInstance
        if let pid = preferredPID, let match = instances.first(where: { $0.pid == pid }) {
            target = match
        } else {
            target = instances[0]
        }

        ActivityLogger.shared.log("hub.shortcut.activate pid=\(target.pid) title=\(target.menuTitle)")
        activate(target)
        ProjectHistoryStore.shared.record(from: target)
    }

    static func cycleToNextInstance() {
        let instances = instancesFast()
        guard !instances.isEmpty else { return }

        let activePID = RStudioDiscovery.activePID()
        let target: RStudioInstance
        if let activeIndex = instances.firstIndex(where: { $0.pid == activePID }) {
            target = instances[(activeIndex + 1) % instances.count]
        } else {
            target = instances[0]
        }

        activate(target)
        ProjectHistoryStore.shared.record(from: target)
    }

    static func activate(_ instance: RStudioInstance) {
        noteFocused(pid: instance.pid)

        guard let app = NSRunningApplication(processIdentifier: instance.pid),
              !app.isTerminated else {
            return
        }

        ActivityLogger.shared.log("window.activate pid=\(instance.pid) title=\(instance.menuTitle)")

        app.activate(options: [.activateIgnoringOtherApps])
        raiseMainWindow(pid: instance.pid)
    }

    /// Hot path for Dock / shortcut switching — never block on title resolution.
    static func activate(pid: pid_t) {
        let cachedTitle = titleByPID[pid]
            ?? cachedInstances.first(where: { $0.pid == pid })?.title
            ?? ""
        let instance = RStudioInstance(pid: pid, title: cachedTitle, isActive: true)
        activate(instance)

        DispatchQueue.global(qos: .utility).async {
            let resolved = resolveTitle(for: pid)
            if RStudioInstance.projectName(from: resolved) != nil {
                DispatchQueue.main.async {
                    rememberTitle(pid: pid, title: resolved)
                    ProjectHistoryStore.shared.record(
                        from: RStudioInstance(pid: pid, title: resolved, isActive: true)
                    )
                }
            }
        }
    }

    private static func raiseMainWindow(pid: pid_t) {
        guard AccessibilityPermission.isGranted else { return }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawValue) == .success,
              let windows = rawValue as? [AXUIElement] else {
            return
        }

        let candidates = windows.filter(isStandardWindow)
        guard let window = mainWindow(in: candidates) ?? candidates.first else { return }

        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private static func instanceForProcess(pid: pid_t, isActive: Bool) -> RStudioInstance {
        var resolvedTitle = ""

        if AccessibilityPermission.isGranted {
            let appElement = AXUIElementCreateApplication(pid)
            var rawValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawValue) == .success,
               let windows = rawValue as? [AXUIElement] {
                let standardWindows = windows.filter(isStandardWindow)
                for window in standardWindows {
                    if let raw = axString(window, kAXTitleAttribute as CFString),
                       RStudioInstance.projectName(from: raw) != nil {
                        resolvedTitle = raw
                        break
                    }
                }
                if resolvedTitle.isEmpty,
                   let window = mainWindow(in: standardWindows) ?? standardWindows.first,
                   let raw = axString(window, kAXTitleAttribute as CFString) {
                    resolvedTitle = raw
                }
            }
        }

        if RStudioInstance.projectName(from: resolvedTitle) == nil {
            resolvedTitle = resolveTitle(for: pid)
        }

        return RStudioInstance(pid: pid, title: resolvedTitle, isActive: isActive)
    }

    private static func resolveTitle(for pid: pid_t) -> String {
        if let remembered = titleByPID[pid], RStudioInstance.projectName(from: remembered) != nil {
            return remembered
        }

        // Only trust explicit project signals — never guess from UI labels
        // (recent-project menus caused false names on blank "New R" windows).
        if let path = projectPathFromMainProcessArguments(pid: pid) {
            rememberTitle(pid: pid, title: path)
            return path
        }

        if let path = initialProjectFromProcess(pid: pid) {
            rememberTitle(pid: pid, title: path)
            return path
        }

        if let path = RStudioSessionProjects.projectPath(forMainPID: pid) {
            rememberTitle(pid: pid, title: path)
            return path
        }

        if let cached = cachedInstances.first(where: { $0.pid == pid })?.title,
           RStudioInstance.projectName(from: cached) != nil {
            rememberTitle(pid: pid, title: cached)
            return cached
        }

        if let cgTitle = windowTitleViaCGWindow(pid: pid),
           RStudioInstance.projectName(from: cgTitle) != nil {
            rememberTitle(pid: pid, title: cgTitle)
            return cgTitle
        }

        if AccessibilityPermission.isGranted {
            let appElement = AXUIElementCreateApplication(pid)
            var rawValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawValue) == .success,
               let windows = rawValue as? [AXUIElement] {
                for window in windows.filter(isStandardWindow) {
                    if let raw = axString(window, kAXTitleAttribute as CFString),
                       RStudioInstance.projectName(from: raw) != nil {
                        rememberTitle(pid: pid, title: raw)
                        return raw
                    }
                }
            }
        }

        return ""
    }

    /// Prefer argv of the main RStudio process: `.../RStudio /path/to/foo.Rproj`.
    private static func projectPathFromMainProcessArguments(pid: pid_t) -> String? {
        if let cPath = HubProcessFindRprojArgument(pid) {
            let path = String(cString: cPath)
            free(cPath)
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Fallback: ps (may mangle non-ASCII paths).
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-ww", "-o", "args="]
        process.environment = ["LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let args = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !args.isEmpty else {
            return nil
        }

        let pattern = #"(/[^\s\"]+\.[Rr]proj)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(args.startIndex..<args.endIndex, in: args)
        guard let match = regex.firstMatch(in: args, range: range),
              let swiftRange = Range(match.range(at: 1), in: args) else {
            return nil
        }

        let path = String(args[swiftRange])
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private static func initialProjectFromProcess(pid: pid_t) -> String? {
        // Check main process and its rsession children via environ.
        var candidates: [pid_t] = [pid]
        if let rsession = RStudioSessionProjects.rsessionPIDForTitleLookup(mainPID: pid) {
            candidates.append(rsession)
        }
        for candidate in candidates {
            if let cPath = HubProcessFindInitialProject(candidate) {
                let path = String(cString: cPath)
                free(cPath)
                if FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    private static func windowTitleViaCGWindow(pid: pid_t) -> String? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let name = info[kCGWindowName as String] as? String else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func mainWindow(in windows: [AXUIElement]) -> AXUIElement? {
        windows.first { window in
            var rawValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXMainAttribute as CFString, &rawValue) == .success else {
                return false
            }
            if let isMain = rawValue as? Bool {
                return isMain
            }
            return (rawValue as? NSNumber)?.boolValue == true
        }
    }

    private static func isStandardWindow(_ window: AXUIElement) -> Bool {
        let role = axString(window, kAXRoleAttribute as CFString) ?? ""
        guard role == kAXWindowRole as String else { return false }

        let subrole = axString(window, kAXSubroleAttribute as CFString) ?? ""
        if subrole.isEmpty {
            return true
        }
        return subrole == kAXStandardWindowSubrole as String
    }

    private static func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &rawValue)
        guard error == .success else { return nil }
        return rawValue as? String
    }
}
