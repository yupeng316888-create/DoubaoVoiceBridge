import AppKit
import ApplicationServices

enum PrivacySafeTextMetrics {
    static func lengthBucket(_ length: Int) -> String {
        switch length {
        case ..<1: return "empty"
        case 1...4: return "1-4"
        case 5...16: return "5-16"
        case 17...64: return "17-64"
        default: return "65+"
        }
    }
}

enum Diagnostics {
    private static let diagnosticTapCallback: CGEventTapCallBack = { _, _, event, _ in
        Unmanaged.passUnretained(event)
    }

    static func checkClipboardImage() -> Bool {
        do {
            let png = try ClipboardImageReader.png(from: .general)
            let image = NSBitmapImageRep(data: png)
            let canBackup = PasteboardSnapshot.capture(from: .general) != nil
            print("clipboard_image=readable png_bytes=\(png.count) width=\(image?.pixelsWide ?? 0) height=\(image?.pixelsHigh ?? 0) backup=\(canBackup)")
            return canBackup
        } catch {
            print("clipboard_image_error=\(error.localizedDescription)")
            return false
        }
    }

    static func printReport() {
        let workspace = NSWorkspace.shared
        let uuRemote = workspace.runningApplications.first {
            $0.bundleIdentifier == AppDelegate.uuRemoteBundleIdentifier
        }
        let doubaoPath = "/Library/Input Methods/DoubaoIme.app"
        let eventMask = CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue)
        let probeTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: diagnosticTapCallback,
            userInfo: nil
        )
        if let probeTap { CFMachPortInvalidate(probeTap) }

        let values: [(String, String)] = [
            ("bundle", Bundle.main.bundleIdentifier ?? "unknown"),
            ("version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"),
            ("local_voice_key", AppDelegate.configuredLocalVoiceKey.rawValue),
            ("accessibility", AXIsProcessTrusted() ? "granted" : "missing"),
            ("input_monitoring", CGPreflightListenEventAccess() ? "granted" : "missing"),
            ("hid_event_tap", probeTap == nil ? "unavailable" : "available"),
            ("doubao", FileManager.default.fileExists(atPath: doubaoPath) ? "installed" : "missing"),
            ("uuremote", uuRemote == nil ? "not_running" : "running"),
            ("frontmost", workspace.frontmostApplication?.bundleIdentifier ?? "unknown")
        ]
        for (key, value) in values {
            print("\(key)=\(value)")
        }
    }
}
