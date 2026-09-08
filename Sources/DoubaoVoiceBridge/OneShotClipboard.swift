import AppKit

/// Writes only the current transcript, once. Never replays an old clipboard.
final class OneShotClipboard {
    private let pasteboard: NSPasteboard
    private var generation: Int?
    private(set) var writeCount = 0

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func stage(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        // Request host-local propagation. Compatibility with UU clipboard forwarding
        // remains experimental; this option is not a remote receipt acknowledgement.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.setString(text, forType: .string) else { return false }
        generation = pasteboard.changeCount
        writeCount += 1
        return true
    }

    func read(expectedText: String) -> DeliveryClipboardState {
        let before = pasteboard.changeCount
        let items = pasteboard.pasteboardItems ?? []
        let matches = items.count == 1 && items[0].string(forType: .string) == expectedText
        let plain = items.count == 1 && !items[0].types.isEmpty &&
            items[0].types.allSatisfy { $0 == .string || $0.rawValue == "NSStringPboardType" }
        let after = pasteboard.changeCount
        return DeliveryClipboardState(
            stableRead: before == after, originalGeneration: after == generation,
            textMatches: matches, onlyPlainText: plain, empty: items.isEmpty
        )
    }
}
