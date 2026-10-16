import AppKit
import ApplicationServices
import os.log

struct ComposerInputEventMetadata {
    let type: UInt
    let keyCode: UInt16
    let flags: UInt
    let sourcePID: Int64

    var flagsHex: String { String(flags, radix: 16) }

    init(event: NSEvent) {
        type = event.type.rawValue
        keyCode = event.keyCode
        flags = event.modifierFlags.rawValue
        sourcePID = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
    }
}

final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ComposerTextView: NSTextView {
    private let logger = Logger(subsystem: "com.lyp.DoubaoVoiceBridge", category: "composer")
    var onCommit: (() -> Void)?
    var onCancel: ((ComposerInputEventMetadata) -> Void)?
    var onControlReleased: (() -> Void)?
    var observesControlRelease = false

    override func keyDown(with event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == ControlHoldMonitor.syntheticEventMarker {
            // The input method sees the posted event before it reaches this
            // local responder. Do not send the synthetic voice shortcut into
            // NSTextView's editing commands or text insertion path: a later
            // rollback could erase text committed by an input method inline.
            return
        }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        if isReturn,
           event.modifierFlags.intersection(disallowedModifiers).isEmpty,
           !hasMarkedText() {
            onCommit?()
            return
        }
        if event.keyCode == 53 {
            let metadata = ComposerInputEventMetadata(event: event)
            logger.notice("Composer cancellation requested type=\(metadata.type, privacy: .public) keyCode=\(metadata.keyCode, privacy: .public) flags=0x\(metadata.flagsHex, privacy: .public) sourcePID=\(metadata.sourcePID, privacy: .public)")
            onCancel?(metadata)
            return
        }
        super.keyDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let isSynthetic = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == ControlHoldMonitor.syntheticEventMarker
        guard !isSynthetic else { return }
        super.flagsChanged(with: event)
        if observesControlRelease, event.keyCode == 59, !event.modifierFlags.contains(.control) {
            onControlReleased?()
        }
    }
}

enum ComposerTextLayout {
    static func attach(_ textView: NSTextView, to scrollView: NSScrollView) {
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        scrollView.documentView = textView
    }

    static func synchronize(_ textView: NSTextView, with scrollView: NSScrollView) {
        scrollView.layoutSubtreeIfNeeded()
        let contentSize = scrollView.contentSize
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        var frame = textView.frame
        frame.size.width = contentSize.width
        frame.size.height = max(frame.height, contentSize.height)
        textView.frame = frame
    }
}

enum TranscriptSettlePolicy {
    static let minimumElapsedAfterRelease: TimeInterval = 0.45
    static let requiredStableDuration: TimeInterval = 0.35
    static let pollingInterval: TimeInterval = 0.05

    static func isReady(
        textIsEmpty: Bool,
        hasMarkedText: Bool,
        elapsedAfterRelease: TimeInterval,
        stableFor: TimeInterval
    ) -> Bool {
        !textIsEmpty &&
            !hasMarkedText &&
            elapsedAfterRelease >= minimumElapsedAfterRelease &&
            stableFor >= requiredStableDuration
    }
}

final class ComposerPanelController: NSWindowController, NSTextViewDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: ((ComposerInputEventMetadata) -> Void)?
    var onControlReleased: (() -> Void)?
    var onTranscriptTimeout: (() -> Void)?

    private let textView = ComposerTextView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let targetLabel = NSTextField(labelWithString: "")
    private let logger = Logger(subsystem: "com.lyp.DoubaoVoiceBridge", category: "composer")
    private var settleWorkItem: DispatchWorkItem?
    private var settleStartedAt: Date?
    private var lastTextChangeAt = Date()
    private var sessionID = UUID()
    private var lastLoggedLength = -1
    private var lastLoggedMarkedState = false
    private var isWaitingForFinalTranscript = false
    private var acceptsTranscriptUpdates = false
    private var shortcutInstruction = ""

    init() {
        let panel = DictationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 570, height: 176),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "远控听写"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97)
        super.init(window: panel)
        buildInterface(in: panel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func begin(
        targetDescription: String,
        shortcutInstruction: String,
        observesControlRelease: Bool,
        startsDictation: Bool = true
    ) {
        sessionID = UUID()
        cancelSettleTimer()
        textView.string = ""
        lastLoggedLength = -1
        lastLoggedMarkedState = false
        isWaitingForFinalTranscript = false
        acceptsTranscriptUpdates = true
        self.shortcutInstruction = shortcutInstruction
        textView.observesControlRelease = observesControlRelease
        textView.isEditable = true
        lastTextChangeAt = Date()
        targetLabel.stringValue = targetDescription
        statusLabel.stringValue = startsDictation ? "正在启动豆包语音输入法…\(shortcutInstruction)" : shortcutInstruction
        statusLabel.textColor = .secondaryLabelColor

        guard let window else { return }
        position(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        ComposerTextLayout.synchronize(textView, with: scrollView)
        window.makeFirstResponder(textView)
        logger.notice(
            "Composer ready session=\(self.shortSessionID, privacy: .public) appActive=\(NSApp.isActive, privacy: .public) windowVisible=\(window.isVisible, privacy: .public) windowKey=\(window.isKeyWindow, privacy: .public) firstResponderIsTextView=\(window.firstResponder === self.textView, privacy: .public) textWidth=\(self.textView.frame.width, privacy: .public) containerWidth=\(self.textView.textContainer?.containerSize.width ?? 0, privacy: .public)"
        )
    }

    func waitForFinalTranscript() {
        isWaitingForFinalTranscript = true
        statusLabel.stringValue = "正在等待豆包语音输入法完成识别…"
        statusLabel.textColor = .secondaryLabelColor
        settleStartedAt = Date()
        lastTextChangeAt = Date()
        scheduleSettleCheck(for: sessionID)
    }

    func showSending() {
        isWaitingForFinalTranscript = false
        acceptsTranscriptUpdates = false
        cancelSettleTimer()
        statusLabel.stringValue = "正在将文字粘贴到 UU 远控…"
        statusLabel.textColor = .secondaryLabelColor
        textView.isEditable = false
        window?.makeFirstResponder(nil)
    }

    func showError(_ message: String) {
        isWaitingForFinalTranscript = false
        acceptsTranscriptUpdates = true
        cancelSettleTimer()
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        textView.isEditable = true
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    func hide() {
        isWaitingForFinalTranscript = false
        acceptsTranscriptUpdates = false
        cancelSettleTimer()
        window?.orderOut(nil)
    }

    func currentText() -> String {
        textView.string
    }

    var isReadyForLocalDictation: Bool {
        guard let window else { return false }
        return NSApp.isActive &&
            window.isKeyWindow &&
            window.firstResponder === textView &&
            textView.frame.width > 0 &&
            (textView.textContainer?.containerSize.width ?? 0) > 0
    }

    @discardableResult
    func stopFnToggleDictationForCancellation() -> Bool {
        guard let window, window.isVisible else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        guard window.makeFirstResponder(textView), isReadyForLocalDictation,
              let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 105, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 105, keyDown: false) else {
            return false
        }
        keyDown.setIntegerValueField(.eventSourceUserData, value: ControlHoldMonitor.syntheticEventMarker)
        keyUp.setIntegerValueField(.eventSourceUserData, value: ControlHoldMonitor.syntheticEventMarker)
        keyDown.flags = []
        keyUp.flags = []
        let processID = ProcessInfo.processInfo.processIdentifier
        keyDown.postToPid(processID)
        keyUp.postToPid(processID)
        return true
    }

    func textDidChange(_ notification: Notification) {
        lastTextChangeAt = Date()
        let length = textView.string.utf16.count
        let marked = textView.hasMarkedText()
        if length != lastLoggedLength || marked != lastLoggedMarkedState {
            lastLoggedLength = length
            lastLoggedMarkedState = marked
            let bucket = PrivacySafeTextMetrics.lengthBucket(length)
            logger.notice(
                "Transcript updated session=\(self.shortSessionID, privacy: .public) lengthBucket=\(bucket, privacy: .public) marked=\(marked, privacy: .public) textWidth=\(self.textView.frame.width, privacy: .public)"
            )
        }
        if length > 0, acceptsTranscriptUpdates {
            if isWaitingForFinalTranscript {
                statusLabel.stringValue = marked
                    ? "豆包语音输入法正在完成识别…"
                    : "已收到文字，正在准备粘贴…"
            } else {
                statusLabel.stringValue = marked
                    ? "豆包语音输入法正在识别…\(shortcutInstruction)"
                    : "已收到文字，\(shortcutInstruction)"
            }
        }
    }

    private func buildInterface(in panel: NSPanel) {
        guard let content = panel.contentView else { return }

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "语音输入")
        icon.contentTintColor = .systemBlue
        icon.translatesAutoresizingMaskIntoConstraints = false

        targetLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        targetLabel.textColor = .labelColor
        targetLabel.lineBreakMode = .byTruncatingMiddle
        targetLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        textView.delegate = self
        textView.font = .systemFont(ofSize: 18)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.onCommit = { [weak self] in self?.commitCurrentText() }
        textView.onCancel = { [weak self] metadata in self?.onCancel?(metadata) }
        textView.onControlReleased = { [weak self] in self?.onControlReleased?() }

        ComposerTextLayout.attach(textView, to: scrollView)
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(icon)
        content.addSubview(targetLabel)
        content.addSubview(statusLabel)
        content.addSubview(scrollView)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            icon.widthAnchor.constraint(equalToConstant: 27),
            icon.heightAnchor.constraint(equalToConstant: 27),

            targetLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            targetLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            targetLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 17),

            statusLabel.leadingAnchor.constraint(equalTo: targetLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: targetLabel.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: targetLabel.bottomAnchor, constant: 2),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
    }

    private func position(_ window: NSWindow) {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            window.center()
            return
        }
        let frame = window.frame
        let origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.minY + 54
        )
        window.setFrameOrigin(origin)
    }

    private func commitCurrentText() {
        let text = textView.string
        guard !text.isEmpty else {
            showError("没有识别到文字，请继续说话或按 Esc 取消")
            return
        }
        onCommit?(text)
    }

    private func scheduleSettleCheck(for expectedSessionID: UUID) {
        settleWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.checkWhetherTranscriptSettled(expectedSessionID: expectedSessionID)
        }
        settleWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + TranscriptSettlePolicy.pollingInterval,
            execute: workItem
        )
    }

    private func checkWhetherTranscriptSettled(expectedSessionID: UUID) {
        guard expectedSessionID == sessionID,
              let startedAt = settleStartedAt else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(startedAt)
        let stableFor = now.timeIntervalSince(lastTextChangeAt)
        let text = textView.string

        if TranscriptSettlePolicy.isReady(
            textIsEmpty: text.isEmpty,
            hasMarkedText: textView.hasMarkedText(),
            elapsedAfterRelease: elapsed,
            stableFor: stableFor
        ) {
            let bucket = PrivacySafeTextMetrics.lengthBucket(text.utf16.count)
            logger.notice(
                "Transcript settled session=\(self.shortSessionID, privacy: .public) lengthBucket=\(bucket, privacy: .public) elapsed=\(elapsed, privacy: .public)"
            )
            onCommit?(text)
            return
        }

        if elapsed >= 8.0 {
            if !text.isEmpty,
               !textView.hasMarkedText(),
               stableFor >= TranscriptSettlePolicy.requiredStableDuration {
                let bucket = PrivacySafeTextMetrics.lengthBucket(text.utf16.count)
                logger.notice(
                    "Transcript settled at deadline session=\(self.shortSessionID, privacy: .public) lengthBucket=\(bucket, privacy: .public)"
                )
                onCommit?(text)
            } else {
                let bucket = PrivacySafeTextMetrics.lengthBucket(text.utf16.count)
                logger.error(
                    "Transcript timeout session=\(self.shortSessionID, privacy: .public) lengthBucket=\(bucket, privacy: .public) marked=\(self.textView.hasMarkedText(), privacy: .public)"
                )
                onTranscriptTimeout?()
            }
            return
        }
        scheduleSettleCheck(for: expectedSessionID)
    }

    private func cancelSettleTimer() {
        settleWorkItem?.cancel()
        settleWorkItem = nil
        settleStartedAt = nil
    }

    private var shortSessionID: String {
        String(sessionID.uuidString.prefix(8))
    }
}
