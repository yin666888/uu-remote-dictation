import Foundation

enum HoldGesturePhase: Equatable {
    case idle, pending, dictating, latched, finishingTap, passthrough

    var isDictating: Bool {
        self == .dictating || self == .latched || self == .finishingTap
    }
}

enum HoldGestureInput {
    case controlDown(targetAvailable: Bool)
    case controlUp, otherInput, thresholdReached
}

enum HoldGestureEffect: Equatable {
    case suppress, passThrough, scheduleThreshold, synthesizeControlDown
    case beginDictation, finishDictation, cancelDictation
}

struct HoldGestureState {
    private(set) var phase: HoldGesturePhase = .idle

    mutating func reset() { phase = .idle }

    mutating func handle(_ input: HoldGestureInput) -> [HoldGestureEffect] {
        switch (phase, input) {
        case (.idle, .controlDown(let available)):
            guard available else { return [.passThrough] }
            phase = .pending
            return [.suppress, .scheduleThreshold]
        case (.pending, .thresholdReached):
            phase = .dictating
            return [.beginDictation]
        case (.pending, .controlUp):
            phase = .latched
            return [.suppress, .beginDictation]
        case (.pending, .otherInput):
            phase = .passthrough
            return [.synthesizeControlDown, .passThrough]
        case (.latched, .controlDown):
            phase = .finishingTap
            return [.suppress]
        case (.finishingTap, .controlUp), (.dictating, .controlUp):
            return [.suppress, .finishDictation]
        case (.latched, .otherInput), (.finishingTap, .otherInput):
            phase = .idle
            return [.cancelDictation, .passThrough]
        case (.dictating, .otherInput):
            return [.passThrough]
        case (.passthrough, .controlUp):
            phase = .idle
            return [.passThrough]
        default:
            return phase.isDictating ? [.suppress] : [.passThrough]
        }
    }
}
