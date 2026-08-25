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
    private var dockMouseMonitor: Any?
    private var dockClickMonitorLocal: Any?
    private var dockHoverMonitorLocal: Any?
    private var dockHoverMonitorGlobal: Any?
    private var dockHoverTimer: Timer?
    private var dockMenuMonitorsActive = false
    private var lastDockFileTooltipPath: String?
    private var lastDockFileTooltipAt: TimeInterval = 0
    private var lastDockFileHoverActivityAt: TimeInterval = 0
    private var pendingDockLaunchFocus = false

    var isHubMenuVisible: Bool { menuIsOpen || menuTrackingActive }
    var isDockHoverMenuSuppressed: Bool { isRecordingShortcut }

    func showMenuAfterShortcutRecording() {
        showMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        ActivityLogger.shared.log("hub.launch version=\(version) log=\(ActivityLogger.shared.currentLogURL.path)")
        HubAppPolicy.showInDock()
        HubMenuBarBuilder.install(on: self)
        popupMenu.delegate = self
        dockMenu.delegate = self
        popupMenu.appearance = NSAppearance(named: .aqua)
        dockMenu.autoenablesItems = true
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

        pendingDockLaunchFocus = true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if pendingDockLaunchFocus {
            pendingDockLaunchFocus = false
            DispatchQueue.main.async { [weak self] in
                self?.focusRStudioFromDockClick()
            }
            return
        }

        if !menuIsOpen && !dockMenuMonitorsActive {
            dismissPathTooltipCompletely()
        }
    }

    func applicationWillResignActive(_ notification: Notification) {
        // Hub often resigns when the Dock menu opens — never tear down an active menu session.
        if menuIsOpen || dockMenuMonitorsActive || HubDockMenuBuilder.openDockSubmenuKind != nil {
            return
        }
        dismissPathTooltipCompletely()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        focusRStudioFromDockClick()
        return false
    }

    private func focusRStudioFromDockClick() {
        let instances = RStudioWindowService.instancesFast()
        if instances.isEmpty {
            ActivityLogger.shared.log("hub.dockClick.launchNew")
            if !DockPolicyService.launchNewInstanceHiddenFromDock(activateWhenReady: true) {
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
        menuIsOpen = true
        startDockFileTooltipMonitoring()
        RStudioWindowService.warmTitlesInBackground()
        return dockMenu
    }

    @objc private func launchAtLoginDidChange() {
        guard menuIsOpen, let openMenu, openMenu !== dockMenu else { return }
        rebuildMenu(openMenu)
    }

    func applicationWillTerminate(_ notification: Notification) {
        ActivityLogger.shared.log("hub.terminate")
        dismissPathTooltipCompletely()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === HubDockMenuBuilder.fileSubmenu {
            HubDockMenuBuilder.openDockSubmenuKind = .files
            menuIsOpen = true
            // Dock submenu tracking needs monitors even if main dock menu already opened them.
            startDockFileTooltipMonitoring()
            return
        }
        if menu === HubDockMenuBuilder.projectSubmenu {
            HubDockMenuBuilder.openDockSubmenuKind = .projects
            menuIsOpen = true
            return
        }

        menuIsOpen = true
        openMenu = menu
        if menu === dockMenu {
            applyDockMenuItems(to: menu, RStudioWindowService.instancesFast())
            startDockFileTooltipMonitoring()
            RStudioWindowService.warmTitlesInBackground()
        } else if menu === popupMenu {
            rebuildMenu(menu)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === HubDockMenuBuilder.fileSubmenu || menu === HubDockMenuBuilder.projectSubmenu {
            HubDockMenuBuilder.openDockSubmenuKind = nil
            HubDockMenuBuilder.resetFilesFrameCache()
            clearDockFileTooltip()
            return
        }

        dismissPathTooltipCompletely()
        HubDockMenuBuilder.resetFilesFrameCache()

        if menu !== dockMenu {
            return
        }

        menuIsOpen = false
        if openMenu === menu {
            openMenu = nil
        }

        stopDockFileTooltipMonitoring()
        // Dock delivers menu actions after the menu closes; keep click intent briefly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.finishDockMenuSession()
        }
    }

    private func finishDockMenuSession() {
        HubDockMenuBuilder.openDockSubmenuKind = nil
        stopDockFileTooltipMonitoring()
    }

    private func dismissPathTooltipCompletely() {
        lastDockFileTooltipPath = nil
        lastDockFileTooltipAt = 0
        lastDockFileHoverActivityAt = 0
        HubPathTooltip.tearDown()
        stopDockFileTooltipMonitoring()
    }

    func menuWillHighlight(_ item: NSMenuItem?) {
        // Any non-file highlight (隐藏 / 新建 R / …) must dismiss immediately.
        guard let item,
              item.action == #selector(dockOpenFile(_:)),
              let path = item.representedObject as? String,
              HubDockMenuBuilder.isMouseInsideFilesSubmenu() else {
            clearDockFileTooltip()
            return
        }
        showDockFileTooltip(path)
    }

    private func startDockFileTooltipMonitoring() {
        stopDockFileTooltipMonitoring()
        dockMenuMonitorsActive = true
        lastDockFileTooltipPath = nil
        lastDockFileTooltipAt = 0
        lastDockFileHoverActivityAt = Date.timeIntervalSinceReferenceDate
        HubDockMenuBuilder.resetCloseZoneTracking()

        let trackClick: (NSEvent) -> Void = { _ in
            HubDockMenuBuilder.updateCloseZoneTracking()
        }

        dockClickMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .mouseMoved]) { event in
            trackClick(event)
            return event
        }
        dockMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .mouseMoved]) { event in
            trackClick(event)
        }

        startDockHoverMonitoring()
    }

    private func startDockHoverMonitoring() {
        stopDockHoverMonitoring()

        dockHoverMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited]) { [weak self] event in
            self?.updateDockFileTooltip()
            return event
        }

        dockHoverMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.updateDockFileTooltip()
        }

        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            HubDockMenuBuilder.updateCloseZoneTracking()
            self?.updateDockFileTooltip()
        }
        RunLoop.main.add(timer, forMode: .common)
        dockHoverTimer = timer
    }

    private func updateDockFileTooltip() {
        guard dockMenuMonitorsActive else {
            clearDockFileTooltip()
            return
        }

        // Requires 2 menu windows + cursor inside the files-height list — never the root menu alone.
        guard HubDockMenuBuilder.isMouseInsideFilesSubmenu() else {
            clearDockFileTooltip()
            HubDockMenuBuilder.resetFilesFrameCache()
            return
        }

        if let path = HubDockMenuBuilder.filePathForHover() {
            lastDockFileHoverActivityAt = Date.timeIntervalSinceReferenceDate
            showDockFileTooltip(path)
            return
        }

        if let last = lastDockFileTooltipPath,
           Date.timeIntervalSinceReferenceDate - lastDockFileTooltipAt < 0.12 {
            HubPathTooltip.show(
                HubDockMenuBuilder.displayPath(last),
                toLeftOf: HubDockMenuBuilder.filesSubmenuFrame()
            )
            return
        }

        clearDockFileTooltip()
    }

    private func showDockFileTooltip(_ path: String) {
        guard dockMenuMonitorsActive,
              HubDockMenuBuilder.isMouseInsideFilesSubmenu() else {
            clearDockFileTooltip()
            return
        }
        menuIsOpen = true
        lastDockFileTooltipPath = path
        lastDockFileTooltipAt = Date.timeIntervalSinceReferenceDate
        lastDockFileHoverActivityAt = lastDockFileTooltipAt
        let display = HubDockMenuBuilder.displayPath(path)
        let anchor = HubDockMenuBuilder.filesSubmenuFrame()
        HubPathTooltip.show(display, toLeftOf: anchor)
    }

    private func clearDockFileTooltip() {
        lastDockFileTooltipPath = nil
        lastDockFileTooltipAt = 0
        HubPathTooltip.hide()
    }

    private func stopDockHoverMonitoring() {
        if let dockHoverMonitorLocal {
            NSEvent.removeMonitor(dockHoverMonitorLocal)
            self.dockHoverMonitorLocal = nil
        }
        if let dockHoverMonitorGlobal {
            NSEvent.removeMonitor(dockHoverMonitorGlobal)
            self.dockHoverMonitorGlobal = nil
        }
        dockHoverTimer?.invalidate()
        dockHoverTimer = nil
        clearDockFileTooltip()
    }

    private func stopDockFileTooltipMonitoring() {
        if let dockClickMonitorLocal {
            NSEvent.removeMonitor(dockClickMonitorLocal)
            self.dockClickMonitorLocal = nil
        }
        if let dockMouseMonitor {
            NSEvent.removeMonitor(dockMouseMonitor)
            self.dockMouseMonitor = nil
        }
        HubDockMenuBuilder.resetCloseZoneTracking()
        stopDockHoverMonitoring()
        dockMenuMonitorsActive = false
        HubPathTooltip.tearDown()
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
                let pid = app.processIdentifier
                let delay: TimeInterval = DockPolicyService.isDylibInjected(pid: pid) ? 0.4 : 1.0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if !DockPolicyService.isDylibInjected(pid: pid) {
                        DockPolicyService.onExternalInstanceLaunched(pid: pid)
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
                guard let path = entry.path else { continue }
                let item = NSMenuItem(
                    title: entry.name,
                    action: #selector(dockOpenProject(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = path
                item.toolTip = entry.path ?? entry.name
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
        guard let pidNumber = sender.representedObject as? NSNumber else { return }
        let pid = pid_t(pidNumber.int32Value)

        let shouldClose = HubDockMenuBuilder.consumeCloseZoneClick()
            || NSEvent.modifierFlags.contains(.option)

        if shouldClose {
            ActivityLogger.shared.log("hub.dockClose pid=\(pid)")
            closeInstance(pid: pid)
            return
        }

        ActivityLogger.shared.log("hub.switch pid=\(pid)")
        let instances = RStudioWindowService.instancesFast()
        if let instance = instances.first(where: { $0.pid == pid }) {
            activateInstance(instance)
        } else {
            RStudioWindowService.activate(pid: pid)
        }
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
        ActivityLogger.shared.log("hub.dockClose pid=\(pidNumber.int32Value)")
        closeInstance(pid: pid_t(pidNumber.int32Value))
    }

    @objc func dockOpenFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openFile(at: path)
    }

    @objc func dockCheckForUpdates(_ sender: NSMenuItem) {
        HubUpdateService.checkForUpdates(interactive: true)
    }

    @objc func hubToolsMenuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = RStudioToolsAction(rawValue: raw) else {
            return
        }
        RStudioMenuBridge.performToolsAction(action)
    }

    @objc func dockOpenProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let entry = ProjectHistoryStore.shared.allEntries().first { $0.path == path }
            ?? ProjectHistoryStore.shared.allEntries().first {
                ProjectHistoryStore.shared.resolveOpenPath(for: $0) == path
            }
        guard let entry else { return }
        openProjectInNewWindow(entry)
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
        if !DockPolicyService.openFileInCurrentInstance(at: path) {
            showLaunchError(message: "无法打开文件：\(URL(fileURLWithPath: path).lastPathComponent)")
        }
    }

    private func openProjectInNewWindow(_ entry: ProjectHistoryEntry) {
        guard let path = ProjectHistoryStore.shared.resolveOpenPath(for: entry) else {
            ActivityLogger.shared.log("hub.openProject.new missingPath name=\(entry.name)")
            showLaunchError(message: "找不到项目文件：\(entry.name)\n请先在 RStudio 中打开过该项目。")
            return
        }

        ActivityLogger.shared.log("hub.openProject.new name=\(entry.name) path=\(path)")
        ProjectHistoryStore.shared.record(name: entry.name, path: path)

        if !DockPolicyService.openProjectInNewWindow(at: path) {
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
        openMenu?.cancelTracking()
        if DockPolicyService.launchNewInstanceHiddenFromDock(activateWhenReady: true) {
            refreshMenuForProcessChange()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.refreshMenuForProcessChange()
            }
        } else {
            showLaunchError(message: "请确认 RStudio 已安装在 /Applications/RStudio.app")
        }
    }

    private func createAndOpenNewRproj() {
        if !RStudioMenuBridge.createNewProject() {
            showLaunchError(message: "请确认 RStudio 已安装在 /Applications/RStudio.app")
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
