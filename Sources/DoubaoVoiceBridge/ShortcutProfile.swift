import AppKit
import Foundation

struct KeyboardShortcut: Codable, Equatable, Hashable {
    static let supportedModifierMask =
        CGEventFlags.maskShift.rawValue |
        CGEventFlags.maskControl.rawValue |
        CGEventFlags.maskAlternate.rawValue |
        CGEventFlags.maskCommand.rawValue

    let keyCode: UInt16
    let modifierMask: UInt64

    init(keyCode: UInt16, modifierMask: UInt64 = 0) {
        self.keyCode = keyCode
        self.modifierMask = modifierMask
    }

    static let fn = KeyboardShortcut(keyCode: 63)
    static let leftControl = KeyboardShortcut(keyCode: 59)

    var eventFlags: CGEventFlags { CGEventFlags(rawValue: modifierMask) }
    var isModifierOnly: Bool { Self.modifierFlag(for: Int64(keyCode)) != nil }

    var validationError: String? {
        guard keyCode <= 127 else { return "该系统按键不能作为触发键" }
        guard keyCode != 53 else { return "Escape 保留为取消键，请选择其他按键" }
        guard keyCode != 57 else { return "Caps Lock 会改变输入状态，不能作为触发键" }
        guard keyCode != 114 else { return "Help 键由系统保留，请选择其他按键" }
        guard keyCode != 127 else { return "电源键由系统保留，请选择其他按键" }
        guard modifierMask & ~Self.supportedModifierMask == 0 else {
            return "仅支持 Control、Shift、Option 和 Command 组合键"
        }
        if let modifierFlag = Self.modifierFlag(for: Int64(keyCode)) {
            guard modifierMask == 0 else { return "修饰键请单独录制，不能再叠加组合键" }
            if modifierFlag == CGEventFlags.maskSecondaryFn.rawValue {
                guard keyCode == 63 else { return "Fn 键不能与其他修饰键组合" }
            }
        }
        return nil
    }

    var doubaoValidationError: String? {
        if let validationError { return validationError }
        if keyCode == 36 || keyCode == 76 {
            return "Return 会提交听写面板，不能作为豆包语音键"
        }
        if modifierMask & CGEventFlags.maskCommand.rawValue != 0,
           [12, 13, 4, 46, 43].contains(keyCode) {
            return "该 Command 组合会触发应用菜单，请为豆包选择其他按键"
        }
        return nil
    }

    var displayName: String {
        var pieces: [String] = []
        if modifierMask & CGEventFlags.maskControl.rawValue != 0 { pieces.append("⌃") }
        if modifierMask & CGEventFlags.maskAlternate.rawValue != 0 { pieces.append("⌥") }
        if modifierMask & CGEventFlags.maskShift.rawValue != 0 { pieces.append("⇧") }
        if modifierMask & CGEventFlags.maskCommand.rawValue != 0 { pieces.append("⌘") }
        pieces.append(Self.keyName(for: keyCode))
        return pieces.joined(separator: "")
    }

    static func modifierFlag(for keyCode: Int64) -> UInt64? {
        switch keyCode {
        case 54, 55: return CGEventFlags.maskCommand.rawValue
        case 56, 60: return CGEventFlags.maskShift.rawValue
        case 58, 61: return CGEventFlags.maskAlternate.rawValue
        case 59, 62: return CGEventFlags.maskControl.rawValue
        case 63: return CGEventFlags.maskSecondaryFn.rawValue
        default: return nil
        }
    }

    static func keyName(for keyCode: UInt16) -> String {
        let names: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
            54: "Right ⌘", 55: "Left ⌘", 56: "Left ⇧", 57: "Caps Lock", 58: "Left ⌥",
            59: "Left ⌃", 60: "Right ⇧", 61: "Right ⌥", 62: "Right ⌃", 63: "Fn",
            76: "Keypad Enter", 115: "Home", 116: "Page Up", 117: "Forward Delete",
            119: "End", 121: "Page Down", 122: "F1", 120: "F2", 99: "F3", 118: "F4",
            96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16",
            64: "F17", 79: "F18", 80: "F19", 90: "F20"
        ]
        if let name = names[keyCode] { return name }
        let symbols: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y",
            17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
            45: "N", 46: "M", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
            22: "6", 26: "7", 28: "8", 25: "9", 29: "0"
        ]
        return symbols[keyCode] ?? "Key \(keyCode)"
    }
}

enum SyntheticShortcutEventFlags {
    static func fnToggle(down: Bool) -> CGEventFlags {
        down ? [.maskSecondaryFn] : []
    }
}

struct SyntheticKeyboardEventDescription: Equatable {
    enum Kind: Equatable { case flagsChanged, keyDown, keyUp }
    let kind: Kind
    let keyCode: UInt16
    let flags: UInt64
}

enum SyntheticKeyboardShortcutPlan {
    private static let modifierKeys: [(UInt64, UInt16)] = [
        (CGEventFlags.maskControl.rawValue, 59),
        (CGEventFlags.maskAlternate.rawValue, 58),
        (CGEventFlags.maskShift.rawValue, 56),
        (CGEventFlags.maskCommand.rawValue, 55)
    ]

    static func events(for shortcut: KeyboardShortcut, down: Bool) -> [SyntheticKeyboardEventDescription] {
        if shortcut.keyCode == 63 {
            return [SyntheticKeyboardEventDescription(
                kind: .flagsChanged,
                keyCode: 63,
                flags: down ? CGEventFlags.maskSecondaryFn.rawValue : 0
            )]
        }
        if shortcut.isModifierOnly {
            let modifierFlag = KeyboardShortcut.modifierFlag(for: Int64(shortcut.keyCode)) ?? 0
            return [SyntheticKeyboardEventDescription(
                kind: .flagsChanged,
                keyCode: shortcut.keyCode,
                flags: down ? modifierFlag : 0
            )]
        }

        let modifiers = modifierKeys.filter { shortcut.modifierMask & $0.0 != 0 }
        if down {
            var flags: UInt64 = 0
            var events: [SyntheticKeyboardEventDescription] = []
            for (modifier, keyCode) in modifiers {
                flags |= modifier
                events.append(SyntheticKeyboardEventDescription(kind: .flagsChanged, keyCode: keyCode, flags: flags))
            }
            events.append(SyntheticKeyboardEventDescription(kind: .keyDown, keyCode: shortcut.keyCode, flags: shortcut.modifierMask))
            return events
        }

        var flags = shortcut.modifierMask
        var events = [SyntheticKeyboardEventDescription(kind: .keyUp, keyCode: shortcut.keyCode, flags: flags)]
        for (modifier, keyCode) in modifiers.reversed() {
            flags &= ~modifier
            events.append(SyntheticKeyboardEventDescription(kind: .flagsChanged, keyCode: keyCode, flags: flags))
        }
        return events
    }

    static func tap(for shortcut: KeyboardShortcut) -> [SyntheticKeyboardEventDescription] {
        events(for: shortcut, down: true) + events(for: shortcut, down: false)
    }
}

enum BridgeShortcutKind: String, CaseIterable {
    case followDoubao
    case leftControlHold
    case customHold

    var title: String {
        switch self {
        case .followDoubao: return "跟随豆包按键"
        case .leftControlHold: return "左 Control 长按"
        case .customHold: return "自定义按键（长按）"
        }
    }
}

struct BridgeShortcutConfiguration: Equatable {
    let kind: BridgeShortcutKind
    let shortcut: KeyboardShortcut?

    init(kind: BridgeShortcutKind, shortcut: KeyboardShortcut? = nil) {
        self.kind = kind
        self.shortcut = shortcut
    }

    static let followDoubao = BridgeShortcutConfiguration(kind: .followDoubao)
    static let leftControlHold = BridgeShortcutConfiguration(kind: .leftControlHold)
    static func customHold(_ shortcut: KeyboardShortcut) -> BridgeShortcutConfiguration {
        BridgeShortcutConfiguration(kind: .customHold, shortcut: shortcut)
    }

    var display: String {
        switch kind {
        case .followDoubao: return "跟随豆包按键"
        case .leftControlHold: return "左 Control 长按"
        case .customHold: return "自定义 \(shortcut?.displayName ?? "未录制")"
        }
    }

    func validationError(for doubao: DoubaoShortcutConfiguration) -> String? {
        guard doubao.mode.isSupported else { return "请先选择豆包支持的语音按键与开始方式" }
        if let error = doubao.shortcut?.doubaoValidationError { return error }
        if kind == .customHold {
            guard let shortcut else { return "请先录制远控触发键" }
            return shortcut.validationError
        }
        return nil
    }
}

struct ShortcutProfile: Equatable {
    let doubao: DoubaoShortcutConfiguration
    let bridge: BridgeShortcutConfiguration

    var isSupported: Bool {
        doubao.mode.isSupported && doubao.shortcut?.doubaoValidationError == nil && bridge.validationError(for: doubao) == nil
    }

    var usesFnBridge: Bool {
        bridge.kind == .followDoubao && doubao.mode == .fnToggle && doubao.shortcut == nil
    }

    var usesLeftControlBridge: Bool {
        bridge.kind == .leftControlHold ||
            (bridge.kind == .followDoubao && doubao.mode == .leftControlHold && doubao.shortcut == nil)
    }

    var usesCustomBridge: Bool {
        bridge.kind == .customHold
    }

    var followsCustomDoubaoShortcut: Bool {
        bridge.kind == .followDoubao && doubao.shortcut != nil
    }

    var usesCustomEventBridge: Bool {
        usesCustomBridge || followsCustomDoubaoShortcut
    }

    var usesFollowCustomToggleBridge: Bool {
        followsCustomDoubaoShortcut && doubao.mode == .fnToggle
    }

    var bridgeShortcut: KeyboardShortcut {
        switch bridge.kind {
        case .followDoubao:
            return doubao.shortcut ?? (doubao.mode == .fnToggle ? .fn : .leftControl)
        case .leftControlHold:
            return .leftControl
        case .customHold:
            return bridge.shortcut ?? .leftControl
        }
    }

    var customBridgeIsSupported: Bool {
        if usesCustomBridge {
            return bridge.shortcut != nil && bridge.shortcut?.validationError == nil
        }
        return followsCustomDoubaoShortcut && doubao.shortcut?.validationError == nil
    }

    var supportsManualComposerEntry: Bool {
        isSupported && doubao.mode == .leftControlHold && doubao.keyboardShortcut == .leftControl
    }

    var bridgeInstruction: String {
        if usesFnBridge { return "按 Fn 开始，再按任意键结束" }
        if followsCustomDoubaoShortcut, doubao.mode == .fnToggle {
            return "轻按 \(bridgeShortcut.displayName) 开始，再按任意键结束"
        }
        return "按住 \(bridgeShortcut.displayName) 开始，松开结束"
    }

    var doubaoInstruction: String {
        doubao.shortcut == nil ? doubao.mode.instruction : doubao.instruction
    }

    var statusMenuLines: [String] {
        [
            "远控触发键：\(bridgeShortcut.displayName)（\(bridgeInstruction)）",
            "豆包语音键：\(doubao.keyboardShortcut.displayName)（\(doubaoInstruction)）"
        ]
    }

    static func hasSameTriggerBehavior(_ first: ShortcutProfile?, _ second: ShortcutProfile?) -> Bool {
        guard let first, let second else { return first == nil && second == nil }
        return first.doubao.mode == second.doubao.mode && first.doubao.shortcut == second.doubao.shortcut &&
            first.bridge.kind == second.bridge.kind && first.bridge.shortcut == second.bridge.shortcut
    }
}

enum ShortcutTriggerReadiness {
    static func status(
        profile: ShortcutProfile?,
        setupPending: Bool,
        monitorActive: Bool,
        accessibilityTrusted: Bool = true
    ) -> String? {
        guard !setupPending, monitorActive, accessibilityTrusted,
              let profile, profile.isSupported else { return nil }
        return "就绪 · \(profile.statusMenuLines.joined(separator: "；"))"
    }
}

struct ShortcutConfigurationStore {
    private let defaults: UserDefaults
    private let manualDoubaoKey = "shortcut.manualDoubaoMode.v1"
    private let manualDoubaoBindingKey = "shortcut.manualDoubaoBinding.v1"
    private let confirmedDoubaoKey = "shortcut.confirmedDoubaoMode.v1"
    private let confirmedDoubaoBindingKey = "shortcut.confirmedDoubaoBinding.v1"
    private let confirmedAtKey = "shortcut.confirmedAt.v1"
    private let bridgeKindKey = "shortcut.bridgeKind.v1"
    private let bridgeBindingKey = "shortcut.bridgeBinding.v1"
    private let setupCompleteKey = "shortcut.setupComplete.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var didCompleteSetup: Bool { defaults.bool(forKey: setupCompleteKey) }

    var hasCorruptOrIncompleteSavedConfiguration: Bool {
        guard didCompleteSetup else { return false }
        let manualWasSaved = defaults.object(forKey: manualDoubaoKey) != nil
        let bridgeWasSaved = defaults.object(forKey: bridgeKindKey) != nil
        let confirmedAt = (defaults.object(forKey: confirmedAtKey) as? NSNumber)?.doubleValue ?? 0
        let manualAndConfirmedModesMatch = loadManualDoubaoConfiguration()?.mode == nil ||
            (loadManualDoubaoConfiguration()?.mode == loadLastConfirmedDoubaoConfiguration()?.mode &&
             loadManualDoubaoConfiguration()?.shortcut == loadLastConfirmedDoubaoConfiguration()?.shortcut)
        let invalidSavedBinding =
            invalidShortcut(forKey: manualDoubaoBindingKey, doubao: true) ||
            invalidShortcut(forKey: confirmedDoubaoBindingKey, doubao: true) ||
            invalidShortcut(forKey: bridgeBindingKey, doubao: false)
        let customBridgeMissingBinding = defaults.string(forKey: bridgeKindKey) == BridgeShortcutKind.customHold.rawValue &&
            loadShortcut(forKey: bridgeBindingKey) == nil
        let selectedDoubao = loadManualDoubaoConfiguration() ?? loadLastConfirmedDoubaoConfiguration()
        let savedProfileIsUnsupported = selectedDoubao.flatMap { doubao in
            loadBridgeConfiguration().map { !ShortcutProfile(doubao: doubao, bridge: $0).isSupported }
        } ?? true
        return (manualWasSaved && loadManualDoubaoConfiguration() == nil) ||
            !bridgeWasSaved || loadBridgeConfiguration() == nil ||
            loadLastConfirmedDoubaoConfiguration() == nil || confirmedAt <= 0 ||
            !manualAndConfirmedModesMatch || invalidSavedBinding || customBridgeMissingBinding || savedProfileIsUnsupported
    }

    func loadManualDoubaoConfiguration() -> DoubaoShortcutConfiguration? {
        guard let raw = defaults.string(forKey: manualDoubaoKey) else { return nil }
        let mode: DoubaoShortcutMode
        switch raw {
        case "fnToggle": mode = .fnToggle
        case "leftControlHold": mode = .leftControlHold
        default: return nil
        }
        return DoubaoShortcutConfiguration(
            mode: mode,
            source: .manual,
            observedAt: Date(),
            shortcut: loadShortcut(forKey: manualDoubaoBindingKey)
        )
    }

    func loadBridgeConfiguration() -> BridgeShortcutConfiguration? {
        guard let raw = defaults.string(forKey: bridgeKindKey),
              let kind = BridgeShortcutKind(rawValue: raw) else { return nil }
        return BridgeShortcutConfiguration(kind: kind, shortcut: loadShortcut(forKey: bridgeBindingKey))
    }

    func loadLastConfirmedDoubaoConfiguration() -> DoubaoShortcutConfiguration? {
        guard let raw = defaults.string(forKey: confirmedDoubaoKey),
              let mode = supportedMode(from: raw) else { return nil }
        let timestamp = defaults.double(forKey: confirmedAtKey)
        let observedAt = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : Date()
        return DoubaoShortcutConfiguration(
            mode: mode,
            source: .confirmed,
            observedAt: observedAt,
            shortcut: loadShortcut(forKey: confirmedDoubaoBindingKey)
        )
    }

    func updateConfirmedModeFromAutomaticRead(_ mode: DoubaoShortcutMode) {
        guard didCompleteSetup,
              defaults.object(forKey: manualDoubaoKey) == nil,
              !hasCorruptOrIncompleteSavedConfiguration,
              let raw = rawValue(for: mode) else { return }
        guard loadLastConfirmedDoubaoConfiguration()?.mode != mode else { return }
        defaults.set(raw, forKey: confirmedDoubaoKey)
        defaults.set(Date().timeIntervalSince1970, forKey: confirmedAtKey)
        defaults.removeObject(forKey: confirmedDoubaoBindingKey)
    }

    func save(
        confirmedDoubaoMode: DoubaoShortcutMode,
        manualDoubaoMode: DoubaoShortcutMode?,
        manualDoubaoShortcut: KeyboardShortcut? = nil,
        confirmedDoubaoShortcut: KeyboardShortcut? = nil,
        bridge: BridgeShortcutConfiguration
    ) -> Bool {
        guard let confirmedRaw = rawValue(for: confirmedDoubaoMode) else { return false }
        let confirmedConfiguration = DoubaoShortcutConfiguration(
            mode: confirmedDoubaoMode,
            source: .confirmed,
            observedAt: Date(),
            shortcut: confirmedDoubaoShortcut
        )
        guard confirmedDoubaoShortcut?.doubaoValidationError == nil,
              bridge.validationError(for: confirmedConfiguration) == nil,
              manualDoubaoMode.map({ $0.isSupported }) ?? true,
              manualDoubaoShortcut?.doubaoValidationError == nil else { return false }
        defaults.set(confirmedRaw, forKey: confirmedDoubaoKey)
        defaults.set(Date().timeIntervalSince1970, forKey: confirmedAtKey)
        saveShortcut(confirmedDoubaoShortcut, forKey: confirmedDoubaoBindingKey)
        if let manualDoubaoMode {
            if let raw = rawValue(for: manualDoubaoMode) {
                defaults.set(raw, forKey: manualDoubaoKey)
            } else {
                defaults.removeObject(forKey: manualDoubaoKey)
            }
            saveShortcut(manualDoubaoShortcut, forKey: manualDoubaoBindingKey)
        } else {
            defaults.removeObject(forKey: manualDoubaoKey)
            defaults.removeObject(forKey: manualDoubaoBindingKey)
        }
        defaults.set(bridge.kind.rawValue, forKey: bridgeKindKey)
        saveShortcut(bridge.shortcut, forKey: bridgeBindingKey)
        defaults.set(true, forKey: setupCompleteKey)

        guard didCompleteSetup,
              loadLastConfirmedDoubaoConfiguration()?.mode == confirmedDoubaoMode,
              loadLastConfirmedDoubaoConfiguration()?.shortcut == confirmedDoubaoShortcut,
              loadBridgeConfiguration()?.kind == bridge.kind,
              loadBridgeConfiguration()?.shortcut == bridge.shortcut else { return false }
        if let manualDoubaoMode {
            return loadManualDoubaoConfiguration()?.mode == manualDoubaoMode &&
                loadManualDoubaoConfiguration()?.shortcut == manualDoubaoShortcut
        }
        return loadManualDoubaoConfiguration() == nil
    }

    private func supportedMode(from raw: String) -> DoubaoShortcutMode? {
        switch raw {
        case "fnToggle": return .fnToggle
        case "leftControlHold": return .leftControlHold
        default: return nil
        }
    }

    private func rawValue(for mode: DoubaoShortcutMode) -> String? {
        switch mode {
        case .fnToggle: return "fnToggle"
        case .leftControlHold: return "leftControlHold"
        case .disabled, .unsupported: return nil
        }
    }

    private func loadShortcut(forKey key: String) -> KeyboardShortcut? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyboardShortcut.self, from: data)
    }

    private func invalidShortcut(forKey key: String, doubao: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return false }
        guard let shortcut = loadShortcut(forKey: key) else { return true }
        return doubao ? shortcut.doubaoValidationError != nil : shortcut.validationError != nil
    }

    private func saveShortcut(_ shortcut: KeyboardShortcut?, forKey key: String) {
        guard let shortcut,
              let data = try? JSONEncoder().encode(shortcut) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
