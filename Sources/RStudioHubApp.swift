import AppKit
import ApplicationServices

final class RStudioHubApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let popupMenu = NSMenu()
    private let dockMenu = NSMenu()
    private var openMenu: NSMenu?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var menuIsOpen = false
    private var menuTrackingActive = false
    private var menuShortcutMonitor: Any?
    private var lastShortcutPressTime: TimeInterval = 0
    private let doublePressInterval: TimeInterval = 0.3
    private var selectedTab: HubMenuTab = .current
    private var isRecordingShortcut = false
    private var dockCloseClickPending = false
    private var dockMouseMonitor: Any?

    func showMenuAfterShortcutRecording() {
        showMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        ActivityLogger.shared.log("hub.launch version=\(version) log=\(ActivityLogger.shared.currentLogURL.path)")
        HubAppPolicy.showInDock()
        popupMenu.delegate = self
        dockMenu.delegate = self
        popupMenu.appearance = NSAppearance(named: .aqua)
        dockMenu.appearance = NSAppearance(named: .aqua)
        RStudioWindowService.restoreFocusedPID()
        LaunchAtLoginSettings.syncOnLaunch()
        setupWorkspaceObservers()
        _ = AccessibilityPermission.ensure(prompt: true)
        RStudioWindowService.warmTitlesInBackground()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            DockPolicyService.hideAllFromDock()
            RStudioWindowService.warmTitlesInBackground()
        }
        GlobalShortcutService.shared.start()
        GlobalShortcutService.shared.onShortcutPress = { [weak self] in
            self?.handleShortcutPress()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(shortcutRecordingDidBegin),
            name: .hubShortcutRecordingDidBegin,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(shortcutRecordingDidEnd),
            name: .hubShortcutRecordingDidEnd,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(launchAtLoginDidChange),
            name: .hubLaunchAtLoginDidChange,
            object: nil
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        focusRStudioFromDockClick()
        return false
    }

    private func focusRStudioFromDockClick() {
        let instances = RStudioWindowService.instancesFast()
        if instances.isEmpty {
            ActivityLogger.shared.log("hub.dockClick.launchNew")
            if !DockPolicyService.launchNewInstanceHiddenFromDock() {
                showLaunchError(message: "请确认 RStudio 已安装在 /Applications/RStudio.app")
            }
            return
        }

        ActivityLogger.shared.log("hub.dockClick.focus")
        // Let Hub finish handling the Dock click, then bring RStudio front.
        // Do not call NSApp.hide — that returns focus to the previous app.
        DispatchQueue.main.async {
            RStudioWindowService.activateActiveInstance()
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        applyDockMenuItems(to: dockMenu, RStudioWindowService.instancesFast())
        startDockCloseClickMonitor()
        // Warm titles after returning so the *next* open has names without delaying this one.
        RStudioWindowService.warmTitlesInBackground()
        return dockMenu
    }

    @objc private func launchAtLoginDidChange() {
        guard menuIsOpen, let openMenu, openMenu !== dockMenu else { return }
        rebuildMenu(openMenu)
    }

    func applicationWillTerminate(_ notification: Notification) {
        ActivityLogger.shared.log("hub.terminate")
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        openMenu = menu
        if menu === dockMenu {
            applyDockMenuItems(to: menu, RStudioWindowService.instancesFast())
            startDockCloseClickMonitor()
            RStudioWindowService.warmTitlesInBackground()
        } else {
            rebuildMenu(menu)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if openMenu === menu {
            openMenu = nil
        }
        if menu === dockMenu {
            // Keep the last close-zone hit briefly; Dock sends the action after the menu closes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.stopDockCloseClickMonitor()
            }
        }
    }

    private func startDockCloseClickMonitor() {
        stopDockCloseClickMonitor()
        dockCloseClickPending = false
        dockMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return }
            let inCloseZone = HubDockMenuBuilder.isCloseClick(event: event)
            if event.type == .leftMouseDown {
                self.dockCloseClickPending = inCloseZone
            } else if event.type == .leftMouseUp, inCloseZone {
                self.dockCloseClickPending = true
            }
        }
    }

    private func stopDockCloseClickMonitor() {
        if let dockMouseMonitor {
            NSEvent.removeMonitor(dockMouseMonitor)
            self.dockMouseMonitor = nil
        }
    }

    func beginShortcutRecording(reopenMenu: Bool) {
        ShortcutRecordingController.begin(reopenMenu: reopenMenu, anchor: nil)
    }

    private func handleShortcutPress() {
        let now = Date.timeIntervalSinceReferenceDate
        let isDoublePress = (now - lastShortcutPressTime) < doublePressInterval
        lastShortcutPressTime = now

        if isDoublePress {
            if menuTrackingActive {
                openMenu?.cancelTracking()
            }
            DispatchQueue.main.async {
                RStudioWindowService.activateActiveInstance()
            }
            return
        }

        if menuTrackingActive {
            openMenu?.cancelTracking()
            return
        }

        showMenu()
    }

    private func showMenu() {
        guard !menuTrackingActive else { return }
        rebuildMenu(popupMenu)

        menuTrackingActive = true
        menuIsOpen = true
        GlobalShortcutService.shared.pauseHotKey()
        installMenuShortcutMonitor()

        popupMenu.popUp(positioning: nil, at: popupMenuLocation(), in: nil)

        removeMenuShortcutMonitor()
        GlobalShortcutService.shared.resumeHotKey()
        menuTrackingActive = false
        menuIsOpen = false
    }

    private func popupMenuLocation() -> NSPoint {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            return NSPoint(x: frame.midX, y: frame.minY + 8)
        }
        return NSEvent.mouseLocation
    }

    private func installMenuShortcutMonitor() {
        let shortcut = ShortcutStore.resolvedShortcut(for: .openMenu)
        menuShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.menuTrackingActive else { return event }
            if event.isARepeat { return event }
            if shortcut.matches(event) {
                self.handleShortcutPress()
                return nil
            }
            return event
        }
    }

    private func removeMenuShortcutMonitor() {
        if let menuShortcutMonitor {
            NSEvent.removeMonitor(menuShortcutMonitor)
            self.menuShortcutMonitor = nil
        }
    }

    @objc private func shortcutRecordingDidBegin() {
        isRecordingShortcut = true
    }

    @objc private func shortcutRecordingDidEnd() {
        isRecordingShortcut = false
    }

    private func setupWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == RStudioDiscovery.bundleIdentifier else { return }
                ActivityLogger.shared.log("rstudio.launch pid=\(app.processIdentifier)")
                DockPolicyService.handleRStudioLaunch(pid: app.processIdentifier)
                self?.refreshMenuForProcessChange()
                RStudioWindowService.warmTitlesInBackground()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if !DockPolicyService.isDylibInjected(pid: app.processIdentifier) {
                        DockPolicyService.onExternalInstanceLaunched(pid: app.processIdentifier)
                    }
                    self?.reloadMenuInstances()
                    RStudioWindowService.warmTitlesInBackground()
                }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                ActivityLogger.shared.log("rstudio.terminate pid=\(app?.processIdentifier ?? -1)")
                if let pid = app?.processIdentifier {
                    DockPolicyService.noteProcessTerminated(pid: pid)
                }
                self?.refreshMenuForProcessChange()
                self?.reloadMenuInstances()
            },
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                if app.bundleIdentifier == RStudioDiscovery.bundleIdentifier, !app.isTerminated, app.isActive {
                    ActivityLogger.shared.log("rstudio.activate pid=\(app.processIdentifier)")
                    RStudioWindowService.noteFocused(pid: app.processIdentifier)
                } else {
                    ActivityLogger.shared.log("app.activate name=\(app.localizedName ?? "?") pid=\(app.processIdentifier)")
                    DockPolicyService.reinforceHideFromDock()
                }
            },
        ]
    }

    private func selectTab(_ tab: HubMenuTab) {
        selectedTab = tab
        if let openMenu {
            rebuildMenu(openMenu)
        }
    }

    private func rebuildMenu(_ menu: NSMenu) {
        applyMenuItems(to: menu, RStudioWindowService.instancesForMenu())
    }

    /// Immediately update the open menu when process count changes.
    private func refreshMenuForProcessChange() {
        RStudioWindowService.invalidateCache()
        guard menuIsOpen, let openMenu else { return }
        applyMenuItems(to: openMenu, RStudioWindowService.instancesFast())
    }

    /// Refresh instance list when an RStudio process is created or removed.
    private func reloadMenuInstances() {
        RStudioWindowService.invalidateCache()
        RStudioWindowService.refreshInstances { [weak self] instances in
            guard let self else { return }
            for instance in instances {
                ProjectHistoryStore.shared.record(from: instance)
            }
            if self.menuIsOpen, let openMenu = self.openMenu {
                self.applyMenuItems(to: openMenu, instances)
            }
        }
    }

    private func applyDockMenuItems(to menu: NSMenu, _ instances: [RStudioInstance]) {
        menu.removeAllItems()
        for item in HubDockMenuBuilder.makeItems(instances: instances, app: self) {
            menu.addItem(item)
        }
    }

    private func applyMenuItems(to menu: NSMenu, _ instances: [RStudioInstance]) {
        menu.removeAllItems()
        for item in buildMenuItems(from: instances) {
            menu.addItem(item)
        }
    }

    private func buildMenuItems(from instances: [RStudioInstance]) -> [NSMenuItem] {
        MenuRowHoverView.applyWidth(selectedTab: selectedTab, instances: instances)
        var items: [NSMenuItem] = []

        let tabItem = NSMenuItem()
        tabItem.view = MenuTabBarView(selectedTab: selectedTab) { [weak self] tab in
            self?.selectTab(tab)
        }
        items.append(tabItem)

        items.append(.separator())

        switch selectedTab {
        case .current:
            items.append(contentsOf: buildCurrentTabItems(from: instances))
        case .project:
            items.append(contentsOf: buildProjectTabItems())
        }

        items.append(.separator())

        if selectedTab == .current {
            let actionsItem = NSMenuItem()
            actionsItem.view = ActionButtonsView(
                onNewR: { [weak self] in
                    self?.launchNewRStudio()
                },
                onNewRproj: { [weak self] in
                    self?.createAndOpenNewRproj()
                },
                onQuitAllR: { [weak self] in
                    self?.quitAllRStudio()
                },
                onQuitHub: {
                    NSApp.terminate(nil)
                },
                quitAllEnabled: !instances.isEmpty
            )
            items.append(actionsItem)

            let shortcutItem = NSMenuItem()
            shortcutItem.view = ShortcutSettingsRowView()
            items.append(shortcutItem)
        }

        return items
    }

    private func buildCurrentTabItems(from instances: [RStudioInstance]) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let hasPermission = AccessibilityPermission.isGranted

        if !hasPermission {
            let permissionItem = NSMenuItem(
                title: "⚠ 需要辅助功能权限",
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            )
            permissionItem.target = self
            items.append(permissionItem)
            items.append(.separator())
        }

        if instances.isEmpty {
            let emptyItem = NSMenuItem(title: "没有打开的 RStudio", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            items.append(emptyItem)
        } else {
            for instance in instances {
                let item = NSMenuItem()
                item.view = InstanceMenuRowView(
                    instance: instance,
                    onActivate: { [weak self] inst in
                        self?.activateInstance(inst)
                    },
                    onClose: { [weak self] pid in
                        self?.closeInstance(pid: pid)
                    }
                )
                items.append(item)
            }
        }

        return items
    }

    private func buildProjectTabItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let projects = ProjectHistoryStore.shared.allEntries()

        if projects.isEmpty {
            let emptyItem = NSMenuItem(title: "没有历史项目", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            items.append(emptyItem)
        } else {
            for entry in projects {
                let item = NSMenuItem()
                item.view = ProjectMenuRowView(entry: entry) { [weak self] project in
                    self?.openProject(project)
                }
                items.append(item)
            }
        }

        return items
    }

    func hubActivateInstance(_ instance: RStudioInstance) {
        activateInstance(instance)
    }

    func hubCloseInstance(pid: pid_t) {
        closeInstance(pid: pid)
    }

    @objc func openAccessibilitySettings() {
        AccessibilityPermission.openSettings()
    }

    @objc func dockInstanceRowAction(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? DockInstanceRowRef else { return }
        // Prefer the flag captured while the Dock menu was still open.
        // Avoid re-scanning CG windows here — that was adding noticeable lag.
        let shouldClose = dockCloseClickPending
        dockCloseClickPending = false

        if shouldClose {
            ActivityLogger.shared.log("hub.dockClose pid=\(ref.pid)")
            hubCloseInstance(pid: ref.pid)
            return
        }

        ActivityLogger.shared.log("hub.switch pid=\(ref.pid)")
        RStudioWindowService.activate(pid: ref.pid)
    }

    @objc func dockActivateInstance(_ sender: NSMenuItem) {
        guard let pidNumber = sender.representedObject as? NSNumber else { return }
        let pid = pid_t(pidNumber.int32Value)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let instances = RStudioWindowService.instancesFast()
            guard let instance = instances.first(where: { $0.pid == pid }) else { return }
            self.activateInstance(instance)
        }
    }

    @objc func dockCloseInstance(_ sender: NSMenuItem) {
        guard let pidNumber = sender.representedObject as? NSNumber else { return }
        closeInstance(pid: pid_t(pidNumber.int32Value))
    }

    @objc func dockOpenFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openFile(at: path)
    }

    @objc func dockCheckForUpdates(_ sender: NSMenuItem) {
        HubUpdateService.checkForUpdates(interactive: true)
    }

    @objc func dockOpenRStudioSettings(_ sender: NSMenuItem) {
        RStudioWindowService.openPreferences()
    }

    @objc func dockOpenProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let entry = ProjectHistoryStore.shared.allEntries().first { $0.path == path }
            ?? ProjectHistoryStore.shared.allEntries().first {
                ProjectHistoryStore.shared.resolveOpenPath(for: $0) == path
            }
        guard let entry else { return }
        openProject(entry)
    }

    @objc func dockCreateNewRproj() {
        createAndOpenNewRproj()
    }

    @objc func dockRecordShortcut() {
        beginShortcutRecording(reopenMenu: false)
    }

    @objc func dockToggleLaunchAtLogin(_ sender: NSMenuItem) {
        let next = !LaunchAtLoginSettings.isEnabled
        _ = LaunchAtLoginSettings.setEnabled(next)
        sender.state = LaunchAtLoginSettings.isEnabled ? .on : .off
    }

    private func activateInstance(_ instance: RStudioInstance) {
        ActivityLogger.shared.log("hub.switch pid=\(instance.pid) title=\(instance.menuTitle)")
        ProjectHistoryStore.shared.record(from: instance)
        RStudioWindowService.activate(instance)
    }

    private func closeInstance(pid: pid_t) {
        ActivityLogger.shared.log("hub.quit pid=\(pid)")
        RStudioDiscovery.quit(pid: pid)
        RStudioWindowService.removeCachedInstance(pid: pid)
        refreshMenuForProcessChange()
    }

    private func openFile(at path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            ActivityLogger.shared.log("hub.openFile missingPath path=\(path)")
            showLaunchError(message: "找不到文件：\(URL(fileURLWithPath: path).lastPathComponent)")
            return
        }

        ActivityLogger.shared.log("hub.openFile path=\(path)")
        let fileURL = URL(fileURLWithPath: path)
        let appURL = URL(fileURLWithPath: RStudioDiscovery.appPath)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: config) { _, error in
            if let error {
                DispatchQueue.main.async { [weak self] in
                    self?.showLaunchError(message: "无法打开文件：\(error.localizedDescription)")
                }
            }
        }
    }

    private func openProject(_ entry: ProjectHistoryEntry) {
        guard let path = ProjectHistoryStore.shared.resolveOpenPath(for: entry) else {
            ActivityLogger.shared.log("hub.openProject missingPath name=\(entry.name)")
            showLaunchError(message: "找不到项目文件：\(entry.name)\n请先在 RStudio 中打开过该项目。")
            return
        }

        ActivityLogger.shared.log("hub.openProject name=\(entry.name) path=\(path)")
        ProjectHistoryStore.shared.record(name: entry.name, path: path)

        if !DockPolicyService.launchProjectHiddenFromDock(at: path) {
            showLaunchError(message: "无法打开项目：\(entry.name)")
        }
    }

    private func showLaunchError(message: String) {
        let alert = NSAlert()
        alert.messageText = "打开失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc func launchNewRStudio() {
        if DockPolicyService.launchNewInstanceHiddenFromDock() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.refreshMenuForProcessChange()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.reloadMenuInstances()
            }
        } else {
            showLaunchError(message: "请确认 RStudio 已安装在 /Applications/RStudio.app")
        }
    }

    private func createAndOpenNewRproj() {
        let panel = NSSavePanel()
        panel.title = "新建 R 项目"
        panel.prompt = "创建"
        panel.nameFieldStringValue = "NewProject.Rproj"
        panel.allowedFileTypes = ["Rproj"]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        var projectURL = url
        if projectURL.pathExtension.lowercased() != "rproj" {
            projectURL = projectURL.appendingPathExtension("Rproj")
        }

        let projectBody = "Version: 1.0\n"
        do {
            try projectBody.write(to: projectURL, atomically: true, encoding: .utf8)
        } catch {
            showLaunchError(message: "无法创建项目文件：\(error.localizedDescription)")
            return
        }

        let path = projectURL.path
        let name = projectURL.deletingPathExtension().lastPathComponent
        ProjectHistoryStore.shared.record(name: name, path: path)

        if !DockPolicyService.launchProjectHiddenFromDock(at: path) {
            showLaunchError(message: "无法打开新建的项目")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.reloadMenuInstances()
        }
    }

    @objc func quitAllRStudio() {
        ActivityLogger.shared.log("hub.quitAllRStudio")
        let pids = RStudioDiscovery.runningApplications().map(\.processIdentifier)
        RStudioDiscovery.quitAll()
        for pid in pids {
            RStudioWindowService.removeCachedInstance(pid: pid)
        }
        RStudioWindowService.clearCachedInstances()
        // Optimistic UI: clear the open menu immediately.
        if menuIsOpen, let openMenu {
            applyMenuItems(to: openMenu, [])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if !RStudioDiscovery.runningApplications().isEmpty {
                RStudioDiscovery.forceQuitAll()
            }
            self?.refreshMenuForProcessChange()
            self?.reloadMenuInstances()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.reloadMenuInstances()
        }
    }
}
