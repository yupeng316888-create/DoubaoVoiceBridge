import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os.log

// Image-only addition. Voice capture, transcription and text delivery stay unchanged.
enum ScreenshotPolicy {
    static let maximumPNGBytes = 16 * 1024 * 1024
    static let maximumPixels = 32_000_000
    static func syncDelay(bytes: Int) -> TimeInterval {
        min(15, 10 + Double(bytes) / 1_048_576)
    }
    static func canPaste(sameClipboard: Bool, sameProcess: Bool, sameWindow: Bool) -> Bool {
        sameClipboard && sameProcess && sameWindow
    }
}

final class ScreenshotDestination {
    let application: NSRunningApplication
    let window: AXUIElement
    let label: String
    init(application: NSRunningApplication, window: AXUIElement, label: String) {
        self.application = application; self.window = window; self.label = label
    }
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func screenLabel(_ element: AXUIElement, depth: Int = 0) -> String? {
        guard depth < 7 else { return nil }
        for name in [kAXValueAttribute, kAXTitleAttribute] {
            if let text = attribute(element, name) as? String,
               text.hasPrefix("显示屏"), text.count < 120 { return text }
        }
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for child in children.prefix(80) {
            if let label = screenLabel(child, depth: depth + 1) { return label }
        }
        return nil
    }
    static func resolve() -> ScreenshotDestination? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == AppDelegate.uuRemoteBundleIdentifier && !$0.isTerminated
        }) else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        if let raw = attribute(element, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            let focused = unsafeDowncast(raw, to: AXUIElement.self)
            if let label = screenLabel(focused) { return ScreenshotDestination(application: app, window: focused, label: label) }
        }
        // A single connected remote screen is unambiguous, even when the UU home or terminal is frontmost.
        let windows = attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let screens = windows.compactMap { w -> ScreenshotDestination? in
            guard let label = screenLabel(w) else { return nil }
            return ScreenshotDestination(application: app, window: w, label: label)
        }
        return screens.count == 1 ? screens[0] : nil
    }
    func activate() {
        application.activate(options: [.activateIgnoringOtherApps])
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }
    func stillFocused() -> Bool {
        guard !application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              let current = Self.attribute(AXUIElementCreateApplication(application.processIdentifier), kAXFocusedWindowAttribute)
        else { return false }
        return CFEqual(window, current)
    }
}

final class ScreenshotCoordinator: NSObject {
    var canStart: () -> Bool = { false }
    var onStatusChange: ((String, Bool) -> Void)?
    private(set) var isBusy = false
    private let logger = Logger(subsystem: "com.lyp.DoubaoVoiceBridge", category: "screenshot")
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var captureProcess: Process?
    private var capturedPNG: Data?
    private var clipboardSnapshot: PasteboardSnapshot?
    private var ownClipboardCount: Int?
    private var panel: NSWindow?
    private var statusLabel: NSTextField?
    private var status = "先在远端点好输入框，再切回本机要截图的内容。"

    func start() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return noErr }
            let owner = Unmanaged<ScreenshotCoordinator>.fromOpaque(data).takeUnretainedValue()
            owner.logger.notice("Screenshot shortcut received")
            DispatchQueue.main.async { owner.beginCapture() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { report("截图快捷键注册失败，可从菜单打开。", error: true); return }
        let hotKeyID = EventHotKeyID(signature: 0x44564253, id: 2)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(optionKey | shiftKey), hotKeyID,
                                        GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { report("⌥⇧S 已被占用，可使用菜单中的截图按钮。", error: true) }
        logger.notice("Screenshot shortcut registration status=\(status)")
    }
    func prepareForTermination() {
        captureProcess?.terminate()
        restoreClipboardIfUnchanged()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
    private func report(_ message: String, error: Bool = false) {
        status = message
        statusLabel?.stringValue = message
        statusLabel?.textColor = error ? .systemRed : .secondaryLabelColor
        onStatusChange?(message, error)
    }
    @objc func showTools() {
        if panel == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 255),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "远控截图"
            window.isReleasedWhenClosed = false
            let title = NSTextField(labelWithString: "截图后粘贴到另一台 Mac · 不自动发送")
            title.font = .systemFont(ofSize: 17, weight: .semibold)
            let help = NSTextField(wrappingLabelWithString: "先在 UU 远端选好输入框，再回到本机。按 ⌥⇧S 框选截图，松开鼠标后自动粘贴；Esc 取消。左 Control 语音输入保持原样。")
            let state = NSTextField(wrappingLabelWithString: status)
            state.font = .systemFont(ofSize: 12)
            state.textColor = .secondaryLabelColor
            statusLabel = state
            let capture = NSButton(title: "开始截图（⌥⇧S）", target: self, action: #selector(beginCapture))
            let clipboard = NSButton(title: "粘贴剪贴板中的图片", target: self, action: #selector(pasteClipboardImage))
            let retry = NSButton(title: "重新粘贴上一张截图", target: self, action: #selector(retryLastImage))
            let stack = NSStackView(views: [title, help, capture, clipboard, retry, state])
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            window.contentView?.addSubview(stack)
            if let view = window.contentView {
                NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
                    stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
                    stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 22)])
            }
            window.center(); panel = window
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }
    private func acquireDestination() -> ScreenshotDestination? {
        guard !isBusy, canStart() else {
            report("正在听写或传送内容，请完成后再截图。", error: true); return nil
        }
        guard AXIsProcessTrusted(), let target = ScreenshotDestination.resolve() else {
            report("请先打开 UU 的远端屏幕并点好输入框，再使用截图。", error: true); showTools(); return nil
        }
        return target
    }
    @objc func beginCapture() {
        guard let target = acquireDestination() else { return }
        guard CGPreflightScreenCaptureAccess() else {
            report("缺少录屏权限：请在系统设置的“录屏与系统录音”中开启远控听写，并重新打开本应用。", error: true)
            logger.error("Capture blocked before launch: screen recording permission missing")
            showTools()
            return
        }
        isBusy = true; panel?.orderOut(nil)
        report("请框选本机截图区域；Esc 取消。")
        waitForModifiers(deadline: Date().addingTimeInterval(3)) { [weak self] in
            self?.launchCapture(to: target)
        }
    }
    private func waitForModifiers(deadline: Date, action: @escaping () -> Void) {
        let flags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        if CGEventSource.flagsState(.combinedSessionState).intersection(flags).isEmpty { action(); return }
        guard Date() < deadline else { isBusy = false; report("请松开快捷键后重试。", error: true); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForModifiers(deadline: deadline, action: action)
        }
    }
    private func launchCapture(to target: ScreenshotDestination) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dvb-screenshot-" + UUID().uuidString)
        let file = dir.appendingPathComponent("capture.png")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", "-t", "png", file.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            captureProcess = process
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.captureProcess = nil
                    defer { try? FileManager.default.removeItem(at: dir) }
                    guard process.terminationStatus == 0 else {
                        self.isBusy = false
                        self.report("系统截图失败。请检查录屏权限，并重新打开远控听写；本次没有粘贴。", error: true)
                        self.logger.error("System capture failed status=\(process.terminationStatus)")
                        self.showTools()
                        return
                    }
                    guard let png = try? Data(contentsOf: file), !png.isEmpty else {
                        self.isBusy = false
                        self.report("截图已取消或未取得图片；没有粘贴任何内容。")
                        self.logger.notice("Capture ended without image; no paste")
                        return
                    }
                    self.deliver(png, to: target)
                }
            }
            try process.run()
        } catch {
            captureProcess = nil; isBusy = false
            try? FileManager.default.removeItem(at: dir)
            report("无法启动系统截图：\(error.localizedDescription)", error: true)
        }
    }
    @objc func pasteClipboardImage() {
        guard let target = acquireDestination() else { return }
        let p = NSPasteboard.general
        let png = p.data(forType: .png) ?? p.data(forType: .tiff).flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        }
        guard let png else { report("剪贴板中没有图片。", error: true); return }
        isBusy = true; deliver(png, to: target)
    }
    @objc func retryLastImage() {
        guard let target = acquireDestination() else { return }
        guard let png = capturedPNG else { report("还没有可重试的截图。", error: true); return }
        isBusy = true; deliver(png, to: target)
    }
    private func deliver(_ png: Data, to target: ScreenshotDestination) {
        guard png.count <= ScreenshotPolicy.maximumPNGBytes,
              let image = NSBitmapImageRep(data: png), image.pixelsWide > 0, image.pixelsHigh > 0,
              image.pixelsWide * image.pixelsHigh <= ScreenshotPolicy.maximumPixels,
              let tiff = image.tiffRepresentation else {
            isBusy = false; report("截图过大或格式不可用，请缩小截图区域。", error: true); showTools(); return
        }
        let pasteboard = NSPasteboard.general
        guard let snapshot = PasteboardSnapshot.capture(from: pasteboard) else {
            isBusy = false; report("原剪贴板内容较大，无法安全备份；本次没有覆盖。", error: true); showTools(); return
        }
        capturedPNG = png
        clipboardSnapshot = snapshot
        let item = NSPasteboardItem(); item.setData(png, forType: .png); item.setData(tiff, forType: .tiff)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            snapshot.restore(to: pasteboard); clipboardSnapshot = nil; isBusy = false
            report("写入图片剪贴板失败。", error: true); return
        }
        ownClipboardCount = pasteboard.changeCount
        let generation = pasteboard.changeCount
        panel?.orderOut(nil); target.activate()
        report("正在将截图同步到远端…")
        logger.notice("Image staged width=\(image.pixelsWide) height=\(image.pixelsHigh) bytes=\(png.count)")
        DispatchQueue.main.asyncAfter(deadline: .now() + ScreenshotPolicy.syncDelay(bytes: png.count)) { [weak self] in
            guard let self else { return }
            guard ScreenshotPolicy.canPaste(sameClipboard: pasteboard.changeCount == generation,
                sameProcess: !target.application.isTerminated,
                sameWindow: target.stillFocused()) else {
                self.restoreClipboardIfUnchanged(); self.isBusy = false
                self.report("焦点或剪贴板已变化，已取消自动粘贴。可从截图工具重试。", error: true)
                self.logger.notice("Image paste cancelled because target or clipboard changed")
                return
            }
            ClipboardKeyboardPaster.postCommandV { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.report("已执行图片粘贴，未发送消息。")
                    self.logger.notice("Image Command-V completed; no Return or send action")
                    // A successful screenshot replaces the clipboard, like native Copy Screenshot.
                    // UU may still be transferring/decoding the image after the key sequence.
                    // A timed restore can overwrite the remote image before the editor consumes it.
                    self.clipboardSnapshot = nil
                    self.ownClipboardCount = nil
                    self.isBusy = false
                case .failure(let error):
                    self.restoreClipboardIfUnchanged(); self.isBusy = false
                    self.report(error.localizedDescription, error: true)
                }
            }
        }
    }
    private func restoreClipboardIfUnchanged() {
        if let snapshot = clipboardSnapshot, let count = ownClipboardCount,
           NSPasteboard.general.changeCount == count { snapshot.restore(to: .general) }
        clipboardSnapshot = nil; ownClipboardCount = nil
    }
}
