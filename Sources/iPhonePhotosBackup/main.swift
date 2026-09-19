import Cocoa

@main
struct AppEntry {
    @MainActor
    static func main() {
        // Use our custom NSApplication subclass so the macOS loading/busy
        // cursor is always suppressed in favour of the standard arrow.
        let app = NoWaitCursorApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
