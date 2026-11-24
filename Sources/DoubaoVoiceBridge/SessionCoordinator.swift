import AppKit

final class SessionCoordinator {
    enum State: Equatable {
        case idle
        case listening
        case finalizing
        case delivering
        case failed
    }

    var onStatusChange: ((String, Bool) -> Void)?
    var onListeningEnded: (() -> Void)?
    var physicalHoldOwnsRelease: (() -> Bool)?

    private lazy var panel = makePanel()
    private let delivery = UURemoteDelivery()
    private(set) var state: State = .idle {
        didSet {
            // A panel release, Return, or Esc can finish listening even if the
            // global keyboard tap never received the physical Control release.
            if oldValue == .listening && state != .listening { onListeningEnded?() }
        }
    }
    private var target: UURemoteTarget?
    private var deliveryAwaitingCleanup = false

    var canBegin: Bool {
        (state == .idle || state == .failed) && !deliveryAwaitingCleanup
    }

    var isLocalComposerReady: Bool {
        state == .listening && panel.isReadyForLocalDictation
    }

    var canRestartInEmptyComposer: Bool { isLocalComposerReady && !panel.hasInput }

    private func makePanel() -> ComposerPanelController {
        let panel = ComposerPanelController()
        panel.onCommit = { [weak self] text in self?.send(text: text) }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onControlReleased = { [weak self] in
            guard let self, self.physicalHoldOwnsRelease?() != true else { return }
            self.controlReleased()
        }
        panel.onTranscriptTimeout = { [weak self] in self?.handleTranscriptTimeout() }
        return panel
    }

    func begin(target: UURemoteTarget) {
        guard (state == .idle || state == .failed), !deliveryAwaitingCleanup else {
            onStatusChange?("正在恢复剪贴板，请稍候…", false)
            return
        }
        self.target = target
        state = .listening
        panel.begin(targetDescription: "发送到 Mac mini · UU 远控")
        onStatusChange?("正在听写…松开左 ⌃ 自动发送", false)
    }

    func controlReleased() {
        guard state == .listening else { return }
        state = .finalizing
        panel.waitForFinalTranscript()
        onStatusChange?("正在完成识别…", false)
    }

    func cancel(restoreTargetFocus: Bool = true) {
        guard state != .idle, state != .delivering else { return }
        let target = self.target
        self.target = nil
        state = .idle
        panel.hide()
        if restoreTargetFocus { target?.activateOriginalWindow() }
        onStatusChange?("就绪 · 在 UU 远控中长按左 ⌃", false)
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
                    self.onStatusChange?("已向 Mac mini 发送自动粘贴指令", false)
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
                    self.onStatusChange?("就绪 · 在 UU 远控中长按左 ⌃", false)
                }
            }
        )
    }

    private func handleTranscriptTimeout() {
        guard state == .finalizing else { return }
        if !panel.hasInput {
            let restoreFocus = NSApp.isActive && panel.window?.isKeyWindow == true
                && target?.stillMatchesFocusedWindow() == true
            panel.retireEmptySession()
            cancel(restoreTargetFocus: restoreFocus)
            panel = makePanel()
            onStatusChange?("本次没有识别到文字，可在 UU 中重新长按左 ⌃", true)
            return
        }
        state = .failed
        panel.showError("豆包语音输入法尚未完成识别，确认文字后按回车发送，或按 Esc 取消")
        onStatusChange?("识别超时，等待手动确认", true)
    }
}
