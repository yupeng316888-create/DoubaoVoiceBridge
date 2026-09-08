import AppKit

/// Runs the real clipboard adapter on private pasteboards; never posts a key.
enum DeliveryPipelineTests {
    private final class Clock {
        var time: TimeInterval = 0
        private var order = 0
        private var jobs: [(TimeInterval, Int, () -> Void)] = []
        func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) {
            order += 1
            jobs.append((time + delay, order, action))
        }
        func advance(to end: TimeInterval) {
            var steps = 0
            while true {
                jobs.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
                guard let next = jobs.first, next.0 <= end else { break }
                jobs.removeFirst()
                time = next.0
                next.2()
                steps += 1
                precondition(steps < 10000, "Delivery timer failed to settle")
            }
            time = end
        }
    }

    private final class Harness {
        let clock = Clock()
        let board = NSPasteboard.withUniqueName()
        lazy var clipboard = OneShotClipboard(pasteboard: board)
        var pipeline: DeliveryPipeline!
        var focus: () -> DeliveryFocusState = { .matching }
        var onStage: (() -> Void)?
        var stageAllowed = true
        var pasteFailure: DeliveryError?
        var doubleCallback = false
        var activations = 0
        var pastes = 0
        var pastedAt: TimeInterval?
        var pastedText: String?
        var results: [Result<Void, Error>] = []

        init() {
            write("old clipboard")
            pipeline = DeliveryPipeline(environment: .init(
                now: { [unowned self] in clock.time },
                schedule: { [unowned self] in clock.schedule($0, $1) },
                activate: { [unowned self] in activations += 1 },
                focus: { [unowned self] in focus() },
                stage: { [unowned self] text in
                    guard stageAllowed else { return false }
                    let ok = clipboard.stage(text)
                    onStage?()
                    return ok
                },
                clipboard: { [unowned self] in clipboard.read(expectedText: $0) },
                paste: { [unowned self] callback in
                    pastes += 1
                    pastedAt = clock.time
                    pastedText = board.string(forType: .string)
                    let result: Result<Void, Error> = pasteFailure.map { .failure($0) } ?? .success(())
                    callback(result)
                    if doubleCallback { callback(result) }
                }
            ), syncDelay: 0.5) { [unowned self] in results.append($0) }
        }
        deinit { board.releaseGlobally() }
        func write(_ text: String) {
            board.prepareForNewContents(with: .currentHostOnly)
            board.setString(text, forType: .string)
        }
        func run() { pipeline.start(text: "听写测试"); clock.advance(to: 8) }
        var succeeded: Bool { results.count == 1 && (try? results[0].get()) != nil }
        var error: DeliveryError? {
            guard results.count == 1, case .failure(let error) = results[0] else { return nil }
            return error as? DeliveryError
        }
    }

    static func run() -> [String] {
        var failures: [String] = []
        var cases = 0
        func check(_ ok: @autoclosure () -> Bool, _ label: String) {
            if !ok() { failures.append("delivery pipeline: \(label)") }
        }

        // Sweep activation timing across the old fixed 0.5-second deadline.
        for index in 0..<61 {
            let h = Harness()
            let delay = Double(index) * 0.025
            h.focus = { [unowned h] in h.clock.time >= delay ? .matching : .transitioning }
            h.run()
            check(h.succeeded && h.pastes == 1 && h.clipboard.writeCount == 1,
                  "delayed activation \(delay) sends exactly once")
            check(h.pastedText == "听写测试" && h.board.string(forType: .string) == "听写测试",
                  "delayed activation \(delay) keeps transcript without old restore")
            cases += 1
        }
        for clearFirst in [false, true] {
            let h = Harness()
            h.onStage = { [unowned h] in
                h.clock.schedule(0.20) {
                    if clearFirst { h.board.clearContents() } else { h.write("听写测试") }
                }
                if clearFirst { h.clock.schedule(0.60) { h.write("听写测试") } }
            }
            h.run()
            check(h.succeeded && h.pastes == 1 && h.clipboard.writeCount == 1,
                  "identical sync rewrite clearFirst=\(clearFirst)")
            cases += 1
        }
        do {
            let h = Harness()
            h.onStage = { [unowned h] in h.clock.schedule(0.25) { h.write("user copied replacement") } }
            h.run()
            check(h.error == .clipboardChanged && h.pastes == 0, "other copied text cancels")
            check(h.board.string(forType: .string) == "user copied replacement", "replacement survives all cleanup timers")
            cases += 1
        }
        do {
            let h = Harness()
            h.onStage = { [unowned h] in h.clock.schedule(0.2) {
                let item = NSPasteboardItem()
                item.setString("听写测试", forType: .string)
                item.setData(Data([1, 2, 3]), forType: .rtf)
                h.board.prepareForNewContents(with: .currentHostOnly)
                h.board.writeObjects([item])
            } }
            h.run()
            check(h.error == .clipboardChanged && h.pastes == 0, "new rich payload is not mistaken for same plain text")
            cases += 1
        }
        for state in [DeliveryFocusState.otherApplication, .otherWindow, .missingOriginalWindow, .closed] {
            let h = Harness()
            h.focus = { state }
            h.run()
            check(h.error != nil && h.pastes == 0 && h.clipboard.writeCount == 0,
                  "invalid initial target \(state) leaves clipboard untouched")
            check(h.board.string(forType: .string) == "old clipboard", "initial focus failure preserves clipboard")
            cases += 1
        }
        for state in [DeliveryFocusState.otherApplication, .otherWindow, .closed] {
            let h = Harness()
            h.onStage = { [unowned h] in h.clock.schedule(0.2) { h.focus = { state } } }
            h.run()
            check(h.error != nil && h.pastes == 0 && h.clipboard.writeCount == 1,
                  "changed target \(state) never receives paste or restores clipboard")
            cases += 1
        }
        do {
            let h = Harness()
            h.focus = { .transitioning }
            h.run()
            check(h.error == .focusTimedOut && h.clipboard.writeCount == 0, "focus wait has a deadline")
            cases += 1
        }
        do {
            let h = Harness()
            h.onStage = { [unowned h] in h.clock.schedule(0.2) { h.board.clearContents() } }
            h.run()
            check(h.error == .clipboardTimedOut && h.pastes == 0 && h.clipboard.writeCount == 1,
                  "empty sync times out without a rewriting loop")
            cases += 1
        }
        do {
            let h = Harness()
            h.doubleCallback = true
            h.pipeline.start(text: "听写测试")
            h.pipeline.start(text: "duplicate request")
            h.clock.advance(to: 8)
            h.pipeline.start(text: "retry finished attempt")
            h.clock.advance(to: 12)
            check(h.succeeded && h.activations == 1 && h.pastes == 1 && h.clipboard.writeCount == 1,
                  "duplicate requests and callbacks do not repeat delivery")
            cases += 1
        }
        for cancelAt in [0.05, 0.30] {
            let h = Harness()
            h.pipeline.start(text: "听写测试")
            h.clock.schedule(cancelAt) { h.pipeline.cancelForTermination() }
            h.clock.advance(to: 8)
            check(h.results.isEmpty && h.pastes == 0 && h.clipboard.writeCount <= 1, "termination cancels pending paste")
            check(h.board.string(forType: .string) == "听写测试",
                  "termination never writes old content back")
            cases += 1
        }
        do {
            let h = Harness()
            h.stageAllowed = false
            h.run()
            check(h.error == .pasteboardUnavailable && h.pastes == 0, "write failure does not send paste")
            cases += 1
        }
        do {
            let h = Harness()
            h.pasteFailure = .modifierKeysActive
            h.run()
            check(h.error == .modifierKeysActive && h.clipboard.writeCount == 1,
                  "keyboard failure does not schedule clipboard restoration")
            cases += 1
        }
        do {
            let h = Harness()
            h.pipeline.start(text: "听写测试")
            h.clock.advance(to: 0.59)
            check(h.succeeded && h.pastes == 1, "focus stability overlaps the 0.5-second sync wait")
            cases += 1
        }
        do {
            let h = Harness()
            h.focus = { [unowned h] in
                h.clock.time >= 0.25 && h.clock.time < 0.55 ? .transitioning : .matching
            }
            h.run()
            check(h.succeeded && (h.pastedAt ?? 0) >= 0.65 && h.clipboard.writeCount == 1,
                  "focus transition during sync must settle again before a single paste")
            cases += 1
        }
        if failures.isEmpty { print("DELIVERY_TEST_OK cases=\(cases) privatePasteboards=true virtualClock=true keysPosted=0") }
        return failures
    }
}
