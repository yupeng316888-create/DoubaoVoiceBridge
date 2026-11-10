import AppKit

@main
enum DoubaoVoiceBridgeMain {
    static func main() {
        if CommandLine.arguments.contains("--diagnostics") {
            Diagnostics.printReport()
            return
        }
        if CommandLine.arguments.contains("--check-clipboard-image") {
            exit(Diagnostics.checkClipboardImage() ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTests.run() ? EXIT_SUCCESS : EXIT_FAILURE)
        }

        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        application.delegate = appDelegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
