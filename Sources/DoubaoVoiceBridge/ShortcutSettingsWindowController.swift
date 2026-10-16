import AppKit
import ApplicationServices

enum ShortcutRecorderMonitorHandler {
    enum FunctionKeyTransition: Equatable {
        case waitingForRelease
        case accepted
        case rejectedCombination
        case ignored
    }

    struct FunctionKeyState {
        private(set) var isDown = false
        private(set) var hasOtherModifier = false

        mutating func transition(isDown nextIsDown: Bool, hasOtherModifiers: Bool) -> FunctionKeyTransition {
            if nextIsDown {
                isDown = true
                hasOtherModifier = hasOtherModifier || hasOtherModifiers
                return .waitingForRelease
            }
            guard isDown else { return .ignored }
            isDown = false
            let result: FunctionKeyTransition = hasOtherModifier ? .rejectedCombination : .accepted
            hasOtherModifier = false
            return result
        }

        mutating func noteOtherModifierOrKey() {
            if isDown { hasOtherModifier = true }
        }

        mutating func reset() {
            isDown = false
            hasOtherModifier = false
        }
    }

    static func isPhysicalFnTransition(_ event: NSEvent) -> Bool {
        event.type == .flagsChanged && event.keyCode == 63
    }

    static func make(
        windowIsKey: @escaping () -> Bool,
        stop: @escaping () -> Void,
        consume: @escaping (NSEvent) -> NSEvent?
    ) -> (NSEvent) -> NSEvent? {
        { event in
            guard windowIsKey() else {
                stop()
                return event
            }
            return consume(event)
        }
    }
}

enum ShortcutSaveError: Error {
    case message(String)

    var localizedDescription: String {
        switch self {
        case .message(let value): return value
        }
    }
}

struct ShortcutSettingsInitialSelection: Equatable {
    let sourceIndex: Int
    let configuration: DoubaoShortcutConfiguration?

    static func resolve(
        automatic: DoubaoShortcutConfiguration?,
        confirmed: DoubaoShortcutConfiguration?,
        manual: DoubaoShortcutConfiguration?
    ) -> ShortcutSettingsInitialSelection {
        if let manual, manual.mode.isSupported {
            return ShortcutSettingsInitialSelection(sourceIndex: 2, configuration: manual)
        }
        if let automatic, automatic.mode.isSupported {
            return ShortcutSettingsInitialSelection(sourceIndex: 0, configuration: automatic)
        }
        if let confirmed, confirmed.mode.isSupported {
            return ShortcutSettingsInitialSelection(sourceIndex: 1, configuration: confirmed)
        }
        return ShortcutSettingsInitialSelection(sourceIndex: 2, configuration: manual)
    }

    static func bridgeShortcut(
        kind: BridgeShortcutKind,
        doubao: DoubaoShortcutConfiguration?,
        custom: KeyboardShortcut?
    ) -> KeyboardShortcut? {
        switch kind {
        case .followDoubao: return doubao?.keyboardShortcut
        case .leftControlHold: return .leftControl
        case .customHold: return custom
        }
    }
}

final class ShortcutSettingsWindowController: NSWindowController, NSWindowDelegate {
    var onSave: ((DoubaoShortcutConfiguration, DoubaoShortcutMode?, KeyboardShortcut?, BridgeShortcutConfiguration) -> Result<Void, ShortcutSaveError>)?
    var onOpenPermissions: (() -> Void)?
    var onOpenLocalTest: (() -> Void)?
    var onOpenPasteTest: (() -> Void)?

    private let automaticConfiguration: DoubaoShortcutConfiguration?
    private let confirmedConfiguration: DoubaoShortcutConfiguration?
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let doubaoModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let bridgePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let doubaoRecordButton = NSButton(title: "录制豆包按键…", target: nil, action: nil)
    private let bridgeRecordButton = NSButton(title: "录制远控触发键…", target: nil, action: nil)
    private let automaticSummary = NSTextField(wrappingLabelWithString: "")
    private let bridgeSummary = NSTextField(wrappingLabelWithString: "")
    private let permissionsSummary = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "保存并启用", target: nil, action: nil)
    private let pasteDelayLabel = NSTextField(labelWithString: "")
    private let usageHeading = NSTextField(wrappingLabelWithString: "")
    private let usageHint = NSTextField(wrappingLabelWithString: "")
    private let advancedStack = NSStackView()
    private let advancedButton = NSButton(title: "更改按键与高级设置…", target: nil, action: nil)
    private let initialSelection: ShortcutSettingsInitialSelection
    private var initialBridgeKind: BridgeShortcutKind
    private var selectedDoubaoShortcut: KeyboardShortcut
    private var selectedBridgeShortcut: KeyboardShortcut?
    private var recordingTarget: RecordingTarget?
    private var recordingSelectionSnapshot: RecordingSelectionSnapshot?
    private var localEventMonitor: Any?
    private var recordingModifierKeyCodes: Set<UInt16> = []
    private var recordingUsedMultipleModifiers = false
    private var recordingFunctionKeyState = ShortcutRecorderMonitorHandler.FunctionKeyState()
    private var recorderKeyUpsToSwallow: Set<UInt16> = []

    private enum RecordingTarget: Equatable {
        case doubao
        case bridge
    }

    private struct RecordingSelectionSnapshot {
        let sourceIndex: Int
        let doubaoModeIndex: Int
        let bridgeIndex: Int
        let doubaoShortcut: KeyboardShortcut
        let bridgeShortcut: KeyboardShortcut?
    }

    init(
        automaticConfiguration: DoubaoShortcutConfiguration?,
        confirmedConfiguration: DoubaoShortcutConfiguration?,
        manualConfiguration: DoubaoShortcutConfiguration?,
        bridgeConfiguration: BridgeShortcutConfiguration?
    ) {
        self.automaticConfiguration = automaticConfiguration
        self.confirmedConfiguration = confirmedConfiguration
        let initialSelection = ShortcutSettingsInitialSelection.resolve(
            automatic: automaticConfiguration,
            confirmed: confirmedConfiguration,
            manual: manualConfiguration
        )
        self.initialSelection = initialSelection
        self.initialBridgeKind = bridgeConfiguration?.kind ?? .followDoubao
        self.selectedDoubaoShortcut = initialSelection.configuration?.keyboardShortcut ?? .fn
        self.selectedBridgeShortcut = bridgeConfiguration?.shortcut

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "远控听写设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface(in: window)
        refreshFields()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
    }

    func present() {
        guard let window else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func buildInterface(in window: NSWindow) {
        guard let contentView = window.contentView else { return }

        sourcePopup.addItems(withTitles: ["自动读取豆包设置", "使用上次确认的设置", "使用录制的按键"])
        sourcePopup.target = self
        sourcePopup.action = #selector(selectionChanged)
        sourcePopup.selectItem(at: initialSelection.sourceIndex)
        sourcePopup.item(at: 0)?.isEnabled = automaticConfiguration?.mode.isSupported == true
        sourcePopup.item(at: 1)?.isEnabled = confirmedConfiguration?.mode.isSupported == true
        doubaoModePopup.addItems(withTitles: ["长按说话，松开结束", "单击启动，任意键结束"])
        doubaoModePopup.target = self
        doubaoModePopup.action = #selector(selectionChanged)
        doubaoModePopup.selectItem(at: initialSelection.configuration?.mode == .leftControlHold ? 0 : 1)
        doubaoRecordButton.target = self
        doubaoRecordButton.action = #selector(recordDoubaoShortcut)
        bridgeRecordButton.target = self
        bridgeRecordButton.action = #selector(recordBridgeShortcut)
        bridgePopup.addItems(withTitles: [BridgeShortcutKind.followDoubao.title, BridgeShortcutKind.leftControlHold.title, BridgeShortcutKind.customHold.title])
        bridgePopup.target = self
        bridgePopup.action = #selector(selectionChanged)
        bridgePopup.selectItem(at: initialBridgeKind == .leftControlHold ? 1 : initialBridgeKind == .customHold ? 2 : 0)
        saveButton.title = "保存并启用"
        saveButton.target = self
        saveButton.action = #selector(saveConfiguration)
        saveButton.keyEquivalent = "\r"
        advancedButton.target = self
        advancedButton.action = #selector(toggleAdvanced)

        let title = NSTextField(labelWithString: "远控听写")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let heading = NSStackView()
        heading.orientation = .horizontal
        heading.spacing = 12
        if let image = NSImage(named: NSImage.Name("AppIcon")) {
            let icon = NSImageView(image: image)
            icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
            heading.addArrangedSubview(icon)
        }
        heading.addArrangedSubview(title)
        usageHeading.font = .systemFont(ofSize: 22, weight: .semibold)
        usageHint.font = .systemFont(ofSize: 13)
        let boundary = NSTextField(wrappingLabelWithString: "先点选远端输入框。粘贴完成后，自行发送消息。")
        boundary.font = .systemFont(ofSize: 12)
        boundary.textColor = .secondaryLabelColor
        permissionsSummary.font = .systemFont(ofSize: 12)
        permissionsSummary.textColor = .secondaryLabelColor
        let permissionsButton = NSButton(title: "检查权限…", target: self, action: #selector(openPermissions))
        let permissionRow = NSStackView(views: [permissionsSummary, permissionsButton])
        permissionRow.spacing = 12

        let localTestButton = NSButton(title: "测试本机语音识别…", target: self, action: #selector(openLocalTest))
        let pasteTestButton = NSButton(title: "测试远端文字粘贴…", target: self, action: #selector(openPasteTest))
        let tests = NSStackView(views: [localTestButton, pasteTestButton])
        tests.spacing = 12
        let testNote = NSTextField(wrappingLabelWithString: "粘贴测试使用手动文字，不启动录音。按回车只粘贴到远端，Esc 取消。")
        let restore = NSButton(checkboxWithTitle: "粘贴后恢复原剪贴板（同步慢时建议关闭）", target: self, action: #selector(changeClipboardRestore(_:)))
        restore.state = UserDefaults.standard.bool(forKey: "restoreClipboard") ? .on : .off
        let delay = NSSlider(value: UserDefaults.standard.double(forKey: "pasteDelay"),
                             minValue: UURemoteDelivery.minimumPasteDelay, maxValue: UURemoteDelivery.maximumPasteDelay,
                             target: self, action: #selector(changePasteDelay(_:)))
        delay.setAccessibilityLabel("等待 UU 剪贴板同步的秒数")
        delay.widthAnchor.constraint(equalToConstant: 180).isActive = true
        updatePasteDelayLabel(delay.doubleValue)
        let delayRow = NSStackView(views: [NSTextField(labelWithString: "粘贴前等待"), delay, pasteDelayLabel])
        delayRow.spacing = 10
        automaticSummary.font = .systemFont(ofSize: 12)
        automaticSummary.textColor = .secondaryLabelColor
        bridgeSummary.font = .systemFont(ofSize: 12)
        bridgeSummary.textColor = .secondaryLabelColor
        testNote.font = .systemFont(ofSize: 12)
        testNote.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        advancedStack.orientation = .vertical
        advancedStack.alignment = .leading
        advancedStack.spacing = 10
        for view in [makeSectionLabel("远控触发键"), bridgePopup, bridgeRecordButton, bridgeSummary,
                     makeSectionLabel("豆包语音键"), sourcePopup, doubaoRecordButton, doubaoModePopup, automaticSummary,
                     makeSectionLabel("粘贴与测试"), restore, delayRow, tests, testNote, messageLabel] {
            advancedStack.addArrangedSubview(view)
        }
        advancedStack.isHidden = true
        for control in [sourcePopup, doubaoModePopup, bridgePopup] {
            control.widthAnchor.constraint(equalToConstant: 540).isActive = true
        }
        for field in [usageHeading, usageHint, boundary, automaticSummary, bridgeSummary, testNote, messageLabel] {
            field.widthAnchor.constraint(equalToConstant: 540).isActive = true
        }
        let stack = NSStackView(views: [heading, usageHeading, usageHint, boundary, permissionRow, advancedButton, advancedStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.addSubview(stack)
        contentView.addSubview(scroll)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let footerLabel = NSTextField(labelWithString: "版本 \(version) · 关闭窗口后在菜单栏运行")
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(footerLabel)
        contentView.addSubview(saveButton)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -18),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            saveButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            saveButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            footerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            footerLabel.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor)
        ])
    }

    @objc private func toggleAdvanced() {
        let expanding = advancedStack.isHidden
        advancedStack.isHidden = !expanding
        advancedButton.title = expanding ? "收起高级设置" : "更改按键与高级设置…"
        guard let window else { return }
        var frame = window.frame
        let newHeight: CGFloat = expanding ? 760 : 388
        frame.origin.y += frame.height - newHeight
        frame.size.height = newHeight
        window.setFrame(frame, display: true)
    }

    private func makeSectionLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .boldSystemFont(ofSize: 13)
        return field
    }

    @objc private func selectionChanged(_ sender: Any) {
        if let popup = sender as? NSPopUpButton, popup === sourcePopup,
           popup.indexOfSelectedItem != 2,
           let configuration = configurationForSource(popup.indexOfSelectedItem) {
            doubaoModePopup.selectItem(at: configuration.mode == .leftControlHold ? 0 : 1)
        }
        refreshFields()
    }

    private func refreshFields() {
        let manual = sourcePopup.indexOfSelectedItem == 2
        let isRecording = recordingTarget != nil
        sourcePopup.isEnabled = !isRecording
        doubaoModePopup.isEnabled = manual && !isRecording
        doubaoRecordButton.isEnabled = true
        bridgePopup.isEnabled = !isRecording
        bridgeRecordButton.isEnabled = true
        if manual {
            automaticSummary.stringValue = selectedDoubaoMode().map { doubaoSummary(for: $0.0) }
                ?? "请录制豆包实际使用的按键，并在下方选择交互方式。"
        } else {
            switch sourcePopup.indexOfSelectedItem {
            case 0:
                if let automaticConfiguration {
                    automaticSummary.stringValue = doubaoSummary(for: automaticConfiguration)
                } else {
                    automaticSummary.stringValue = "当前没有可确认的自动读取结果；请选择手动配置。"
                }
            case 1:
                if let confirmedConfiguration {
                    automaticSummary.stringValue = doubaoSummary(for: confirmedConfiguration)
                } else {
                    automaticSummary.stringValue = "当前没有上次确认的按键；请选择手动配置。"
                }
            default:
                automaticSummary.stringValue = "当前没有可确认的自动读取结果；请选择手动配置。"
            }
        }
        updateBridgeSummary()

        let accessibilityGranted = AXIsProcessTrusted()
        let inputGranted = CGPreflightListenEventAccess()
        permissionsSummary.stringValue = "辅助功能\(accessibilityGranted ? "已授权" : "未授权") · 输入监控\(inputGranted ? "已授权" : "未授权")"
        let usage = ShortcutUsageCopy.make(doubao: selectedDoubaoMode()?.0, bridge: selectedBridge())
        usageHeading.stringValue = usage.title
        usageHint.stringValue = usage.detail
        messageLabel.stringValue = ""
        updateSaveButtonState()
        updateRecorderTitles()
    }

    private func doubaoSummary(for configuration: DoubaoShortcutConfiguration) -> String {
        let interaction: String
        switch configuration.mode {
        case .fnToggle:
            interaction = "单击开始，任意键结束"
        case .leftControlHold:
            interaction = "按住开始，松开结束"
        case .disabled, .unsupported:
            interaction = configuration.mode.instruction
        }
        return "豆包语音键：\(configuration.keyboardShortcut.displayName)；\(interaction)。本工具听写框就绪后，才会把此键发送给豆包。\(configuration.sourceAndTime)"
    }

    private func updateBridgeSummary() {
        switch selectedBridge().kind {
        case .followDoubao:
            guard let doubao = selectedDoubaoMode()?.0 else {
                bridgeSummary.stringValue = "跟随豆包按键：当前豆包语音键尚未设置。UU 在前台时，此选择会用豆包语音键打开本工具听写框；完成豆包配置后会显示实际按键。"
                return
            }
            let interaction = doubao.mode == .fnToggle ? "单击开始，任意键结束" : "按住开始，松开结束"
            bridgeSummary.stringValue = "远控触发键：\(doubao.keyboardShortcut.displayName)（跟随豆包）。UU 在前台时用它打开本工具听写框；按键和交互方式与豆包语音键共用：\(interaction)。"
        case .leftControlHold:
            bridgeSummary.stringValue = "远控触发键：Left ⌃（独立设置）。UU 在前台时按住它打开本工具听写框，松开结束；豆包语音键单独设置。"
        case .customHold:
            let key = selectedBridgeShortcut?.displayName ?? "未录制"
            bridgeSummary.stringValue = "远控触发键：\(key)（独立设置）。UU 在前台时按住它打开本工具听写框，松开结束；豆包语音键单独设置。"
        }
    }

    private func selectedDoubaoMode() -> (DoubaoShortcutConfiguration, DoubaoShortcutMode?)? {
        if sourcePopup.indexOfSelectedItem == 0 {
            guard let automaticConfiguration, automaticConfiguration.mode.isSupported else { return nil }
            return (automaticConfiguration, automaticConfiguration.shortcut == nil ? nil : automaticConfiguration.mode)
        }
        if sourcePopup.indexOfSelectedItem == 1 {
            guard let confirmedConfiguration, confirmedConfiguration.mode.isSupported else { return nil }
            return (confirmedConfiguration, confirmedConfiguration.shortcut == nil ? nil : confirmedConfiguration.mode)
        }
        let mode: DoubaoShortcutMode = doubaoModePopup.indexOfSelectedItem == 0 ? .leftControlHold : .fnToggle
        return (.manual(mode, shortcut: selectedDoubaoShortcut), mode)
    }

    private func configurationForSource(_ sourceIndex: Int) -> DoubaoShortcutConfiguration? {
        switch sourceIndex {
        case 0: return automaticConfiguration
        case 1: return confirmedConfiguration
        default:
            let mode: DoubaoShortcutMode = doubaoModePopup.indexOfSelectedItem == 0 ? .leftControlHold : .fnToggle
            return .manual(mode, shortcut: selectedDoubaoShortcut)
        }
    }

    private var effectiveDoubaoShortcut: KeyboardShortcut? {
        selectedDoubaoMode()?.0.keyboardShortcut
    }

    private var effectiveBridgeShortcut: KeyboardShortcut? {
        ShortcutSettingsInitialSelection.bridgeShortcut(
            kind: selectedBridge().kind,
            doubao: selectedDoubaoMode()?.0,
            custom: selectedBridgeShortcut
        )
    }

    private func selectedBridge() -> BridgeShortcutConfiguration {
        switch bridgePopup.indexOfSelectedItem {
        case 1: return .leftControlHold
        case 2: return BridgeShortcutConfiguration(kind: .customHold, shortcut: selectedBridgeShortcut)
        default: return .followDoubao
        }
    }

    private func updateSaveButtonState() {
        guard recordingTarget == nil else {
            saveButton.isEnabled = false
            return
        }
        guard let (doubao, _) = selectedDoubaoMode() else {
            saveButton.isEnabled = false
            messageLabel.stringValue = "自动读取当前不可用，请直接录制豆包按键。"
            messageLabel.textColor = .systemRed
            return
        }
        let bridge = selectedBridge()
        let validationError = bridge.validationError(for: doubao)
        saveButton.isEnabled = doubao.mode.isSupported && validationError == nil
        if let validationError {
            messageLabel.stringValue = validationError
            messageLabel.textColor = .systemRed
        } else {
            messageLabel.stringValue = ""
            messageLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func saveConfiguration() {
        guard let (doubao, manualMode) = selectedDoubaoMode() else {
            messageLabel.stringValue = "自动读取当前不可用，请直接录制豆包按键。"
            messageLabel.textColor = .systemRed
            return
        }
        let bridge = selectedBridge()
        guard let validationError = bridge.validationError(for: doubao) else {
            guard let result = onSave?(doubao, manualMode, doubao.shortcut, bridge) else {
                messageLabel.stringValue = "配置未保存，请重试。"
                messageLabel.textColor = .systemRed
                return
            }
            switch result {
            case .success:
                close()
            case .failure(let error):
                messageLabel.stringValue = error.localizedDescription
                messageLabel.textColor = .systemRed
            }
            return
        }
        messageLabel.stringValue = validationError
        messageLabel.textColor = .systemRed
    }

    @objc private func openPermissions() {
        onOpenPermissions?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.refreshFields()
        }
    }

    @objc private func openLocalTest() {
        onOpenLocalTest?()
    }

    @objc private func openPasteTest() { onOpenPasteTest?() }

    @objc private func changeClipboardRestore(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "restoreClipboard")
    }

    @objc private func changePasteDelay(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: "pasteDelay")
        updatePasteDelayLabel(sender.doubleValue)
    }

    private func updatePasteDelayLabel(_ value: Double) {
        pasteDelayLabel.stringValue = String(format: "%.2f 秒", value)
    }

    @objc private func recordDoubaoShortcut() {
        startRecording(.doubao)
    }

    @objc private func recordBridgeShortcut() {
        startRecording(.bridge)
    }

    private func startRecording(_ target: RecordingTarget) {
        if recordingSelectionSnapshot != nil {
            cancelRecordingAndRestore(message: nil)
        } else {
            stopRecording(removeMonitor: true)
        }
        recordingSelectionSnapshot = RecordingSelectionSnapshot(
            sourceIndex: sourcePopup.indexOfSelectedItem,
            doubaoModeIndex: doubaoModePopup.indexOfSelectedItem,
            bridgeIndex: bridgePopup.indexOfSelectedItem,
            doubaoShortcut: selectedDoubaoShortcut,
            bridgeShortcut: selectedBridgeShortcut
        )
        switch target {
        case .doubao:
            if let current = configurationForSource(sourcePopup.indexOfSelectedItem) {
                selectedDoubaoShortcut = current.keyboardShortcut
                doubaoModePopup.selectItem(at: current.mode == .leftControlHold ? 0 : 1)
            }
            sourcePopup.selectItem(at: 2)
        case .bridge:
            selectedBridgeShortcut = effectiveBridgeShortcut
            bridgePopup.selectItem(at: 2)
        }
        recordingTarget = target
        recordingModifierKeyCodes.removeAll()
        recordingUsedMultipleModifiers = false
        recordingFunctionKeyState.reset()
        recorderKeyUpsToSwallow.removeAll()
        refreshFields()
        let title = target == .doubao ? "请按下豆包当前使用的按键…" : "请按住要作为远控触发键的按键…"
        messageLabel.stringValue = "\(title) 按 Esc 取消；组合键请同时按住修饰键和主键。"
        messageLabel.textColor = .secondaryLabelColor
        let handler = ShortcutRecorderMonitorHandler.make(
            windowIsKey: { [weak self] in self?.window?.isKeyWindow == true },
            stop: { [weak self] in
                self?.cancelRecordingAndRestore(message: "设置窗口失去焦点，已停止录制并恢复原配置。")
            },
            consume: { [weak self] event in
                guard let self else { return event }
                return self.consumeRecordingEvent(event)
            }
        )
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged], handler: handler)
        updateRecorderTitles()
    }

    private func stopRecording(removeMonitor: Bool) {
        recordingTarget = nil
        recordingModifierKeyCodes.removeAll()
        recordingUsedMultipleModifiers = false
        recordingFunctionKeyState.reset()
        if removeMonitor, let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
            recorderKeyUpsToSwallow.removeAll()
        }
    }

    private func cancelRecordingAndRestore(message: String?) {
        let snapshot = recordingSelectionSnapshot
        stopRecording(removeMonitor: true)
        guard let snapshot else {
            if let message {
                messageLabel.stringValue = message
                messageLabel.textColor = .secondaryLabelColor
            }
            return
        }
        sourcePopup.selectItem(at: snapshot.sourceIndex)
        doubaoModePopup.selectItem(at: snapshot.doubaoModeIndex)
        bridgePopup.selectItem(at: snapshot.bridgeIndex)
        selectedDoubaoShortcut = snapshot.doubaoShortcut
        selectedBridgeShortcut = snapshot.bridgeShortcut
        recordingSelectionSnapshot = nil
        refreshFields()
        if let message {
            messageLabel.stringValue = message
            messageLabel.textColor = .secondaryLabelColor
        }
    }

    private func consumeRecordingEvent(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyUp, recorderKeyUpsToSwallow.remove(event.keyCode) != nil {
            if recorderKeyUpsToSwallow.isEmpty, recordingTarget == nil { stopRecording(removeMonitor: true) }
            return nil
        }
        if event.type == .flagsChanged, recorderKeyUpsToSwallow.remove(event.keyCode) != nil {
            if recorderKeyUpsToSwallow.isEmpty, recordingTarget == nil { stopRecording(removeMonitor: true) }
            return nil
        }
        guard let target = recordingTarget else {
            return event
        }

        if event.type == .keyDown, event.keyCode == 53 {
            cancelRecordingAndRestore(message: "已取消录制；原有来源与按键保持不变。")
            return nil
        }

        if event.type == .flagsChanged {
            let code = event.keyCode
            let isFunction = ShortcutRecorderMonitorHandler.isPhysicalFnTransition(event)
            if isFunction {
                let otherModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
                let transition = recordingFunctionKeyState.transition(
                    isDown: event.modifierFlags.contains(.function),
                    hasOtherModifiers: !event.modifierFlags.intersection(otherModifiers).isEmpty || !recordingModifierKeyCodes.isEmpty
                )
                switch transition {
                case .waitingForRelease:
                    if recordingFunctionKeyState.hasOtherModifier {
                        messageLabel.stringValue = "Fn 只能单独录制，不能与其他修饰键组合。"
                        messageLabel.textColor = .systemRed
                    }
                    return nil
                case .rejectedCombination:
                    messageLabel.stringValue = "Fn 只能单独录制，不能与其他修饰键组合。"
                    messageLabel.textColor = .systemRed
                    return nil
                case .ignored:
                    return nil
                case .accepted:
                    _ = acceptRecordedShortcut(KeyboardShortcut(keyCode: 63), for: target)
                    if recordingTarget == nil { stopRecording(removeMonitor: true) }
                    return nil
                }
            }
            guard KeyboardShortcut.modifierFlag(for: Int64(code)) != nil else { return event }
            if recordingFunctionKeyState.isDown {
                recordingFunctionKeyState.noteOtherModifierOrKey()
                messageLabel.stringValue = "Fn 只能单独录制，不能与其他修饰键组合。"
                messageLabel.textColor = .systemRed
            }
            if recordingModifierKeyCodes.contains(code) {
                recordingModifierKeyCodes.remove(code)
                if recordingModifierKeyCodes.isEmpty, !recordingUsedMultipleModifiers {
                    _ = acceptRecordedShortcut(KeyboardShortcut(keyCode: code), for: target)
                    if recordingTarget == nil { stopRecording(removeMonitor: true) }
                }
            } else {
                recordingModifierKeyCodes.insert(code)
                if recordingModifierKeyCodes.count > 1 { recordingUsedMultipleModifiers = true }
            }
            return event
        }

        guard event.type == .keyDown else { return event }
        let modifiers = event.modifierFlags
        if recordingFunctionKeyState.isDown {
            recordingFunctionKeyState.noteOtherModifierOrKey()
            messageLabel.stringValue = "Fn 只能单独录制，不能与其他按键组合。"
            messageLabel.textColor = .systemRed
            return nil
        }
        let mask = Self.shortcutModifierMask(from: modifiers)
        let shortcut = KeyboardShortcut(keyCode: event.keyCode, modifierMask: mask)
        recorderKeyUpsToSwallow.insert(event.keyCode)
        _ = acceptRecordedShortcut(shortcut, for: target)
        updateRecorderTitles()
        return nil
    }

    @discardableResult
    private func acceptRecordedShortcut(_ shortcut: KeyboardShortcut, for target: RecordingTarget) -> Bool {
        let error: String?
        switch target {
        case .doubao: error = shortcut.doubaoValidationError
        case .bridge: error = shortcut.validationError
        }
        guard let error else {
            switch target {
            case .doubao: selectedDoubaoShortcut = shortcut
            case .bridge:
                selectedBridgeShortcut = shortcut
                if bridgePopup.indexOfSelectedItem != 2 { bridgePopup.selectItem(at: 2) }
            }
            recordingTarget = nil
            recordingSelectionSnapshot = nil
            refreshFields()
            if target == .doubao,
               let (doubao, _) = selectedDoubaoMode(),
               let followUp = selectedBridge().validationError(for: doubao) {
                messageLabel.stringValue = "已录制：\(shortcut.displayName)。\(followUp)"
                messageLabel.textColor = .systemRed
            } else {
                messageLabel.stringValue = "已录制：\(shortcut.displayName)"
                messageLabel.textColor = .secondaryLabelColor
            }
            return true
        }
        messageLabel.stringValue = error
        messageLabel.textColor = .systemRed
        return false
    }

    private static func shortcutModifierMask(from flags: NSEvent.ModifierFlags) -> UInt64 {
        var mask: UInt64 = 0
        if flags.contains(.control) { mask |= CGEventFlags.maskControl.rawValue }
        if flags.contains(.option) { mask |= CGEventFlags.maskAlternate.rawValue }
        if flags.contains(.shift) { mask |= CGEventFlags.maskShift.rawValue }
        if flags.contains(.command) { mask |= CGEventFlags.maskCommand.rawValue }
        return mask
    }

    private func updateRecorderTitles() {
        doubaoRecordButton.title = recordingTarget == .doubao
            ? "正在录制豆包按键…"
            : "录制豆包按键：\(effectiveDoubaoShortcut?.displayName ?? "未设置")"
        bridgeRecordButton.title = recordingTarget == .bridge
            ? "正在录制远控触发键…"
            : "录制远控触发键：\(effectiveBridgeShortcut?.displayName ?? "未设置")"
    }

    func windowWillClose(_ notification: Notification) {
        cancelRecordingAndRestore(message: nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard recordingSelectionSnapshot != nil else { return }
        cancelRecordingAndRestore(message: "设置窗口失去焦点，已停止录制并恢复原配置。")
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
