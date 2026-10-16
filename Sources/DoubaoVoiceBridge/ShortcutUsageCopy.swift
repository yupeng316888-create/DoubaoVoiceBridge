import Foundation

struct ShortcutUsageCopy: Equatable {
    let title: String
    let detail: String

    static func make(doubao: DoubaoShortcutConfiguration?, bridge: BridgeShortcutConfiguration) -> ShortcutUsageCopy {
        guard let doubao, doubao.mode.isSupported, bridge.validationError(for: doubao) == nil else {
            return ShortcutUsageCopy(title: "先设置语音按键", detail: "打开高级设置，选择与豆包相同的语音键和远控触发键。")
        }
        let profile = ShortcutProfile(doubao: doubao, bridge: bridge)
        let name = profile.bridgeShortcut.displayName
            .replacingOccurrences(of: "Right", with: "右")
            .replacingOccurrences(of: "Left", with: "左")
        let toggles = bridge.kind == .followDoubao && doubao.mode == .fnToggle
        return ShortcutUsageCopy(
            title: toggles ? "在 UU 中点按 \(name) 开始" : "在 UU 中按住 \(name) 说话",
            detail: toggles ? "按任意键结束识别，文字自动粘贴到远端输入框。" : "松开按键结束识别，文字自动粘贴到远端输入框。"
        )
    }
}
