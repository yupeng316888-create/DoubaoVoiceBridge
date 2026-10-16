import AppKit
import ApplicationServices
import notify
import os.log

enum LatencyDefaultsMigration {
    static let legacyPasteDelay: TimeInterval = 0.9

    static func replacementPasteDelay(for storedValue: Any?) -> TimeInterval? {
        guard let storedValue else { return UURemoteDelivery.defaultPasteDelay }

        let numericValue: Double?
        if let number = storedValue as? NSNumber {
            numericValue = number.doubleValue
        } else if let string = storedValue as? String {
            numericValue = Double(string)
        } else {
            numericValue = nil
        }

        guard let numericValue,
              abs(numericValue - legacyPasteDelay) < 0.000_1 else {
            return nil
        }
        return UURemoteDelivery.defaultPasteDelay
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let uuRemoteBundleIdentifier = "com.netease.uuremote"
    private static let latencyDefaultsMigrationKey = "didMigrateLatencyDefaultsV23"

    private let logger = Logger(subsystem: "com.lyp.DoubaoVoiceBridge", category: "app")
    private let coordinator = SessionCoordinator()
    private let shortcutStore = ShortcutConfigurationStore()
    private var monitor: ControlHoldMonitor?
    private var shortcutConfiguration: DoubaoShortcutConfiguration?
    private var bridgeShortcutConfiguration: BridgeShortcutConfiguration = .followDoubao
    private var shortcutProfile: ShortcutProfile?
    private var settingsWindowController: ShortcutSettingsWindowController?
    private var setupPending = false
    private var statusItem: NSStatusItem?
    private var statusText = "正在启动…"
    private var statusIsError = false
    private var permissionRetryTimer: Timer?
    private var shortcutRefreshTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var observedUURemotePID: pid_t?
    private var eventTapNotificationTokens: [Int32] = []
    private var tapOrderAuditWorkItem: DispatchWorkItem?
    private var tapOrderAuditTimer: Timer?
    private var tapReinstallTimes: [Date] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "pasteDelay": UURemoteDelivery.defaultPasteDelay,
            // UU has no delivery acknowledgement. Keep the transcript until
            // the user chooses to replace it, unless restoration is opted in.
            "restoreClipboard": false,
            "autoPasteUU": true,
            "controlHoldThreshold": 0.18
        ])
        UserDefaults.standard.set(true, forKey: "autoPasteUU")
        migrateLatencyDefaultsIfNeeded()

        configureStatusItem()
        refreshResolvedProfile()
        coordinator.updateShortcutProfile(shortcutProfile)
        coordinator.onStatusChange = { [weak self] text, isError in
            self?.setStatus(text, isError: isError)
        }

        let monitor = ControlHoldMonitor(
            profile: shortcutProfile,
            holdThreshold: UserDefaults.standard.double(forKey: "controlHoldThreshold"),
            targetProvider: { [weak self] in
                guard let self, self.coordinator.canBegin else { return nil }
                return self.currentUURemoteTarget()
            },
            targetProviderDiagnostic: { [weak self] in
                guard let self else { return "frontmostBundle=unavailable frontmostPID=-1 coordinator=unavailable" }
                let frontmost = NSWorkspace.shared.frontmostApplication
                let frontmostBundle = frontmost?.bundleIdentifier ?? "none"
                let frontmostPID = frontmost?.processIdentifier ?? -1
                return "frontmostBundle=\(frontmostBundle) frontmostPID=\(frontmostPID) \(self.coordinator.fnTriggerGateDiagnostic)"
            },
            targetIsActive: { target in
                guard let frontmost = NSWorkspace.shared.frontmostApplication,
                      !frontmost.isTerminated else { return false }
                return frontmost.processIdentifier == target.processIdentifier ||
                    frontmost.bundleIdentifier == Bundle.main.bundleIdentifier
            },
            localComposerReady: { [weak self] in
                self?.coordinator.isLocalComposerReady ?? false
            },
            onBegin: { [weak self] target, profile in
                self?.coordinator.begin(target: target, profile: profile)
            },
            onFnToggleMayBeActive: { [weak self] in
                self?.coordinator.markLocalFnToggleMayBeActive()
            },
            onRelease: { [weak self] in self?.coordinator.controlReleased() },
            onCancel: { [weak self] in self?.coordinator.cancel() },
            onTriggerUnavailable: { [weak self] message in
                DispatchQueue.main.async { self?.setStatus(message, isError: true) }
            }
        )
        self.monitor = monitor
        coordinator.readyStatusProvider = { [weak self] in
            guard let self else { return nil }
            return ShortcutTriggerReadiness.status(
                profile: self.shortcutProfile,
                setupPending: self.setupPending,
                monitorActive: self.monitor?.activeTapLocation != nil,
                accessibilityTrusted: AXIsProcessTrusted()
            )
        }
        coordinator.onUserCancelRequested = { [weak self] metadata in
            guard let self else { return }
            if let monitor = self.monitor {
                monitor.cancelActiveSession(event: metadata)
            } else {
                self.coordinator.cancel()
            }
        }
        observeUURemoteLifecycle()
        observeEventTapChanges()
        shortcutRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshDoubaoShortcut()
        }
        setupPending = !shortcutStore.didCompleteSetup || shortcutStore.hasCorruptOrIncompleteSavedConfiguration
        if setupPending {
            setStatus("首次配置：确认豆包按键与远控触发键", isError: false)
            showShortcutSettings()
            return
        }
        if shortcutProfile?.isSupported != true {
            setupPending = true
            setStatus("快捷键配置缺失或不受支持，请重新确认", isError: true)
            showShortcutSettings()
            return
        }
        startMonitorOrRequestPermissions(promptIfNeeded: false)
        if shortcutConfiguration == nil {
            setStatus("使用上次确认的豆包按键；打开设置可重新确认", isError: false)
        }
        showShortcutSettings()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showShortcutSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        coordinator.prepareForTermination()
        permissionRetryTimer?.invalidate()
        shortcutRefreshTimer?.invalidate()
        tapOrderAuditWorkItem?.cancel()
        tapOrderAuditTimer?.invalidate()
        for token in eventTapNotificationTokens {
            notify_cancel(token)
        }
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "mic.and.signal.meter", accessibilityDescription: "远控听写")
            button.toolTip = "远控听写 · 点击查看设置与状态"
            button.setAccessibilityLabel("远控听写：设置与状态")
        }
        statusItem = item
        rebuildMenu()
    }

    private func migrateLatencyDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.latencyDefaultsMigrationKey) else { return }

        // Preserve deliberate custom settings. Only migrate the exact value
        // shipped by v2.2 to the faster, measured default.
        if let replacement = LatencyDefaultsMigration.replacementPasteDelay(
            for: defaults.object(forKey: "pasteDelay")
        ) {
            defaults.set(replacement, forKey: "pasteDelay")
        }
        defaults.set(true, forKey: Self.latencyDefaultsMigrationKey)
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusText = text
        statusIsError = isError
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let displayStatus: String
        if !statusIsError, statusText.hasPrefix("就绪"), let profile = shortcutProfile {
            displayStatus = "就绪 · " + ShortcutUsageCopy.make(doubao: profile.doubao, bridge: profile.bridge).title
        } else { displayStatus = statusText }
        let status = NSMenuItem(title: displayStatus, action: nil, keyEquivalent: "")
        status.isEnabled = false
        if statusIsError {
            status.attributedTitle = NSAttributedString(
                string: statusText,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
        }
        menu.addItem(status)

        menu.addItem(.separator())
        let setup = NSMenuItem(title: "打开设置…", action: #selector(openShortcutSettingsFromMenu), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
        let more = NSMenuItem(title: "更多", action: nil, keyEquivalent: "")
        let details = NSMenu()
        for line in shortcutProfile?.statusMenuLines ?? ["尚未配置语音按键"] {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            details.addItem(item)
        }
        details.addItem(.separator())
        for (title, action) in [
            ("读取豆包快捷键", #selector(readDoubaoShortcut)),
            ("打开豆包设置…", #selector(openDoubaoSettings)),
            ("检查权限…", #selector(openPermissions))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            details.addItem(item)
        }
        let manual = NSMenuItem(title: "手动打开听写框", action: #selector(openComposerManually), keyEquivalent: "")
        manual.target = self
        manual.isEnabled = shortcutProfile?.supportsManualComposerEntry == true
        details.addItem(manual)
        more.submenu = details
        menu.addItem(more)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出远控听写", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
    }

    private func currentUURemoteTarget() -> UURemoteTarget? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier == Self.uuRemoteBundleIdentifier,
              !frontmost.isTerminated else {
            return nil
        }
        return UURemoteTarget(application: frontmost)
    }

    @objc private func openComposerManually() {
        guard let shortcutProfile, shortcutProfile.isSupported else {
            setStatus("尚未完成豆包与远控快捷键配置", isError: true)
            return
        }
        guard shortcutProfile.supportsManualComposerEntry else {
            setStatus("Fn 免按模式请使用已配置的触发键打开听写框", isError: true)
            return
        }
        guard let target = currentUURemoteTarget() else {
            setStatus("请先点回 UU 远控，再使用豆包快捷键", isError: true)
            return
        }
        guard target.captureFocusedWindow() else {
            setStatus("无法安全读取 UU 当前窗口；请检查辅助功能权限并确认 UU 窗口可访问", isError: true)
            return
        }
        coordinator.begin(target: target, profile: shortcutProfile, manualEntry: true)
    }

    @objc private func openShortcutSettingsFromMenu() {
        showShortcutSettings()
    }

    @objc private func readDoubaoShortcut() {
        refreshDoubaoShortcut(forceStatus: true)
        if setupPending {
            showShortcutSettings()
        }
    }

    private func showShortcutSettings() {
        guard coordinator.canBegin, monitor?.isGestureIdle != false else {
            setStatus("请先结束当前听写，再打开快捷键设置", isError: true)
            return
        }
        if let settingsWindowController, settingsWindowController.window?.isVisible == true {
            settingsWindowController.present()
            return
        }
        let automatic = DoubaoShortcutSettingsReader.discover()
        let controller = ShortcutSettingsWindowController(
            automaticConfiguration: automatic,
            confirmedConfiguration: DoubaoShortcutSettingsReader.hasVisibleSettingsWindow()
                ? nil
                : shortcutStore.loadLastConfirmedDoubaoConfiguration(),
            manualConfiguration: shortcutStore.loadManualDoubaoConfiguration(),
            bridgeConfiguration: shortcutStore.loadBridgeConfiguration()
        )
        controller.onOpenPermissions = { [weak self] in
            self?.requestRequiredPermissions(forceOpenSettings: true)
        }
        controller.onOpenLocalTest = { [weak self] in
            self?.openTextEditForLocalTest()
        }
        controller.onSave = { [weak self] selectedConfiguration, manualMode, manualShortcut, bridge in
            guard let self else { return .failure(.message("应用已关闭，请重新打开设置。")) }
            guard self.coordinator.canBegin, self.monitor?.isGestureIdle != false else {
                self.setStatus("请先完成当前听写，再保存快捷键设置", isError: true)
                return .failure(.message("当前听写尚未结束；结束后再保存配置。"))
            }
            let saved = self.shortcutStore.save(
                confirmedDoubaoMode: selectedConfiguration.mode,
                manualDoubaoMode: manualMode,
                manualDoubaoShortcut: manualShortcut,
                confirmedDoubaoShortcut: selectedConfiguration.shortcut,
                bridge: bridge
            )
            guard saved else {
                return .failure(.message("配置写入后回读校验失败；请重试。"))
            }
            self.shortcutConfiguration = selectedConfiguration
            self.bridgeShortcutConfiguration = bridge
            self.shortcutProfile = ShortcutProfile(doubao: selectedConfiguration, bridge: bridge)
            self.setupPending = false
            self.monitor?.updateProfile(self.shortcutProfile)
            self.coordinator.updateShortcutProfile(self.shortcutProfile)
            self.settingsWindowController = nil
            self.startMonitorOrRequestPermissions(promptIfNeeded: false)
            if self.monitor?.activeTapLocation == nil {
                self.setStatus("配置已保存；开启所需权限后才能监听快捷键", isError: true)
            }
            return .success(())
        }
        controller.onOpenPasteTest = { [weak self] in self?.openPasteTest() }
        settingsWindowController = controller
        controller.present()
    }

    private func openPasteTest() {
        guard coordinator.canBegin else {
            setStatus("请先完成或取消当前听写，再测试粘贴", isError: true)
            return
        }
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == Self.uuRemoteBundleIdentifier && !$0.isTerminated
              }) else {
            setStatus("请先打开 UU 并确认辅助功能权限", isError: true)
            return
        }
        let target = UURemoteTarget(application: app)
        guard target.captureFocusedWindow() else {
            setStatus("无法确认 UU 目标窗口；请先点选远端输入框", isError: true)
            return
        }
        settingsWindowController?.window?.orderOut(nil)
        coordinator.beginPasteTest(target: target)
    }

    private func openTextEditForLocalTest() {
        let textEditPath = "/System/Applications/TextEdit.app"
        guard FileManager.default.fileExists(atPath: textEditPath) else {
            setStatus("未找到 TextEdit；请使用任意本机空白文本框测试豆包识别", isError: true)
            return
        }
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: textEditPath),
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.setStatus("无法打开 TextEdit：\(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    @objc private func openDoubaoSettings() {
        guard FileManager.default.fileExists(atPath: DoubaoShortcutSettingsReader.settingsApplicationPath.path) else {
            setStatus("未找到已安装的豆包设置应用", isError: true)
            return
        }
        NSWorkspace.shared.openApplication(
            at: DoubaoShortcutSettingsReader.settingsApplicationPath,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let error {
                    self?.setStatus("无法打开豆包设置：\(error.localizedDescription)", isError: true)
                } else {
                    self?.refreshDoubaoShortcut(forceStatus: true)
                    if self?.setupPending == true {
                        self?.showShortcutSettings()
                    }
                }
            }
        }
    }

    @objc private func openPermissions() {
        requestRequiredPermissions(forceOpenSettings: true)
    }

    private func requestRequiredPermissions(forceOpenSettings: Bool = false) {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        let inputGranted = CGRequestListenEventAccess()

        if forceOpenSettings || !accessibilityGranted {
            openSystemSettings(anchor: "Privacy_Accessibility")
        } else if !inputGranted {
            openSystemSettings(anchor: "Privacy_ListenEvent")
        }
    }

    private func startMonitorOrRequestPermissions(promptIfNeeded: Bool) {
        guard let monitor else { return }
        guard !setupPending, let profile = shortcutProfile, profile.isSupported else {
            setStatus("尚未完成豆包与远控快捷键配置", isError: true)
            return
        }
        if monitor.activeTapLocation == nil {
            do {
                try monitor.start()
            } catch {
                logger.error("Unable to start control monitor: \(error.localizedDescription, privacy: .public)")
                setStatus("快捷键已识别；需要开启辅助功能与输入监控权限", isError: true)
                if promptIfNeeded {
                    requestRequiredPermissions()
                }
                schedulePermissionRetryIfNeeded()
                return
            }
        }
        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
        guard AXIsProcessTrusted() else {
            let message = "快捷键监听已启动；需要辅助功能权限才能安全读取 UU 窗口并打开听写框"
            if statusText != message { setStatus(message, isError: true) }
            schedulePermissionRetryIfNeeded()
            return
        }
        if let readyStatus = ShortcutTriggerReadiness.status(
            profile: profile,
            setupPending: setupPending,
            monitorActive: monitor.activeTapLocation != nil,
            accessibilityTrusted: AXIsProcessTrusted()
        ) {
            setStatus(readyStatus, isError: false)
        }
    }

    private func schedulePermissionRetryIfNeeded() {
        guard permissionRetryTimer == nil else { return }
        permissionRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.startMonitorOrRequestPermissions(promptIfNeeded: false)
        }
    }

    private func observeUURemoteLifecycle() {
        observedUURemotePID = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == Self.uuRemoteBundleIdentifier
        }?.processIdentifier

        let center = NSWorkspace.shared.notificationCenter
        let focusObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundleIdentifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            self?.monitor?.cancelIfFocusLost(activatedBundleIdentifier: bundleIdentifier)
        }
        workspaceObservers.append(focusObserver)
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self,
                      let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.bundleIdentifier == Self.uuRemoteBundleIdentifier else { return }
                let pid = application.processIdentifier
                let delay = UURemoteActivationAudit.delay(
                    previousPID: self.observedUURemotePID,
                    activatedPID: pid
                )
                self.observedUURemotePID = pid
                self.scheduleTapOrderAudit(after: delay)
            }
            workspaceObservers.append(observer)
        }
    }

    private func refreshDoubaoShortcut(forceStatus: Bool = false) {
        guard monitor?.isGestureIdle != false, coordinator.canBegin else { return }
        let oldProfile = shortcutProfile
        refreshResolvedProfile()
        coordinator.updateShortcutProfile(shortcutProfile)
        guard !hasSameShortcutBehavior(shortcutProfile, oldProfile) else {
            if forceStatus {
                setStatus(shortcutProfile?.doubao.sourceAndTime ?? "没有可确认的豆包快捷键配置", isError: shortcutProfile == nil)
            }
            return
        }

        monitor?.updateProfile(shortcutProfile)
        if shortcutProfile?.isSupported == true, !setupPending {
            startMonitorOrRequestPermissions(promptIfNeeded: false)
        } else if shortcutProfile == nil {
            monitor?.stop()
            permissionRetryTimer?.invalidate()
            permissionRetryTimer = nil
            setStatus("没有可确认的豆包快捷键；请打开设置并手动选择", isError: true)
        }
    }

    private func refreshResolvedProfile() {
        let automatic = DoubaoShortcutSettingsReader.discover()
        let manual = shortcutStore.loadManualDoubaoConfiguration()
        if manual == nil, let automatic, automatic.mode.isSupported {
            shortcutStore.updateConfirmedModeFromAutomaticRead(automatic.mode)
        }
        let fallback = DoubaoShortcutSettingsReader.hasVisibleSettingsWindow()
            ? nil
            : shortcutStore.loadLastConfirmedDoubaoConfiguration()
        shortcutConfiguration = manual ?? automatic ?? fallback
        bridgeShortcutConfiguration = shortcutStore.loadBridgeConfiguration() ?? .followDoubao
        if let shortcutConfiguration {
            let profile = ShortcutProfile(doubao: shortcutConfiguration, bridge: bridgeShortcutConfiguration)
            shortcutProfile = profile.isSupported ? profile : nil
        } else {
            shortcutProfile = nil
        }
    }

    private func hasSameShortcutBehavior(
        _ first: ShortcutProfile?,
        _ second: ShortcutProfile?
    ) -> Bool {
        ShortcutProfile.hasSameTriggerBehavior(first, second)
    }

    private func observeEventTapChanges() {
        for name in [
            "com.apple.coregraphics.eventTapAdded",
            "com.apple.coregraphics.eventTapRemoved"
        ] {
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, .main) { [weak self] _ in
                self?.scheduleTapOrderAudit(after: 0.08)
            }
            if status == NOTIFY_STATUS_OK {
                eventTapNotificationTokens.append(token)
            } else {
                logger.error("Unable to observe event-tap changes (status=\(status, privacy: .public))")
            }
        }

        tapOrderAuditTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.auditTapOrder()
        }
    }

    private func scheduleTapOrderAudit(after delay: TimeInterval) {
        tapOrderAuditWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.auditTapOrder() }
        tapOrderAuditWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func auditTapOrder() {
        guard let monitor, monitor.activeTapLocation != nil, monitor.isGestureIdle,
              let uuRemote = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == Self.uuRemoteBundleIdentifier && !$0.isTerminated
              }) else { return }

        let taps = Self.installedEventTaps()
        let bridgePID = ProcessInfo.processInfo.processIdentifier
        guard UURemoteTapOrder.needsReinstall(
            taps: taps,
            bridgePID: bridgePID,
            uuRemotePID: uuRemote.processIdentifier
        ) else { return }

        let now = Date()
        tapReinstallTimes.removeAll { now.timeIntervalSince($0) > 5.0 }
        guard tapReinstallTimes.count < 3 else {
            logger.error("Tap-order contention detected; deferring to the low-frequency audit")
            return
        }
        tapReinstallTimes.append(now)
        logger.notice("UU keyboard tap moved ahead; reinstalling local head tap")
        monitor.stop()
        startMonitorOrRequestPermissions(promptIfNeeded: false)
    }

    private static func installedEventTaps() -> [InstalledEventTap] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else { return [] }
        let capacity = max(count + 8, 32)
        let buffer = UnsafeMutablePointer<CGEventTapInformation>.allocate(capacity: Int(capacity))
        defer { buffer.deallocate() }

        var filled = capacity
        guard CGGetEventTapList(capacity, buffer, &filled) == .success else { return [] }
        return (0..<Int(filled)).map { InstalledEventTap(buffer[$0]) }
    }

    private func openSystemSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}

struct InstalledEventTap: Equatable {
    let processIdentifier: pid_t
    let location: UInt32
    let options: UInt32
    let eventMask: CGEventMask
    let isEnabled: Bool

    init(
        processIdentifier: pid_t,
        location: UInt32,
        options: UInt32,
        eventMask: CGEventMask,
        isEnabled: Bool
    ) {
        self.processIdentifier = processIdentifier
        self.location = location
        self.options = options
        self.eventMask = eventMask
        self.isEnabled = isEnabled
    }

    init(_ information: CGEventTapInformation) {
        self.init(
            processIdentifier: information.tappingProcess,
            location: information.tapPoint.rawValue,
            options: information.options.rawValue,
            eventMask: information.eventsOfInterest,
            isEnabled: information.enabled
        )
    }
}

enum UURemoteTapOrder {
    private static let keyboardMask: CGEventMask = [
        CGEventType.keyDown,
        CGEventType.keyUp,
        CGEventType.flagsChanged
    ].reduce(CGEventMask(0)) {
        $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
    }

    static func needsReinstall(
        taps: [InstalledEventTap],
        bridgePID: pid_t,
        uuRemotePID: pid_t
    ) -> Bool {
        let relevant = taps.enumerated().filter { _, tap in
            tap.isEnabled &&
                tap.location == CGEventTapLocation.cghidEventTap.rawValue &&
                tap.options == CGEventTapOptions.defaultTap.rawValue &&
                (tap.eventMask & keyboardMask) != 0
        }
        guard let uuIndex = relevant.first(where: { $0.element.processIdentifier == uuRemotePID })?.offset else {
            return false
        }
        guard let bridgeIndex = relevant.first(where: { $0.element.processIdentifier == bridgePID })?.offset else {
            return true
        }
        return uuIndex < bridgeIndex
    }
}

enum UURemoteActivationAudit {
    static func delay(previousPID: pid_t?, activatedPID: pid_t) -> TimeInterval {
        previousPID == activatedPID ? 0.25 : 0.8
    }
}
