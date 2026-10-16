import AppKit
import os.log

final class SessionCoordinator {
    enum State: Equatable {
        case idle
        case listening
        case finalizing
        case delivering
        case failed
    }

    var onStatusChange: ((String, Bool) -> Void)?
    var onUserCancelRequested: ((ComposerInputEventMetadata) -> Void)?
    var readyStatusProvider: (() -> String?)?

    private let panel = ComposerPanelController()
    private let delivery = UURemoteDelivery()
    private(set) var state: State = .idle
    private var target: UURemoteTarget?
    private var deliveryAwaitingCleanup = false
    private var cancellationCleanupPending = false
    private var activeShortcutProfile: ShortcutProfile?
    private var sessionShortcutProfile: ShortcutProfile?
    private var localFnDictationActive = false
    private let logger = Logger(subsystem: "com.lyp.DoubaoVoiceBridge", category: "session")

    var canBegin: Bool {
        (state == .idle || state == .failed) &&
            !deliveryAwaitingCleanup &&
            !cancellationCleanupPending
    }

    var isLocalComposerReady: Bool {
        state == .listening && panel.isReadyForLocalDictation
    }

    var fnTriggerGateDiagnostic: String {
        "coordinatorState=\(String(describing: state)) canBegin=\(canBegin) deliveryAwaitingCleanup=\(deliveryAwaitingCleanup) cancellationCleanupPending=\(cancellationCleanupPending) configurationMode=\(activeShortcutProfile?.doubao.mode.diagnosticName ?? "none") bridge=\(activeShortcutProfile?.bridge.display ?? "none")"
    }

    init() {
        panel.onCommit = { [weak self] text in self?.send(text: text) }
        panel.onCancel = { [weak self] metadata in
            guard let self else { return }
            if let onUserCancelRequested = self.onUserCancelRequested {
                onUserCancelRequested(metadata)
            } else {
                self.cancel()
            }
        }
        panel.onControlReleased = { [weak self] in self?.controlReleased() }
        panel.onTranscriptTimeout = { [weak self] in self?.handleTranscriptTimeout() }
    }

    func updateShortcutProfile(_ profile: ShortcutProfile?) {
        activeShortcutProfile = profile
    }

    static func shouldObserveControlRelease(manualEntry: Bool, profile: ShortcutProfile) -> Bool {
        manualEntry && profile.doubao.mode == .leftControlHold &&
            profile.doubao.keyboardShortcut == .leftControl
    }

    func begin(target: UURemoteTarget, profile: ShortcutProfile, manualEntry: Bool = false) {
        guard (state == .idle || state == .failed),
              !deliveryAwaitingCleanup,
              !cancellationCleanupPending else {
            onStatusChange?("正在恢复剪贴板，请稍候…", false)
            return
        }
        self.target = target
        sessionShortcutProfile = profile
        localFnDictationActive = false
        state = .listening
        let instruction = "\(profile.bridgeInstruction)；识别完成后自动粘贴"
        panel.begin(
            targetDescription: "粘贴到 UU 远控输入框",
            shortcutInstruction: instruction,
            observesControlRelease: Self.shouldObserveControlRelease(manualEntry: manualEntry, profile: profile)
        )
        onStatusChange?("正在听写…\(instruction)", false)
    }

    func controlReleased() {
        guard state == .listening else { return }
        localFnDictationActive = false
        state = .finalizing
        panel.waitForFinalTranscript()
        onStatusChange?("正在完成识别…", false)
    }

    func beginPasteTest(target: UURemoteTarget) {
        guard canBegin else { return }
        self.target = target
        sessionShortcutProfile = nil
        localFnDictationActive = false
        state = .listening
        panel.begin(
            targetDescription: "测试粘贴到 UU 远控的当前输入框",
            shortcutInstruction: "输入测试文字后按回车仅粘贴 · 不启动录音 · Esc 取消",
            observesControlRelease: false,
            startsDictation: false
        )
        onStatusChange?("输入测试文字，按回车粘贴到 UU；不会发送远端消息", false)
    }

    func cancel() {
        guard state != .idle, state != .delivering else { return }
        let frontmostBeforeCancel = NSWorkspace.shared.frontmostApplication
        let shouldStopLocalFnDictation = localFnDictationActive && sessionShortcutProfile?.doubao.mode == .fnToggle
        localFnDictationActive = false
        let localStopSucceeded = !shouldStopLocalFnDictation || panel.stopFnToggleDictationForCancellation()
        if shouldStopLocalFnDictation && !localStopSucceeded {
            logger.error("Unable to safely send a stop key to the local Fn-toggle composer during cancellation")
        }
        let target = self.target
        self.target = nil
        sessionShortcutProfile = nil
        state = .idle
        let status: (String, Bool)?
        if shouldStopLocalFnDictation && !localStopSucceeded {
            status = ("已取消；无法确认豆包语音已停止，请检查本机识别状态", true)
        } else if shouldStopLocalFnDictation {
            status = ("已取消；已向本机豆包听写框发送停止键", false)
        } else if let readyStatus = readyStatusProvider?() {
            status = (readyStatus, false)
        } else {
            status = ("已取消", false)
        }

        if shouldStopLocalFnDictation && localStopSucceeded {
            cancellationCleanupPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
                guard let self else { return }
                self.cancellationCleanupPending = false
                self.panel.hide()
                self.restoreFocusIfBridgeStillOwnsIt(
                    frontmostBeforeCancel: frontmostBeforeCancel,
                    target: target
                )
                if let status { self.onStatusChange?(status.0, status.1) }
            }
            return
        }

        panel.hide()
        restoreFocusIfBridgeStillOwnsIt(
            frontmostBeforeCancel: frontmostBeforeCancel,
            target: target
        )
        if let status { onStatusChange?(status.0, status.1) }
    }

    private func restoreFocusIfBridgeStillOwnsIt(
        frontmostBeforeCancel: NSRunningApplication?,
        target: UURemoteTarget?
    ) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            return
        }

        if let frontmostBeforeCancel,
           frontmostBeforeCancel.bundleIdentifier != Bundle.main.bundleIdentifier,
           !frontmostBeforeCancel.isTerminated {
            frontmostBeforeCancel.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        } else {
            target?.activateOriginalWindow()
        }
    }

    func markLocalFnToggleMayBeActive() {
        guard state == .listening, sessionShortcutProfile?.doubao.mode == .fnToggle else { return }
        localFnDictationActive = true
    }

    func prepareForTermination() {
        ClipboardKeyboardPaster.finishPendingEventsBeforeTermination()
        delivery.restoreClipboardForTermination()
    }

    private func send(text: String) {
        guard state == .listening || state == .finalizing || state == .failed,
              let target else { return }
        state = .delivering
        deliveryAwaitingCleanup = true
        panel.showSending()
        onStatusChange?("正在同步并自动粘贴…", false)

        delivery.deliver(
            text: text,
            to: target,
            panelWillHide: { [weak self] in self?.panel.hide() },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.target = nil
                    self.onStatusChange?("已向 UU 远控发送自动粘贴指令", false)
                case .failure(let error):
                    self.deliveryAwaitingCleanup = false
                    self.state = .failed
                    let message = error.localizedDescription
                    self.panel.showError("\(message)。文字仍保留，可按回车重试")
                    self.onStatusChange?(message, true)
                }
            },
            cleanupCompletion: { [weak self] in
                guard let self else { return }
                self.deliveryAwaitingCleanup = false
                if self.state == .delivering {
                    self.state = .idle
                    self.sessionShortcutProfile = nil
                    if let readyStatus = self.readyStatusProvider?() {
                        self.onStatusChange?(readyStatus, false)
                    }
                }
            }
        )
    }

    private func handleTranscriptTimeout() {
        state = .failed
        if panel.currentText().isEmpty {
            panel.showError("没有识别到文字。按 Esc 返回 UU 后可重试")
            onStatusChange?("没有识别到文字，请重试", true)
        } else {
            panel.showError("豆包语音输入法尚未完成识别，确认文字后按回车发送，或按 Esc 取消")
            onStatusChange?("识别超时，等待手动确认", true)
        }
    }

}
