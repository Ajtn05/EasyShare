import AppKit

/// Explicitly owns the AppKit lifetime for the menu-bar process.
///
/// `@main` on an `NSApplicationDelegate` class is normally enough for a Cocoa
/// app, but this no-nib LSUIElement build was reaching the event loop without
/// ever installing its delegate: it launched and immediately had no status
/// item, listener, or Bonjour advertisement. Retaining the delegate here makes
/// the startup contract unambiguous and keeps it alive for `run()`'s lifetime.
@main
struct EasyShareMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
