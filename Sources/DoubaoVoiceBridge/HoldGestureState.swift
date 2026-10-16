import Foundation

enum HoldGesturePhase: Equatable {
    case idle
    case pending
    case dictating
    case passthrough
}

enum HoldGestureInput {
    case controlDown(targetAvailable: Bool)
    case controlUp
    case otherInput
    case thresholdReached
}

enum HoldGestureEffect: Equatable {
    case suppress
    case passThrough
    case scheduleThreshold
    case synthesizeControlDown
    case beginDictation
    case finishDictation
}

struct HoldGestureState {
    private(set) var phase: HoldGesturePhase = .idle

    mutating func reset() {
        phase = .idle
    }

    mutating func handle(_ input: HoldGestureInput) -> [HoldGestureEffect] {
        switch (phase, input) {
        case (.idle, .controlDown(let targetAvailable)):
            guard targetAvailable else { return [.passThrough] }
            phase = .pending
            return [.suppress, .scheduleThreshold]

        case (.pending, .thresholdReached):
            phase = .dictating
            return [.beginDictation]

        case (.pending, .otherInput):
            phase = .passthrough
            return [.synthesizeControlDown, .passThrough]

        case (.pending, .controlUp):
            phase = .idle
            return [.suppress]

        case (.dictating, .controlUp):
            return [.suppress, .finishDictation]

        case (.passthrough, .controlUp):
            phase = .idle
            return [.passThrough]

        case (.dictating, .otherInput), (.passthrough, .otherInput), (.idle, .otherInput):
            return [.passThrough]

        case (.idle, .controlUp), (.idle, .thresholdReached),
             (.pending, .controlDown), (.dictating, .controlDown),
             (.dictating, .thresholdReached), (.passthrough, .controlDown),
             (.passthrough, .thresholdReached):
            return phase == .dictating ? [.suppress] : [.passThrough]
        }
    }
}

enum FnTogglePhase: Equatable {
    case idle
    case pendingClick
    case starting
    case dictating
    case stopping
}

enum FnToggleInput {
    case fnDown(targetAvailable: Bool, conflictingModifiersPresent: Bool = false)
    case fnUp
    case otherKeyDown
    case otherKeyUp
    case localFnDownPosted
    case localFnTapPosted
    case cancel
}

enum FnToggleEffect: Equatable {
    case suppress
    case passThrough
    case restoreFnPassthrough
    case beginDictation
    case markDictationMayBeActive
    case finishDictation
    case cancelDictation
}

struct FnToggleGestureState {
    private(set) var phase: FnTogglePhase = .idle

    mutating func reset() {
        phase = .idle
    }

    mutating func handle(_ input: FnToggleInput) -> [FnToggleEffect] {
        switch (phase, input) {
        case (.idle, .fnDown(targetAvailable: true, conflictingModifiersPresent: false)):
            phase = .pendingClick
            return [.suppress]
        case (.idle, .fnDown(targetAvailable: false, conflictingModifiersPresent: _)),
             (.idle, .fnDown(targetAvailable: true, conflictingModifiersPresent: true)):
            return [.passThrough]
        case (.pendingClick, .fnUp):
            phase = .starting
            return [.suppress, .beginDictation]
        case (.pendingClick, .otherKeyDown), (.pendingClick, .otherKeyUp):
            phase = .idle
            return [.restoreFnPassthrough, .passThrough]
        case (.pendingClick, .cancel):
            phase = .idle
            return [.passThrough]
        case (.starting, .fnDown), (.starting, .fnUp), (.starting, .otherKeyUp):
            return [.suppress]
        case (.dictating, .fnDown), (.dictating, .otherKeyDown):
            phase = .stopping
            return [.suppress, .finishDictation]
        case (.dictating, .fnUp), (.dictating, .otherKeyUp):
            return [.suppress]
        case (.starting, .localFnTapPosted):
            phase = .dictating
            return []
        case (.starting, .otherKeyDown):
            phase = .idle
            return [.suppress, .cancelDictation]
        case (.starting, .localFnDownPosted):
            return [.markDictationMayBeActive]
        case (.starting, .cancel), (.dictating, .cancel):
            phase = .idle
            return [.cancelDictation]
        case (.stopping, .cancel):
            phase = .idle
            return [.cancelDictation]
        case (.idle, .fnUp), (.idle, .otherKeyDown), (.idle, .otherKeyUp), (.idle, .localFnDownPosted), (.idle, .localFnTapPosted),
             (.idle, .cancel),
             (.pendingClick, .fnDown), (.pendingClick, .localFnDownPosted), (.pendingClick, .localFnTapPosted),
             (.dictating, .localFnDownPosted), (.dictating, .localFnTapPosted),
             (.stopping, .fnDown), (.stopping, .fnUp), (.stopping, .otherKeyDown), (.stopping, .otherKeyUp),
             (.stopping, .localFnDownPosted), (.stopping, .localFnTapPosted):
            return phase == .stopping ? [.suppress] : [.passThrough]
        }
    }
}

struct SuppressedKeyTransitions {
    private var keyCodes: Set<Int64> = []

    func suppressRepeatedKeyDown(_ keyCode: Int64) -> Bool {
        keyCodes.contains(keyCode)
    }

    mutating func suppressThroughKeyUp(_ keyCode: Int64) {
        keyCodes.insert(keyCode)
    }

    mutating func consumeKeyUp(_ keyCode: Int64) -> Bool {
        keyCodes.remove(keyCode) != nil
    }

    mutating func consumeModifierRelease(keyCode: Int64, wasDown: Bool, isDown: Bool) -> Bool {
        !isDown && wasDown && consumeKeyUp(keyCode)
    }

    mutating func removeAll() {
        keyCodes.removeAll()
    }
}

enum FnCompanionKeyEventType {
    case keyDown
    case keyUp
}

struct FnCompanionKeySuppression {
    static let companionKeyCode: Int64 = 179
    static let syntheticSourcePID: Int64 = 0
    static let suppressionWindow: TimeInterval = 0.25
    private static let repeatReleaseGrace: TimeInterval = 2.0

    private var armedUntil: TimeInterval?
    private var suppressedKeyDownIsPending = false
    private var repeatReleaseDeadline: TimeInterval?

    mutating func arm(at time: TimeInterval) {
        armedUntil = time + Self.suppressionWindow
    }

    mutating func disarm() {
        armedUntil = nil
    }

    mutating func shouldSuppress(
        type: FnCompanionKeyEventType,
        keyCode: Int64,
        sourcePID: Int64,
        at time: TimeInterval
    ) -> Bool {
        guard keyCode == Self.companionKeyCode,
              sourcePID == Self.syntheticSourcePID else {
            return false
        }

        switch type {
        case .keyDown:
            if suppressedKeyDownIsPending {
                if let repeatReleaseDeadline, time <= repeatReleaseDeadline {
                    self.repeatReleaseDeadline = time + Self.repeatReleaseGrace
                    return true
                }
                suppressedKeyDownIsPending = false
                repeatReleaseDeadline = nil
            }
            guard let armedUntil, time <= armedUntil else {
                if let armedUntil, time > armedUntil {
                    self.armedUntil = nil
                }
                return false
            }
            suppressedKeyDownIsPending = true
            repeatReleaseDeadline = time + Self.repeatReleaseGrace
            return true
        case .keyUp:
            guard suppressedKeyDownIsPending else { return false }
            guard let repeatReleaseDeadline, time <= repeatReleaseDeadline else {
                suppressedKeyDownIsPending = false
                self.repeatReleaseDeadline = nil
                self.armedUntil = nil
                return false
            }
            suppressedKeyDownIsPending = false
            self.repeatReleaseDeadline = nil
            return true
        }
    }
}
