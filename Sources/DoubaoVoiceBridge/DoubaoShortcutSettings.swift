import AppKit
import ApplicationServices

enum DoubaoShortcutMode: Equatable, Hashable {
    case fnToggle
    case leftControlHold
    case disabled
    case unsupported(String)

    var isSupported: Bool {
        switch self {
        case .fnToggle, .leftControlHold:
            return true
        case .disabled, .unsupported:
            return false
        }
    }

    var diagnosticName: String {
        switch self {
        case .fnToggle: return "fnToggle"
        case .leftControlHold: return "leftControlHold"
        case .disabled: return "disabled"
        case .unsupported: return "unsupported"
        }
    }

    var instruction: String {
        switch self {
        case .fnToggle:
            return "单击 Fn 开始，任意键结束"
        case .leftControlHold:
            return "长按左 ⌃ 说话，松开自动发送"
        case .disabled:
            return "豆包语音快捷键已关闭"
        case .unsupported(let display):
            return "豆包快捷键「\(display)」暂不支持"
        }
    }
}

enum DoubaoShortcutSource: Equatable {
    case preferences(String)
    case visibleSettingsWindow
    case manual
    case confirmed

    var description: String {
        switch self {
        case .preferences, .visibleSettingsWindow:
            return "豆包自动读取"
        case .manual:
            return "手动选择"
        case .confirmed:
            return "上次确认的设置"
        }
    }
}

struct DoubaoShortcutConfiguration: Equatable {
    let mode: DoubaoShortcutMode
    let source: DoubaoShortcutSource
    let observedAt: Date
    let shortcut: KeyboardShortcut?

    init(
        mode: DoubaoShortcutMode,
        source: DoubaoShortcutSource,
        observedAt: Date,
        shortcut: KeyboardShortcut? = nil
    ) {
        self.mode = mode
        self.source = source
        self.observedAt = observedAt
        self.shortcut = shortcut
    }

    var keyboardShortcut: KeyboardShortcut {
        shortcut ?? (mode == .fnToggle ? .fn : .leftControl)
    }

    var instruction: String {
        switch mode {
        case .fnToggle:
            return "按 \(keyboardShortcut.displayName) 启动，任意键结束"
        case .leftControlHold:
            return "按住 \(keyboardShortcut.displayName) 说话，松开结束"
        case .disabled, .unsupported:
            return mode.instruction
        }
    }

    var sourceAndTime: String {
        let time = DateFormatter.localizedString(from: observedAt, dateStyle: .none, timeStyle: .short)
        return "来源：\(source.description)，读取于 \(time)"
    }

    static func manual(
        _ mode: DoubaoShortcutMode,
        shortcut: KeyboardShortcut? = nil
    ) -> DoubaoShortcutConfiguration {
        let defaultShortcut = mode == .fnToggle ? KeyboardShortcut.fn : KeyboardShortcut.leftControl
        return DoubaoShortcutConfiguration(
            mode: mode,
            source: .manual,
            observedAt: Date(),
            shortcut: shortcut == defaultShortcut ? nil : shortcut
        )
    }
}

enum DoubaoShortcutSettingsReader {
    static let settingsBundleIdentifier = "com.bytedance.inputmethod.doubaoime.settings"
    static let settingsApplicationPath = URL(
        fileURLWithPath: "/Library/Input Methods/DoubaoIme.app/Contents/Applications/DoubaoImeSettings.app"
    )

    private static let preferenceDomains = [
        "com.bytedance.inputmethod.doubaoime.settings",
        "com.bytedance.inputmethod.doubaoime"
    ]

    private static let shortcutTextMarkers = [
        "快捷键", "免按模式", "长按模式", "按一次即可开始说话", "再按任意键可结束",
        "按住说话", "松手结束", "松开结束", "asrshortcut", "asrlongpress", "fn",
        "left control", "left ctrl", "leftcontrol", "leftctrl", "左control", "左ctrl",
        "right control", "right ctrl", "rightcontrol", "rightctrl", "右control", "右ctrl",
        "⌃", "control", "ctrl", "全局唤起语音", "离线语音", "高级设置", "其他设置"
    ]
    private static let modeGroupBoundaries = ["全局唤起语音", "离线语音", "高级设置", "其他设置"]
    private static let excludedAXRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXTextView", "AXSearchField", "AXTable", "AXOutline",
        "AXList", "AXRow", "AXCell"
    ]
    private static let explicitLeftControlTokens = [
        "leftcontrol", "leftctrl", "左control", "左ctrl", "left⌃", "左⌃"
    ]
    private static let explicitRightControlTokens = [
        "rightcontrol", "rightctrl", "右control", "右ctrl", "right⌃", "右⌃"
    ]
    private static let visibleKeyTokens = [
        "fn", "左shift", "leftshift", "shift", "⇧", "左option", "leftoption", "option", "alt", "⌥",
        "左command", "leftcommand", "command", "cmd", "⌘", "空格", "space", "回车", "return",
        "enter", "tab", "escape", "esc", "capslock"
    ]
    private static let standaloneVisibleKeyValues = Set(
        (visibleKeyTokens + explicitLeftControlTokens + explicitRightControlTokens + ["control", "ctrl"])
            .map { $0.lowercased().filter { !$0.isWhitespace } }
    )

    static func discover() -> DoubaoShortcutConfiguration? {
        if let visibleConfiguration = readVisibleSettingsWindow() {
            return visibleConfiguration
        }
        if let preferenceConfiguration = readShortcutPreferences() {
            return preferenceConfiguration
        }
        return nil
    }

    static func readShortcutPreferences() -> DoubaoShortcutConfiguration? {
        for domain in preferenceDomains {
            guard let defaults = UserDefaults(suiteName: domain),
                  let mode = mode(from: defaults) else { continue }
            return DoubaoShortcutConfiguration(mode: mode, source: .preferences(domain), observedAt: Date())
        }
        return nil
    }

    static func mode(
        isStartEnabled: Bool?,
        isGlobalEnabled: Bool?,
        keyCode: Int?,
        keyDisplay: String?,
        longPressKeyCode: Int?,
        longPressKeyDisplay: String?,
        modifierFlags: Int? = nil,
        longPressModifierFlags: Int? = nil
    ) -> DoubaoShortcutMode? {
        let isEnabled = isStartEnabled == true || isGlobalEnabled == true
        if isEnabled {
            guard let keyCode, let keyDisplay, !keyDisplay.isEmpty else { return nil }
            guard modifierFlags == nil || modifierFlags == 0 else {
                return .unsupported(keyDisplay)
            }
            if keyCode == 63 && keyDisplay.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "fn" {
                return .fnToggle
            }
            return .unsupported(keyDisplay)
        }

        if let longPressKeyCode, longPressKeyCode > 0 {
            guard let longPressKeyDisplay,
                  !longPressKeyDisplay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .unsupported("长按按键 \(longPressKeyCode)")
            }
            guard longPressModifierFlags == nil || longPressModifierFlags == 0 else {
                return .unsupported(longPressKeyDisplay)
            }
            if longPressKeyCode == 59 && isExplicitLeftControlDisplay(longPressKeyDisplay) {
                return .leftControlHold
            }
            return .unsupported(longPressKeyDisplay)
        }

        if isStartEnabled != nil || isGlobalEnabled != nil {
            return .disabled
        }
        return nil
    }

    static func mode(fromVisibleSettingsText text: String) -> DoubaoShortcutMode? {
        let modes = modeGroups(in: [[text]]).compactMap(mode(fromVisibleModeGroup:))
        let uniqueModes = Array(Set(modes))
        guard uniqueModes.count == 1 else { return nil }
        return uniqueModes[0]
    }

    static func readVisibleSettingsWindow() -> DoubaoShortcutConfiguration? {
        guard AXIsProcessTrusted(), let application = runningSettingsApplication() else { return nil }
        let snapshot = visibleSettingsTextSnapshot(for: application)
        let candidates = visibleModeCandidates(in: snapshot.windows)
        let uniqueModes = Array(Set(candidates))
        guard uniqueModes.count == 1, let mode = uniqueModes.first else { return nil }
        return DoubaoShortcutConfiguration(mode: mode, source: .visibleSettingsWindow, observedAt: Date())
    }

    static func hasVisibleSettingsWindow() -> Bool {
        guard AXIsProcessTrusted(),
              let application = runningSettingsApplication(),
              !application.isHidden else { return false }
        return visibleSettingsTextSnapshot(for: application).readableWindowCount > 0
    }

    static func visibleSettingsDiagnostics() -> String {
        guard AXIsProcessTrusted() else { return "Doubao settings AX: not trusted" }
        guard let application = runningSettingsApplication() else { return "Doubao settings AX: app not running" }
        let snapshot = visibleSettingsTextSnapshot(for: application)
        let candidates = visibleModeCandidates(in: snapshot.windows)
        let uniqueModes = Array(Set(candidates))
        let modeDescription = uniqueModes.count == 1 ? uniqueModes[0].instruction : "unreadable or conflicting"
        let candidateGroups = modeGroups(in: snapshot.windows)
        let instructionFragmentCount = candidateGroups.filter { hasShortcutModeInstructions($0.joined()) }.count
        let categorySummary = candidateCategorySummary(candidates)
        let snippets = candidateGroups
            .filter { hasShortcutModeInstructions($0.joined()) }
            .map(shortSettingsSnippet)
            .prefix(3)
            .joined(separator: " || ")
        return "Doubao settings AX: hidden=\(application.isHidden) windows=\(snapshot.windowCount) readable=\(snapshot.readableWindowCount) textFragments=\(snapshot.fragments.count) instructionGroups=\(instructionFragmentCount) parsedModes=\(candidates.count) categories=\(categorySummary) mode=\(modeDescription) fields=[\(snippets)]"
    }

    private static func mode(from defaults: UserDefaults) -> DoubaoShortcutMode? {
        func boolValue(_ keys: [String]) -> Bool? {
            let values = keys.compactMap { defaults.object(forKey: $0) as? NSNumber }.map(\.boolValue)
            return values.isEmpty ? nil : values.contains(true)
        }

        func intValue(_ key: String) -> Int? {
            guard let value = defaults.object(forKey: key) as? NSNumber else { return nil }
            return value.intValue
        }

        return mode(
            isStartEnabled: boolValue(["isStartASRShortcutEnable"]),
            isGlobalEnabled: boolValue(["isGlobalASRShortcutEnable", "isGloableASRShortcutEnable"]),
            keyCode: intValue("asrShortcutKeyCode"),
            keyDisplay: defaults.string(forKey: "asrShortcutKeyDisplay"),
            longPressKeyCode: intValue("asrLongPressShortcutKeyCode"),
            longPressKeyDisplay: defaults.string(forKey: "asrLongPressShortcutKeyDisplay"),
            modifierFlags: intValue("asrShortcutModifierFlags"),
            longPressModifierFlags: intValue("asrLongPressShortcutModifierFlags")
        )
    }

    private static func runningSettingsApplication() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == settingsBundleIdentifier && !$0.isTerminated
        }
    }

    private static func visibleSettingsTextSnapshot(for application: NSRunningApplication) -> SettingsTextSnapshot {
        guard !application.isHidden else { return SettingsTextSnapshot(windowCount: 0, readableWindowCount: 0, windows: []) }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows) == .success,
              let windows = rawWindows as? [AXUIElement] else {
            return SettingsTextSnapshot(windowCount: 0, readableWindowCount: 0, windows: [])
        }

        var collectedWindows: [[String]] = []
        var remainingNodeBudget = 600
        var readableWindowCount = 0
        for window in windows where isReadableWindow(window) {
            readableWindowCount += 1
            var textFragments: [String] = []
            collectShortcutText(from: window, depth: 0, budget: &remainingNodeBudget, into: &textFragments)
            collectedWindows.append(textFragments)
        }
        return SettingsTextSnapshot(
            windowCount: windows.count,
            readableWindowCount: readableWindowCount,
            windows: collectedWindows
        )
    }

    static func visibleModeCandidates(in windows: [[String]]) -> [DoubaoShortcutMode] {
        let filteredWindows = windows.map { $0.filter(shouldCollectShortcutText) }
        return modeGroups(in: filteredWindows).compactMap(mode(fromVisibleModeGroup:))
    }

    static func shouldCollectShortcutText(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let compacted = lowercased.filter { !$0.isWhitespace }
        return standaloneVisibleKeyValues.contains(compacted) || shortcutTextMarkers.contains { marker in
            lowercased.contains(marker) || compacted.contains(marker.filter { !$0.isWhitespace })
        }
    }

    private static func mode(fromVisibleModeGroup group: [String]) -> DoubaoShortcutMode? {
        let normalized = group.joined(separator: "|").lowercased().filter { !$0.isWhitespace }
        if normalized.contains("免按模式"),
           normalized.contains("按一次即可开始说话"),
           normalized.contains("再按任意键可结束"),
           let modeRange = normalized.range(of: "免按模式") {
            let modeText = String(normalized[modeRange.upperBound...])
            guard let startRange = modeText.range(of: "按一次即可开始说话"),
                  let endingRange = modeText.range(
                      of: "再按任意键可结束",
                      range: startRange.upperBound..<modeText.endIndex
                  ) else { return nil }
            let selectedKeyArea = String(modeText[..<startRange.lowerBound]) +
                String(modeText[endingRange.upperBound...])
            guard let candidate = uniqueVisibleKeyCandidate(in: selectedKeyArea) else { return nil }
            return candidate == "fn" ? .fnToggle : .unsupported(displayName(for: candidate))
        }

        guard normalized.contains("长按模式"),
              normalized.contains("按住说话"),
              let modeRange = normalized.range(of: "长按模式") else { return nil }
        let modeText = String(normalized[modeRange.upperBound...])
        guard let pressRange = modeText.range(of: "按住说话") else { return nil }
        let releaseRanges = ["松手结束", "松开结束"].compactMap { token in
            modeText.range(of: token, range: pressRange.upperBound..<modeText.endIndex)
        }
        guard let releaseRange = releaseRanges.min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let selectedKeyArea = String(modeText[..<pressRange.lowerBound]) +
            String(modeText[releaseRange.upperBound...])
        guard let candidate = uniqueVisibleKeyCandidate(in: selectedKeyArea) else { return nil }
        return candidate == "leftcontrol" ? .leftControlHold : .unsupported(displayName(for: candidate))
    }

    private static func modeGroups(in windows: [[String]]) -> [[String]] {
        windows.flatMap { fragments in
            var groups: [[String]] = []
            var activeGroup: [String]?
            for fragment in fragments {
                let normalized = fragment.lowercased().filter { !$0.isWhitespace }
                var cursor = normalized.startIndex
                while cursor < normalized.endIndex {
                    var next: (range: Range<String.Index>, token: String, startsGroup: Bool)?
                    for token in ["免按模式", "长按模式"] + modeGroupBoundaries {
                        guard let range = normalized.range(of: token, range: cursor..<normalized.endIndex) else { continue }
                        if next == nil || range.lowerBound < next!.range.lowerBound {
                            next = (range, token, token == "免按模式" || token == "长按模式")
                        }
                    }
                    guard let next else {
                        if activeGroup != nil, cursor < normalized.endIndex {
                            activeGroup?.append(String(normalized[cursor...]))
                        }
                        break
                    }

                    if activeGroup != nil, cursor < next.range.lowerBound {
                        activeGroup?.append(String(normalized[cursor..<next.range.lowerBound]))
                    }
                    if next.startsGroup {
                        if let activeGroup { groups.append(activeGroup) }
                        activeGroup = [next.token]
                    } else if activeGroup != nil {
                        groups.append(activeGroup ?? [])
                        activeGroup = nil
                    }
                    cursor = next.range.upperBound
                }
            }
            if let activeGroup { groups.append(activeGroup) }
            return groups
        }
    }

    private static func hasShortcutModeInstructions(_ text: String) -> Bool {
        let normalized = text.lowercased().filter { !$0.isWhitespace }
        let hasFnToggleInstructions = normalized.contains("免按模式") &&
            normalized.contains("按一次即可开始说话") &&
            normalized.contains("再按任意键可结束")
        let hasLongPressInstructions = normalized.contains("长按模式") &&
            normalized.contains("按住说话") &&
            (normalized.contains("松手结束") || normalized.contains("松开结束"))
        return hasFnToggleInstructions || hasLongPressInstructions
    }

    private static func candidateCategorySummary(_ modes: [DoubaoShortcutMode]) -> String {
        var counts: [String: Int] = [:]
        for mode in modes {
            let category: String
            switch mode {
            case .fnToggle: category = "fn"
            case .leftControlHold: category = "left-control"
            case .disabled: category = "disabled"
            case .unsupported: category = "unsupported"
            }
            counts[category, default: 0] += 1
        }
        return counts.keys.sorted().map { "\($0):\(counts[$0] ?? 0)" }.joined(separator: ",")
    }

    private static func shortSettingsSnippet(_ fragments: [String]) -> String {
        let joined = fragments.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(joined.prefix(220))
    }

    private static func isReadableWindow(_ element: AXUIElement) -> Bool {
        var rawValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &rawValue) == .success,
           (rawValue as? NSNumber)?.boolValue == true {
            return false
        }
        if AXUIElementCopyAttributeValue(element, "AXHidden" as CFString, &rawValue) == .success,
           (rawValue as? NSNumber)?.boolValue == true {
            return false
        }
        var rawSize: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &rawSize) == .success,
           let rawSize,
           CFGetTypeID(rawSize) == AXValueGetTypeID() {
            let value = unsafeBitCast(rawSize, to: AXValue.self)
            var size = CGSize.zero
            if AXValueGetValue(value, .cgSize, &size), size.width <= 0 || size.height <= 0 {
                return false
            }
        }
        return true
    }

    private static func containsVisibleToken(_ token: String, in text: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: token, range: searchRange) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            let beforeIsASCIIWord = before.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false
            let afterIsASCIIWord = after.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false
            if !beforeIsASCIIWord && !afterIsASCIIWord { return true }
            searchRange = range.upperBound..<text.endIndex
        }
        return false
    }

    private static func uniqueVisibleKeyCandidate(in text: String) -> String? {
        let normalized = text.lowercased().filter { !$0.isWhitespace }
        var candidates = Set<String>()

        if explicitLeftControlTokens.contains(where: { containsVisibleToken($0, in: normalized) }) {
            candidates.insert("leftcontrol")
        }
        if explicitRightControlTokens.contains(where: { containsVisibleToken($0, in: normalized) }) {
            candidates.insert("rightcontrol")
        }
        if candidates.isEmpty,
           ["control", "ctrl", "⌃"].contains(where: { containsVisibleToken($0, in: normalized) }) {
            candidates.insert("control")
        }
        for token in visibleKeyTokens where containsVisibleToken(token, in: normalized) {
            candidates.insert(token)
        }

        guard candidates.count == 1 else { return nil }
        return candidates.first
    }

    private static func displayName(for candidate: String) -> String {
        switch candidate {
        case "leftcontrol": return "left control"
        case "rightcontrol": return "right control"
        case "control": return "control"
        default: return candidate
        }
    }

    private static func isExplicitLeftControlDisplay(_ value: String) -> Bool {
        let normalized = value.lowercased().filter { !$0.isWhitespace }
        return normalized.contains("leftcontrol") || normalized.contains("leftctrl") ||
            normalized.contains("左control") || normalized.contains("左ctrl") ||
            normalized.contains("left⌃") || normalized.contains("左⌃")
    }

    private struct SettingsTextSnapshot {
        let windowCount: Int
        let readableWindowCount: Int
        let windows: [[String]]
        var fragments: [String] { windows.flatMap { $0 } }
    }

    private static func collectShortcutText(
        from element: AXUIElement,
        depth: Int,
        budget: inout Int,
        into fragments: inout [String]
    ) {
        guard depth <= 10, budget > 0 else { return }
        budget -= 1

        var rawRole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &rawRole) == .success,
           let role = rawRole as? String,
           excludedAXRoles.contains(role) {
            return
        }

        for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            var rawValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
                  let text = rawValue as? String else { continue }
            if shouldCollectShortcutText(text) {
                fragments.append(text)
            }
        }

        var rawChildren: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &rawChildren) == .success,
              let children = rawChildren as? [AXUIElement] else { return }
        for child in children where budget > 0 {
            collectShortcutText(from: child, depth: depth + 1, budget: &budget, into: &fragments)
        }
    }
}
