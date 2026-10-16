import AppKit

enum DeliverySelfTests {
    static func run() -> [String] {
        var failures: [String] = []
        for republish in [false, true] {
            failures.append(contentsOf: runScenario(republish: republish))
        }
        failures.append(contentsOf: runScenario(republish: true, replacement: "a later user copy"))
        failures.append(contentsOf: runScenario(republish: false, windowMatches: false))
        failures.append(contentsOf: runScenario(republish: false, appTerminated: true))
        failures.append(contentsOf: runActivationScenario(becomesActive: true))
        failures.append(contentsOf: runActivationScenario(becomesActive: false))
        failures.append(contentsOf: runActivationScenario(becomesActive: true, delayedWindow: true))
        failures.append(contentsOf: runScenario(republish: false, copyAfterPaste: true))
        return failures
    }

    private static func runScenario(
        republish: Bool, replacement: String? = nil,
        windowMatches: Bool = true, appTerminated: Bool = false,
        copyAfterPaste: Bool = false
    ) -> [String] {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let suite = "DoubaoVoiceBridge.DeliveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "restoreClipboard")
        defaults.set(0.5, forKey: "pasteDelay")
        board.setString("original", forType: .string)
        let target = DeliveryTestTarget()
        var pending: [() -> Void] = []
        var pasteCount = 0
        var failure: Error?
        var completed = false
        var cleanupCount = 0
        var hidden = false
        var activatedBeforeStaging = false
        target.onActivate = { activatedBeforeStaging = board.string(forType: .string) == "original" }
        let delivery = UURemoteDelivery(
            pasteboard: board, defaults: defaults,
            accessibilityGranted: { true }, frontmostPID: { target.processIdentifier },
            schedule: { _, work in pending.append(work) },
            postPaste: { validate, completion in
                if let error = validate() { completion(.failure(error)); return }
                pasteCount += 1
                completion(.success(()))
            }
        )
        delivery.deliver(text: "voice bridge fixture", to: target, panelWillHide: { hidden = true }, completion: {
            completed = true
            if case .failure(let error) = $0 { failure = error }
        }, cleanupCompletion: { cleanupCount += 1 })
        // A clipboard bridge can republish identical text in a new pasteboard
        // generation while synchronizing. Exercise the real deliver callback.
        if republish {
            board.clearContents()
            board.setString(replacement ?? "voice bridge fixture", forType: .string)
        }
        target.windowMatches = windowMatches
        target.isTerminated = appTerminated
        if !pending.isEmpty { pending.removeFirst()() }
        var failures: [String] = []
        let shouldPaste = replacement == nil && windowMatches && !appTerminated
        if shouldPaste && (pasteCount != 1 || !completed || failure != nil) {
            failures.append("same transcript republished during sync must still paste into unchanged UU target; pasteCount=\(pasteCount) error=\(failure?.localizedDescription ?? "none")")
        }
        if !shouldPaste && (pasteCount != 0 || failure == nil) {
            failures.append("changed clipboard or target must cancel paste")
        }
        if replacement != nil, failure as? DeliveryError != .clipboardChanged {
            failures.append("clipboard replacement must not be mislabeled as a focus failure")
        }
        if copyAfterPaste { board.clearContents(); board.setString("new copy after paste", forType: .string) }
        while !pending.isEmpty { pending.removeFirst()() }
        let expectedClipboard = copyAfterPaste ? "new copy after paste" : republish ? replacement ?? "voice bridge fixture" : "original"
        if board.string(forType: .string) != expectedClipboard {
            failures.append("restore must keep later clipboard generations and restore only the bridge-owned generation")
        }
        if cleanupCount != 1 || !hidden || target.activationCount != 1 {
            failures.append("delivery must activate target, hide composer and clean up exactly once")
        }
        if !activatedBeforeStaging {
            failures.append("UU activation must precede publishing the transcript for clipboard synchronization")
        }
        return failures
    }

    private static func runActivationScenario(becomesActive: Bool, delayedWindow: Bool = false) -> [String] {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("activation original", forType: .string)
        let suite = "DoubaoVoiceBridge.ActivationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "restoreClipboard")
        let target = DeliveryTestTarget()
        target.windowMatches = !delayedWindow
        var activePID: pid_t? = delayedWindow ? target.processIdentifier : nil
        var pending: [() -> Void] = []
        var pasteCount = 0
        var cleanupCount = 0
        var completionCount = 0
        var error: Error?
        let delivery = UURemoteDelivery(
            pasteboard: board, defaults: defaults, accessibilityGranted: { true },
            frontmostPID: { activePID }, schedule: { _, work in pending.append(work) },
            postPaste: { validate, done in
                if let value = validate() { done(.failure(value)); return }
                pasteCount += 1; done(.success(()))
            }
        )
        delivery.deliver(text: "activation fixture", to: target, panelWillHide: {}, completion: {
            completionCount += 1
            if case .failure(let value) = $0 { error = value }
        }, cleanupCompletion: { cleanupCount += 1 })
        var failures: [String] = []
        if board.string(forType: .string) != "activation original" {
            failures.append("clipboard must remain untouched until UU is active")
        }
        if becomesActive { activePID = target.processIdentifier }
        target.windowMatches = true
        while !pending.isEmpty { pending.removeFirst()() }
        if pasteCount != (becomesActive ? 1 : 0) || completionCount != 1 || cleanupCount != 1 {
            failures.append("bounded activation must paste once when ready, otherwise fail and clean up once")
        }
        if !becomesActive && (error as? DeliveryError != .targetChanged || board.string(forType: .string) != "activation original") {
            failures.append("activation timeout must preserve clipboard and report target change")
        }
        return failures
    }
}

private final class DeliveryTestTarget: RemoteDeliveryTarget {
    var isTerminated = false
    var windowMatches = true
    var activationCount = 0
    var onActivate: (() -> Void)?
    let processIdentifier: pid_t = 12345
    func activateOriginalWindow() { activationCount += 1; onActivate?() }
    func stillMatchesFocusedWindow() -> Bool { windowMatches }
}
