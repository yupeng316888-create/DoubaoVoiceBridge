import Foundation

enum ClipboardDeliveryPolicy {
    static func allowsPaste(
        stableRead: Bool,
        originalGeneration: Bool,
        textMatches: Bool,
        onlyPlainText: Bool
    ) -> Bool {
        stableRead && textMatches && (originalGeneration || onlyPlainText)
    }
}
