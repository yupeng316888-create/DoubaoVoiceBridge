import Carbon.HIToolbox
import CoreGraphics
import IOKit.hidsystem

enum HandsFreeShortcutTests {
    static func run() -> [String] {
        var failures = [String]()
        func expect(_ value: Bool, _ message: String) {
            if !value { failures.append(message) }
        }
        guard let source = CGEventSource(stateID: .privateState) else { return ["hands-free event source"] }
        source.keyboardType = 47
        let shortcut = LocalVoiceKey.rightOptionTap
        let filter = { (event: CGEvent) in shortcut.filtersEvent(type: event.type, event: event) }
        let session = HandsFreeShortcutSession()
        var events = [CGEvent]()
        let post = { (event: CGEvent) in events.append(event) }
        let codes = { events.map { Int($0.getIntegerValueField(.keyboardEventKeycode)) } }
        expect(shortcut.rawValue == "rightOptionTap" && shortcut.usesSeparateShortcut, "hands-free preference selects the intercepted route")
        expect(SyntheticControlRoute.remoteHIDPassthrough.key(localVoiceKey: shortcut) == .leftControl, "hands-free preserves remote Control chords")
        expect(session.begin(source: nil, post: post) == nil && events.isEmpty, "unavailable source emits no partial start")
        session.finish(useNonprintingStop: false, post: post)
        expect(events.isEmpty, "cancel before start emits no stop")

        guard let first = session.begin(source: source, post: post) else { return failures + ["hands-free start"] }
        expect(session.begin(source: source, post: post) == nil, "repeated begin during a tap is ignored")
        session.completeTap(ticket: first, post: post)
        session.completeTap(ticket: first, post: post)
        expect(codes() == [kVK_RightOption, kVK_RightOption], "one complete right Option tap starts listening")
        session.finish(useNonprintingStop: false, post: post)
        session.finish(useNonprintingStop: true, post: post)
        expect(codes() == [kVK_RightOption, kVK_RightOption, kVK_Space, kVK_Space], "normal release posts one stop without retriggering Option")
        expect(events.map(\.type) == [.flagsChanged, .flagsChanged, .keyDown, .keyUp], "hands-free start and stop use native event types")
        guard events.count == 4 else { return failures }
        let nativeDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_RightOption), keyDown: true)
        let nativeUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_RightOption), keyDown: false)
        let rightOption: CGEventFlags = [.maskAlternate, CGEventFlags(rawValue: UInt64(NX_DEVICERALTKEYMASK))]
        expect(events[0].flags == nativeDown?.flags && events[1].flags == nativeUp?.flags, "right Option preserves Quartz's native flags on both edges")
        expect(events[0].flags.contains(rightOption) && events[1].flags.intersection(rightOption).isEmpty, "the right Option bits change together")
        let modifiers: CGEventFlags = [.maskControl, .maskShift, .maskAlternate, .maskCommand, .maskSecondaryFn]
        expect(events.suffix(2).allSatisfy { $0.flags.intersection(modifiers).isEmpty }, "stop never inherits physical modifiers")
        expect(events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeyboardType) == 47 }, "all edges retain the same event source keyboard")
        expect(events.allSatisfy(filter), "all marked start and stop edges are consumed")
        for event in events {
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let down = event.type == .keyDown || event.flags.contains(.maskAlternate)
            guard let real = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down),
                  let other = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down),
                  let unrelated = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: down) else {
                return failures + ["construct independent keyboard events"]
            }
            expect(!filter(real), "real Option and Space must pass")
            other.setIntegerValueField(.eventSourceUserData, value: ControlHoldMonitor.syntheticEventMarker)
            expect(!filter(other), "other bridge operations must pass")
            unrelated.setIntegerValueField(.eventSourceUserData, value: HandsFreeShortcutSession.eventMarker)
            expect(!filter(unrelated), "unrelated key codes must pass")
        }

        events.removeAll()
        guard let second = session.begin(source: source, post: post) else { return failures + ["second hands-free start"] }
        session.completeTap(ticket: first, post: post)
        expect(events.count == 1, "stale timer cannot release the next trigger")
        session.finish(useNonprintingStop: true, post: post)
        session.completeTap(ticket: second, post: post)
        session.finish(useNonprintingStop: false, post: post)
        expect(codes() == [kVK_RightOption, kVK_RightOption, kVK_F18, kVK_F18], "cancel during the opening tap closes it before one nonprinting stop")
        expect(events.map(\.type) == [.flagsChanged, .flagsChanged, .keyDown, .keyUp] && events.allSatisfy(filter), "both nonprinting stop edges are filtered")
        return failures
    }
}
