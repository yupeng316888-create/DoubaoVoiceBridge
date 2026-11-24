import Foundation

enum TapOrderRecoveryTests {
    static func run() -> [String] {
        var failures: [String] = []
        var recovery = TapOrderRecovery()
        func audit(_ time: TimeInterval, lost: Bool = true, uu: pid_t = 10, ime: pid_t = 20) -> Bool {
            recovery.shouldReinstall(needsReinstall: lost, uuPID: uu, inputMethodPID: ime, now: time)
        }

        // Model new-tap notifications and ordinary focus changes. A moment
        // at the head before the IME moves back must not rearm the fast retry.
        var reinstalls: [Int] = []
        for tick in 0...1_850 {
            let now = Double(tick) / 10
            if tick % 10 == 1 { _ = audit(now, lost: false) }
            if audit(now) { reinstalls.append(tick) }
        }
        if reinstalls != [0, 50, 950, 1_850] {
            failures.append("Persistent keyboard tap contention caused a retry storm or permanent suppression")
        }
        if !audit(186, ime: 21) || !audit(187, uu: 11, ime: 21) {
            failures.append("A restarted UU or input method inherited another process's cooldown")
        }
        _ = audit(192, uu: 11, ime: 21) // second attempt puts the pair into slow recovery
        for tick in 193...223 { _ = audit(Double(tick), lost: false, uu: 11, ime: 21) }
        if !audit(224, uu: 11, ime: 21) {
            failures.append("A new tap order change after stable recovery did not trigger an immediate repair")
        }
        return failures
    }
}
