import Cocoa
import EasyShareKit

/// The long-lived Quick Share receiver. It is an accessory app: its status
/// item is the only persistent UI, while Finder invokes the embedded extension
/// for Mac-to-Android sends.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let receivingEnabledKey = "dev.easyshare.quickshare.receiving-enabled"
    private static let offerDecisionTimeout: TimeInterval = 60

    private enum ReceiverStatus {
        case starting
        case ready(port: UInt16)
        case off
        case failed(String)

        var summary: String {
            switch self {
            case .starting: return "Starting Android Quick Share…"
            case .ready: return "Ready for Android Quick Share"
            case .off: return "Not receiving"
            case .failed(let detail): return "Can’t receive — \(detail)"
            }
        }

        var tint: NSColor {
            switch self {
            case .starting: return .systemOrange
            case .ready: return .systemGreen
            case .off: return .tertiaryLabelColor
            case .failed: return .systemRed
            }
        }
    }

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var receiver: QuickShareReceiver?
    private var status: ReceiverStatus = .starting
    private var receivedFiles: [String: [URL]] = [:]
    private var menuIsOpen = false

    private var receivingEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.receivingEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.receivingEnabledKey) }
    }

    private var displayName: String {
        let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Mac"
        return name.isEmpty ? "Mac" : name
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        if receivingEnabled {
            startReceiver()
        } else {
            status = .off
            refreshUI()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        receiver?.stop()
    }

    // MARK: - Receiver

    private func startReceiver() {
        guard receiver == nil else { return }
        let downloads = (try? FileManager.default.url(
            for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

        do {
            let receiver = try QuickShareReceiver(
                displayName: displayName, downloadsDirectory: downloads, delegate: self
            )
            receiver.onStateChange = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .starting: self.status = .starting
                    case .ready(let port): self.status = .ready(port: port)
                    case .stopped: self.status = .off
                    case .failed(let detail): self.status = .failed(detail)
                    }
                    self.refreshUI()
                }
            }
            self.receiver = receiver
            try receiver.start()
        } catch {
            status = .failed(error.localizedDescription)
            refreshUI()
            NSLog("[EasyShare.QuickShare] could not start receiver: \(error)")
        }
    }

    private func stopReceiver() {
        receiver?.stop()
        receiver = nil
        receivedFiles.removeAll()
        status = .off
        refreshUI()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(named: "MenuBarIcon")
        icon?.isTemplate = true
        icon?.accessibilityDescription = "Easy Share"
        item.button?.image = icon
        item.button?.imagePosition = .imageOnly
        item.menu = menu
        menu.delegate = self
        statusItem = item
        refreshUI()
    }

    private func refreshUI() {
        statusItem?.button?.appearsDisabled = !receivingEnabled || receiver == nil
        statusItem?.button?.toolTip = "Easy Share — \(status.summary)"
        guard !menuIsOpen else { return }
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(sectionHeader("Easy Share"))

        let statusItem = disabled(status.summary)
        statusItem.image = Self.dot(status.tint)
        menu.addItem(statusItem)

        let guidance = disabled("Use Android’s Quick Share with visibility set to Everyone. Both devices must be on the same Wi-Fi network.")
        guidance.attributedTitle = Self.twoLine(
            "Android Quick Share",
            "Set visibility to Everyone, then select \(displayName)."
        )
        menu.addItem(guidance)

        menu.addItem(.separator())
        let toggle = NSMenuItem(
            title: receivingEnabled ? "Stop Receiving" : "Receive with Quick Share",
            action: #selector(toggleReceiving), keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let downloads = NSMenuItem(title: "Open Downloads", action: #selector(openDownloads), keyEquivalent: "")
        downloads.target = self
        menu.addItem(downloads)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Easy Share", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(withTitle: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func twoLine(_ primary: String, _ secondary: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: primary, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        text.append(NSAttributedString(string: "\n" + secondary, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]))
        return text
    }

    private static func dot(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 9, height: 9), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.accessibilityDescription = color.accessibilityName
        return image
    }

    @objc private func toggleReceiving() {
        receivingEnabled.toggle()
        if receivingEnabled { startReceiver() } else { stopReceiver() }
    }

    @objc private func openDownloads() {
        let downloads = (try? FileManager.default.url(
            for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        NSWorkspace.shared.open(downloads)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Incoming offers

    private func askToAccept(_ offer: QuickShareIncomingOffer) -> Bool {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = offer.files.count == 1
            ? "\(offer.senderName) wants to send \(IncomingFilename.sanitize(offer.files[0].name))"
            : "\(offer.senderName) wants to send \(offer.files.count) files"
        alert.informativeText = Self.describe(offer)
        alert.addButton(withTitle: "Accept")
        alert.addButton(withTitle: "Decline")

        let timeout = DispatchWorkItem { NSApp.abortModal() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.offerDecisionTimeout, execute: timeout)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        timeout.cancel()
        return response == .alertFirstButtonReturn
    }

    private static func describe(_ offer: QuickShareIncomingOffer) -> String {
        let total = ByteCountFormatter.string(fromByteCount: offer.totalSize, countStyle: .file)
        let files = offer.files.prefix(5)
            .map { "• " + IncomingFilename.sanitize($0.name) }
            .joined(separator: "\n")
        let more = offer.files.count > 5 ? "\n… and \(offer.files.count - 5) more" : ""
        let code = offer.verificationPIN.isEmpty ? "" : "\n\nVerify code: \(offer.verificationPIN)"
        return "\(total) total\n\n\(files)\(more)\(code)"
    }

    private func recordReceivedFile(_ url: URL, from senderName: String) {
        let senderID = "quickshare:\(senderName)"
        var files = receivedFiles[senderID] ?? []
        guard files.count < 64 else { return }
        files.append(url)
        receivedFiles[senderID] = files
    }

    private func revealTransfer(from senderName: String) {
        let files = receivedFiles.removeValue(forKey: "quickshare:\(senderName)") ?? []
        if !files.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(files)
        } else {
            openDownloads()
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }
    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        rebuildMenu()
    }
}

extension AppDelegate: QuickShareReceiverDelegate {
    nonisolated func quickShareReceiverShouldAccept(_ offer: QuickShareIncomingOffer) async -> Bool {
        await MainActor.run { self.askToAccept(offer) }
    }

    nonisolated func quickShareReceiverDidReceiveFile(at url: URL, from senderName: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.recordReceivedFile(url, from: senderName) } }
    }

    nonisolated func quickShareReceiverDidFinishTransfer(from senderName: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.revealTransfer(from: senderName) } }
    }

    nonisolated func quickShareReceiverDidFail(_ error: Error, from senderName: String?) {
        NSLog("[EasyShare.QuickShare] transfer from \(senderName ?? "unknown device") failed: \(error)")
    }
}
