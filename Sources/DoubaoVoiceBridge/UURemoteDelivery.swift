import AppKit
import ApplicationServices
import os.log

enum DeliveryError: LocalizedError, Equatable {
    case emptyText
    case accessibilityMissing
    case targetAppMissing
    case clipboardSnapshotUnavailable
    case pasteboardUnavailable
    case targetChanged
    case clipboardChanged
    case keyboardEventFailed
    case modifierKeysActive

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "没有可发送的文字"
        case .accessibilityMissing:
            return "尚未开启辅助功能权限"
        case .targetAppMissing:
            return "UU 远控已经关闭"
        case .clipboardSnapshotUnavailable:
            return "原剪贴板内容过大或无法安全备份"
        case .pasteboardUnavailable:
            return "无法写入系统剪贴板"
        case .targetChanged:
            return "发送前焦点发生变化，已取消自动粘贴"
        case .clipboardChanged:
            return "等待 UU 同步时剪贴板文字已改变，已取消自动粘贴"
        case .keyboardEventFailed:
            return "无法发送 Command-V"
        case .modifierKeysActive:
            return "请先松开 Command、Shift、Option 或 Control 键"
        }
    }
}

final class UURemoteDelivery {
    static let defaultPasteDelay: TimeInterval = 0.50
    static let minimumPasteDelay: TimeInterval = 0.45
    static let maximumPasteDelay: TimeInterval = 3.0

    private let pasteboard: NSPasteboard
    private let defaults: UserDefaults
    private let accessibilityGranted: () -> Bool
    private let frontmostPID: () -> pid_t?
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let postPaste: (@escaping () -> DeliveryError?, @escaping (Result<Void, Error>) -> Void) -> Void
    private let logger = Logger(subsystem: "com.lyp.DoubaoVoiceBridge", category: "delivery")
    private var activeSnapshot: PasteboardSnapshot?
    private var activeBridgeChangeCount: Int?
    private var shouldRestoreActiveSnapshot = false

    init(
        pasteboard: NSPasteboard = .general,
        defaults: UserDefaults = .standard,
        accessibilityGranted: @escaping () -> Bool = { AXIsProcessTrusted() },
        frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        postPaste: @escaping (@escaping () -> DeliveryError?, @escaping (Result<Void, Error>) -> Void) -> Void = ClipboardKeyboardPaster.postCommandV
    ) {
        self.pasteboard = pasteboard
        self.defaults = defaults
        self.accessibilityGranted = accessibilityGranted
        self.frontmostPID = frontmostPID
        self.schedule = schedule
        self.postPaste = postPaste
    }

    func deliver(
        text: String,
        to target: RemoteDeliveryTarget,
        panelWillHide: @escaping () -> Void,
        completion: @escaping (Result<Void, Error>) -> Void,
        cleanupCompletion: @escaping () -> Void
    ) {
        precondition(Thread.isMainThread)

        guard !text.isEmpty else {
            completion(.failure(DeliveryError.emptyText))
            return
        }
        guard accessibilityGranted() else {
            completion(.failure(DeliveryError.accessibilityMissing))
            return
        }
        guard !target.isTerminated else {
            cleanupCompletion()
            completion(.failure(DeliveryError.targetAppMissing))
            return
        }

        panelWillHide()
        target.activateOriginalWindow()
        waitForActivation(target, remainingAttempts: 20) { [weak self] ready in
            guard let self else { return }
            guard ready else {
                completion(.failure(target.isTerminated ? DeliveryError.targetAppMissing : DeliveryError.targetChanged))
                cleanupCompletion()
                return
            }
            self.stageTranscript(text, to: target, completion: completion, cleanupCompletion: cleanupCompletion)
        }
    }

    private func waitForActivation(_ target: RemoteDeliveryTarget, remainingAttempts: Int, completion: @escaping (Bool) -> Void) {
        guard !target.isTerminated else { completion(false); return }
        if frontmostPID() == target.processIdentifier && target.stillMatchesFocusedWindow() {
            completion(true)
            return
        }
        guard remainingAttempts > 0 else { completion(false); return }
        schedule(0.05) { [weak self] in
            self?.waitForActivation(target, remainingAttempts: remainingAttempts - 1, completion: completion)
        }
    }

    private func stageTranscript(
        _ text: String, to target: RemoteDeliveryTarget,
        completion: @escaping (Result<Void, Error>) -> Void,
        cleanupCompletion: @escaping () -> Void
    ) {

        let shouldRestore = defaults.bool(forKey: "restoreClipboard")
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        if shouldRestore && snapshot == nil {
            completion(.failure(DeliveryError.clipboardSnapshotUnavailable))
            cleanupCompletion()
            return
        }

        let clearedGeneration = pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restoreImmediatelyIfSafe(snapshot, expectedChangeCount: clearedGeneration)
            completion(.failure(DeliveryError.pasteboardUnavailable))
            cleanupCompletion()
            return
        }
        let bridgeChangeCount = pasteboard.changeCount
        activeSnapshot = snapshot
        activeBridgeChangeCount = bridgeChangeCount
        shouldRestoreActiveSnapshot = shouldRestore
        let lengthBucket = PrivacySafeTextMetrics.lengthBucket(text.utf16.count)
        logger.notice(
            "Transcript staged for UU lengthBucket=\(lengthBucket, privacy: .public) pasteboardGeneration=\(bridgeChangeCount, privacy: .private)"
        )
        let configuredDelay = defaults.double(forKey: "pasteDelay")
        let syncDelay = min(
            max(configuredDelay, Self.minimumPasteDelay),
            Self.maximumPasteDelay
        )

        logger.notice("Original UU window is active; waiting for clipboard synchronization")

        schedule(syncDelay) { [weak self] in
            guard let self else { return }
            guard !target.isTerminated else {
                self.restoreImmediatelyIfSafe(snapshot, expectedChangeCount: bridgeChangeCount)
                self.clearActiveDelivery()
                completion(.failure(DeliveryError.targetAppMissing))
                cleanupCompletion()
                return
            }
            guard self.pasteboard.string(forType: .string) == text else {
                self.logger.error("Clipboard text changed while waiting for UU; keeping the transcript for retry")
                self.clearActiveDelivery()
                completion(.failure(DeliveryError.clipboardChanged))
                cleanupCompletion()
                return
            }
            guard self.frontmostPID() == target.processIdentifier,
                  target.stillMatchesFocusedWindow() else {
                self.restoreImmediatelyIfSafe(snapshot, expectedChangeCount: bridgeChangeCount)
                self.clearActiveDelivery()
                completion(.failure(DeliveryError.targetChanged))
                cleanupCompletion()
                return
            }

            // Clipboard synchronization can republish the same transcript in
            // a new generation. Check the payload, not just the generation,
            // before pasting. Restoration still requires our own generation
            // so we never replace a later copy made by the user or UU.
            if self.pasteboard.changeCount != bridgeChangeCount {
                self.logger.notice("Clipboard was republished with unchanged text; continuing paste without claiming ownership")
            }

            self.postPaste({
                if target.isTerminated { return .targetAppMissing }
                if self.pasteboard.string(forType: .string) != text { return .clipboardChanged }
                if self.frontmostPID() != target.processIdentifier || !target.stillMatchesFocusedWindow() { return .targetChanged }
                return nil
            }) { result in
                switch result {
                case .success:
                    self.logger.notice("Complete Command-V key sequence posted to UU")
                    completion(.success(()))
                    guard shouldRestore, let snapshot else {
                        self.clearActiveDelivery()
                        cleanupCompletion()
                        return
                    }
                    self.schedule(2.0) {
                        if self.pasteboard.changeCount == bridgeChangeCount {
                            snapshot.restore(to: self.pasteboard)
                            self.logger.notice("Original clipboard restored")
                        }
                        self.clearActiveDelivery()
                        cleanupCompletion()
                    }
                case .failure(let error):
                    self.restoreImmediatelyIfSafe(snapshot, expectedChangeCount: bridgeChangeCount)
                    self.clearActiveDelivery()
                    completion(.failure(error))
                    cleanupCompletion()
                }
            }
        }
    }

    func restoreClipboardForTermination() {
        precondition(Thread.isMainThread)
        guard shouldRestoreActiveSnapshot,
              let snapshot = activeSnapshot,
              let changeCount = activeBridgeChangeCount else {
            clearActiveDelivery()
            return
        }
        restoreImmediatelyIfSafe(snapshot, expectedChangeCount: changeCount)
        clearActiveDelivery()
    }

    private func restoreImmediatelyIfSafe(
        _ snapshot: PasteboardSnapshot?,
        expectedChangeCount: Int
    ) {
        guard let snapshot, pasteboard.changeCount == expectedChangeCount else { return }
        snapshot.restore(to: pasteboard)
    }

    private func clearActiveDelivery() {
        activeSnapshot = nil
        activeBridgeChangeCount = nil
        shouldRestoreActiveSnapshot = false
    }
}

enum ClipboardKeyboardPaster {
    private static let leftCommandKeyCode: CGKeyCode = 55
    private static let vKeyCode: CGKeyCode = 9
    private static let interEventDelay: TimeInterval = 0.025
    private static let eventQueue = DispatchQueue(
        label: "com.lyp.DoubaoVoiceBridge.command-v",
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
                value: ControlHoldMonitor.syntheticEventMarker
            )
        }
        return events
    }

    static func postCommandV(validateTarget: @escaping () -> DeliveryError?, completion: @escaping (Result<Void, Error>) -> Void) {
        precondition(Thread.isMainThread)
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

        if let error = validateTarget() {
            completion(.failure(error))
            return
        }
        // Check the target and post the first event together on main, without
        // a queued gap in which another application can become the target.
        events[0].post(tap: .cghidEventTap)
        eventQueue.async {
            for event in events.dropFirst() {
                Thread.sleep(forTimeInterval: interEventDelay)
                // Always release both keys after starting the sequence.
                event.post(tap: .cghidEventTap)
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
