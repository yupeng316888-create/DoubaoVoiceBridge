import AppKit
import ApplicationServices
import os.log

enum DeliveryError: LocalizedError, Equatable {
    case emptyText, accessibilityMissing, targetAppMissing, pasteboardUnavailable
    case targetChanged, originalWindowUnavailable, focusTimedOut
    case clipboardChanged, clipboardTimedOut, keyboardEventFailed, modifierKeysActive, deliveryBusy

    var errorDescription: String? {
        switch self {
        case .emptyText: return "没有可发送的文字"
        case .accessibilityMissing: return "尚未开启辅助功能权限"
        case .targetAppMissing: return "UU 远控已经关闭"
        case .pasteboardUnavailable: return "无法写入系统剪贴板"
        case .targetChanged: return "已切换到其他应用或窗口，已取消自动粘贴"
        case .originalWindowUnavailable: return "没有记录到原来的 UU 窗口，请返回远控窗口后重试"
        case .focusTimedOut: return "UU 原窗口未能及时就绪，已保留文字"
        case .clipboardChanged: return "剪贴板内容或格式在同步期间发生变化，已取消自动粘贴"
        case .clipboardTimedOut: return "剪贴板同步未能及时稳定，已保留文字"
        case .keyboardEventFailed: return "无法发送 Command-V"
        case .modifierKeysActive: return "请先松开 Fn、Command、Shift、Option 或 Control 键"
        case .deliveryBusy: return "正在完成上一条输入，请稍候"
        }
    }
}

final class UURemoteDelivery {
    static let defaultPasteDelay: TimeInterval = 0.50
    static let minimumPasteDelay: TimeInterval = 0.45
    static let maximumPasteDelay: TimeInterval = 3.0

    private let clipboard = OneShotClipboard()
    private let logger = Logger(subsystem: "com.example.DoubaoVoiceBridge.Fn", category: "delivery")
    private var pipeline: DeliveryPipeline?

    func deliver(
        text: String,
        to target: UURemoteTarget,
        panelWillHide: @escaping () -> Void,
        completion: @escaping (Result<Void, Error>) -> Void,
        cleanupCompletion: @escaping () -> Void
    ) {
        precondition(Thread.isMainThread)
        guard pipeline == nil else { completion(.failure(DeliveryError.deliveryBusy)); return }
        guard !text.isEmpty else { completion(.failure(DeliveryError.emptyText)); return }
        guard AXIsProcessTrusted() else { completion(.failure(DeliveryError.accessibilityMissing)); return }
        guard !target.isTerminated else { completion(.failure(DeliveryError.targetAppMissing)); return }

        let configuredDelay = UserDefaults.standard.double(forKey: "pasteDelay")
        let syncDelay = min(max(configuredDelay, Self.minimumPasteDelay), Self.maximumPasteDelay)
        let startedAt = ProcessInfo.processInfo.systemUptime
        var lastFocus: DeliveryFocusState?
        var lastClipboardStatus: String?
        let environment = DeliveryPipeline.Environment(
            now: { ProcessInfo.processInfo.systemUptime },
            schedule: { delay, action in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action) },
            activate: {
                panelWillHide()
                target.activateOriginalWindow()
                self.logger.notice("Original UU activation requested; awaiting stable target window")
            },
            focus: {
                let state = target.deliveryFocusState()
                if state != lastFocus {
                    let description = String(describing: state)
                    self.logger.notice("Delivery focus=\(description, privacy: .public)")
                    lastFocus = state
                }
                return state
            },
            stage: { transcript in
                let success = self.clipboard.stage(transcript)
                self.logger.notice("Transcript clipboard staged once hostOnly=true success=\(success, privacy: .public)")
                return success
            },
            clipboard: { transcript in
                let state = self.clipboard.read(expectedText: transcript)
                let description = "stable=\(state.stableRead) original=\(state.originalGeneration) matches=\(state.textMatches) plain=\(state.onlyPlainText) empty=\(state.empty)"
                if description != lastClipboardStatus {
                    self.logger.notice("Clipboard check \(description, privacy: .public)")
                    lastClipboardStatus = description
                }
                return state
            },
            paste: { callback in ClipboardKeyboardPaster.postCommandV(completion: callback) }
        )
        let attempt = DeliveryPipeline(environment: environment, syncDelay: syncDelay) { [weak self] result in
            guard let self else { return }
            self.pipeline = nil
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            switch result {
            case .success:
                self.logger.notice("Complete Command-V posted once elapsed=\(elapsed, privacy: .public); no clipboard restoration")
            case .failure(let error):
                let reason = String(describing: error)
                self.logger.notice("Delivery cancelled reason=\(reason, privacy: .public) elapsed=\(elapsed, privacy: .public); no clipboard restoration")
            }
            completion(result)
            cleanupCompletion()
        }
        pipeline = attempt
        attempt.start(text: text)
    }

    func cancelForTermination() {
        precondition(Thread.isMainThread)
        pipeline?.cancelForTermination()
        pipeline = nil
    }
}

enum ClipboardKeyboardPaster {
    private static let leftCommandKeyCode: CGKeyCode = 55
    private static let vKeyCode: CGKeyCode = 9
    private static let interEventDelay: TimeInterval = 0.025
    private static let eventQueue = DispatchQueue(
        label: "com.example.DoubaoVoiceBridge.Fn.command-v",
        qos: .userInteractive
    )

    static func makeCommandVEvents() throws -> [CGEvent] {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let commandDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: leftCommandKeyCode,
                keyDown: true
              ),
              let vDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: vKeyCode,
                keyDown: true
              ),
              let vUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: vKeyCode,
                keyDown: false
              ),
              let commandUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: leftCommandKeyCode,
                keyDown: false
              ) else {
            throw DeliveryError.keyboardEventFailed
        }

        // Keep the constructor-generated left-Command device flag. UU Remote
        // tracks modifier down/up events separately and otherwise forwards a
        // plain "V" to the remote Mac.
        vDown.flags = commandDown.flags
        vUp.flags = commandDown.flags

        let events = [commandDown, vDown, vUp, commandUp]
        for event in events {
            event.setIntegerValueField(
                .eventSourceUserData,
                value: FnHoldMonitor.syntheticEventMarker
            )
        }
        return events
    }

    static func postCommandV(completion: @escaping (Result<Void, Error>) -> Void) {
        let conflictingFlags: CGEventFlags = [
            .maskShift,
            .maskControl,
            .maskAlternate,
            .maskCommand,
            .maskSecondaryFn
        ]
        guard CGEventSource.flagsState(.combinedSessionState)
            .intersection(conflictingFlags).isEmpty else {
            completion(.failure(DeliveryError.modifierKeysActive))
            return
        }

        let events: [CGEvent]
        do {
            // Construct all four first, so allocation failure can never leave
            // a synthetic Command key held down.
            events = try makeCommandVEvents()
        } catch {
            completion(.failure(error))
            return
        }

        eventQueue.async {
            for (index, event) in events.enumerated() {
                // Eligibility and modifier state are validated immediately
                // before this queue starts. Once Command-down is posted, the
                // remaining events run unconditionally so neither V nor
                // Command can be left held by a blocking AX/focus check.
                event.post(tap: .cghidEventTap)
                if index < events.count - 1 {
                    Thread.sleep(forTimeInterval: interEventDelay)
                }
            }
            DispatchQueue.main.async {
                completion(.success(()))
            }
        }
    }

    static func finishPendingEventsBeforeTermination() {
        precondition(Thread.isMainThread)
        // The serial event queue never calls back synchronously to main while
        // a modifier is held. A barrier here therefore guarantees any posted
        // Command-down has matching V-up and Command-up before process exit.
        eventQueue.sync {}
    }
}
