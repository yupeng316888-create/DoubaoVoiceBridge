import Foundation

enum DeliveryFocusState: Equatable {
    case matching, transitioning, otherApplication, otherWindow, missingOriginalWindow, closed
}

struct DeliveryClipboardState {
    let stableRead: Bool
    let originalGeneration: Bool
    let textMatches: Bool
    let onlyPlainText: Bool
    let empty: Bool

    var allowsPaste: Bool {
        ClipboardDeliveryPolicy.allowsPaste(
            stableRead: stableRead, originalGeneration: originalGeneration,
            textMatches: textMatches, onlyPlainText: onlyPlainText
        )
    }
}

/// A single delivery attempt. Tests supply a virtual clock and a private clipboard.
final class DeliveryPipeline {
    struct Environment {
        let now: () -> TimeInterval
        let schedule: (TimeInterval, @escaping () -> Void) -> Void
        let activate: () -> Void
        let focus: () -> DeliveryFocusState
        let stage: (String) -> Bool
        let clipboard: (String) -> DeliveryClipboardState
        let paste: (@escaping (Result<Void, Error>) -> Void) -> Void
    }

    private enum Phase { case idle, focus, clipboard, sending, finished }
    private let environment: Environment
    private let syncDelay: TimeInterval
    private let completion: (Result<Void, Error>) -> Void
    private var phase: Phase = .idle
    private var text = ""
    private var deadline: TimeInterval = 0
    private var readySince: TimeInterval?
    private var stagedAt: TimeInterval = 0
    private var clipboardStableSince: TimeInterval?
    private var sends = 0

    init(environment: Environment, syncDelay: TimeInterval,
         completion: @escaping (Result<Void, Error>) -> Void) {
        self.environment = environment
        self.syncDelay = syncDelay
        self.completion = completion
    }

    func start(text: String) {
        guard phase == .idle else { return }
        guard !text.isEmpty else { finish(.failure(DeliveryError.emptyText)); return }
        self.text = text
        phase = .focus
        environment.activate()
        deadline = environment.now() + 2.0
        tick()
    }

    func cancelForTermination() { phase = .finished; text = "" }

    private func tick() {
        guard phase == .focus || phase == .clipboard else { return }
        let now = environment.now()
        switch environment.focus() {
        case .closed:
            finish(.failure(DeliveryError.targetAppMissing)); return
        case .missingOriginalWindow:
            finish(.failure(DeliveryError.originalWindowUnavailable)); return
        case .otherApplication, .otherWindow:
            finish(.failure(DeliveryError.targetChanged)); return
        case .transitioning:
            readySince = nil
            clipboardStableSince = nil
            if now >= deadline { finish(.failure(DeliveryError.focusTimedOut)); return }
            scheduleNext(); return
        case .matching:
            break
        }

        if readySince == nil { readySince = now }
        if phase == .focus {
            // Once the exact original window matches, synchronization and the
            // stability interval can overlap. Both must still pass before paste.
            guard environment.stage(text) else {
                finish(.failure(DeliveryError.pasteboardUnavailable)); return
            }
            phase = .clipboard
            stagedAt = now
            deadline = now + syncDelay + 1.5
            scheduleNext(); return
        }

        let clipboard = environment.clipboard(text)
        if clipboard.allowsPaste {
            if clipboardStableSince == nil { clipboardStableSince = now }
            if now - stagedAt >= syncDelay && now - (clipboardStableSince ?? now) >= 0.10 &&
                now - (readySince ?? now) >= 0.10 {
                guard sends == 0 else { return }
                sends += 1
                phase = .sending
                environment.paste { [weak self] result in self?.finish(result) }
                return
            }
        } else if !clipboard.stableRead || clipboard.empty {
            // A synchronizer may briefly clear before writing. Wait, never rewrite.
            clipboardStableSince = nil
        } else {
            finish(.failure(DeliveryError.clipboardChanged)); return
        }
        if now >= deadline { finish(.failure(DeliveryError.clipboardTimedOut)); return }
        scheduleNext()
    }

    private func scheduleNext() {
        environment.schedule(0.05) { [weak self] in self?.tick() }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard phase != .finished else { return }
        phase = .finished
        text = ""
        completion(result)
    }
}
