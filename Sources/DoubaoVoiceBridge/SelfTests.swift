import Foundation
import CoreGraphics
import AppKit

enum SelfTests {
    static func run() -> Bool {
        var failures = DeliverySelfTests.run()

        func check<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
            if actual != expected {
                failures.append("\(label): expected \(expected), got \(actual)")
            }
        }

        do {
            let rightOption = KeyboardShortcut(keyCode: 61)
            let toggle = DoubaoShortcutConfiguration.manual(.fnToggle, shortcut: rightOption)
            let independent = BridgeShortcutConfiguration(kind: .customHold, shortcut: rightOption)
            let holdCopy = ShortcutUsageCopy.make(doubao: toggle, bridge: independent)
            check(holdCopy.title, "在 UU 中按住 右 ⌥ 说话", "independent remote Option requires holding even when Doubao is click-to-start")
            check(holdCopy.detail.hasPrefix("松开"), true, "hold instruction describes release")
            let recordedCases: [(KeyboardShortcut, String)] = [
                (KeyboardShortcut(keyCode: 58), "左 ⌥"),
                (KeyboardShortcut(keyCode: 97), "F6"),
                (KeyboardShortcut(keyCode: 2, modifierMask: CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue), "⌃⇧D")
            ]
            for (shortcut, name) in recordedCases {
                let custom = BridgeShortcutConfiguration(kind: .customHold, shortcut: shortcut)
                let copy = ShortcutUsageCopy.make(doubao: toggle, bridge: custom)
                check(copy.title, "在 UU 中按住 \(name) 说话", "usage follows the user's recorded remote key")
                check(copy.detail, holdCopy.detail, "changing a recorded key preserves the remote hold interaction")
            }
            let recordedDoubao = DoubaoShortcutConfiguration.manual(.fnToggle, shortcut: KeyboardShortcut(keyCode: 97))
            check(ShortcutUsageCopy.make(doubao: recordedDoubao, bridge: .followDoubao).title,
                  "在 UU 中点按 F6 开始", "follow usage updates when the recorded Doubao key changes")
            let followCopy = ShortcutUsageCopy.make(doubao: toggle, bridge: .followDoubao)
            check(followCopy.title, "在 UU 中点按 右 ⌥ 开始", "explicit follow mode retains click-to-start")
            check(followCopy.detail.hasPrefix("按任意键"), true, "toggle instruction describes its actual stop action")
            check(ShortcutUsageCopy.make(doubao: nil, bridge: independent).title, "先设置语音按键", "missing configuration never advertises a usable shortcut")
        }

        do {
            var state = HoldGestureState()
            check(state.handle(.controlDown(targetAvailable: true)), [.suppress, .scheduleThreshold], "long hold down")
            check(state.phase, .pending, "long hold pending")
            check(state.handle(.thresholdReached), [.beginDictation], "long hold threshold")
            check(state.phase, .dictating, "long hold dictating")
            check(state.handle(.controlUp), [.suppress, .finishDictation], "long hold release")
            state.reset()
            check(state.phase, .idle, "long hold idle")
        }

        do {
            var state = HoldGestureState()
            _ = state.handle(.controlDown(targetAvailable: true))
            check(state.handle(.otherInput), [.synthesizeControlDown, .passThrough], "chord recovery")
            check(state.phase, .passthrough, "chord passthrough")
            check(state.handle(.controlUp), [.passThrough], "chord release")
            check(state.phase, .idle, "chord idle")
        }

        do {
            var state = HoldGestureState()
            check(state.handle(.controlDown(targetAvailable: false)), [.passThrough], "non-UU down")
            check(state.phase, .idle, "non-UU idle")
            check(state.handle(.controlUp), [.passThrough], "non-UU release")
        }

        do {
            var state = FnToggleGestureState()
            check(
                state.handle(.fnDown(targetAvailable: false, conflictingModifiersPresent: false)),
                [.passThrough],
                "Fn shortcut passes through without a valid UU target"
            )
            check(
                state.handle(.fnDown(targetAvailable: true, conflictingModifiersPresent: true)),
                [.passThrough],
                "Fn pressed after a modifier passes through as a native chord"
            )
            check(state.phase, .idle, "modifier chord leaves Fn state idle")
            check(
                state.handle(.fnDown(targetAvailable: true, conflictingModifiersPresent: false)),
                [.suppress],
                "Fn down waits for release to distinguish a click from a chord"
            )
            check(state.phase, .pendingClick, "Fn press remains pending until physical release")
            check(
                state.handle(.otherKeyDown),
                [.restoreFnPassthrough, .passThrough],
                "Fn plus another key restores the Fn modifier and passes the key through"
            )
            check(state.phase, .idle, "native Fn chord leaves toggle state idle")
            _ = state.handle(.fnDown(targetAvailable: true, conflictingModifiersPresent: false))
            check(
                state.handle(.otherKeyUp),
                [.restoreFnPassthrough, .passThrough],
                "a key released after Fn went down aborts the pending click and passes its release"
            )
            check(state.phase, .idle, "pre-existing key release leaves Fn idle")
            check(state.handle(.fnUp), [.passThrough], "the later physical Fn release stays native after the chord abort")
            check(state.phase, .idle, "an aborted Fn chord cannot start dictation on release")
            _ = state.handle(.fnDown(targetAvailable: true, conflictingModifiersPresent: false))
            check(
                state.handle(.fnUp),
                [.suppress, .beginDictation],
                "Fn release confirms a standalone click and begins dictation"
            )
            check(state.phase, .starting, "Fn stays starting until local tap posts")
            check(state.handle(.fnUp), [.suppress], "Fn trigger release does not finish dictation")
            check(state.phase, .starting, "Fn release leaves the toggle session active")
            check(
                state.handle(.localFnDownPosted),
                [.markDictationMayBeActive],
                "cancellation treats the interval after synthetic Fn down as possibly recording"
            )
            check(state.phase, .starting, "synthetic Fn down keeps the gesture in its start phase")
            check(state.handle(.localFnTapPosted), [], "local Fn tap activates Doubao")
            check(state.phase, .dictating, "Fn local tap enters dictation")
            check(state.handle(.fnUp), [.suppress], "Fn release during toggle dictation does not finish it")
            check(state.phase, .dictating, "Fn release preserves active toggle dictation")
            check(state.handle(.otherKeyDown), [.suppress, .finishDictation], "any key ends Fn dictation")
            check(state.phase, .stopping, "Fn any-key stop enters stopping state")
            _ = state.handle(.cancel)
            check(state.phase, .idle, "Fn cancellation returns to idle")
        }

        do {
            var suppressed = SuppressedKeyTransitions()
            check(suppressed.suppressRepeatedKeyDown(49), false, "stop-key first down is handled by the gesture")
            suppressed.suppressThroughKeyUp(49)
            check(suppressed.suppressRepeatedKeyDown(49), true, "held stop key repeat down stays suppressed")
            check(suppressed.consumeKeyUp(49), true, "stop-key release is consumed")
            check(suppressed.suppressRepeatedKeyDown(49), false, "keydown passes after paired release")
            suppressed.suppressThroughKeyUp(56)
            check(
                suppressed.consumeModifierRelease(keyCode: 56, wasDown: true, isDown: false),
                true,
                "modifier stop release is consumed from flagsChanged"
            )
            check(suppressed.suppressRepeatedKeyDown(56), false, "modifier release clears suppressed state")
        }

        do {
            var state = FnToggleGestureState()
            var companion = FnCompanionKeySuppression()
            companion.arm(at: 100.0)
            _ = state.handle(.fnDown(targetAvailable: true))
            _ = state.handle(.fnUp)
            check(state.phase, .starting, "recorded Fn click reaches startup before companion event")

            let startEventSuppressed = companion.shouldSuppress(
                type: .keyDown,
                keyCode: 179,
                sourcePID: 0,
                at: 100.011
            )
            check(startEventSuppressed, true, "source-PID-0 key 179 in the Fn startup window is suppressed")
            if !startEventSuppressed {
                _ = state.handle(.otherKeyDown)
            }
            check(state.phase, .starting, "key 179 companion must not cancel the recorded Fn startup")
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 100.30),
                true,
                "key 179 repeats remain suppressed until its matching release"
            )
            check(
                companion.shouldSuppress(type: .keyUp, keyCode: 179, sourcePID: 0, at: 100.31),
                true,
                "matching key 179 release is suppressed even after the initial window"
            )
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 100.32),
                false,
                "key 179 is not permanently swallowed after its paired release"
            )

            companion.arm(at: 150.0)
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 150.01),
                true,
                "source-PID-0 companion down starts a paired suppression"
            )
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 152.02),
                false,
                "unpaired key 179 cannot remain suppressed indefinitely"
            )

            companion.arm(at: 200.0)
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 123, sourcePID: 0, at: 200.01),
                false,
                "Fn plus Arrow remains eligible for native chord passthrough"
            )
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 42, at: 200.01),
                false,
                "key 179 from a non-system source is not suppressed"
            )
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 200.26),
                false,
                "key 179 is not suppressed outside the bounded Fn window"
            )

            companion.arm(at: 225.0)
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 225.01),
                true,
                "swallowed key down starts its matching-release guard"
            )
            companion.disarm()
            check(
                companion.shouldSuppress(type: .keyUp, keyCode: 179, sourcePID: 0, at: 225.02),
                true,
                "disarming the trigger window preserves the matching swallowed key-up"
            )

            state.reset()
            companion.arm(at: 250.0)
            _ = state.handle(.fnDown(targetAvailable: true))
            check(state.handle(.otherKeyDown), [.restoreFnPassthrough, .passThrough], "Fn chord abort restores native passthrough")
            companion.disarm()
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 250.01),
                false,
                "key 179 passes after a native chord abort disarms the pending click window"
            )

            companion.arm(at: 275.0)
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 275.01),
                true,
                "companion key down begins a bounded key-up suppression"
            )
            check(
                companion.shouldSuppress(type: .keyUp, keyCode: 179, sourcePID: 0, at: 277.02),
                false,
                "key-up after the two-second pairing grace is passed and clears pending state"
            )
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 277.03),
                false,
                "expired key-up pairing leaves no stale suppression state"
            )

            state.reset()
            _ = state.handle(.fnDown(targetAvailable: true))
            _ = state.handle(.fnUp)
            _ = state.handle(.localFnDownPosted)
            _ = state.handle(.localFnTapPosted)
            check(state.phase, .dictating, "Fn stop test reaches dictating")
            _ = state.handle(.fnDown(targetAvailable: true))
            companion.arm(at: 300.0)
            state.reset()
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 300.02),
                true,
                "key 179 companion immediately after the Fn stop is suppressed"
            )
        }

        do {
            var state = HoldGestureState()
            _ = state.handle(.controlDown(targetAvailable: true))
            check(state.handle(.controlUp), [.suppress], "quick tap")
            check(state.phase, .idle, "quick tap idle")
        }

        do {
            let flagsMask = CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue)
            let uu = InstalledEventTap(
                processIdentifier: 100,
                location: CGEventTapLocation.cghidEventTap.rawValue,
                options: CGEventTapOptions.defaultTap.rawValue,
                eventMask: flagsMask,
                isEnabled: true
            )
            let bridge = InstalledEventTap(
                processIdentifier: 200,
                location: CGEventTapLocation.cghidEventTap.rawValue,
                options: CGEventTapOptions.defaultTap.rawValue,
                eventMask: flagsMask,
                isEnabled: true
            )
            check(
                UURemoteTapOrder.needsReinstall(taps: [uu, bridge], bridgePID: 200, uuRemotePID: 100),
                true,
                "UU tap ahead requires reinstall"
            )
            check(
                UURemoteTapOrder.needsReinstall(taps: [bridge, uu], bridgePID: 200, uuRemotePID: 100),
                false,
                "bridge tap ahead stays installed"
            )
            check(
                UURemoteActivationAudit.delay(previousPID: 100, activatedPID: 100),
                0.25,
                "same-PID UU activation is audited"
            )
            check(
                UURemoteActivationAudit.delay(previousPID: 100, activatedPID: 101),
                0.8,
                "new-PID UU launch gets settle time"
            )
        }

        do {
            check(
                SyntheticControlRoute.localSessionDictation.eventTapLocation.rawValue,
                CGEventTapLocation.cgSessionEventTap.rawValue,
                "local dictation bypasses UU HID tap"
            )
            check(
                SyntheticControlRoute.remoteHIDPassthrough.eventTapLocation.rawValue,
                CGEventTapLocation.cghidEventTap.rawValue,
                "remote Control chords stay on HID path"
            )
        }

        do {
            do {
                let events = try ClipboardKeyboardPaster.makeCommandVEvents()
                check(events.count, 4, "Command-V event count")
                check(
                    events.map(\.type),
                    [.flagsChanged, .keyDown, .keyUp, .flagsChanged],
                    "Command-V event types"
                )
                check(
                    events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                    [55, 9, 9, 55],
                    "Command-V event key codes"
                )
                check(events[0].flags.contains(.maskCommand), true, "Command down flag")
                check(
                    (events[0].flags.rawValue & 0x8) != 0,
                    true,
                    "left Command device flag"
                )
                check(events[1].flags, events[0].flags, "V down inherits Command state")
                check(events[2].flags, events[0].flags, "V up inherits Command state")
                check(events[3].flags.contains(.maskCommand), false, "Command up clears flag")
                check(
                    (events[3].flags.rawValue & 0x8) == 0,
                    true,
                    "Command up clears left device flag"
                )
                check(
                    events.allSatisfy {
                        $0.getIntegerValueField(.eventSourceUserData) ==
                            ControlHoldMonitor.syntheticEventMarker
                    },
                    true,
                    "Command-V events carry bridge marker"
                )
            } catch {
                failures.append("Command-V event creation: \(error)")
            }
        }

        do {
            check(
                DoubaoShortcutSettingsReader.mode(fromVisibleSettingsText: "免按模式：fn，按一次即可开始说话，再按任意键可结束"),
                .fnToggle,
                "visible Doubao settings detect Fn toggle"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "语音输入实时上屏 … 语音输入模式 长按模式 按住说话，松手结束 点击设置 免按模式 按一次即可开始说话，再按任意键可结束 fn 全局唤起语音 离线语音"
                ),
                .fnToggle,
                "actual AX settings text reads the bounded Fn key after the any-key instruction"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "语音输入模式 长按模式 按住说话，松手结束 左 Control 免按模式 按一次即可开始说话，再按任意键可结束"
                ),
                .leftControlHold,
                "visible left Control long-press is detected when the Fn mode has no selected key"
            )
            check(
                DoubaoShortcutSettingsReader.visibleModeCandidates(in: [[
                    "长按模式", "按住说话，松手结束", "点击设置", "免按模式",
                    "按一次即可开始说话", "再按任意键可结束", "Fn", "全局唤起语音",
                    "Ctrl", "离线语音", "未选中的其他快捷键"
                ]]),
                [.fnToggle],
                "split setting nodes aggregate only within the selected mode field"
            )
            check(
                DoubaoShortcutSettingsReader.visibleModeCandidates(in: [[
                    "长按模式", "按住说话，松手结束", "Left Control"
                ]]),
                [.leftControlHold],
                "AX title, instruction and left Control value aggregate across nodes"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "长按模式 按住说话，松手结束 Left ⌃"
                ),
                .leftControlHold,
                "visible left Control glyph is canonicalized to the supported trigger"
            )
            check(
                DoubaoShortcutSettingsReader.shouldCollectShortcutText("Left Control"),
                true,
                "AX collection keeps a standalone English Left Control value"
            )
            check(
                DoubaoShortcutSettingsReader.shouldCollectShortcutText("左 Control"),
                true,
                "AX collection keeps a standalone Chinese left Control value"
            )
            check(
                DoubaoShortcutSettingsReader.shouldCollectShortcutText("⌃"),
                true,
                "AX collection keeps a standalone Control glyph"
            )
            check(
                DoubaoShortcutSettingsReader.shouldCollectShortcutText("Shift"),
                true,
                "AX collection keeps a standalone modifier value"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "长按模式 按住说话，松手结束 ⌃"
                ),
                .unsupported("control"),
                "a bare Control glyph is not assumed to mean left Control"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "长按模式 按住说话，松手结束 Right ⌃"
                ),
                .unsupported("right control"),
                "a right Control glyph is not treated as left Control"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "长按模式 按住说话，松手结束 Right Control"
                ),
                .unsupported("right control"),
                "visible right Control is never mistaken for left Control"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "长按模式 按住说话，松手结束 Control"
                ),
                .unsupported("control"),
                "a generic Control label is not assumed to mean left Control"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "长按模式 按住说话，松手结束 Left Control + Shift"
                ),
                nil,
                "a Control modifier chord is not treated as the supported single-key shortcut"
            )
            check(
                DoubaoShortcutSettingsReader.visibleModeCandidates(in: [[
                    "长按模式", "按住说话", "松手结束", "Left Control", "+", "Shift"
                ]]),
                [],
                "AX filtering retains split Control and Shift values and rejects their chord"
            )
            check(
                DoubaoShortcutSettingsReader.visibleModeCandidates(in: [[
                    "长按模式", "按住说话，松手结束", "全局唤起语音", "Left Control"
                ]]),
                [],
                "an unrelated global shortcut stays outside the long-press settings group"
            )
            check(
                DoubaoShortcutSettingsReader.visibleModeCandidates(in: [[
                    "长按模式", "按住说话，松手结束", "左 Control", "免按模式",
                    "按一次即可开始说话", "再按任意键可结束", "Fn"
                ]]),
                [.leftControlHold, .fnToggle],
                "separate active long-press and Fn modes remain distinct candidates"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "长按模式 按住说话，松手结束 左 Control 免按模式 按一次即可开始说话，再按任意键可结束 Fn"
                ),
                nil,
                "whole settings text with two active shortcut modes is ambiguous"
            )
            check(
                DoubaoShortcutSettingsReader.visibleModeCandidates(in: [
                    ["免按模式", "按一次即可开始说话"],
                    ["再按任意键可结束", "Fn"]
                ]),
                [],
                "AX settings from separate windows are never combined"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "免按模式 按一次即可开始说话，再按任意键可结束 fn+control"
                ),
                nil,
                "conflicting visible shortcut candidates are rejected"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "免按模式 点击设置 按一次即可开始说话，再按任意键可结束"
                ),
                nil,
                "the settings button label is never treated as a shortcut"
            )
            check(
                DoubaoShortcutSettingsReader.mode(fromVisibleSettingsText: "fn 是可用按键；请打开设置查看"),
                nil,
                "unrelated Fn text is not accepted as a shortcut"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    isStartEnabled: true,
                    isGlobalEnabled: nil,
                    keyCode: 63,
                    keyDisplay: "fn",
                    longPressKeyCode: nil,
                    longPressKeyDisplay: nil,
                    modifierFlags: 0
                ),
                .fnToggle,
                "ASR preference contract detects Fn toggle"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    isStartEnabled: true,
                    isGlobalEnabled: nil,
                    keyCode: 63,
                    keyDisplay: "fn",
                    longPressKeyCode: nil,
                    longPressKeyDisplay: nil,
                    modifierFlags: 1
                ),
                .unsupported("fn"),
                "Fn plus a modifier is not treated as the Fn-only shortcut"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    isStartEnabled: true,
                    isGlobalEnabled: nil,
                    keyCode: 36,
                    keyDisplay: "Return",
                    longPressKeyCode: nil,
                    longPressKeyDisplay: nil,
                    modifierFlags: 0
                ),
                .unsupported("Return"),
                "unknown configured shortcut is not guessed"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    isStartEnabled: false,
                    isGlobalEnabled: nil,
                    keyCode: nil,
                    keyDisplay: nil,
                    longPressKeyCode: nil,
                    longPressKeyDisplay: nil,
                    modifierFlags: 0
                ),
                .disabled,
                "disabled ASR shortcut stays disabled"
            )
        }

        do {
            check(PrivacySafeTextMetrics.lengthBucket(0), "empty", "empty length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(4), "1-4", "short length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(16), "5-16", "medium length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(64), "17-64", "long length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(65), "65+", "largest length bucket")
        }

        do {
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: true,
                    hasMarkedText: false,
                    elapsedAfterRelease: 1.0,
                    stableFor: 1.0
                ),
                false,
                "empty transcript never settles"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: false,
                    elapsedAfterRelease: 0.45,
                    stableFor: 0.35
                ),
                true,
                "settle at optimized thresholds"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: true,
                    elapsedAfterRelease: 1.0,
                    stableFor: 1.0
                ),
                false,
                "marked transcript never settles"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: false,
                    elapsedAfterRelease: 0.44,
                    stableFor: 1.0
                ),
                false,
                "release grace is preserved"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: false,
                    elapsedAfterRelease: 1.0,
                    stableFor: 0.34
                ),
                false,
                "tail correction resets stable window"
            )
            check(
                UURemoteDelivery.defaultPasteDelay >= UURemoteDelivery.minimumPasteDelay,
                true,
                "default UU sync delay respects safety floor"
            )
            check(
                LatencyDefaultsMigration.replacementPasteDelay(for: NSNumber(value: 0.9)),
                UURemoteDelivery.defaultPasteDelay,
                "numeric v2.2 delay migrates"
            )
            check(
                LatencyDefaultsMigration.replacementPasteDelay(for: "0.9"),
                UURemoteDelivery.defaultPasteDelay,
                "string v2.2 delay migrates"
            )
            check(
                LatencyDefaultsMigration.replacementPasteDelay(for: NSNumber(value: 0.7)),
                nil,
                "custom delay is preserved"
            )
        }

        do {
            let f5WithFunctionFlag = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.function],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "5",
                charactersIgnoringModifiers: "5",
                isARepeat: false,
                keyCode: 96
            )!
            check(
                ShortcutRecorderMonitorHandler.isPhysicalFnTransition(f5WithFunctionFlag),
                false,
                "AppKit function flag on F5 is not a physical Fn transition"
            )
            let physicalFnTransition = NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: [.function],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 63
            )!
            check(
                ShortcutRecorderMonitorHandler.isPhysicalFnTransition(physicalFnTransition),
                true,
                "only keyCode 63 flagsChanged represents physical Fn"
            )

            var functionKeyState = ShortcutRecorderMonitorHandler.FunctionKeyState()
            check(
                functionKeyState.transition(isDown: true, hasOtherModifiers: false),
                .waitingForRelease,
                "Fn recording waits through the physical release"
            )
            functionKeyState.noteOtherModifierOrKey()
            check(
                functionKeyState.transition(isDown: false, hasOtherModifiers: false),
                .rejectedCombination,
                "Fn plus a modifier is rejected after observing the full chord"
            )
            check(
                functionKeyState.transition(isDown: true, hasOtherModifiers: false),
                .waitingForRelease,
                "a fresh standalone Fn attempt can follow a rejected chord"
            )
            check(
                functionKeyState.transition(isDown: false, hasOtherModifiers: false),
                .accepted,
                "standalone Fn is accepted on release"
            )

            let recorderEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "q",
                charactersIgnoringModifiers: "q",
                isARepeat: false,
                keyCode: 12
            )!
            var consumeCalled = false
            let keyWindowHandler = ShortcutRecorderMonitorHandler.make(
                windowIsKey: { true },
                stop: {},
                consume: { _ in consumeCalled = true; return nil }
            )
            let consumedResult = keyWindowHandler(recorderEvent)
            check(consumedResult.map { _ in false } ?? true, true, "recorder local-monitor closure preserves intentional nil")
            check(consumeCalled, true, "recorder local-monitor closure reaches its event consumer")

            var stoppedAfterFocusLoss = false
            let focusLostHandler = ShortcutRecorderMonitorHandler.make(
                windowIsKey: { false },
                stop: { stoppedAfterFocusLoss = true },
                consume: { _ in nil }
            )
            check(focusLostHandler(recorderEvent) === recorderEvent, true, "focus loss forwards the current event")
            check(stoppedAfterFocusLoss, true, "focus loss stops the recorder and removes its monitor")

            let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
            textView.string = "已有听写正文"
            var commitCount = 0
            textView.onCommit = { commitCount += 1 }
            textView.observesControlRelease = true
            var cancelCount = 0
            textView.onCancel = { _ in cancelCount += 1 }
            let syntheticSource = CGEventSource(stateID: .combinedSessionState)!
            let syntheticLetter = CGEvent(keyboardEventSource: syntheticSource, virtualKey: 0, keyDown: true)!
            syntheticLetter.setIntegerValueField(.eventSourceUserData, value: ControlHoldMonitor.syntheticEventMarker)
            textView.keyDown(with: NSEvent(cgEvent: syntheticLetter)!)
            check(textView.string, "已有听写正文", "marked synthetic voice key cannot overwrite existing composer text")
            let syntheticReturn = CGEvent(keyboardEventSource: syntheticSource, virtualKey: 36, keyDown: true)!
            syntheticReturn.setIntegerValueField(.eventSourceUserData, value: ControlHoldMonitor.syntheticEventMarker)
            textView.keyDown(with: NSEvent(cgEvent: syntheticReturn)!)
            check(commitCount, 0, "marked synthetic voice Return cannot commit the composer")
            let syntheticEscape = CGEvent(keyboardEventSource: syntheticSource, virtualKey: 53, keyDown: true)!
            syntheticEscape.setIntegerValueField(.eventSourceUserData, value: ControlHoldMonitor.syntheticEventMarker)
            textView.keyDown(with: NSEvent(cgEvent: syntheticEscape)!)
            check(cancelCount, 0, "marked synthetic voice Escape cannot cancel the composer")
        }

        do {
            let scrollView = NSScrollView(frame: .zero)
            let textView = NSTextView()
            textView.textContainerInset = NSSize(width: 12, height: 10)
            ComposerTextLayout.attach(textView, to: scrollView)
            scrollView.hasVerticalScroller = true
            scrollView.borderType = .bezelBorder
            scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 100)
            ComposerTextLayout.synchronize(textView, with: scrollView)
            check(textView.frame.width > 0, true, "composer text view has drawable width")
            check(
                textView.frame.width,
                scrollView.contentSize.width,
                "composer text view tracks scroll width"
            )
            check(
                (textView.textContainer?.containerSize.width ?? 0) > 0,
                true,
                "composer text container has drawable width"
            )
            check(
                textView.textContainer?.widthTracksTextView,
                true,
                "composer container tracks text view width"
            )
        }

        do {
            let automaticFn = DoubaoShortcutConfiguration(
                mode: .fnToggle,
                source: .preferences("fixture"),
                observedAt: Date(timeIntervalSince1970: 1_800_000_100)
            )
            let confirmedF6 = DoubaoShortcutConfiguration(
                mode: .leftControlHold,
                source: .confirmed,
                observedAt: Date(timeIntervalSince1970: 1_800_000_000),
                shortcut: KeyboardShortcut(keyCode: 97)
            )
            let initial = ShortcutSettingsInitialSelection.resolve(
                automatic: automaticFn,
                confirmed: confirmedF6,
                manual: nil
            )
            check(initial.sourceIndex, 0, "available automatic settings are the initially selected source")
            check(initial.configuration?.keyboardShortcut, .fn, "initial effective voice key comes from automatic Fn, not confirmed F6")
            check(initial.configuration?.mode, .fnToggle, "initial interaction mode comes from the active automatic source")
            check(
                ShortcutSettingsInitialSelection.bridgeShortcut(
                    kind: .followDoubao,
                    doubao: initial.configuration,
                    custom: KeyboardShortcut(keyCode: 97)
                ),
                .fn,
                "follow-Doubao recorder displays the active automatic key"
            )
            check(
                ShortcutSettingsInitialSelection.bridgeShortcut(kind: .leftControlHold, doubao: initial.configuration, custom: nil),
                .leftControl,
                "left-Control recorder displays its active fixed binding"
            )

            let domain = "DoubaoVoiceBridgeSelfTest.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: domain)!
            defaults.removePersistentDomain(forName: domain)
            defer { defaults.removePersistentDomain(forName: domain) }
            let store = ShortcutConfigurationStore(defaults: defaults)
            check(store.didCompleteSetup, false, "first run starts without a completed setup record")

            let controlShiftK = KeyboardShortcut(
                keyCode: 40,
                modifierMask: CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
            )
            check(controlShiftK.validationError, nil, "ordinary modifier chords can be recorded")
            check(KeyboardShortcut(keyCode: 62).isModifierOnly, true, "right Control can be recorded alone")
            check(KeyboardShortcut(keyCode: 53).validationError != nil, true, "Escape remains reserved")
            check(
                KeyboardShortcut(keyCode: 63, modifierMask: CGEventFlags.maskCommand.rawValue).validationError != nil,
                true,
                "Fn cannot be combined with another modifier"
            )
            let expectedChordDown: [SyntheticKeyboardEventDescription] = [
                .init(kind: .flagsChanged, keyCode: 59, flags: CGEventFlags.maskControl.rawValue),
                .init(
                    kind: .flagsChanged,
                    keyCode: 56,
                    flags: CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
                ),
                .init(
                    kind: .keyDown,
                    keyCode: 40,
                    flags: CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
                )
            ]
            check(
                SyntheticKeyboardShortcutPlan.events(for: controlShiftK, down: true),
                expectedChordDown,
                "synthetic custom chord presses modifiers before its primary key"
            )
            let expectedChordUp: [SyntheticKeyboardEventDescription] = [
                .init(
                    kind: .keyUp,
                    keyCode: 40,
                    flags: CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
                ),
                .init(kind: .flagsChanged, keyCode: 56, flags: CGEventFlags.maskControl.rawValue),
                .init(kind: .flagsChanged, keyCode: 59, flags: 0)
            ]
            check(
                SyntheticKeyboardShortcutPlan.events(for: controlShiftK, down: false),
                expectedChordUp,
                "synthetic custom chord releases its primary before balancing modifiers"
            )
            check(
                SyntheticKeyboardShortcutPlan.events(for: KeyboardShortcut(keyCode: 62), down: true),
                [.init(kind: .flagsChanged, keyCode: 62, flags: CGEventFlags.maskControl.rawValue)],
                "right Control uses its own modifier keycode"
            )

            let customDoubao = DoubaoShortcutConfiguration.manual(.leftControlHold, shortcut: controlShiftK)
            let remoteLeftControl = ShortcutProfile(doubao: customDoubao, bridge: .leftControlHold)
            check(remoteLeftControl.isSupported, true, "custom Doubao chord works with the independent left-Control bridge")
            check(remoteLeftControl.bridgeShortcut, .leftControl, "left-Control remote trigger remains independent of Doubao chord")
            let remoteCustom = ShortcutProfile(
                doubao: DoubaoShortcutConfiguration.manual(.leftControlHold, shortcut: KeyboardShortcut(keyCode: 62)),
                bridge: .customHold(KeyboardShortcut(keyCode: 40))
            )
            check(remoteCustom.isSupported, true, "right-Control Doubao hold works with a custom remote trigger")
            check(remoteCustom.bridgeShortcut, KeyboardShortcut(keyCode: 40), "custom remote binding is selected")
            let customReadiness = ShortcutTriggerReadiness.status(
                profile: remoteCustom,
                setupPending: false,
                monitorActive: true
            ) ?? ""
            check(
                customReadiness.contains(remoteCustom.bridgeShortcut.displayName) &&
                    customReadiness.contains(remoteCustom.doubao.keyboardShortcut.displayName),
                true,
                "custom status text names the configured remote and Doubao keys"
            )
            check(
                SessionCoordinator.shouldObserveControlRelease(manualEntry: false, profile: controlProfileForReleaseTest()),
                false,
                "a monitor-triggered session ignores unrelated local left-Control releases"
            )
            check(
                SessionCoordinator.shouldObserveControlRelease(manualEntry: false, profile: remoteCustom),
                false,
                "custom remote sessions never use the fixed left-Control composer release"
            )
            check(
                SessionCoordinator.shouldObserveControlRelease(manualEntry: true, profile: remoteCustom),
                false,
                "custom Doubao bindings cannot open an unfinished manual composer session"
            )
            let customFollow = ShortcutProfile(doubao: customDoubao, bridge: .followDoubao)
            check(customFollow.isSupported, true, "follow mode accepts a recorded Doubao hold key")
            check(customFollow.usesCustomEventBridge, true, "recorded follow keys use the generic physical trigger route")
            check(customFollow.usesFollowCustomToggleBridge, false, "a recorded hold key keeps hold-and-release behavior")
            check(customFollow.bridgeInstruction.contains("按住 ⌃⇧K"), true, "followed custom hold displays its actual key and interaction")

            let rightOptionFollow = ShortcutProfile(
                doubao: DoubaoShortcutConfiguration.manual(.fnToggle, shortcut: KeyboardShortcut(keyCode: 61)),
                bridge: .followDoubao
            )
            check(rightOptionFollow.isSupported, true, "Right Option Fn-toggle can be followed by the remote bridge")
            check(rightOptionFollow.usesFollowCustomToggleBridge, true, "a followed custom toggle has click-to-start behavior")
            check(rightOptionFollow.bridgeInstruction.contains("轻按 Right ⌥"), true, "followed toggle status names Right Option")
            check(
                rightOptionFollow.statusMenuLines,
                [
                    "远控触发键：Right ⌥（轻按 Right ⌥ 开始，再按任意键结束）",
                    "豆包语音键：Right ⌥（按 Right ⌥ 启动，任意键结束）"
                ],
                "status menu separately labels the remote trigger and Doubao voice key"
            )

            let doubao = DoubaoShortcutConfiguration(
                mode: .fnToggle,
                source: .visibleSettingsWindow,
                observedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
            check(
                store.save(confirmedDoubaoMode: .fnToggle, manualDoubaoMode: nil, bridge: .leftControlHold),
                true,
                "valid automatic profile writes and passes readback"
            )
            check(store.didCompleteSetup, true, "saving a valid profile completes setup")
            check(store.loadManualDoubaoConfiguration(), nil, "automatic confirmation does not become a manual override")
            check(store.loadLastConfirmedDoubaoConfiguration()?.mode, .fnToggle, "confirmed mode persists after automatic settings close")
            check(store.loadLastConfirmedDoubaoConfiguration()?.source, .confirmed, "persisted automatic mode is labeled as last confirmed")
            check(store.loadBridgeConfiguration()?.kind, .leftControlHold, "independent bridge shortcut persists")
            check(store.hasCorruptOrIncompleteSavedConfiguration, false, "complete valid setup is accepted")

            store.updateConfirmedModeFromAutomaticRead(.leftControlHold)
            check(store.loadLastConfirmedDoubaoConfiguration()?.mode, .leftControlHold, "automatic profile refresh changes the saved mode")
            check(store.loadBridgeConfiguration()?.kind, .leftControlHold, "automatic mode refresh preserves the independent bridge key")
            check(store.loadManualDoubaoConfiguration(), nil, "automatic refresh does not create a manual override")

            let customRemoteKey = KeyboardShortcut(keyCode: 40, modifierMask: CGEventFlags.maskCommand.rawValue)
            check(
                store.save(
                    confirmedDoubaoMode: .leftControlHold,
                    manualDoubaoMode: .leftControlHold,
                    manualDoubaoShortcut: controlShiftK,
                    confirmedDoubaoShortcut: controlShiftK,
                    bridge: .customHold(customRemoteKey)
                ),
                true,
                "custom Doubao and remote bindings persist with readback validation"
            )
            check(store.loadManualDoubaoConfiguration()?.keyboardShortcut, controlShiftK, "manual Doubao chord reads back intact")
            check(store.loadLastConfirmedDoubaoConfiguration()?.keyboardShortcut, controlShiftK, "confirmed Doubao chord reads back intact")
            check(store.loadBridgeConfiguration()?.shortcut, customRemoteKey, "custom remote shortcut reads back intact")
            check(store.hasCorruptOrIncompleteSavedConfiguration, false, "complete custom configuration is accepted")

            let confirmedDomain = "DoubaoVoiceBridgeConfirmedCustomSelfTest.\(UUID().uuidString)"
            let confirmedDefaults = UserDefaults(suiteName: confirmedDomain)!
            confirmedDefaults.removePersistentDomain(forName: confirmedDomain)
            defer { confirmedDefaults.removePersistentDomain(forName: confirmedDomain) }
            let confirmedStore = ShortcutConfigurationStore(defaults: confirmedDefaults)
            let customDoubaoKey = KeyboardShortcut(
                keyCode: 40,
                modifierMask: CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
            )
            let remoteKey = KeyboardShortcut(keyCode: 97)
            check(
                confirmedStore.save(
                    confirmedDoubaoMode: .leftControlHold,
                    manualDoubaoMode: .leftControlHold,
                    manualDoubaoShortcut: customDoubaoKey,
                    confirmedDoubaoShortcut: customDoubaoKey,
                    bridge: .customHold(remoteKey)
                ),
                true,
                "choosing a confirmed custom Doubao key preserves it as an explicit override"
            )
            confirmedStore.updateConfirmedModeFromAutomaticRead(.fnToggle)
            check(
                confirmedStore.loadLastConfirmedDoubaoConfiguration()?.keyboardShortcut,
                customDoubaoKey,
                "a later automatic legacy read cannot replace the explicitly selected confirmed custom key"
            )
            let resolvedCustom = confirmedStore.loadManualDoubaoConfiguration() ??
                confirmedStore.loadLastConfirmedDoubaoConfiguration()
            check(
                resolvedCustom?.keyboardShortcut,
                customDoubaoKey,
                "store-to-refresh resolution keeps the custom voice key active across automatic refresh"
            )

            store.updateConfirmedModeFromAutomaticRead(.fnToggle)
            check(store.loadLastConfirmedDoubaoConfiguration()?.mode, .leftControlHold, "automatic legacy reads cannot override an explicitly selected custom shortcut")
            check(store.loadBridgeConfiguration()?.kind, .customHold, "automatic reads preserve an explicitly selected custom remote key")
            check(store.loadManualDoubaoConfiguration()?.keyboardShortcut, controlShiftK, "explicit custom voice key remains a manual override")

            defaults.set("unknown-v99", forKey: "shortcut.manualDoubaoMode.v1")
            check(store.loadManualDoubaoConfiguration(), nil, "unknown manual profile is not interpreted")
            check(store.hasCorruptOrIncompleteSavedConfiguration, true, "corrupt saved profile requires setup again")

            let followProfile = ShortcutProfile(doubao: doubao, bridge: .followDoubao)
            check(followProfile.usesFnBridge, true, "follow mode uses the confirmed Fn trigger")
            check(followProfile.usesLeftControlBridge, false, "follow Fn mode does not also capture Control")
            let independentProfile = ShortcutProfile(doubao: doubao, bridge: .leftControlHold)
            check(independentProfile.usesFnBridge, false, "independent Control bridge does not intercept physical Fn")
            check(independentProfile.usesLeftControlBridge, true, "independent bridge captures left Control")
            check(independentProfile.isSupported, true, "Fn Doubao with Control bridge is a supported profile")
            check(followProfile.supportsManualComposerEntry, false, "Fn-follow profile cannot open an unfinishable manual session")
            check(independentProfile.supportsManualComposerEntry, false, "independent Control-to-Fn profile cannot bypass its trigger lifecycle")

            let controlProfile = ShortcutProfile(
                doubao: DoubaoShortcutConfiguration(mode: .leftControlHold, source: .manual, observedAt: Date()),
                bridge: .followDoubao
            )
            check(controlProfile.supportsManualComposerEntry, true, "left Control profile keeps manual composer entry")
            let refreshedControlProfile = ShortcutProfile(
                doubao: DoubaoShortcutConfiguration(
                    mode: .leftControlHold,
                    source: .preferences("test"),
                    observedAt: Date()
                ),
                bridge: .followDoubao
            )
            check(
                ShortcutProfile.hasSameTriggerBehavior(controlProfile, refreshedControlProfile),
                true,
                "a source-only refresh does not count as a shortcut behavior change"
            )
            check(
                ShortcutTriggerReadiness.status(profile: controlProfile, setupPending: false, monitorActive: false),
                nil,
                "readiness is unavailable before the event tap starts"
            )
            check(
                ShortcutTriggerReadiness.status(profile: controlProfile, setupPending: true, monitorActive: true),
                nil,
                "a supported profile is not ready while setup remains pending"
            )
            check(
                ShortcutTriggerReadiness.status(profile: controlProfile, setupPending: false, monitorActive: true),
                "就绪 · 远控触发键：Left ⌃（按住 Left ⌃ 开始，松开结束）；豆包语音键：Left ⌃（长按左 ⌃ 说话，松开自动发送）",
                "readiness is published only for a supported profile with an active event tap"
            )
            check(
                ShortcutTriggerReadiness.status(
                    profile: controlProfile,
                    setupPending: false,
                    monitorActive: true,
                    accessibilityTrusted: false
                ),
                nil,
                "readiness is withheld when the app cannot safely capture the UU window"
            )

            let unsupportedProfile = ShortcutProfile(
                doubao: DoubaoShortcutConfiguration(mode: .disabled, source: .manual, observedAt: Date()),
                bridge: .followDoubao
            )
            check(unsupportedProfile.supportsManualComposerEntry, false, "disabled profiles cannot enter manual composer")

            let coordinator = SessionCoordinator()
            var statusChanges: [String] = []
            coordinator.onStatusChange = { text, _ in statusChanges.append(text) }
            coordinator.updateShortcutProfile(controlProfile)
            coordinator.updateShortcutProfile(refreshedControlProfile)
            check(
                statusChanges,
                [],
                "repeated profile refresh does not publish readiness over an existing error status"
            )

            let syntheticFnDownFlags = SyntheticShortcutEventFlags.fnToggle(down: true)
            check(syntheticFnDownFlags.contains(.maskSecondaryFn), true, "synthetic Doubao Fn down carries Fn")
            check(syntheticFnDownFlags.contains(.maskControl), false, "synthetic Doubao Fn does not inherit physical bridge Control")
            check(SyntheticShortcutEventFlags.fnToggle(down: false), [], "synthetic Doubao Fn up clears all modifiers")
        }

        do {
            let controlShiftChord = KeyboardShortcut(
                keyCode: 40,
                modifierMask: CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
            )
            let controlK = KeyboardShortcut(keyCode: 40, modifierMask: CGEventFlags.maskControl.rawValue)

            let rightOptionFollowProfile = ShortcutProfile(
                doubao: DoubaoShortcutConfiguration.manual(.fnToggle, shortcut: KeyboardShortcut(keyCode: 61)),
                bridge: .followDoubao
            )
            let rightOptionFollow = ControlMonitorEventHarness(profile: rightOptionFollowProfile)
            check(rightOptionFollow.sendModifier(61, flags: .maskAlternate), true, "followed Right Option down is intercepted as the remote toggle trigger")
            check(rightOptionFollow.beginCount, 0, "followed Right Option waits for its click release before opening the composer")
            check(rightOptionFollow.sendModifier(61, flags: []), true, "followed Right Option release is consumed")
            check(rightOptionFollow.beginCount, 1, "Right Option click enters the production composer-start route exactly once")
            rightOptionFollow.composerReady = true
            rightOptionFollow.monitor.postSyntheticDownIfNeeded()
            check(
                rightOptionFollow.postedShortcuts,
                [.init(shortcut: KeyboardShortcut(keyCode: 61), down: true)],
                "the followed Right Option click synthesizes the configured Doubao key only after composer readiness"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(5)) {}
            check(
                waitForMainRunLoopCondition(timeout: 0.5) {
                    rightOptionFollow.postedShortcuts.count == 2 &&
                        rightOptionFollow.postedShortcuts.last?.down == false
                },
                true,
                "the followed toggle release completes despite an earlier main-run-loop wake"
            )
            check(
                rightOptionFollow.postedShortcuts,
                [
                    .init(shortcut: KeyboardShortcut(keyCode: 61), down: true),
                    .init(shortcut: KeyboardShortcut(keyCode: 61), down: false)
                ],
                "the synthetic Right Option press is paired with its release"
            )
            check(rightOptionFollow.sendKey(40, down: true, flags: []), true, "the next physical key is consumed as the any-key stop")
            check(rightOptionFollow.anyKeyStopCount, 1, "the followed toggle closes Doubao with a local any-key stop")
            check(rightOptionFollow.releaseCount, 1, "the followed toggle reaches the normal transcript-finalization callback")
            _ = rightOptionFollow.sendKey(40, down: false, flags: [])
            check(rightOptionFollow.monitor.isGestureIdle, true, "followed Right Option trigger and stop release return the monitor to idle")
            rightOptionFollow.monitor.stop()

            let chordFollowProfile = ShortcutProfile(
                doubao: DoubaoShortcutConfiguration.manual(.fnToggle, shortcut: controlShiftChord),
                bridge: .followDoubao
            )
            let chordFollow = ControlMonitorEventHarness(profile: chordFollowProfile)
            _ = chordFollow.sendModifier(59, flags: .maskControl)
            _ = chordFollow.sendModifier(56, flags: [.maskControl, .maskShift])
            check(
                chordFollow.sendKey(40, down: true, flags: [.maskControl, .maskShift]),
                true,
                "followed chord primary-down is captured after its modifier prefix"
            )
            check(
                chordFollow.sendKey(40, down: false, flags: [.maskControl, .maskShift]),
                true,
                "followed chord primary-up starts the local composer"
            )
            check(chordFollow.beginCount, 1, "the followed chord enters the production start route once")
            chordFollow.composerReady = true
            chordFollow.monitor.postSyntheticDownIfNeeded()
            check(
                waitForMainRunLoopCondition(timeout: 0.5) {
                    chordFollow.postedShortcuts.count == 2 && chordFollow.postedShortcuts.last?.down == false
                },
                true,
                "the followed chord release completes before the bounded test deadline"
            )
            check(
                chordFollow.postedShortcuts,
                [
                    .init(shortcut: controlShiftChord, down: true),
                    .init(shortcut: controlShiftChord, down: false)
                ],
                "followed chord is synthesized only to the ready local composer"
            )
            check(chordFollow.sendModifier(56, flags: .maskControl), true, "the original Shift release is swallowed after chord activation")
            check(chordFollow.sendModifier(59, flags: []), true, "the original Control release is swallowed after chord activation")
            check(chordFollow.anyKeyStopCount, 0, "releasing the chord modifiers does not stop followed toggle dictation")
            check(chordFollow.releaseCount, 0, "modifier releases do not finalize the followed chord session")
            check(chordFollow.sendModifier(59, flags: .maskControl), true, "a later modifier-down ends followed toggle dictation")
            check(chordFollow.anyKeyStopCount, 1, "the later modifier-down is translated into the local any-key stop")
            check(chordFollow.releaseCount, 1, "the chord session finalizes exactly once after the later stop")
            check(chordFollow.sendModifier(59, flags: []), true, "the stop modifier release is consumed without toggling state twice")
            chordFollow.monitor.stop()

            let followedHoldProfile = ShortcutProfile(
                doubao: DoubaoShortcutConfiguration.manual(.leftControlHold, shortcut: KeyboardShortcut(keyCode: 61)),
                bridge: .followDoubao
            )
            let followedHold = ControlMonitorEventHarness(profile: followedHoldProfile)
            _ = followedHold.sendModifier(61, flags: .maskAlternate)
            check(followedHold.beginCount, 0, "followed custom hold does not begin before its threshold")
            followedHold.monitor.activateDictationIfStillPending()
            check(followedHold.beginCount, 1, "followed custom hold starts through the production threshold route")
            followedHold.monitor.stop()

            let failedCapture = ControlMonitorEventHarness(shortcut: .fn)
            failedCapture.windowCaptureSucceeds = false
            check(failedCapture.sendModifier(63, flags: .maskSecondaryFn), false, "a trigger with no capturable UU window remains native")
            check(failedCapture.beginCount, 0, "failed UU window capture never opens the composer")
            check(
                failedCapture.unavailableMessages.last?.contains("辅助功能权限") ?? false,
                true,
                "failed UU window capture reports actionable accessibility guidance"
            )
            failedCapture.monitor.stop()

            let startupRace = ControlMonitorEventHarness(profile: ShortcutProfile(
                doubao: DoubaoShortcutConfiguration.manual(.fnToggle, shortcut: KeyboardShortcut(keyCode: 61)),
                bridge: .customHold(.fn)
            ))
            _ = startupRace.sendModifier(63, flags: .maskSecondaryFn)
            startupRace.monitor.activateDictationIfStillPending()
            check(startupRace.beginCount, 1, "custom Fn hold enters the production composer-start route")
            startupRace.uuIsFrontmost = false
            startupRace.bridgeHasFocus = false
            startupRace.monitor.cancelIfFocusLost(
                activatedBundleIdentifier: "com.lyp.DoubaoVoiceBridge",
                at: Date().addingTimeInterval(0.031)
            )
            check(startupRace.cancelCount, 0, "the own-app activation transition does not cancel within the readiness deadline")
            startupRace.bridgeHasFocus = true
            startupRace.composerReady = true
            startupRace.monitor.postSyntheticDownIfNeeded()
            check(
                startupRace.postedShortcuts.first,
                .init(shortcut: KeyboardShortcut(keyCode: 61), down: true),
                "after the focus transition, the ready composer receives only the configured Right Option key"
            )
            startupRace.bridgeHasFocus = false
            startupRace.monitor.cancelIfFocusLost(activatedBundleIdentifier: "com.apple.Safari")
            check(startupRace.cancelCount, 1, "focus loss after first composer readiness cancels immediately")
            startupRace.monitor.stop()

            let legacyStartup = ControlMonitorEventHarness(profile: ShortcutProfile(
                doubao: DoubaoShortcutConfiguration(mode: .leftControlHold, source: .manual, observedAt: Date()),
                bridge: .followDoubao
            ))
            check(legacyStartup.profile.usesLeftControlBridge, true, "legacy startup fixture exercises the historic left-Control bridge route")
            check(legacyStartup.profile.usesCustomEventBridge, false, "legacy startup fixture does not enter the custom-key event route")
            check(legacyStartup.sendModifier(59, flags: .maskControl), true, "legacy left Control enters the same production gesture route")
            legacyStartup.monitor.activateDictationIfStillPending()
            check(legacyStartup.beginCount, 1, "legacy left Control reaches composer startup after its hold threshold")
            legacyStartup.uuIsFrontmost = false
            legacyStartup.bridgeHasFocus = false
            legacyStartup.monitor.cancelIfFocusLost(
                activatedBundleIdentifier: "com.lyp.DoubaoVoiceBridge",
                at: Date().addingTimeInterval(0.031)
            )
            check(legacyStartup.cancelCount, 0, "legacy left Control also gets the bounded own-app activation transition")
            legacyStartup.bridgeHasFocus = true
            legacyStartup.composerReady = true
            legacyStartup.monitor.postSyntheticDownIfNeeded()
            check(
                legacyStartup.postedShortcuts.first,
                .init(shortcut: KeyboardShortcut(keyCode: 59), down: true),
                "legacy startup synthesizes its configured voice key only after the local composer is ready"
            )
            legacyStartup.bridgeHasFocus = false
            legacyStartup.monitor.cancelIfFocusLost(activatedBundleIdentifier: "com.apple.Safari")
            check(legacyStartup.cancelCount, 1, "legacy left Control returns to strict focus cancellation after first readiness")
            check(
                legacyStartup.postedShortcuts.last,
                .init(shortcut: KeyboardShortcut(keyCode: 59), down: false),
                "legacy focus cancellation balances the synthetic voice key without sending it to Safari"
            )
            legacyStartup.monitor.stop()

            let startupWindowChanged = ControlMonitorEventHarness(shortcut: .fn)
            _ = startupWindowChanged.sendModifier(63, flags: .maskSecondaryFn)
            startupWindowChanged.monitor.activateDictationIfStillPending()
            startupWindowChanged.uuIsFrontmost = false
            startupWindowChanged.bridgeHasFocus = false
            startupWindowChanged.windowMatches = false
            startupWindowChanged.monitor.cancelIfFocusLost(
                activatedBundleIdentifier: "com.lyp.DoubaoVoiceBridge",
                at: Date().addingTimeInterval(0.031)
            )
            check(startupWindowChanged.cancelCount, 1, "startup grace never crosses a change in the captured UU window")
            check(startupWindowChanged.postedShortcuts, [], "a changed UU window receives no synthetic voice shortcut")
            startupWindowChanged.monitor.stop()

            let startupExternalSwitch = ControlMonitorEventHarness(shortcut: .fn)
            _ = startupExternalSwitch.sendModifier(63, flags: .maskSecondaryFn)
            startupExternalSwitch.monitor.activateDictationIfStillPending()
            startupExternalSwitch.uuIsFrontmost = false
            startupExternalSwitch.bridgeHasFocus = false
            startupExternalSwitch.monitor.cancelIfFocusLost(
                activatedBundleIdentifier: "com.apple.Safari",
                at: Date().addingTimeInterval(0.031)
            )
            check(startupExternalSwitch.cancelCount, 1, "an explicit external app switch cancels during startup grace")
            check(startupExternalSwitch.postedShortcuts, [], "an external app switch receives no synthetic voice shortcut")
            startupExternalSwitch.monitor.stop()

            let startupExpired = ControlMonitorEventHarness(shortcut: .fn)
            _ = startupExpired.sendModifier(63, flags: .maskSecondaryFn)
            startupExpired.monitor.activateDictationIfStillPending()
            startupExpired.uuIsFrontmost = false
            startupExpired.bridgeHasFocus = false
            startupExpired.monitor.cancelIfFocusLost(
                activatedBundleIdentifier: "com.lyp.DoubaoVoiceBridge",
                at: Date().addingTimeInterval(2)
            )
            check(startupExpired.cancelCount, 1, "the composer activation grace is bounded by its readiness deadline")
            check(startupExpired.postedShortcuts, [], "a timed-out composer receives no synthetic voice shortcut")
            startupExpired.monitor.stop()

            let startupInput = ControlMonitorEventHarness(shortcut: .fn)
            _ = startupInput.sendModifier(63, flags: .maskSecondaryFn)
            startupInput.monitor.activateDictationIfStillPending()
            startupInput.uuIsFrontmost = false
            startupInput.bridgeHasFocus = false
            _ = startupInput.sendKey(40, down: true, flags: [])
            check(startupInput.cancelCount, 1, "physical key input before composer readiness cancels startup")
            check(startupInput.postedShortcuts, [], "physical input before composer readiness is never synthesized into another app")
            startupInput.monitor.stop()

            let mismatch = ControlMonitorEventHarness(shortcut: controlK)
            check(mismatch.sendModifier(59, flags: .maskControl), true, "custom chord buffers its Control prefix")
            check(mismatch.sendKey(1, down: true, flags: .maskControl), false, "a nonmatching key replays the native prefix and passes through")
            check(
                mismatch.replayed.map(\.summary),
                [.init(type: .flagsChanged, keyCode: 59, flags: CGEventFlags.maskControl.rawValue)],
                "custom chord mismatch replays only the original modifier prefix"
            )
            mismatch.monitor.stop()

            let quickModifierRelease = ControlMonitorEventHarness(shortcut: controlK)
            _ = quickModifierRelease.sendModifier(59, flags: .maskControl)
            _ = quickModifierRelease.sendKey(40, down: true, flags: .maskControl)
            check(quickModifierRelease.sendModifier(59, flags: []), true, "quick custom hold consumes its matching modifier release")
            check(
                quickModifierRelease.replayed.map(\.summary),
                [
                    .init(type: .flagsChanged, keyCode: 59, flags: CGEventFlags.maskControl.rawValue),
                    .init(type: .keyDown, keyCode: 40, flags: CGEventFlags.maskControl.rawValue),
                    .init(type: .flagsChanged, keyCode: 59, flags: 0)
                ],
                "quick custom modifier release replays the complete down/down/up sequence in order"
            )
            quickModifierRelease.monitor.stop()

            let quickPrimaryRelease = ControlMonitorEventHarness(shortcut: controlK)
            _ = quickPrimaryRelease.sendModifier(59, flags: .maskControl)
            _ = quickPrimaryRelease.sendKey(40, down: true, flags: .maskControl)
            check(quickPrimaryRelease.sendKey(40, down: false, flags: .maskControl), true, "quick custom primary release is consumed")
            check(
                quickPrimaryRelease.replayed.map(\.summary),
                [
                    .init(type: .flagsChanged, keyCode: 59, flags: CGEventFlags.maskControl.rawValue),
                    .init(type: .keyDown, keyCode: 40, flags: CGEventFlags.maskControl.rawValue),
                    .init(type: .keyUp, keyCode: 40, flags: CGEventFlags.maskControl.rawValue)
                ],
                "quick custom primary release balances the buffered trigger without losing native typing"
            )
            quickPrimaryRelease.monitor.stop()

            let neutralized = ControlMonitorEventHarness(shortcut: controlK)
            _ = neutralized.sendModifier(59, flags: .maskControl)
            _ = neutralized.sendKey(40, down: true, flags: .maskControl)
            neutralized.monitor.activateDictationIfStillPending()
            check(neutralized.beginCount, 1, "custom trigger reaches the production long-press activation path")
            check(neutralized.sendModifier(56, flags: [.maskControl, .maskShift]), true, "extra Shift is reposted without the swallowed Control mask")
            check(
                neutralized.replayed.last?.summary,
                .init(type: .flagsChanged, keyCode: 56, flags: CGEventFlags.maskShift.rawValue),
                "custom hold strips swallowed Control from a later modifier event"
            )
            check(neutralized.sendMouseDown(flags: [.maskControl, .maskShift]), true, "mouse input is reposted without the swallowed Control mask")
            check(
                neutralized.replayed.last?.summary,
                .init(type: .leftMouseDown, keyCode: 0, flags: CGEventFlags.maskShift.rawValue),
                "custom hold strips swallowed Control from mouse events too"
            )
            neutralized.monitor.stop()

            let lostFocus = ControlMonitorEventHarness(shortcut: controlK)
            _ = lostFocus.sendModifier(59, flags: .maskControl)
            lostFocus.windowMatches = false
            check(lostFocus.sendKey(40, down: true, flags: .maskControl), true, "focus loss drops a buffered prefix instead of replaying into another app")
            check(
                lostFocus.replayed.last?.summary,
                .init(type: .keyDown, keyCode: 40, flags: 0),
                "focus loss removes the buffered Control mask from later key events"
            )
            check(lostFocus.sendModifier(59, flags: []), true, "orphaned Control release remains consumed after focus loss")
            check(lostFocus.monitor.isGestureIdle, true, "focus-lost modifier state clears when its physical release arrives")
            lostFocus.monitor.stop()

            let changedTargetAtThreshold = ControlMonitorEventHarness(shortcut: controlK)
            _ = changedTargetAtThreshold.sendModifier(59, flags: .maskControl)
            _ = changedTargetAtThreshold.sendKey(40, down: true, flags: .maskControl)
            changedTargetAtThreshold.windowMatches = false
            changedTargetAtThreshold.monitor.activateDictationIfStillPending()
            check(changedTargetAtThreshold.beginCount, 0, "custom long-press cancels when the captured UU window changes before threshold")
            check(changedTargetAtThreshold.captureCount, 1, "custom threshold never recaptures a newly focused window")
            check(changedTargetAtThreshold.monitor.isGestureIdle, false, "changed target keeps consumed modifiers neutralized until release")
            _ = changedTargetAtThreshold.sendKey(40, down: false, flags: .maskControl)
            _ = changedTargetAtThreshold.sendModifier(59, flags: [])
            check(changedTargetAtThreshold.monitor.isGestureIdle, true, "changed-target modifier state clears after physical releases")
            changedTargetAtThreshold.monitor.stop()

            let fnCompanion = ControlMonitorEventHarness(shortcut: .fn)
            check(fnCompanion.sendModifier(63, flags: .maskSecondaryFn), true, "custom Fn trigger begins from the physical Fn flags event")
            check(fnCompanion.sendKey(179, down: true, flags: .maskSecondaryFn, sourcePID: 0), true, "Fn companion key 179 is suppressed by the custom trigger path")
            check(fnCompanion.monitor.isGestureIdle, false, "Fn companion does not abort the pending custom Fn trigger")
            fnCompanion.monitor.activateDictationIfStillPending()
            check(fnCompanion.beginCount, 1, "custom Fn survives its companion event and reaches activation")
            fnCompanion.monitor.stop()

            let fnChord = ControlMonitorEventHarness(shortcut: .fn)
            _ = fnChord.sendModifier(63, flags: .maskSecondaryFn)
            check(
                fnChord.sendModifier(59, flags: [.maskSecondaryFn, .maskControl]),
                false,
                "Fn plus Control aborts the custom Fn trigger and remains a native chord"
            )
            check(fnChord.beginCount, 0, "Fn plus Control cannot reach custom trigger activation")
            check(
                fnChord.sendKey(179, down: true, flags: [.maskSecondaryFn, .maskControl], sourcePID: 0),
                false,
                "aborted Fn chord disarms companion suppression so key 179 stays native"
            )
            fnChord.monitor.stop()

            let functionKey = ControlMonitorEventHarness(shortcut: KeyboardShortcut(keyCode: 97))
            check(functionKey.sendKey(97, down: true, flags: .maskSecondaryFn), true, "F6 keydown flag does not masquerade as a physical Fn chord")
            check(functionKey.monitor.isGestureIdle, false, "F6 remains a usable custom remote trigger")
            functionKey.monitor.stop()

            let physicalFnChord = ControlMonitorEventHarness(shortcut: KeyboardShortcut(keyCode: 97))
            _ = physicalFnChord.sendModifier(63, flags: .maskSecondaryFn)
            check(physicalFnChord.sendKey(97, down: true, flags: .maskSecondaryFn), false, "actual physical Fn plus F6 is passed through as a chord")
            check(physicalFnChord.beginCount, 0, "actual Fn plus another key cannot start a custom F6 trigger")
            physicalFnChord.monitor.stop()

            let cancelled = ControlMonitorEventHarness(shortcut: controlK)
            _ = cancelled.sendModifier(59, flags: .maskControl)
            _ = cancelled.sendKey(40, down: true, flags: .maskControl)
            let escape = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )!
            cancelled.monitor.cancelActiveSession(event: ComposerInputEventMetadata(event: escape))
            check(cancelled.replayed, [], "Escape cancellation discards a buffered shortcut without replaying it")
            _ = cancelled.sendKey(40, down: false, flags: .maskControl)
            _ = cancelled.sendModifier(59, flags: [])
            check(cancelled.monitor.isGestureIdle, true, "cancelled custom keys drain their releases and return to idle")
            cancelled.monitor.stop()

            let tapInterrupted = ControlMonitorEventHarness(shortcut: controlK)
            _ = tapInterrupted.sendModifier(59, flags: .maskControl)
            let disabledEvent = CGEvent(source: tapInterrupted.source)!
            _ = tapInterrupted.monitor.processEventForTesting(type: .tapDisabledByTimeout, event: disabledEvent)
            check(tapInterrupted.monitor.isGestureIdle, false, "tap interruption retains an orphan mask until a physical release")
            tapInterrupted.monitor.stop()
            check(tapInterrupted.monitor.isGestureIdle, true, "stopping after tap interruption clears all custom interception state")

            check(controlShiftChord.validationError, nil, "event-level chord cases use a valid configurable shortcut")
        }

        if failures.isEmpty {
            print("SELF_TEST_OK")
            return true
        }
        for failure in failures {
            fputs("SELF_TEST_FAILURE \(failure)\n", stderr)
        }
        return false
    }

    private static func controlProfileForReleaseTest() -> ShortcutProfile {
        ShortcutProfile(
            doubao: DoubaoShortcutConfiguration(
                mode: .leftControlHold,
                source: .manual,
                observedAt: Date()
            ),
            bridge: .followDoubao
        )
    }

    private static func waitForMainRunLoopCondition(
        timeout: TimeInterval,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return condition() }
            let nextPoll = Date().addingTimeInterval(min(remaining, 0.05))
            // RunLoop.run(until:) may return after handling another source.
            // Keep pumping until the production completion condition is true
            // or this test reaches its explicit upper bound.
            _ = RunLoop.main.run(mode: .default, before: nextPoll)
        }
        return true
    }
}

private final class ControlMonitorEventHarness {
    struct Summary: Equatable {
        let type: CGEventType
        let keyCode: Int64
        let flags: UInt64
    }

    struct RecordedEvent: Equatable {
        let summary: Summary
    }

    struct PostedShortcut: Equatable {
        let shortcut: KeyboardShortcut
        let down: Bool
    }

    let source = CGEventSource(stateID: .combinedSessionState)!
    let target = UURemoteTarget(application: NSRunningApplication.current)
    let profile: ShortcutProfile
    var windowMatches = true
    var windowCaptureSucceeds = true
    var uuIsFrontmost = true
    var bridgeHasFocus = true
    var composerReady = false
    var captureCount = 0
    var beginCount = 0
    var cancelCount = 0
    var releaseCount = 0
    var anyKeyStopCount = 0
    var postedShortcuts: [PostedShortcut] = []
    var replayed: [RecordedEvent] = []
    var unavailableMessages: [String] = []

    lazy var monitor: ControlHoldMonitor = {
        ControlHoldMonitor(
            profile: profile,
            holdThreshold: 0.25,
            targetProvider: { self.uuIsFrontmost ? self.target : nil },
            targetProviderDiagnostic: { "self-test" },
            targetIsActive: { _ in self.uuIsFrontmost || self.bridgeHasFocus },
            localComposerReady: { self.composerReady },
            onBegin: { _, _ in self.beginCount += 1 },
            onFnToggleMayBeActive: {},
            onRelease: { self.releaseCount += 1 },
            onCancel: { self.cancelCount += 1 },
            onTriggerUnavailable: { self.unavailableMessages.append($0) },
            customTargetWindowMatches: { _ in self.windowMatches },
            customTargetWindowCapture: { _ in self.captureCount += 1; return self.windowCaptureSucceeds },
            customEventReplay: { _, event in
                self.replayed.append(RecordedEvent(summary: Summary(
                    type: event.type,
                    keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                    flags: event.flags.rawValue
                )))
            },
            syntheticKeyboardEventPoster: { shortcut, down in
                self.postedShortcuts.append(PostedShortcut(shortcut: shortcut, down: down))
                return true
            },
            syntheticAnyKeyEventPoster: { self.anyKeyStopCount += 1; return true },
            bridgeApplicationOwnsFocus: { self.bridgeHasFocus }
        )
    }()

    convenience init(shortcut: KeyboardShortcut) {
        self.init(profile: ShortcutProfile(
            doubao: DoubaoShortcutConfiguration(mode: .leftControlHold, source: .manual, observedAt: Date()),
            bridge: .customHold(shortcut)
        ))
    }

    init(profile: ShortcutProfile) {
        self.profile = profile
    }

    @discardableResult
    func sendModifier(_ keyCode: Int64, flags: CGEventFlags) -> Bool {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)!
        event.type = .flagsChanged
        event.flags = flags
        return monitor.processEventForTesting(type: .flagsChanged, event: event)
    }

    @discardableResult
    func sendKey(_ keyCode: Int64, down: Bool, flags: CGEventFlags, sourcePID: Int64? = nil) -> Bool {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down)!
        event.flags = flags
        if let sourcePID { event.setIntegerValueField(.eventSourceUnixProcessID, value: sourcePID) }
        let type: CGEventType = down ? .keyDown : .keyUp
        return monitor.processEventForTesting(type: type, event: event)
    }

    @discardableResult
    func sendMouseDown(flags: CGEventFlags) -> Bool {
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .left
        )!
        event.flags = flags
        return monitor.processEventForTesting(type: .leftMouseDown, event: event)
    }
}
