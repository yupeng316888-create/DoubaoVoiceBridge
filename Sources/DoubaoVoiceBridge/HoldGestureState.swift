import Foundation

enum HoldGesturePhase: Equatable {
    case idle
    case pending
    case dictating
    case passthrough
}

enum HoldGestureInput {
    case fnDown(targetAvailable: Bool)
    case fnUp
    case otherInput
    case thresholdReached
}

enum HoldGestureEffect: Equatable {
    case suppress
    case passThrough
    case scheduleThreshold
    case synthesizeFnDown
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
        case (.idle, .fnDown(let targetAvailable)):
            guard targetAvailable else { return [.passThrough] }
            phase = .pending
            return [.suppress, .scheduleThreshold]

        case (.pending, .thresholdReached):
            phase = .dictating
            return [.beginDictation]

        case (.pending, .otherInput):
            phase = .passthrough
            return [.synthesizeFnDown, .passThrough]

        case (.pending, .fnUp):
            phase = .idle
            return [.synthesizeFnDown, .passThrough]

        case (.dictating, .fnUp):
            return [.suppress, .finishDictation]

        case (.passthrough, .fnUp):
            phase = .idle
            return [.passThrough]

        case (.dictating, .otherInput), (.passthrough, .otherInput), (.idle, .otherInput):
            return [.passThrough]

        case (.idle, .fnUp), (.idle, .thresholdReached),
             (.pending, .fnDown), (.dictating, .fnDown),
             (.dictating, .thresholdReached), (.passthrough, .fnDown),
             (.passthrough, .thresholdReached):
            return phase == .dictating ? [.suppress] : [.passThrough]
        }
    }
}
