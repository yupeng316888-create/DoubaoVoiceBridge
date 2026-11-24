import AppKit
import ApplicationServices
import Carbon.HIToolbox
import IOKit.hidsystem
import os.log

enum ControlMonitorError: LocalizedError {
    case eventTapUnavailable

    var errorDescription: String? {
        "无法监听左 Control，请开启“辅助功能”和“输入监控”权限"
    }
}

enum ControlKeySide {
    case left, right

    func deviceState(in flags: CGEventFlags) -> Bool? {
        let left = UInt64(NX_DEVICELCTLKEYMASK)
        let right = UInt64(NX_DEVICERCTLKEYMASK)
        guard flags.rawValue & (left | right) != 0 else { return nil }
        return flags.rawValue & (self == .left ? left : right) != 0
    }

    func isDown(flags: CGEventFlags, otherSideDown: Bool, hardwareDown: Bool) -> Bool {
        if let side = deviceState(in: flags) { return side }
        guard flags.contains(.maskControl) else { return false }
        // The generic flag describes either key. Consult hardware if the
        // other key alone could account for that flag.
        return !otherSideDown || hardwareDown
    }
}

struct RightControlState {
    private(set) var isDown = false
    private var genericVirtualDown = false

    mutating func updateRightEvent(flags: CGEventFlags, leftHardwareDown: Bool, rightHardwareDown: Bool) {
        isDown = ControlKeySide.right.isDown(flags: flags, otherSideDown: leftHardwareDown, hardwareDown: rightHardwareDown)
        genericVirtualDown = isDown && !rightHardwareDown && ControlKeySide.right.deviceState(in: flags) == nil
    }

    mutating func reconcileLeftEvent(flags: CGEventFlags, rightHardwareDown: Bool) {
        if let side = ControlKeySide.right.deviceState(in: flags) {
            isDown = side
            genericVirtualDown = false
        } else {
            genericVirtualDown = genericVirtualDown && flags.contains(.maskControl)
            isDown = flags.contains(.maskControl) && (rightHardwareDown || genericVirtualDown)
        }
    }

    mutating func synchronize(hardwareDown: Bool) {
        isDown = hardwareDown
        genericVirtualDown = false
    }
}

struct HardwareControlRelease {
    private var sawDown = false
    private var previousSampleWasUp = false

    // Split shortcuts use IOHID exclusively to close a press intercepted by
    // Quartz. A real key down or a release in another app cannot start one.
    static func canFinishInterceptedHold(down: Bool, phase: HoldGesturePhase, waitingForRelease: Bool) -> Bool {
        !down && (waitingForRelease || phase == .pending || phase == .dictating)
    }

    mutating func observe(down: Bool) -> Bool {
        if down {
            sawDown = true
            previousSampleWasUp = false
        } else if sawDown {
            if previousSampleWasUp {
                self = HardwareControlRelease()
                return true
            }
            previousSampleWasUp = true
        }
        return false
    }
}

// A physical press is visible to both IOHID and Quartz, in either order.
// Only a press missed by Quartz may open the panel on the native path.
struct PhysicalFallbackGate {
    enum Phase { case idle, waiting, quartz, native, ignored }
    private(set) var phase = Phase.idle
    private(set) var physicalHeld = false
    private var quartzHeld = false

    mutating func physicalPress(eligible: Bool) -> Bool {
        guard !physicalHeld else { return false }
        physicalHeld = true
        phase = quartzHeld ? .quartz : (eligible ? .waiting : .ignored)
        return phase == .waiting
    }

    mutating func quartzPress() -> Bool {
        quartzHeld = true
        if phase == .native || phase == .ignored { return false }
        if physicalHeld { phase = .quartz }
        return true
    }

    mutating func quartzRelease() {
        quartzHeld = false
        if phase == .waiting { phase = .ignored }
    }

    mutating func beginNative(stillEligible: Bool) -> Bool {
        guard phase == .waiting else { return false }
        phase = stillEligible ? .native : .ignored
        return stillEligible
    }

    mutating func abandon() {
        if phase == .waiting || phase == .native { phase = .ignored }
    }

    mutating func physicalRelease() -> Bool {
        let wasNative = phase == .native
        self = PhysicalFallbackGate()
        return wasNative
    }
}

// Each physical hold owns one ticket. Delayed checks from a released or
// cancelled hold cannot start the input method in a later session.
struct NativeControlRearm {
    enum Phase { case idle, awaitingFocus, neutralGap, restarted, nativeOnly }
    private(set) var phase = Phase.idle
    private(set) var ticket: UInt64 = 0
    private(set) var postedFlags: UInt32 = 0

    mutating func begin() -> UInt64 {
        ticket &+= 1
        phase = .awaitingFocus
        postedFlags = 0
        return ticket
    }

    mutating func focused(_ id: UInt64, empty: Bool) -> Bool {
        guard id == ticket && phase == .awaitingFocus else { return false }
        phase = empty ? .neutralGap : .nativeOnly
        if empty { postedFlags = 1 }
        return empty
    }

    mutating func freshDown(_ id: UInt64, empty: Bool) -> Bool {
        guard id == ticket && phase == .neutralGap else { return false }
        phase = empty ? .restarted : .nativeOnly
        if empty { postedFlags = 2 }
        return empty
    }

    // Only a successfully posted fresh down requires a paired synthetic up.
    mutating func finish() -> Bool {
        let needsUp = phase == .restarted
        phase = .idle
        postedFlags = 0
        return needsUp
    }
}

// Totals only. A chord or a click is detectable even when another tap
// consumes the original event. No characters or key codes are collected.
private struct PhysicalInputCounts: Equatable {
    let nonModifierEvents: UInt32
    let modifierChanges: UInt32

    init() {
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        nonModifierEvents = types.reduce(UInt32(0)) {
            $0 &+ CGEventSource.counterForEventType(.hidSystemState, eventType: $1)
        }
        modifierChanges = CGEventSource.counterForEventType(.hidSystemState, eventType: .flagsChanged)
    }

    func stillAlone(since previous: Self, allowedModifierChanges: UInt32) -> Bool {
        nonModifierEvents == previous.nonModifierEvents && modifierChanges &- previous.modifierChanges <= allowedModifierChanges
    }
}

final class ControlHoldMonitor {
    static let syntheticEventMarker: Int64 = 0x4456_4252
    private static let leftControlKeyCode: Int64 = 59

    private let holdThreshold: TimeInterval
    private let localVoiceKey: LocalVoiceKey
    // Keep one isolated source for both edges of every local voice shortcut.
    // A physical left Control remains down while the synthetic shortcut runs.
    private let localVoiceSource = CGEventSource(stateID: .privateState)
    private lazy var voiceFilter = SyntheticVoiceKeyFilter(key: localVoiceKey)
    // UU also observes the session stream. Stop the hands-free keys at the
    // end of HID, after Doubao's HID listeners and before any session tap.
    private lazy var handsFreeHIDFilter = SyntheticVoiceKeyFilter(key: .rightOptionTap, location: .cghidEventTap, placement: .tailAppendEventTap)
    private let handsFree = HandsFreeShortcutSession()
    private let targetProvider: () -> UURemoteTarget?
    private let localComposerReady: () -> Bool
    private let onBegin: (UURemoteTarget) -> Void
    private let onRelease: () -> Void
    private let onCancel: () -> Void
    private let logger = Logger(subsystem: "com.lyp.DoubaoVoiceBridge", category: "control")

    private var gesture = HoldGestureState()
    private var target: UURemoteTarget?
    private var activationWorkItem: DispatchWorkItem?
    private var syntheticDownWorkItem: DispatchWorkItem?
    private var syntheticDownPosted = false
    private var syntheticDownAt: Date?
    private var syntheticRoute: SyntheticControlRoute?
    private var localFocusDeadline: Date?
    private var releaseWatch: Timer?
    private var hardwareRelease = HardwareControlRelease()
    private var waitForHeldKeyRelease = false
    private var suppressLateRelease = false
    private var rightControl = RightControlState()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var activeTapLocation: CGEventTapLocation?
    private lazy var physicalObserver = PhysicalLeftControlObserver { [weak self] down in
        self?.physicalLeftChanged(down)
    }
    private var fallback = PhysicalFallbackGate()
    private var fallbackRearm = NativeControlRearm()
    var localComposerReadyForRestart: (() -> Bool)?
    var ownsPhysicalFallbackRelease: Bool { fallback.phase == .native && fallback.physicalHeld }
    private var fallbackWork: DispatchWorkItem?
    private var fallbackTarget: UURemoteTarget?
    private var fallbackInput: PhysicalInputCounts?
    private var focusObservation: NSObjectProtocol?
    var onFallbackAbandoned: (() -> Void)?
    var isGestureIdle: Bool {
        gesture.phase == .idle && !waitForHeldKeyRelease && !fallback.physicalHeld
    }

    private var leftHardwareDown: Bool {
        CGEventSource.keyState(.hidSystemState, key: CGKeyCode(Self.leftControlKeyCode))
    }
    private var rightHardwareDown: Bool {
        CGEventSource.keyState(.hidSystemState, key: 62)
    }

    init(
        holdThreshold: TimeInterval,
        localVoiceKey: LocalVoiceKey = .leftControl,
        targetProvider: @escaping () -> UURemoteTarget?,
        localComposerReady: @escaping () -> Bool,
        onBegin: @escaping (UURemoteTarget) -> Void,
        onRelease: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.holdThreshold = min(max(holdThreshold, 0.18), 0.60)
        self.localVoiceKey = localVoiceKey
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
        if localVoiceKey.usesSeparateShortcut && (localVoiceSource == nil || !voiceFilter.start()) {
            throw ControlMonitorError.eventTapUnavailable
        }
        if localVoiceKey == .rightOptionTap && !handsFreeHIDFilter.start() {
            throw ControlMonitorError.eventTapUnavailable
        }

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
            let monitor = Unmanaged<ControlHoldMonitor>.fromOpaque(userInfo).takeUnretainedValue()
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
            throw ControlMonitorError.eventTapUnavailable
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw ControlMonitorError.eventTapUnavailable
        }

        eventTap = tap
        activeTapLocation = .cghidEventTap
        rightControl.synchronize(hardwareDown: rightHardwareDown)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.notice("HID event tap started at head")
        let observingPhysicalControl = physicalObserver.start()
        if localVoiceKey.usesSeparateShortcut {
            logger.notice("Using \(self.localVoiceKey.rawValue, privacy: .public) after intercepting UU left Control; physical release observer=\(observingPhysicalControl)")
        } else if observingPhysicalControl {
            observeFocusChanges()
            logger.notice("Physical left Control observer available")
        } else {
            logger.error("Physical left Control observer unavailable")
        }
        if localVoiceKey == .rightOptionTap { observeFocusChanges() }
    }

    private func observeFocusChanges() {
        let center = NSWorkspace.shared.notificationCenter
        focusObservation = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.activationDuringPhysicalHold(app)
        }
    }

    func stop() {
        if let focusObservation {
            NSWorkspace.shared.notificationCenter.removeObserver(focusObservation)
            self.focusObservation = nil
        }
        let nativeWasOpen = fallback.phase == .native
        fallback = PhysicalFallbackGate()
        clearFallbackWork()
        physicalObserver.stop()
        if nativeWasOpen { onCancel() }
        resetGesture(notifyCancel: true, useNonprintingStop: true)
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

    private func clearFallbackWork() {
        if fallbackRearm.finish() {
            let posted = postRearmControl(down: false)
            logger.notice("Finished fallback local Control hold; matching up posted=\(posted)")
        }
        fallbackWork?.cancel()
        fallbackWork = nil
        fallbackTarget = nil
        fallbackInput = nil
    }

    private var conflictingPhysicalInput: Bool {
        let flags = CGEventSource.flagsState(.hidSystemState)
        let modifiers: CGEventFlags = [.maskShift, .maskAlternate, .maskCommand, .maskSecondaryFn]
        if !flags.intersection(modifiers).isEmpty || rightHardwareDown { return true }
        return [CGMouseButton.left, .right, .center].contains {
            CGEventSource.buttonState(.hidSystemState, button: $0)
        }
    }

    private func physicalLeftChanged(_ down: Bool) {
        if localVoiceKey.usesSeparateShortcut {
            if HardwareControlRelease.canFinishInterceptedHold(down: down, phase: gesture.phase, waitingForRelease: waitForHeldKeyRelease) {
                fallback.quartzRelease()
                recoverHardwareRelease(source: "IOHID")
            }
            return
        }
        if down {
            guard !fallback.physicalHeld else { return }
            let input = PhysicalInputCounts()
            let candidate = gesture.phase == .idle && !waitForHeldKeyRelease && !conflictingPhysicalInput ? targetProvider() : nil
            guard fallback.physicalPress(eligible: candidate != nil), let candidate else { return }
            guard candidate.captureFocusedWindow() else {
                fallback.abandon()
                return
            }
            fallbackTarget = candidate
            fallbackInput = input
            logger.notice("Physical observer received left Control in UU; waiting for Quartz")
            let item = DispatchWorkItem { [weak self] in self?.beginNativeFallback() }
            fallbackWork = item
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold + 0.04, execute: item)
            return
        }
        let wasNative = fallback.physicalRelease()
        let cleanHold = wasNative && fallbackInput.map {
            PhysicalInputCounts().stillAlone(since: $0, allowedModifierChanges: 2 + fallbackRearm.postedFlags)
        } == true && !conflictingPhysicalInput
        let endedBeforeReady = fallbackRearm.phase == .awaitingFocus || fallbackRearm.phase == .neutralGap
        let canFinalize = cleanHold && (!endedBeforeReady || (localComposerReady() && localComposerReadyForRestart?() == false))
        clearFallbackWork()
        if wasNative {
            logger.notice("Native fallback physical Control released; finalizing=\(canFinalize)")
            if canFinalize { onRelease() }
            else { onCancel() }
        }
    }

    private func beginNativeFallback() {
        guard fallback.phase == .waiting, let target = fallbackTarget, let input = fallbackInput else { return }
        let eligible = gesture.phase == .idle && !conflictingPhysicalInput &&
            targetProvider()?.processIdentifier == target.processIdentifier &&
            target.stillMatchesFocusedWindow() && PhysicalInputCounts().stillAlone(since: input, allowedModifierChanges: 1)
        guard fallback.beginNative(stillEligible: eligible) else { clearFallbackWork(); return }
        fallbackWork = nil
        logger.notice("Opening local composer for native physical Control hold")
        let ticket = fallbackRearm.begin()
        onBegin(target)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        scheduleFallbackRearm(ticket: ticket, focusDeadline: deadline, delay: 0.03)
    }

    private func scheduleFallbackRearm(ticket: UInt64, focusDeadline: TimeInterval, delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            self?.advanceFallbackRearm(ticket: ticket, focusDeadline: focusDeadline)
        }
        fallbackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func advanceFallbackRearm(ticket: UInt64, focusDeadline: TimeInterval) {
        guard ownsPhysicalFallbackRelease, fallbackRearm.ticket == ticket, let input = fallbackInput else { return }
        let allowedFlags = 1 + fallbackRearm.postedFlags
        guard !conflictingPhysicalInput, PhysicalInputCounts().stillAlone(since: input, allowedModifierChanges: allowedFlags) else {
            logger.notice("Fallback restart cancelled because physical input changed")
            abandonFallback()
            return
        }
        guard localComposerReady() else {
            if fallbackRearm.phase == .awaitingFocus && ProcessInfo.processInfo.systemUptime < focusDeadline {
                scheduleFallbackRearm(ticket: ticket, focusDeadline: focusDeadline, delay: 0.02)
            } else {
                logger.notice("Fallback restart cancelled because local composer does not own focus")
                abandonFallback(focusChanged: !NSApp.isActive)
            }
            return
        }
        let empty = localComposerReadyForRestart?() == true
        switch fallbackRearm.phase {
        case .awaitingFocus:
            guard fallbackRearm.focused(ticket, empty: empty) else {
                logger.notice("Fallback composer already has input; preserving native session")
                return
            }
            guard postRearmControl(down: false) else { abandonFallback(); return }
            logger.notice("Fallback empty local composer ready; posted neutral Control up")
            scheduleFallbackRearm(ticket: ticket, focusDeadline: focusDeadline, delay: 0.12)
        case .neutralGap:
            guard fallbackRearm.freshDown(ticket, empty: empty) else {
                logger.notice("Input arrived during fallback neutral gap; skipping fresh Control down")
                return
            }
            guard postRearmControl(down: true) else {
                _ = fallbackRearm.finish()  // No synthetic down was posted.
                abandonFallback()
                return
            }
            logger.notice("Fallback fresh local Control down posted to Doubao")
        default:
            return
        }
    }

    // A real left Control can still be held when we post the neutral up.
    // Explicitly set its device and generic flags independently of that hold.
    private func postRearmControl(down: Bool) -> Bool {
        let rightHeld = rightHardwareDown
        guard let event = Self.makeControlEvent(down: down, rightControlHeld: rightHeld) else { return false }
        let leftDevice = CGEventFlags(rawValue: UInt64(NX_DEVICELCTLKEYMASK))
        if down {
            event.flags.formUnion([leftDevice, .maskControl])
        } else {
            event.flags.remove(leftDevice)
            if !rightHeld { event.flags.remove(.maskControl) }
        }
        event.post(tap: SyntheticControlRoute.localHIDDictation.eventTapLocation)
        return true
    }

    private func abandonFallback(focusChanged: Bool = false) {
        let wasNative = fallback.phase == .native
        guard wasNative || fallback.phase == .waiting else { return }
        fallback.abandon()
        clearFallbackWork()
        if wasNative {
            if focusChanged, let onFallbackAbandoned { onFallbackAbandoned() }
            else { onCancel() }
        }
    }

    private func activationDuringPhysicalHold(_ app: NSRunningApplication) {
        if localVoiceKey == .rightOptionTap, gesture.phase == .dictating,
           app.processIdentifier != getpid(),
           app.bundleIdentifier != "com.bytedance.inputmethod.doubaoime" {
            // The notification may refer to an activation already superseded
            // while the local composer was opening.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
            resetAfterSessionEnd(useNonprintingStop: true)
            if let onFallbackAbandoned { onFallbackAbandoned() } else { onCancel() }
            return
        }
        guard let target = fallbackTarget, app.processIdentifier != target.processIdentifier else { return }
        if fallback.phase == .native &&
            (app.processIdentifier == getpid() || app.bundleIdentifier == "com.bytedance.inputmethod.doubaoime") { return }
        abandonFallback(focusChanged: true)
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.error("HID event tap disabled; re-enabling (reason=\(type.rawValue, privacy: .public))")
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            resetGesture(notifyCancel: true)
            rightControl.synchronize(hardwareDown: rightHardwareDown)
            return Unmanaged.passUnretained(event)
        }

        let marker = event.getIntegerValueField(.eventSourceUserData)
        if marker == Self.syntheticEventMarker || marker == HandsFreeShortcutSession.eventMarker {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let leftEvent = type == .flagsChanged && keyCode == Self.leftControlKeyCode
        if !leftEvent { abandonFallback() }
        if type == .flagsChanged, keyCode == 62 {
            let wasDown = rightControl.isDown
            rightControl.updateRightEvent(flags: event.flags, leftHardwareDown: leftHardwareDown, rightHardwareDown: rightHardwareDown)
            guard rightControl.isDown != wasDown else { return Unmanaged.passUnretained(event) }
            if gesture.phase == .pending {
                beginPassthroughForChord()
            } else if gesture.phase == .dictating {
                resetAfterSessionEnd()
                onCancel()
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged, keyCode == Self.leftControlKeyCode {
            rightControl.reconcileLeftEvent(flags: event.flags, rightHardwareDown: rightHardwareDown)
            let isDown = ControlKeySide.left.isDown(flags: event.flags, otherSideDown: rightControl.isDown, hardwareDown: leftHardwareDown)
            if isDown {
                guard fallback.quartzPress() else { return Unmanaged.passUnretained(event) }
                clearFallbackWork()
            } else {
                let nativeOwnsRelease = fallback.phase == .native || fallback.phase == .ignored
                fallback.quartzRelease()
                if nativeOwnsRelease && gesture.phase == .idle && !waitForHeldKeyRelease {
                    return Unmanaged.passUnretained(event)
                }
            }
            if waitForHeldKeyRelease {
                if !isDown { stopReleaseWatch() }
                return nil
            }
            if !isDown && suppressLateRelease {
                suppressLateRelease = false
                return nil
            }
            suppressLateRelease = false
            if isDown, case .idle = gesture.phase {
                let conflictingFlags: CGEventFlags = [.maskShift, .maskAlternate, .maskCommand, .maskSecondaryFn]
                if rightControl.isDown || !event.flags.intersection(conflictingFlags).isEmpty {
                    return Unmanaged.passUnretained(event)
                }
            }
            return handleLeftControl(isDown: isDown, event: event)
        }

        switch gesture.phase {
        case .pending:
            logger.notice("Control hold became a chord; restoring remote Control passthrough")
            beginPassthroughForChord(proxy: proxy)
        case .idle, .dictating, .passthrough:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleLeftControl(isDown: Bool, event: CGEvent) -> Unmanaged<CGEvent>? {
        if isDown {
            guard case .idle = gesture.phase else {
                return gesture.phase == .passthrough ? Unmanaged.passUnretained(event) : nil
            }
            guard let target = targetProvider() else {
                logger.notice("Left Control passed through because UU is not eligible")
                return Unmanaged.passUnretained(event)
            }

            logger.notice("Physical left Control down intercepted for local dictation")
            self.target = target
            _ = gesture.handle(.controlDown(targetAvailable: true))
            startReleaseWatch(hardwareDown: leftHardwareDown)
            let workItem = DispatchWorkItem { [weak self] in self?.activateDictationIfStillPending() }
            activationWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: workItem)
            return nil
        }

        switch gesture.phase {
        case .idle:
            return Unmanaged.passUnretained(event)
        case .pending:
            logger.notice("Physical left Control released before long-press threshold")
            _ = gesture.handle(.controlUp)
            resetGesture(notifyCancel: false)
            return nil
        case .passthrough:
            _ = gesture.handle(.controlUp)
            // The real left-Control release is about to pass through, so it
            // completes the synthetic down used to recover the chord.
            syntheticDownPosted = false
            resetGesture(notifyCancel: false)
            return Unmanaged.passUnretained(event)
        case .dictating:
            logger.notice("Physical left Control released; finishing local dictation")
            _ = gesture.handle(.controlUp)
            finishDictationGesture()
            return nil
        }
    }

    private func activateDictationIfStillPending() {
        guard case .pending = gesture.phase, let target else { return }
        guard !rightControl.isDown,
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
        guard localComposerReady() else {
            if Date() < localFocusDeadline ?? .distantPast {
                scheduleSyntheticDownCheck(after: 0.02)
            } else {
                logger.error("Local composer did not become ready; cancelling dictation")
                resetAfterSessionEnd()
                onCancel()
            }
            return
        }
        logger.notice("Local composer is key and ready for Doubao voice input method")
        let route = SyntheticControlRoute.localHIDDictation
        let started = localVoiceKey == .rightOptionTap ? beginHandsFreeShortcut() : postSyntheticControl(down: true, route: route)
        guard started else {
            logger.error("Unable to start local dictation shortcut")
            resetAfterSessionEnd()
            onCancel()
            return
        }
        syntheticDownPosted = true
        syntheticDownAt = Date()
        syntheticRoute = route
        logger.notice("Posted local dictation shortcut to Doubao: \(self.localVoiceKey.rawValue, privacy: .public)")
    }

    private func beginHandsFreeShortcut() -> Bool {
        guard voiceFilter.isEnabled, handsFreeHIDFilter.isEnabled,
              let ticket = handsFree.begin(source: localVoiceSource, post: postHandsFreeEvent) else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.handsFree.completeTap(ticket: ticket, post: self.postHandsFreeEvent)
        }
        return true
    }

    private func postHandsFreeEvent(_ event: CGEvent) {
        // A release or a cancellation can be seconds after these four events
        // were allocated. Give each edge its actual dispatch timestamp.
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.post(tap: .cghidEventTap)
    }

    private func scheduleSyntheticDownCheck(after delay: TimeInterval) {
        syntheticDownWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.postSyntheticDownIfNeeded() }
        syntheticDownWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func finishDictationGesture() {
        let heldLongEnough = syntheticDownPosted && Date().timeIntervalSince(syntheticDownAt ?? .distantPast) >= 0.15
        resetGesture(notifyCancel: false)
        if heldLongEnough {
            logger.notice("Local Doubao voice input method gesture completed; waiting for transcript")
            onRelease()
        } else {
            logger.notice("Local Control released before minimum dictation duration; cancelling")
            onCancel()
        }
    }

    // Local commits, cancellations and timeouts can end the session even if
    // another tap consumed the hardware key-up. Close both halves together.
    func resetAfterSessionEnd(useNonprintingStop: Bool = false) {
        if fallback.phase == .native {
            fallback.abandon()
            clearFallbackWork()
        }
        guard gesture.phase != .idle else { return }
        let stillHeld = leftHardwareDown
        resetGesture(notifyCancel: false, useNonprintingStop: useNonprintingStop)
        if stillHeld {
            waitForHeldKeyRelease = true
            startReleaseWatch(hardwareDown: true)
        }
    }

    private func startReleaseWatch(hardwareDown: Bool) {
        hardwareRelease = HardwareControlRelease()
        _ = hardwareRelease.observe(down: hardwareDown)
        if releaseWatch != nil { return }
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            self?.checkHardwareRelease()
        }
        releaseWatch = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func checkHardwareRelease() {
        guard hardwareRelease.observe(down: leftHardwareDown) else { return }
        recoverHardwareRelease(source: "Quartz polling")
    }

    private func recoverHardwareRelease(source: String) {
        suppressLateRelease = true
        if waitForHeldKeyRelease {
            stopReleaseWatch()
            return
        }
        logger.notice("Recovered hardware left Control release via \(source, privacy: .public), phase=\(String(describing: self.gesture.phase), privacy: .public)")
        if gesture.phase == .dictating {
            finishDictationGesture()
        } else {
            // For a remote chord, the missing physical up must be replaced
            // just like the synthetic down it would normally complete.
            resetGesture(notifyCancel: false)
        }
    }

    private func stopReleaseWatch() {
        releaseWatch?.invalidate()
        releaseWatch = nil
        hardwareRelease = HardwareControlRelease()
        waitForHeldKeyRelease = false
    }

    private func beginPassthroughForChord(proxy: CGEventTapProxy? = nil) {
        guard case .pending = gesture.phase else { return }
        activationWorkItem?.cancel()
        activationWorkItem = nil
        _ = gesture.handle(.otherInput)
        target = nil
        let route = SyntheticControlRoute.remoteHIDPassthrough
        if postSyntheticControl(down: true, route: route, proxy: proxy) {
            syntheticDownPosted = true
            syntheticRoute = route
        } else {
            logger.error("Unable to recover remote Control chord")
        }
    }

    private func resetGesture(notifyCancel: Bool, useNonprintingStop: Bool = false) {
        let wasDictating = gesture.phase == .dictating
        stopReleaseWatch()
        if syntheticDownPosted, let syntheticRoute {
            syntheticDownPosted = false
            if localVoiceKey == .rightOptionTap && syntheticRoute == .localHIDDictation {
                if !handsFreeHIDFilter.isEnabled { _ = handsFreeHIDFilter.start() }
                if !voiceFilter.isEnabled { _ = voiceFilter.start() }
                let canPostSpace = !useNonprintingStop && localComposerReady() && (handsFreeHIDFilter.isEnabled || voiceFilter.isEnabled)
                handsFree.finish(useNonprintingStop: !canPostSpace, post: postHandsFreeEvent)
            } else {
                postSyntheticControl(down: false, route: syntheticRoute)
            }
        }
        activationWorkItem?.cancel()
        syntheticDownWorkItem?.cancel()
        activationWorkItem = nil
        syntheticDownWorkItem = nil
        syntheticDownPosted = false
        syntheticDownAt = nil
        syntheticRoute = nil
        localFocusDeadline = nil
        gesture.reset()
        target = nil
        if notifyCancel && wasDictating { onCancel() }
    }

    static func makeControlEvent(down: Bool, rightControlHeld: Bool) -> CGEvent? {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let event = CGEvent(keyboardEventSource: source,
                  virtualKey: CGKeyCode(leftControlKeyCode), keyDown: down) else { return nil }
        // The keyboard constructor includes the left-device modifier bit.
        // A generic flagsChanged event with only maskControl is insufficient
        // for listeners that distinguish left Control from right Control.
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        if !down && rightControlHeld { event.flags.insert(.maskControl) }
        return event
    }

    @discardableResult
    private func postSyntheticControl(
        down: Bool,
        route: SyntheticControlRoute,
        proxy: CGEventTapProxy? = nil
    ) -> Bool {
        let key = route.key(localVoiceKey: localVoiceKey)
        if key.usesSeparateShortcut && down && !voiceFilter.isEnabled { return false }
        guard let event = key.makeEvent(
            down: down, rightControlHeld: rightControl.isDown, voiceSource: localVoiceSource
        ) else { return false }
        if route == .remoteHIDPassthrough, let proxy {
            event.tapPostEvent(proxy)
        } else {
            event.post(tap: route.eventTapLocation)
        }
        return true
    }
}

enum SyntheticControlRoute: Equatable {
    case remoteHIDPassthrough
    case localHIDDictation

    func key(localVoiceKey: LocalVoiceKey) -> LocalVoiceKey {
        self == .localHIDDictation ? localVoiceKey : .leftControl
    }

    var eventTapLocation: CGEventTapLocation {
        switch self {
        case .remoteHIDPassthrough:
            return .cghidEventTap
        case .localHIDDictation:
            // Doubao 1.0.3 listens at HID, before the session event stream.
            // The caller has already verified that the local composer owns focus.
            return .cghidEventTap
        }
    }
}

enum LocalVoiceKey: String {
    case leftControl
    case fn
    case rightCommand
    case rightOptionTap

    var usesSeparateShortcut: Bool { self != .leftControl }

    private var keyCode: CGKeyCode {
        switch self {
        case .leftControl: return CGKeyCode(kVK_Control)
        case .fn: return CGKeyCode(kVK_Function)
        case .rightCommand: return CGKeyCode(kVK_RightCommand)
        case .rightOptionTap: return CGKeyCode(kVK_RightOption)
        }
    }

    func makeEvent(down: Bool, rightControlHeld: Bool, voiceSource: CGEventSource?) -> CGEvent? {
        let downFlags: CGEventFlags
        switch self {
        case .leftControl:
            return ControlHoldMonitor.makeControlEvent(down: down, rightControlHeld: rightControlHeld)
        case .fn:
            downFlags = .maskSecondaryFn
        case .rightCommand:
            downFlags = [.maskCommand, CGEventFlags(rawValue: UInt64(NX_DEVICERCMDKEYMASK))]
        case .rightOptionTap:
            guard let voiceSource, let event = CGEvent(keyboardEventSource: voiceSource, virtualKey: keyCode, keyDown: down) else { return nil }
            // The private keyboard source constructs the native Option flags,
            // including Quartz's platform bits. The physical left Control
            // belongs to the remote gesture and must never join this shortcut.
            let controlFlags: CGEventFlags = [.maskControl, CGEventFlags(rawValue: UInt64(NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK))]
            event.flags.subtract(controlFlags)
            event.setIntegerValueField(.eventSourceUserData, value: HandsFreeShortcutSession.eventMarker)
            return event
        }
        guard let voiceSource, let event = CGEvent(keyboardEventSource: voiceSource, virtualKey: keyCode, keyDown: down) else { return nil }
        event.type = .flagsChanged
        event.flags = down ? downFlags : []
        event.setIntegerValueField(.eventSourceUserData, value: ControlHoldMonitor.syntheticEventMarker)
        return event
    }

    func filtersEvent(type: CGEventType, event: CGEvent) -> Bool {
        if self == .rightOptionTap {
            guard event.getIntegerValueField(.eventSourceUserData) == HandsFreeShortcutSession.eventMarker else { return false }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            return (type == .flagsChanged && code == Int64(kVK_RightOption)) ||
                   ((type == .keyDown || type == .keyUp) && (code == Int64(kVK_Space) || code == Int64(kVK_F18)))
        }
        return usesSeparateShortcut && type == .flagsChanged &&
        event.getIntegerValueField(.keyboardEventKeycode) == Int64(keyCode) &&
        event.getIntegerValueField(.eventSourceUserData) == ControlHoldMonitor.syntheticEventMarker
    }
}

/// Doubao's hands-free mode uses one short right Option tap to start and a
/// different, ordinary key press to stop. Reserve the stop events before
/// starting so a cancellation can always close the same recording.
final class HandsFreeShortcutSession {
    static let eventMarker: Int64 = 0x4456_4846
    private var generation: UInt64 = 0
    private var optionUp: CGEvent?
    private typealias KeyPair = (down: CGEvent, up: CGEvent)
    private var stopKeys: (space: KeyPair, nonprinting: KeyPair)?

    private func stopPair(keyCode: Int, source: CGEventSource) -> KeyPair? {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false) else { return nil }
        for event in [down, up] {
            event.flags = event.flags.intersection(.maskNonCoalesced)
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        }
        return (down, up)
    }

    func begin(source: CGEventSource?, post: (CGEvent) -> Void) -> UInt64? {
        guard stopKeys == nil, let source,
              let down = LocalVoiceKey.rightOptionTap.makeEvent(down: true, rightControlHeld: false, voiceSource: source),
              let up = LocalVoiceKey.rightOptionTap.makeEvent(down: false, rightControlHeld: false, voiceSource: source),
              let space = stopPair(keyCode: kVK_Space, source: source),
              let nonprinting = stopPair(keyCode: kVK_F18, source: source) else { return nil }
        generation &+= 1
        let ticket = generation
        optionUp = up
        stopKeys = (space, nonprinting)
        post(down)
        return ticket
    }

    func completeTap(ticket: UInt64, post: (CGEvent) -> Void) {
        guard ticket == generation, let up = optionUp else { return }
        optionUp = nil
        post(up)
    }

    func finish(useNonprintingStop: Bool, post: (CGEvent) -> Void) {
        guard let stopKeys else { return }
        self.stopKeys = nil
        completeTap(ticket: generation, post: post)
        let stopPair = useNonprintingStop ? stopKeys.nonprinting : stopKeys.space
        post(stopPair.down)
        post(stopPair.up)
    }
}

/// Doubao observes the shortcut at HID. Block only our marked voice key
/// at the session boundary before it can reach other applications.
private final class SyntheticVoiceKeyFilter {
    private let key: LocalVoiceKey
    private let location: CGEventTapLocation
    private let placement: CGEventTapPlacement
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(key: LocalVoiceKey, location: CGEventTapLocation = .cgSessionEventTap, placement: CGEventTapPlacement = .headInsertEventTap) {
        self.key = key
        self.location = location
        self.placement = placement
    }

    var isEnabled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() -> Bool {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return isEnabled
        }
        var mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        if key == .rightOptionTap {
            mask |= CGEventMask(1) << CGEventType.keyDown.rawValue
            mask |= CGEventMask(1) << CGEventType.keyUp.rawValue
        }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let filter = Unmanaged<SyntheticVoiceKeyFilter>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = filter.tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            } else if filter.key.filtersEvent(type: type, event: event) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: location, place: placement,
                                          options: .defaultTap, eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return isEnabled
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }
}
