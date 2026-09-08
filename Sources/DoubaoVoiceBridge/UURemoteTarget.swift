import AppKit
import ApplicationServices

final class UURemoteTarget {
    let application: NSRunningApplication
    private var focusedWindow: AXUIElement?

    init(application: NSRunningApplication) {
        self.application = application
    }

    var isTerminated: Bool { application.isTerminated }
    var processIdentifier: pid_t { application.processIdentifier }

    @discardableResult
    func captureFocusedWindow() -> Bool {
        focusedWindow = Self.copyFocusedWindow(pid: processIdentifier)
        return focusedWindow != nil
    }

    func activateOriginalWindow() {
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: application)
            application.activate(from: .current, options: [])
        } else {
            application.activate(options: [.activateIgnoringOtherApps])
        }
        guard let focusedWindow else { return }
        // UU normally retains its focused window while the composer is active.
        // Avoid two synchronous AX writes on every utterance in that common case.
        if let current = Self.copyFocusedWindow(pid: processIdentifier), CFEqual(focusedWindow, current) {
            return
        }
        AXUIElementSetMessagingTimeout(focusedWindow, 0.15)
        AXUIElementPerformAction(focusedWindow, kAXRaiseAction as CFString)
    }

    func deliveryFocusState() -> DeliveryFocusState {
        guard !isTerminated else { return .closed }
        guard let focusedWindow else { return .missingOriginalWindow }
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard frontmost?.processIdentifier == processIdentifier else {
            if frontmost == nil || frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ||
                frontmost?.bundleIdentifier == "com.apple.dock" { return .transitioning }
            return .otherApplication
        }
        guard let current = Self.copyFocusedWindow(pid: processIdentifier) else { return .transitioning }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
            return .transitioning
        }
        return CFEqual(focusedWindow, current) ? .matching : .otherWindow
    }

    func stillMatchesFocusedWindow() -> Bool {
        guard let focusedWindow else { return false }
        guard let current = Self.copyFocusedWindow(pid: processIdentifier) else { return false }
        return CFEqual(focusedWindow, current)
    }

    private static func copyFocusedWindow(pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}
