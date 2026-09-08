import AppKit
import ApplicationServices
import os.log

enum FnMonitorError: LocalizedError {
    case eventTapUnavailable

    var errorDescription: String? {
        "无法监听Fn，请开启“辅助功能”和“输入监控”权限"
    }
}

final class FnHoldMonitor {
    static let syntheticEventMarker: Int64 = 0x4456_4252
    private static let fnKeyCode = FnKeyPolicy.keyCode

    private let holdThreshold: TimeInterval
    private let targetProvider: () -> UURemoteTarget?
    private let localComposerReady: () -> Bool
    private let onBegin: (UURemoteTarget) -> Void
    private let onRelease: () -> Void
    private let onCancel: () -> Void
    private let logger = Logger(subsystem: "com.example.DoubaoVoiceBridge.Fn", category: "fn")

    private var gesture = HoldGestureState()
    private var target: UURemoteTarget?
    private var activationWorkItem: DispatchWorkItem?
    private var syntheticDownWorkItem: DispatchWorkItem?
    private var syntheticDownPosted = false
    private var syntheticDownAt: Date?
    private var syntheticRoute: SyntheticFnRoute?
    private var localFocusDeadline: Date?
    private var releaseRequestedBeforeSyntheticDown = false
    private var physicalFnIsDown = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var activeTapLocation: CGEventTapLocation?
    var isGestureIdle: Bool { gesture.phase == .idle }

    init(
        holdThreshold: TimeInterval,
        targetProvider: @escaping () -> UURemoteTarget?,
        localComposerReady: @escaping () -> Bool,
        onBegin: @escaping (UURemoteTarget) -> Void,
        onRelease: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.holdThreshold = min(max(holdThreshold, 0.18), 0.60)
        self.targetProvider = targetProvider
        self.localComposerReady = localComposerReady
        self.onBegin = onBegin
        self.onRelease = onRelease
        self.onCancel = onCancel
    }

    deinit {
        stop()
    }

    func start() throws {
        guard eventTap == nil else { return }

        let eventTypes: [CGEventType] = [
            .flagsChanged,
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel
        ]
        let eventMask = eventTypes.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
        }

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<FnHoldMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(proxy: proxy, type: type, event: event)
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: userInfo
        ) else {
            throw FnMonitorError.eventTapUnavailable
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw FnMonitorError.eventTapUnavailable
        }

        eventTap = tap
        activeTapLocation = .cghidEventTap
        physicalFnIsDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(Self.fnKeyCode))
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.notice("HID event tap started at head")
    }

    func stop() {
        resetGesture(notifyCancel: true)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        eventTap = nil
        activeTapLocation = nil
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.error("HID event tap disabled; re-enabling (reason=\(type.rawValue, privacy: .public))")
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            resetGesture(notifyCancel: true)
            physicalFnIsDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(Self.fnKeyCode))
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged, keyCode == Self.fnKeyCode {
            physicalFnIsDown = FnKeyPolicy.isDown(flags: event.flags)
            let isDown = physicalFnIsDown
            if isDown, case .idle = gesture.phase {
                if FnKeyPolicy.hasConflictingModifiers(flags: event.flags) {
                    return Unmanaged.passUnretained(event)
                }
            }
            return handleFn(isDown: isDown, event: event, proxy: proxy)
        }

        switch gesture.phase {
        case .pending:
            logger.notice("Fn hold became a chord; restoring remote Fn passthrough")
            beginPassthroughForChord(proxy: proxy)
        case .idle, .dictating, .passthrough:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleFn(isDown: Bool, event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        if isDown {
            guard case .idle = gesture.phase else {
                return gesture.phase == .passthrough ? Unmanaged.passUnretained(event) : nil
            }
            guard let target = targetProvider() else {
                logger.notice("Fn passed through because UU is not eligible")
                return Unmanaged.passUnretained(event)
            }

            logger.notice("Physical Fn down intercepted for local dictation")
            self.target = target
            _ = gesture.handle(.fnDown(targetAvailable: true))
            let workItem = DispatchWorkItem { [weak self] in self?.activateDictationIfStillPending() }
            activationWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: workItem)
            return nil
        }

        switch gesture.phase {
        case .idle:
            return Unmanaged.passUnretained(event)
        case .pending:
            logger.notice("Physical Fn released before long-press threshold")
            _ = gesture.handle(.fnUp)
            // Preserve a short Fn tap: deliver its down before the physical up.
            postSyntheticFn(down: true, route: .remoteHIDPassthrough, proxy: proxy)
            resetGesture(notifyCancel: false)
            return Unmanaged.passUnretained(event)
        case .passthrough:
            _ = gesture.handle(.fnUp)
            // The real Fn release is about to pass through, so it
            // completes the synthetic down used to recover the chord.
            syntheticDownPosted = false
            resetGesture(notifyCancel: false)
            return Unmanaged.passUnretained(event)
        case .dictating:
            logger.notice("Physical Fn released; finishing local dictation")
            _ = gesture.handle(.fnUp)
            finishDictationGesture()
            return nil
        }
    }

    private func activateDictationIfStillPending() {
        guard case .pending = gesture.phase, let target else { return }
        guard physicalFnIsDown,
              targetProvider()?.processIdentifier == target.processIdentifier else {
            logger.notice("Long-press cancelled because UU is no longer the eligible target")
            resetGesture(notifyCancel: false)
            return
        }
        _ = gesture.handle(.thresholdReached)
        target.captureFocusedWindow()
        logger.notice("Long-press threshold reached; opening local composer")
        onBegin(target)
        localFocusDeadline = Date().addingTimeInterval(0.75)
        scheduleSyntheticDownCheck(after: 0.03)
    }

    private func postSyntheticDownIfNeeded() {
        guard case .dictating = gesture.phase, !syntheticDownPosted else { return }
        if releaseRequestedBeforeSyntheticDown {
            onCancel()
            resetGesture(notifyCancel: false)
            return
        }
        guard localComposerReady() else {
            if Date() < localFocusDeadline ?? .distantPast {
                scheduleSyntheticDownCheck(after: 0.02)
            } else {
                logger.error("Local composer did not become ready; cancelling dictation")
                onCancel()
                resetGesture(notifyCancel: false)
            }
            return
        }
        logger.notice("Local composer is key and ready for Doubao voice input method")
        let route = SyntheticFnRoute.localSessionDictation
        guard postSyntheticFn(down: true, route: route) else {
            logger.error("Unable to create synthetic local Fn down")
            onCancel()
            resetGesture(notifyCancel: false)
            return
        }
        syntheticDownPosted = true
        syntheticDownAt = Date()
        syntheticRoute = route
        logger.notice("Synthetic local Fn down posted at session tap")
    }

    private func scheduleSyntheticDownCheck(after delay: TimeInterval) {
        syntheticDownWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.postSyntheticDownIfNeeded() }
        syntheticDownWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func finishDictationGesture() {
        if syntheticDownPosted {
            if let syntheticRoute {
                postSyntheticFn(down: false, route: syntheticRoute)
            }
            syntheticDownPosted = false
            let heldLongEnough = Date().timeIntervalSince(syntheticDownAt ?? .distantPast) >= 0.15
            if heldLongEnough {
                logger.notice("Local Doubao voice input method gesture completed; waiting for transcript")
                onRelease()
            } else {
                logger.notice("Synthetic local Fn hold was too short; cancelling")
                onCancel()
            }
            resetGesture(notifyCancel: false)
        } else {
            releaseRequestedBeforeSyntheticDown = true
        }
    }

    private func beginPassthroughForChord(proxy: CGEventTapProxy? = nil) {
        guard case .pending = gesture.phase else { return }
        activationWorkItem?.cancel()
        activationWorkItem = nil
        _ = gesture.handle(.otherInput)
        target = nil
        let route = SyntheticFnRoute.remoteHIDPassthrough
        if postSyntheticFn(down: true, route: route, proxy: proxy) {
            syntheticDownPosted = true
            syntheticRoute = route
        } else {
            logger.error("Unable to recover remote Fn chord")
        }
    }

    private func resetGesture(notifyCancel: Bool) {
        let wasDictating = gesture.phase == .dictating
        if syntheticDownPosted, let syntheticRoute {
            postSyntheticFn(down: false, route: syntheticRoute)
        }
        activationWorkItem?.cancel()
        syntheticDownWorkItem?.cancel()
        activationWorkItem = nil
        syntheticDownWorkItem = nil
        syntheticDownPosted = false
        syntheticDownAt = nil
        syntheticRoute = nil
        localFocusDeadline = nil
        releaseRequestedBeforeSyntheticDown = false
        gesture.reset()
        target = nil
        if notifyCancel && wasDictating { onCancel() }
    }

    @discardableResult
    private func postSyntheticFn(
        down: Bool,
        route: SyntheticFnRoute,
        proxy: CGEventTapProxy? = nil
    ) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let event = CGEvent(source: source) else { return false }
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Self.fnKeyCode)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        event.flags = FnKeyPolicy.flags(
            for: down,
            preserving: CGEventSource.flagsState(.combinedSessionState)
        )
        if route == .remoteHIDPassthrough, let proxy {
            event.tapPostEvent(proxy)
        } else {
            event.post(tap: route.eventTapLocation)
        }
        return true
    }
}

enum SyntheticFnRoute: Equatable {
    case remoteHIDPassthrough
    case localSessionDictation

    var eventTapLocation: CGEventTapLocation {
        switch self {
        case .remoteHIDPassthrough:
            return .cghidEventTap
        case .localSessionDictation:
            return .cgSessionEventTap
        }
    }
}
