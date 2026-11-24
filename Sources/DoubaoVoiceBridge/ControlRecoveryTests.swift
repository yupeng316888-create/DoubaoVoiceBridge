import CoreGraphics
import IOKit.hidsystem

enum ControlRecoveryTests {
    static func run() -> [String] {
        var failures = [String]()
        func expect(_ value: Bool, _ message: String) {
            if !value { failures.append(message) }
        }

        let left = CGEventFlags(rawValue: UInt64(NX_DEVICELCTLKEYMASK)).union(.maskControl)
        let right = CGEventFlags(rawValue: UInt64(NX_DEVICERCTLKEYMASK)).union(.maskControl)
        expect(ControlKeySide.left.isDown(flags: left, otherSideDown: false, hardwareDown: false), "left device flag is down")
        expect(!ControlKeySide.left.isDown(flags: right, otherSideDown: true, hardwareDown: true), "release left while right is held")
        expect(ControlKeySide.right.isDown(flags: right, otherSideDown: false, hardwareDown: false), "right device flag is down")
        expect(!ControlKeySide.right.isDown(flags: left, otherSideDown: true, hardwareDown: false), "release right while left is held")
        expect(ControlKeySide.right.isDown(flags: right.union(left), otherSideDown: true, hardwareDown: false), "both controls held")
        expect(ControlKeySide.left.isDown(flags: .maskControl, otherSideDown: false, hardwareDown: false), "virtual generic ctrl down")
        expect(!ControlKeySide.left.isDown(flags: [], otherSideDown: false, hardwareDown: true), "key up reports actual event")
        expect(!ControlKeySide.left.isDown(flags: .maskControl, otherSideDown: true, hardwareDown: false), "generic mask with other control held")
        expect(ControlKeySide.left.isDown(flags: .maskControl, otherSideDown: true, hardwareDown: true), "generic mask with both physical controls held")

        var other = RightControlState()
        other.updateRightEvent(flags: right, leftHardwareDown: false, rightHardwareDown: true)
        other.reconcileLeftEvent(flags: left, rightHardwareDown: false)
        expect(!other.isDown, "left-only device flag recovers missing right release")
        other.updateRightEvent(flags: .maskControl, leftHardwareDown: false, rightHardwareDown: true)
        other.reconcileLeftEvent(flags: .maskControl, rightHardwareDown: false)
        expect(!other.isDown, "physical snapshot recovers missing generic hardware right release")
        other.updateRightEvent(flags: .maskControl, leftHardwareDown: false, rightHardwareDown: false)
        other.reconcileLeftEvent(flags: .maskControl, rightHardwareDown: false)
        expect(other.isDown, "generic virtual right control stays held during a virtual two-key chord")
        other.reconcileLeftEvent(flags: [], rightHardwareDown: false)
        expect(!other.isDown, "clearing generic control flags ends a virtual two-key chord")

        var watch = HardwareControlRelease()
        var intercepted = HoldGestureState()
        func canFinish(_ down: Bool, waiting: Bool = false) -> Bool {
            HardwareControlRelease.canFinishInterceptedHold(down: down, phase: intercepted.phase, waitingForRelease: waiting)
        }
        expect(!canFinish(true) && !canFinish(false), "passive hardware press and release cannot initiate split dictation")
        _ = intercepted.handle(.controlDown(targetAvailable: true))
        expect(!canFinish(true) && canFinish(false), "only hardware release can close an intercepted short press")
        _ = intercepted.handle(.thresholdReached)
        expect(!canFinish(true) && canFinish(false), "IOHID release closes dictation even when Quartz polling never saw down")
        intercepted.reset()
        expect(!canFinish(false), "a second release after finishing cannot deliver again")
        expect(canFinish(false, waiting: true) && !canFinish(true, waiting: true), "IOHID releases the canceled hold lockout")
        _ = intercepted.handle(.controlDown(targetAvailable: true))
        _ = intercepted.handle(.otherInput)
        expect(!canFinish(false), "hardware release leaves passthrough chords to Quartz")
        let samples = [false, false, true, false, true, false, false, false, true, false, false]
        let expected = [false, false, false, false, false, false, true, false, false, false, true]
        expect(samples.map { watch.observe(down: $0) } == expected,
               "wait for a hardware press, tolerate a single stale sample, emit each missing release once")
        var fallback = PhysicalFallbackGate()
        expect(fallback.quartzPress(), "Quartz-first press remains primary")
        expect(!fallback.physicalPress(eligible: true), "same hardware press cannot open a second panel")
        expect(!fallback.beginNative(stillEligible: true), "primary press never starts native fallback")
        fallback.quartzRelease()
        expect(!fallback.physicalRelease(), "primary release is not finalized twice")

        expect(fallback.physicalPress(eligible: true), "hardware-first press arms fallback")
        expect(fallback.quartzPress(), "timely Quartz intercept wins after hardware down")
        expect(!fallback.beginNative(stillEligible: true), "overlapping channels share one press")
        _ = fallback.physicalRelease()
        fallback.quartzRelease()

        expect(fallback.physicalPress(eligible: true), "arm hardware-only press")
        expect(!fallback.physicalPress(eligible: true), "duplicate hardware down does not rearm")
        expect(fallback.beginNative(stillEligible: true), "single sustained hardware-only press starts native")
        expect(!fallback.beginNative(stillEligible: true), "native composer begins only once")
        expect(!fallback.quartzPress(), "late Quartz down passes through to native input")
        fallback.quartzRelease()
        expect(fallback.physicalRelease(), "hardware up completes native path once")
        expect(!fallback.physicalRelease(), "duplicate hardware up cannot complete twice")

        _ = fallback.physicalPress(eligible: true)
        expect(!fallback.physicalRelease() && !fallback.beginNative(stillEligible: true), "quick tap never opens native panel")
        _ = fallback.physicalPress(eligible: true)
        fallback.abandon()
        expect(!fallback.beginNative(stillEligible: true) && !fallback.quartzPress(), "chord or focus change cancels candidate for rest of press")
        _ = fallback.physicalRelease()
        _ = fallback.physicalPress(eligible: true)
        expect(!fallback.beginNative(stillEligible: false), "changed hardware counts cannot open a composer")
        _ = fallback.physicalRelease()
        expect(!fallback.physicalPress(eligible: false) && !fallback.quartzPress(), "native local left Control passes unchanged")
        _ = fallback.physicalRelease()
        _ = fallback.physicalPress(eligible: true)
        _ = fallback.beginNative(stillEligible: true)
        fallback.abandon()
        expect(!fallback.physicalRelease(), "manual completion will not submit twice on release")
        var rearm = NativeControlRearm()
        let first = rearm.begin()
        expect(rearm.focused(first, empty: true) && rearm.postedFlags == 1, "empty focused first hold emits one neutral up")
        expect(!rearm.focused(first, empty: true), "repeated focus callback cannot emit a second neutral up")
        expect(rearm.freshDown(first, empty: true) && rearm.postedFlags == 2, "fresh down belongs to same physical hold")
        expect(!rearm.freshDown(first, empty: true), "duplicate timer cannot restart twice")
        expect(rearm.finish() && !rearm.finish(), "real release pairs fresh down exactly once")

        let early = rearm.begin()
        expect(!rearm.finish() && !rearm.focused(early, empty: true), "release before local focus cannot post either event")
        let gap = rearm.begin()
        _ = rearm.focused(gap, empty: true)
        expect(!rearm.finish() && !rearm.freshDown(gap, empty: true), "release or cancellation during gap cannot post late down")
        let next = rearm.begin()
        expect(!rearm.focused(gap, empty: true), "stale focus callback cannot attach to a consecutive hold")
        expect(rearm.focused(next, empty: true) && !rearm.freshDown(gap, empty: true), "stale delayed down cannot attach to a consecutive hold")
        expect(!rearm.freshDown(next, empty: false) && !rearm.finish(), "input arriving in gap preserves native transcript without another down/up")
        let live = rearm.begin()
        expect(!rearm.focused(live, empty: false) && !rearm.finish(), "already-recognizing composer is not restarted")

        return failures
    }
}
