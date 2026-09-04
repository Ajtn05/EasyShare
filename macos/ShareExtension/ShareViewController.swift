import Cocoa
import CoreImage
import EasyShareKit
import UniformTypeIdentifiers

/// The Finder Share menu entry point.
///
/// This class is named as `NSExtensionPrincipalClass` in Info.plist. macOS
/// instantiates it inside a short-lived, sandboxed process when the user picks
/// "Easy Share" from a Share menu.
///
/// Three constraints shape everything here:
///
/// 1. **The process is short-lived.** As soon as you call
///    `completeRequest`/`cancelRequest`, macOS may tear you down. Do NOT start a
///    transfer and then complete the request — the upload dies mid-flight.
///    Either hold the extension open for the duration (what this scaffold does),
///    or hand off to the container app via an XPC service or a URL scheme.
///
/// 2. **The sandbox is tight.** The extension gets read access to exactly the
///    URLs handed to it in the `NSItemProvider`s, and nothing else. It needs its
///    own `com.apple.security.network.client` entitlement — the container app's
///    entitlements do not apply here.
///
/// 3. **Discovery is best-effort.** A paired Android companion is the normal
///    route; stock Quick Share and its QR handoff remain available as a
///    compatibility fallback when the companion is not enabled.
final class ShareViewController: NSViewController {

    private struct PreparedFile {
        let url: URL
        let type: UTType?
        let name: String
        let size: Int64
        let mimeType: String
        /// A folder is staged as a ZIP in the extension's temporary directory.
        /// Regular files are uploaded from the URL supplied by the item provider.
        let isTemporaryArchive: Bool
    }

    /// Where the sender flow currently is.
    ///
    /// Every control on screen is a function of this value and nothing else.
    /// The previous version inferred its state from the text on a button —
    /// `if cancelButton.title == "Done"` — which meant the flow could only ever
    /// be as correct as that string, and any new state needed another string to
    /// compare against.
    fileprivate enum Destination: Identifiable, Equatable {
        case companion(CompanionPeer, pairedRecord: StoredCompanion?)
        case nearby(QuickSharePeer)
        case saved(SavedRecipient, resolvedPeer: QuickSharePeer?)
        case qrCode

        var id: String {
            switch self {
            case .companion(let peer, _): return "companion:\(peer.id)"
            case .nearby(let peer): return "quickshare:\(peer.id)"
            case .saved(let recipient, _): return "saved:\(recipient.id)"
            case .qrCode: return "quickshare-qr"
            }
        }

        var displayName: String {
            switch self {
            case .companion(let peer, _): return peer.displayName
            case .nearby(let peer): return peer.displayName
            case .saved(let recipient, _): return recipient.displayName
            case .qrCode: return "Connect with QR Code"
            }
        }

        var detail: String {
            switch self {
            case .companion(let peer, .some):
                return "Paired Android companion • \(peer.address)"
            case .companion(let peer, .none):
                return "Android companion • Pair this Mac • \(peer.address)"
            case .nearby(let peer):
                return "Android Quick Share • \(peer.address)"
            case .saved(_, let peer?):
                return "Saved Android Quick Share device • \(peer.address)"
            case .saved:
                return "Saved device • open Quick Share on the phone"
            case .qrCode:
                return "Scan with your Android phone when discovery is unavailable"
            }
        }

        var iconName: String {
            switch self {
            case .companion: return "lock.iphone"
            default: return "iphone"
            }
        }

        /// A remembered name is only a preference, never a stored network
        /// address or identity. It becomes sendable only after this share
        /// session has a live Quick Share advertisement to bind it to.
        var resolvedPeer: QuickSharePeer? {
            switch self {
            case .nearby(let peer): return peer
            case .saved(_, let peer): return peer
            case .companion, .qrCode: return nil
            }
        }

        var isReadyToSend: Bool {
            switch self {
            case .companion: return true
            case .qrCode: return true
            default: return resolvedPeer != nil
            }
        }
    }

    /// A local convenience label, not a Quick Share trust relationship. Stock
    /// Everyone advertisements use ephemeral endpoints, so keeping an IP,
    /// port, QR URL, or prior UKEY2 state would be both unreliable and unsafe.
    /// The optional marker is the public opaque value from the last QR-backed
    /// advertisement; it disambiguates current anonymous receivers but is not
    /// a credential and may rotate.
    fileprivate struct SavedRecipient: Codable, Identifiable, Equatable {
        let id: String
        let displayName: String
        var advertisingIdentity: Data?
        var lastUsed: Date
    }

    private enum Phase {
        case preparing
        case searching
        case choosing
        case awaitingQuickShareQRCode
        case connecting(Destination)
        case sending(Destination, fileIndex: Int, fraction: Double)
        case finished(Destination)
        /// `retry` is the peer to try again, when trying again could work.
        case failed(message: String, retry: Destination?)

        /// Whether the peer list should still accept a click.
        var allowsPeerSelection: Bool {
            switch self {
            case .choosing, .searching, .failed: return true
            default:                             return false
            }
        }
    }

    private var quickShareDiscovery: QuickShareDiscovery?
    private var companionDiscovery: CompanionDiscovery?
    private var companionPeers: [CompanionPeer] = []
    private var quickSharePeers: [QuickSharePeer] = []
    private var storedCompanions: [StoredCompanion] = CompanionCredentialStore.records()
    private var savedRecipients: [SavedRecipient] = ShareViewController.loadSavedRecipients()
    private var orderedPeers: [Destination] = []
    private var files: [PreparedFile] = []
    private var totalBytes: Int64 = 0
    private var activeQuickShareSender: QuickShareSender?
    private var quickShareQRCodeSession: QuickShareQRCodeSession?
    private var quickShareQRCodeTimeout: DispatchWorkItem?
    private var quickShareVerificationPIN: String?
    private var transferTask: Task<Void, Never>?
    private var noPeersWorkItem: DispatchWorkItem?
    private var phase: Phase = .preparing { didSet { render() } }

    // MARK: Views

    private let fileIcon = NSImageView()
    private let eyebrowLabel = NSTextField(labelWithString: "EASY SHARE")
    private let titleLabel = NSTextField(labelWithString: "Send to Android")
    private let filesLabel = NSTextField(labelWithString: "Preparing files…")
    private let listContainer = NSView()
    private let statusCard = NSView()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let quickShareQRCodeImage = NSImageView()
    private let quickShareQRCodeCaption = NSTextField(
        wrappingLabelWithString: "Scan with the phone camera, then tap the Quick Share link. Keep Wi‑Fi and Bluetooth on while this screen stays open."
    )
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let uploadProgress = NSProgressIndicator()
    private let primaryButton = NSButton(title: "Send", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private static let rowIdentifier = NSUserInterfaceItemIdentifier("peer")
    private static let savedRecipientsKey = "dev.easyshare.quickshare.saved-recipients.v1"

    override func loadView() {
        let root = AppearanceObservingView(frame: NSRect(x: 0, y: 0, width: 460, height: 440))
        root.onAppearanceChange = { [weak self] in self?.applyThemeColors() }

        // --- Header ---------------------------------------------------------
        fileIcon.imageScaling = .scaleProportionallyUpOrDown
        fileIcon.image = NSImage(named: "ShareIcon")
        NSLayoutConstraint.activate([
            fileIcon.widthAnchor.constraint(equalToConstant: 40),
            fileIcon.heightAnchor.constraint(equalToConstant: 40),
        ])

        eyebrowLabel.attributedStringValue = NSAttributedString(string: "EASY SHARE", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: Brand.primary,
            .kern: 0.8,
        ])
        titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
        filesLabel.font = .systemFont(ofSize: 12)
        filesLabel.textColor = .secondaryLabelColor
        filesLabel.lineBreakMode = .byTruncatingMiddle
        filesLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let headerText = NSStackView(views: [eyebrowLabel, titleLabel, filesLabel])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 2
        headerText.setCustomSpacing(1, after: eyebrowLabel)

        let header = NSStackView(views: [fileIcon, headerText])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        // --- Peer list ------------------------------------------------------
        table.headerView = nil
        table.rowHeight = 46
        table.style = .inset
        table.backgroundColor = .clear
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.intercellSpacing = NSSize(width: 0, height: 2)
        let column = NSTableColumn(identifier: Self.rowIdentifier)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        // Double-click sends, for anyone who treats a list like a Finder window.
        table.doubleAction = #selector(primaryAction)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        quickShareQRCodeImage.imageScaling = .scaleAxesIndependently
        quickShareQRCodeImage.wantsLayer = true
        quickShareQRCodeImage.layer?.magnificationFilter = .nearest
        quickShareQRCodeImage.isHidden = true
        quickShareQRCodeImage.translatesAutoresizingMaskIntoConstraints = false

        quickShareQRCodeCaption.alignment = .center
        quickShareQRCodeCaption.textColor = .secondaryLabelColor
        quickShareQRCodeCaption.font = .systemFont(ofSize: 11)
        quickShareQRCodeCaption.maximumNumberOfLines = 2
        quickShareQRCodeCaption.isHidden = true
        quickShareQRCodeCaption.translatesAutoresizingMaskIntoConstraints = false

        listContainer.wantsLayer = true
        listContainer.layer?.cornerRadius = 14
        listContainer.layer?.borderWidth = 1
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(scroll)
        listContainer.addSubview(emptyLabel)
        listContainer.addSubview(quickShareQRCodeImage)
        listContainer.addSubview(quickShareQRCodeCaption)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: listContainer.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor, constant: -4),
            emptyLabel.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: listContainer.widthAnchor, constant: -40),
            quickShareQRCodeImage.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor),
            quickShareQRCodeImage.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor, constant: -20),
            quickShareQRCodeImage.widthAnchor.constraint(equalToConstant: 152),
            quickShareQRCodeImage.heightAnchor.constraint(equalToConstant: 152),
            quickShareQRCodeCaption.topAnchor.constraint(equalTo: quickShareQRCodeImage.bottomAnchor, constant: 7),
            quickShareQRCodeCaption.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor),
            quickShareQRCodeCaption.widthAnchor.constraint(equalTo: listContainer.widthAnchor, constant: -32),
        ])

        // --- Status ---------------------------------------------------------
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3

        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        statusCard.wantsLayer = true
        statusCard.layer?.cornerRadius = 12
        statusCard.translatesAutoresizingMaskIntoConstraints = false
        statusCard.addSubview(statusRow)
        NSLayoutConstraint.activate([
            statusRow.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 12),
            statusRow.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -12),
            statusRow.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 9),
            statusRow.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -9),
        ])

        uploadProgress.style = .bar
        uploadProgress.isIndeterminate = false
        uploadProgress.minValue = 0
        uploadProgress.maxValue = 1
        uploadProgress.isHidden = true
        uploadProgress.controlSize = .small

        // --- Buttons --------------------------------------------------------
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}"          // Esc
        cancelButton.bezelStyle = .rounded

        primaryButton.target = self
        primaryButton.action = #selector(primaryAction)
        primaryButton.keyEquivalent = "\r"             // Return
        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .large
        primaryButton.bezelColor = Brand.primary

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancelButton, primaryButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10

        // --- Assembly -------------------------------------------------------
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(header)
        content.addArrangedSubview(listContainer)
        content.addArrangedSubview(statusCard)
        content.addArrangedSubview(uploadProgress)
        content.addArrangedSubview(buttons)
        content.setCustomSpacing(8, after: statusCard)

        root.addSubview(content)
        for view in [header, listContainer, statusCard, uploadProgress, buttons] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            listContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 190),
        ])

        self.view = root
        self.preferredContentSize = root.frame.size
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyThemeColors()

        Task { [weak self] in
            guard let self else { return }
            let urls = await self.resolveAttachments()
            await MainActor.run {
                self.prepare(urls: urls)
            }
        }
    }

    /// CGColor does not follow the system appearance the way an NSColor does. A
    /// border, background, or status tint set once stays wrong on a sheet whose
    /// appearance changes, so every appearance-derived layer color is reapplied
    /// whenever the effective appearance changes. `render()` recomputes the
    /// status card's tint from the current phase as a side effect.
    private func applyThemeColors() {
        listContainer.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        listContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        render()
    }

    deinit {
        quickShareDiscovery?.stop()
        companionDiscovery?.stop()
        activeQuickShareSender?.cancel()
        noPeersWorkItem?.cancel()
        quickShareQRCodeTimeout?.cancel()
        transferTask?.cancel()
        cleanUpTemporaryArchives()
    }

    // MARK: - Rendering

    /// The single place any control's appearance is decided.
    private func render() {
        switch phase {
        case .preparing:
            setStatus("Preparing…", busy: true)
        case .searching:
            setStatus("Looking for paired Android companions…", busy: true)
        case .choosing:
            let companionCount = companionPeers.count
            if let paired = orderedPeers.first(where: {
                if case .companion(_, .some) = $0 { return true }
                return false
            }) {
                setStatus(
                    "\(paired.displayName) is ready to receive.",
                    busy: false
                )
            } else if companionCount > 0 {
                setStatus("Select your Android companion to pair this Mac.", busy: false)
            } else {
                setStatus("Turn on Receive from Mac on Android, or use Quick Share QR Code.", busy: false)
            }
        case .awaitingQuickShareQRCode:
            setStatus("Waiting for Android Quick Share to connect…", busy: true)
        case .connecting(let peer):
            if let pin = quickShareVerificationPIN {
                setStatus("Verify code \(pin) on \(peer.displayName), then accept…", busy: true)
            } else {
                setStatus("Waiting for \(peer.displayName) to accept…", busy: true)
            }
        case .sending(let peer, let index, let fraction):
            let name = files.indices.contains(index) ? files[index].name : ""
            let counter = files.count > 1 ? " (\(index + 1) of \(files.count))" : ""
            setStatus("Sending \(name)\(counter) to \(peer.displayName)…", busy: true)
            uploadProgress.doubleValue = overallFraction(fileIndex: index, fraction: fraction)
        case .finished(let peer):
            setStatus(
                "Sent \(files.count == 1 ? "1 file" : "\(files.count) files") to \(peer.displayName).",
                busy: false,
                isSuccess: true
            )
        case .failed(let message, _):
            setStatus(message, busy: false, isError: true)
        }

        if case .sending = phase {
            uploadProgress.isHidden = false
        } else {
            uploadProgress.isHidden = true
        }

        let showingQRCode: Bool
        if case .awaitingQuickShareQRCode = phase { showingQRCode = true } else { showingQRCode = false }
        quickShareQRCodeImage.isHidden = !showingQRCode
        quickShareQRCodeCaption.isHidden = !showingQRCode
        table.isHidden = showingQRCode
        emptyLabel.isHidden = showingQRCode || !orderedPeers.isEmpty

        primaryButton.title = primaryButtonTitle
        primaryButton.isEnabled = isPrimaryButtonEnabled
        primaryButton.isHidden = showingQRCode
        cancelButton.title = isTerminal ? "Close" : "Cancel"
        table.isEnabled = phase.allowsPeerSelection
    }

    private var primaryButtonTitle: String {
        switch phase {
        case .finished:      return "Done"
        case .failed(_, .some): return "Try Again"
        default:             return "Send"
        }
    }

    private var isPrimaryButtonEnabled: Bool {
        switch phase {
        case .finished: return true
        case .failed(_, let retry):    return retry != nil
        case .choosing, .searching:    return selectedDestination?.isReadyToSend ?? false
        default:                       return false
        }
    }

    private var isTerminal: Bool {
        if case .finished = phase { return true }
        return false
    }

    private func setStatus(_ text: String, busy: Bool, isError: Bool = false, isSuccess: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        statusCard.layer?.backgroundColor = (
            isError ? Brand.alertSurface : isSuccess ? Brand.successSurface : Brand.primarySurface
        ).cgColor
    }

    /// Progress across the whole transfer, not the current file.
    ///
    /// Per-file percentages restart from zero on every file, so a ten-file
    /// transfer shows a bar that fills and resets ten times and tells the user
    /// nothing about how long is left. Weighted by byte count because the files
    /// are rarely the same size.
    private func overallFraction(fileIndex: Int, fraction: Double) -> Double {
        guard totalBytes > 0 else { return 0 }
        let completed = files.prefix(fileIndex).reduce(Int64(0)) { $0 + $1.size }
        let current = files.indices.contains(fileIndex) ? Double(files[fileIndex].size) : 0
        return min(1, (Double(completed) + current * fraction) / Double(totalBytes))
    }

    private var selectedDestination: Destination? {
        let row = table.selectedRow
        guard orderedPeers.indices.contains(row) else { return nil }
        return orderedPeers[row]
    }

    // MARK: - Picker setup

    private func prepare(urls: [URL]) {
        guard !urls.isEmpty else {
            NSLog("[EasyShare] share invoked with no resolvable file URLs")
            phase = .failed(message: "Quick Share could not read the selected file.", retry: nil)
            return
        }

        do {
            files = try urls.map(makePreparedFile)
        } catch {
            phase = .failed(message: error.localizedDescription, retry: nil)
            return
        }

        totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        if files.count == 1, let file = files.first {
            filesLabel.stringValue = "\(file.name) • \(size)"
            // The type icon, not the file's own icon: resolving a custom icon
            // would touch the file, and the sandbox has handed us read access to
            // exactly these URLs for exactly as long as we hold the scope.
            if let type = file.type {
                fileIcon.image = NSWorkspace.shared.icon(for: type)
            }
        } else {
            filesLabel.stringValue = "\(files.count) files • \(size)"
            fileIcon.image = NSImage(systemSymbolName: "doc.on.doc.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 30, weight: .regular))
                ?? fileIcon.image
        }
        filesLabel.toolTip = files.map(\.name).joined(separator: "\n")
        emptyLabel.stringValue = "Searching for Android companions…"
        phase = .searching
        startDiscovery()
    }

    private func makePreparedFile(_ url: URL) throws -> PreparedFile {
        // Folder packaging happens while the extension still owns the source
        // item's security scope. Deferring it until upload would let the scope
        // disappear while FileManager is traversing the folder.
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let values = try url.resourceValues(forKeys: [
            .fileSizeKey, .isRegularFileKey, .isDirectoryKey, .contentTypeKey,
        ])
        if values.isDirectory == true {
            return try makeFolderArchive(from: url)
        }

        guard values.isRegularFile == true else {
            throw NSError(
                domain: "dev.easyshare",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Quick Share can only send files or folders."]
            )
        }
        guard let fileSize = values.fileSize, fileSize >= 0 else {
            throw NSError(
                domain: "dev.easyshare",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Quick Share couldn't determine the size of \(url.lastPathComponent)."]
            )
        }

        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        return PreparedFile(
            url: url,
            type: type,
            name: url.lastPathComponent,
            size: Int64(fileSize),
            mimeType: mime,
            isTemporaryArchive: false
        )
    }

    /// v1 carries folders as ordinary ZIP files. Keeping the folder's root in
    /// the archive makes extracting `Photos.zip` produce `Photos/`, rather
    /// than scattering its contents into whichever directory the user picked.
    private func makeFolderArchive(from folder: URL) throws -> PreparedFile {
        let archiveName = folder.lastPathComponent + ".zip"
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickShare-\(UUID().uuidString)")
            .appendingPathExtension("zip")

        do {
            try FolderArchiveWriter.writeFolder(at: folder, to: archive)
            let values = try archive.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size >= 0 else {
                throw NSError(
                    domain: "dev.easyshare",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Quick Share couldn't prepare \(folder.lastPathComponent)."]
                )
            }
            return PreparedFile(
                url: archive,
                type: .zip,
                name: archiveName,
                size: Int64(size),
                mimeType: "application/zip",
                isTemporaryArchive: true
            )
        } catch {
            // A partially produced archive may be large. Do not leave it in
            // the extension's temporary directory when packaging fails.
            try? FileManager.default.removeItem(at: archive)
            throw error
        }
    }

    private func cleanUpTemporaryArchives() {
        for file in files where file.isTemporaryArchive {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    private func startDiscovery() {
        let companionDiscovery = CompanionDiscovery()
        companionDiscovery.onChange = { [weak self] peers in
            DispatchQueue.main.async {
                self?.replaceCompanionPeers(peers)
            }
        }
        companionDiscovery.onFailure = { error in
            NSLog("[EasyShare] companion discovery: \(error)")
        }
        companionDiscovery.start()
        self.companionDiscovery = companionDiscovery

        let quickShareDiscovery = QuickShareDiscovery()
        quickShareDiscovery.onChange = { [weak self] peers in
            DispatchQueue.main.async {
                self?.replaceQuickSharePeers(peers)
            }
        }
        quickShareDiscovery.onFailure = { error in
            NSLog("[EasyShare] Quick Share discovery: \(error)")
        }
        quickShareDiscovery.start()
        self.quickShareDiscovery = quickShareDiscovery

        // The QR route is a deliberate destination, not a discovered device,
        // so make it available immediately even on a network with no mDNS
        // traffic yet.
        replaceDestinations()

        let noPeers = DispatchWorkItem { [weak self] in
            guard let self, self.quickSharePeers.isEmpty else { return }
            if case .searching = self.phase {
                // A QR handoff remains usable even when ordinary discovery is
                // silent, so transition to the selectable picker rather than
                // presenting an empty-list error.
                self.phase = .choosing
            }
        }
        noPeersWorkItem = noPeers
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: noPeers)
    }

    private func replaceQuickSharePeers(_ discoveredPeers: [QuickSharePeer]) {
        quickSharePeers = discoveredPeers
        if let session = quickShareQRCodeSession,
           case .awaitingQuickShareQRCode = phase,
           let peer = discoveredPeers.lazy.compactMap({ session.resolvedPeer(from: $0) }).first {
            // Keep this session in the sender for its ownership signature;
            // clear only the waiting reference after finding the matching peer.
            quickShareQRCodeSession = nil
            quickShareQRCodeTimeout?.cancel()
            quickShareQRCodeTimeout = nil
            sendQuickShare(to: peer, qrCodeSession: session)
        }
        replaceDestinations()
    }

    private func replaceCompanionPeers(_ discoveredPeers: [CompanionPeer]) {
        companionPeers = discoveredPeers
        replaceDestinations()
    }

    private func replaceDestinations() {
        // Preserve the selection across a refresh: discovery republishes the
        // whole list every few seconds, and a picker that deselects itself
        // under the pointer is unusable.
        let selected = selectedDestination?.id
        let companions = companionPeers.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }.map { peer -> Destination in
            let record = storedCompanions.first(where: { record in
                record.fingerprint == peer.fingerprint && CompanionCredentialStore.token(for: record) != nil
            })
            return .companion(peer, pairedRecord: record)
        }
        let namedPeers = selectableQuickSharePeers.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let anonymousPeers = quickSharePeers.filter { !$0.hasDisplayName }
        var matchedPeerIDs = Set<String>()
        // Stock Quick Share's anonymous advertisements are intentionally
        // ephemeral. Do not turn an old UI label into a pretend pairing; the
        // companion rows above are the only durable destinations.
        let saved: [Destination] = []
        let otherNearby = namedPeers
            .filter { !matchedPeerIDs.contains($0.id) }
            .map(Destination.nearby)
        orderedPeers = companions + saved + otherNearby + [.qrCode]
        table.reloadData()
        if let selected, let row = orderedPeers.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }

        if !companionPeers.isEmpty || !selectableQuickSharePeers.isEmpty || orderedPeers.contains(where: { $0.isReadyToSend && $0.id != "quickshare-qr" }) {
            noPeersWorkItem?.cancel()
            if case .searching = phase { phase = .choosing }
        }
        render()
    }

    /// Hidden Quick Share advertisements carry no name, so their addresses
    /// are not a reliable way to identify the user's phone. Retain them in the
    /// discovery result for QR-token matching, but never make an anonymous row
    /// that asks the user to guess among identical devices.
    private var selectableQuickSharePeers: [QuickSharePeer] {
        quickSharePeers.filter(\.hasDisplayName)
    }

    // MARK: - Sender flow

    @objc private func primaryAction() {
        switch phase {
        case .finished:
            finish()
        case .failed(_, let retry):
            if let retry { send(to: retry) }
        case .choosing, .searching:
            if let destination = selectedDestination { send(to: destination) }
        default:
            break
        }
    }

    private func send(to destination: Destination) {
        switch destination {
        case .companion(let peer, let record?):
            sendCompanion(to: peer, record: record)
        case .companion(let peer, nil):
            pairCompanion(peer)
        case .nearby(let peer):
            sendQuickShare(to: peer)
        case .saved(_, let peer?):
            sendQuickShare(to: peer)
        case .saved:
            // The disabled row is not normally selectable. Keep this branch
            // defensive in case a table refresh races a click.
            phase = .failed(
                message: "Open Quick Share on the saved phone, then try again.", retry: nil
            )
        case .qrCode:
            beginQuickShareQRCode()
        }
    }

    private func pairCompanion(_ peer: CompanionPeer) {
        phase = .connecting(.companion(peer, pairedRecord: nil))
        transferTask = Task { [weak self] in
            guard let self else { return }
            do {
                let attempt = try await CompanionClient.beginPairing(to: peer, macName: Self.localDisplayName)
                let shouldPair = await MainActor.run { self.confirmPairingCode(attempt.comparisonCode, peerName: peer.displayName) }
                guard shouldPair else {
                    attempt.cancel()
                    throw CompanionError.cancelled
                }
                let credentials = try await attempt.confirm()
                try CompanionCredentialStore.save(credentials.record, token: credentials.token)
                await MainActor.run {
                    self.storedCompanions = CompanionCredentialStore.records()
                    self.replaceDestinations()
                }
                let stored = credentials.record
                // The just-issued token is already in hand. Use it for this
                // first send rather than re-querying Keychain while the share
                // extension is still completing its pairing transaction.
                await MainActor.run { self.sendCompanion(to: peer, record: stored, token: credentials.token) }
            } catch {
                await MainActor.run {
                    self.transferTask = nil
                    if !Task.isCancelled, !Self.isCancellation(error) {
                        self.fail(error, destination: .companion(peer, pairedRecord: nil))
                    }
                }
            }
        }
    }

    /// The only trust ceremony for a new companion. The number comes from the
    /// actual TLS certificate, not from Bonjour. Android independently derives
    /// it and requires its own Approve action before releasing a pairing token.
    @MainActor
    private func confirmPairingCode(_ code: String, peerName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Pair with \(peerName)?"
        alert.informativeText = "Compare this code with the Easy Share notification on Android:\n\n\(code)\n\nChoose Pair only when the two codes match."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func sendCompanion(to peer: CompanionPeer, record: StoredCompanion) {
        guard let token = CompanionCredentialStore.token(for: record) else {
            phase = .failed(message: "The saved pairing is no longer available. Pair this Android companion again.", retry: .companion(peer, pairedRecord: nil))
            return
        }
        sendCompanion(to: peer, record: record, token: token)
    }

    /// The first transfer after pairing already owns the freshly issued token;
    /// subsequent transfers fetch the same credential from Keychain above.
    private func sendCompanion(to peer: CompanionPeer, record: StoredCompanion, token: Data) {
        phase = .connecting(.companion(peer, pairedRecord: record))
        transferTask = Task { [weak self] in
            guard let self else { return }
            let access = self.files.map { $0.url.startAccessingSecurityScopedResource() }
            defer {
                for (file, granted) in zip(self.files, access) where granted {
                    file.url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                try await CompanionClient.send(
                    to: peer,
                    record: record,
                    token: token,
                    files: self.files.map {
                        CompanionOutgoingFile(url: $0.url, name: $0.name, size: $0.size, mimeType: $0.mimeType)
                    },
                    sender: Self.localDisplayName,
                    progress: { [weak self] index, fraction in
                        DispatchQueue.main.async {
                            self?.phase = .sending(.companion(peer, pairedRecord: record), fileIndex: index, fraction: fraction)
                        }
                    }
                )
                await MainActor.run {
                    CompanionCredentialStore.markUsed(record)
                    self.storedCompanions = CompanionCredentialStore.records()
                    self.transferTask = nil
                    self.phase = .finished(.companion(peer, pairedRecord: record))
                }
            } catch {
                await MainActor.run {
                    self.transferTask = nil
                    if !Task.isCancelled { self.fail(error, destination: .companion(peer, pairedRecord: record)) }
                }
            }
        }
    }

    private func beginQuickShareQRCode() {
        do {
            let session = try QuickShareQRCodeSession()
            guard let image = Self.quickShareQRCodeImage(for: session.url) else {
                throw QuickShareError.unsupported("macOS could not generate the Quick Share QR code")
            }
            quickShareQRCodeSession = session
            quickShareQRCodeImage.image = image
            phase = .awaitingQuickShareQRCode
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, case .awaitingQuickShareQRCode = self.phase else { return }
                self.quickShareQRCodeSession = nil
                self.quickShareQRCodeImage.image = nil
                self.quickShareQRCodeTimeout = nil
                self.fail(QuickShareError.qrCodeActivationTimedOut, destination: .qrCode)
            }
            quickShareQRCodeTimeout?.cancel()
            quickShareQRCodeTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        } catch {
            fail(error, destination: nil)
        }
    }

    private func sendQuickShare(to peer: QuickSharePeer, qrCodeSession: QuickShareQRCodeSession? = nil) {
        do {
            let sender = try QuickShareSender(
                peer: peer, displayName: Self.localDisplayName, qrCodeSession: qrCodeSession
            )
            activeQuickShareSender = sender
            quickShareVerificationPIN = nil
            phase = .connecting(.nearby(peer))
            transferTask = Task { [weak self, weak sender] in
                guard let self, let sender else { return }
                let access = self.files.map { $0.url.startAccessingSecurityScopedResource() }
                defer {
                    for (file, granted) in zip(self.files, access) where granted {
                        file.url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    try await sender.send(
                        files: self.files.map {
                            QuickShareOutgoingFile(
                                url: $0.url,
                                name: $0.name,
                                size: $0.size,
                                mimeType: $0.mimeType
                            )
                        },
                        verificationPIN: { [weak self] pin in
                            DispatchQueue.main.async {
                                self?.quickShareVerificationPIN = pin
                                self?.render()
                            }
                        },
                        progress: { [weak self] index, fraction in
                            DispatchQueue.main.async {
                                self?.phase = .sending(.nearby(peer), fileIndex: index, fraction: fraction)
                            }
                        }
                    )
                    await MainActor.run {
                        self.activeQuickShareSender = nil
                        self.quickShareVerificationPIN = nil
                        self.transferTask = nil
                        self.phase = .finished(.nearby(peer))
                    }
                } catch {
                    await MainActor.run {
                        self.activeQuickShareSender = nil
                        self.quickShareVerificationPIN = nil
                        if !Task.isCancelled { self.fail(error, destination: .nearby(peer)) }
                    }
                }
            }
        } catch {
            fail(error, destination: .nearby(peer))
        }
    }

    private func fail(_ error: Error, destination: Destination?) {
        transferTask = nil
        phase = .failed(
            message: Self.message(for: error, peerName: destination?.displayName),
            retry: Self.isWorthRetrying(error) ? destination : nil
        )
    }

    private func rememberSuccessfulRecipient(_ peer: QuickSharePeer) {
        guard peer.hasDisplayName else { return }
        let name = PeerText.displayName(peer.displayName, fallback: "Quick Share device")
        let marker = peer.advertisingIdentity.count == 16 ? peer.advertisingIdentity : nil
        let now = Date()
        if let index = savedRecipients.firstIndex(where: {
            $0.displayName.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            savedRecipients[index].advertisingIdentity = marker ?? savedRecipients[index].advertisingIdentity
            savedRecipients[index].lastUsed = now
        } else {
            savedRecipients.append(SavedRecipient(
                id: UUID().uuidString,
                displayName: name,
                advertisingIdentity: marker,
                lastUsed: now
            ))
        }
        savedRecipients.sort { $0.lastUsed > $1.lastUsed }
        savedRecipients = Array(savedRecipients.prefix(5))
        Self.saveSavedRecipients(savedRecipients)
    }

    private static func loadSavedRecipients() -> [SavedRecipient] {
        guard let data = UserDefaults.standard.data(forKey: savedRecipientsKey),
              let values = try? JSONDecoder().decode([SavedRecipient].self, from: data)
        else { return [] }
        return values
            .map {
                SavedRecipient(
                    id: PeerText.identifier($0.id),
                    displayName: PeerText.displayName($0.displayName),
                    advertisingIdentity: $0.advertisingIdentity?.count == 16 ? $0.advertisingIdentity : nil,
                    lastUsed: $0.lastUsed
                )
            }
            .filter { !$0.id.isEmpty }
            .sorted { $0.lastUsed > $1.lastUsed }
            .prefix(5)
            .map { $0 }
    }

    private static func saveSavedRecipients(_ recipients: [SavedRecipient]) {
        guard let data = try? JSONEncoder().encode(recipients) else { return }
        UserDefaults.standard.set(data, forKey: savedRecipientsKey)
    }

    /// Retrying a declined transfer or one rejected for lack of storage would
    /// only repeat the same result. A dropped LAN connection often succeeds on
    /// the next attempt, so retain the selected Quick Share destination there.
    private static func isWorthRetrying(_ error: Error) -> Bool {
        if let error = error as? CompanionError {
            switch error {
            case .cancelled, .certificateChanged, .keychain:
                return false
            default:
                return true
            }
        }
        guard let error = error as? QuickShareError else { return true }
        switch error {
        case .peerRejected, .insufficientSpace:
            return false
        default:
            return true
        }
    }

    private static func message(for error: Error, peerName: String?) -> String {
        let name = peerName ?? "This device"
        if let error = error as? CompanionError {
            switch error {
            case .connectionTimedOut, .connectionClosed:
                return "\(name) is no longer available. Turn on Receive from Mac on Android, then try again."
            case .certificateChanged:
                return "\(name)'s identity changed. Pair it again from the Android companion."
            case .rejected(let message):
                return message
            case .cancelled:
                return "Sharing was cancelled."
            default:
                return error.localizedDescription
            }
        }
        if let error = error as? QuickShareError {
            switch error {
            case .qrCodeActivationTimedOut:
                return "The phone did not start Quick Share. Scan the code again and tap the Quick Share link on the phone."
            case .connectionTimedOut:
                return "\(name) did not accept the Quick Share connection. Keep Wi‑Fi and Bluetooth on, then try again."
            case .peerRejected:
                return "\(name) declined the Quick Share transfer."
            case .insufficientSpace:
                return "\(name) does not have enough free space."
            case .cancelled:
                return "Quick Share was cancelled."
            case .connectionClosed:
                return "\(name) closed the Quick Share connection. Try again."
            case .connectionClosedDuring(let stage):
                return "\(name) stopped Quick Share while \(stage)."
            case .deliveryConfirmationTimedOut:
                return "\(name) did not confirm that it finished writing the file. The transfer was not completed."
            case .frameTooLarge(let length):
                return "Couldn't send to \(name) with Quick Share: received an oversized \(length)-byte frame."
            case .truncatedFrame:
                return "Couldn't send to \(name) with Quick Share: the connection sent an incomplete frame."
            case .malformed(let detail), .unsupported(let detail), .cryptography(let detail):
                return "Couldn't send to \(name) with Quick Share: \(detail)"
            }
        }
        return error.localizedDescription
    }

    private static func isCancellation(_ error: Error) -> Bool {
        guard let error = error as? CompanionError else { return false }
        if case .cancelled = error { return true }
        return false
    }

    private static var localDisplayName: String {
        let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Mac"
        return name.isEmpty ? "Mac" : name
    }

    /// Pull file URLs out of the extension context.
    ///
    /// Every attachment is an `NSItemProvider`, and each may or may not be able
    /// to vend a file URL. Text-only shares and shares from apps that only offer
    /// in-memory data will not, which is why this filters rather than assumes.
    /// The extension's activation rule limits the system UI to attachment/file
    /// shares; the runtime check remains necessary because providers vary.
    private func resolveAttachments() async -> [URL] {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return [] }

        var urls: [URL] = []
        for item in items {
            for provider in item.attachments ?? [] {
                guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                    // Quick Share accepts files; providers that expose only
                    // in-memory text are intentionally not materialized here.
                    continue
                }
                if let url = await loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                if let error {
                    NSLog("[EasyShare] attachment failed: \(error)")
                    continuation.resume(returning: nil)
                    return
                }
                // The item arrives as Data holding a bookmark-ish URL encoding,
                // or occasionally as a URL directly. Handle both.
                switch item {
                case let url as URL:
                    continuation.resume(returning: url)
                case let data as Data:
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Completion

    @objc private func cancelPressed() {
        if isTerminal {
            finish()
            return
        }

        transferTask?.cancel()
        activeQuickShareSender?.cancel()
        activeQuickShareSender = nil
        quickShareQRCodeSession = nil
        quickShareQRCodeTimeout?.cancel()
        quickShareQRCodeTimeout = nil
        quickShareQRCodeImage.image = nil
        quickShareVerificationPIN = nil
        cancel()
    }

    /// Call ONLY after every upload has finished. See constraint 1.
    private func finish() {
        // At this point no upload can still be reading a staged folder archive.
        // Keep it through failures for Try Again, but remove it as soon as the
        // successfully completed share sheet is dismissed.
        cleanUpTemporaryArchives()
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancel() {
        let error = NSError(domain: "dev.easyshare", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "Sharing cancelled"
        ])
        extensionContext?.cancelRequest(withError: error)
    }

    private static func quickShareQRCodeImage(for url: URL) -> NSImage? {
        guard let generator = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        generator.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        generator.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = generator.outputImage else { return nil }
        let representation = NSCIImageRep(
            ciImage: output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        )
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

// MARK: - Peer list

extension ShareViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        orderedPeers.count
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: Self.rowIdentifier, owner: self) as? PeerRowView
            ?? PeerRowView(identifier: Self.rowIdentifier)
        view.configure(with: orderedPeers[row])
        return view
    }

    /// This also locks the list once a transfer starts. `isEnabled` on
    /// an NSTableView does not stop selection, so relying on it would leave the
    /// highlight moving off the device the bytes are actually going to.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard phase.allowsPeerSelection else { return false }
        return orderedPeers.indices.contains(row) && orderedPeers[row].isReadyToSend
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        primaryButton.isEnabled = isPrimaryButtonEnabled
    }
}

/// One row of the peer list: device icon, name, and where it is.
///
/// The address is not decoration. Two Macs on a network are routinely called the
/// same thing, and it is the only thing on screen that tells them apart.
private final class PeerRowView: NSTableCellView {

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setContentHuggingPriority(.required, for: .horizontal)

        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle

        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(with destination: ShareViewController.Destination) {
        // SF Symbols has no Android glyph. `iphone` is a bare rounded-rectangle
        // handset outline, so it reads as "a phone" rather than as one
        // particular brand of phone — the closest honest option available.
        icon.image = NSImage(systemSymbolName: destination.iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))

        name.stringValue = destination.displayName
        detail.stringValue = destination.detail

        name.textColor = .labelColor
        detail.textColor = .secondaryLabelColor
        icon.contentTintColor = Brand.primary
        toolTip = destination.id
    }
}

/// Relays appearance changes to the view controller.
///
/// `viewDidChangeEffectiveAppearance` is an `NSView` callback; `NSViewController`
/// has no equivalent, so the root view has to forward it.
private final class AppearanceObservingView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

// MARK: - Brand

/// Easy Share's palette, shared with the Android companion so both ends of a
/// transfer look like one product. Each color adapts with the sheet's
/// effective appearance the same way a system color would.
private enum Brand {
    static let primary = dynamic(
        light: NSColor(srgbRed: 0.192, green: 0.361, blue: 0.961, alpha: 1),
        dark: NSColor(srgbRed: 0.463, green: 0.573, blue: 1.0, alpha: 1)
    )
    static let primarySurface = dynamic(
        light: NSColor(srgbRed: 0.929, green: 0.945, blue: 1.0, alpha: 1),
        dark: NSColor(srgbRed: 0.145, green: 0.180, blue: 0.294, alpha: 1)
    )
    static let successSurface = dynamic(
        light: NSColor(srgbRed: 0.918, green: 0.973, blue: 0.941, alpha: 1),
        dark: NSColor(srgbRed: 0.110, green: 0.204, blue: 0.157, alpha: 1)
    )
    static let alertSurface = dynamic(
        light: NSColor(srgbRed: 1.0, green: 0.945, blue: 0.929, alpha: 1),
        dark: NSColor(srgbRed: 0.278, green: 0.145, blue: 0.122, alpha: 1)
    )

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

// MARK: - Folder archive writer

/// A tiny ZIP writer for the Finder extension.
///
/// `Process` is not a viable way to call `ditto` from an app extension: the
/// extension sandbox is intentionally not a general process launcher. This
/// writer stores files without compression, which keeps memory bounded and
/// makes folder contents travel through the same streamed upload path as any
/// other file. It emits ZIP64 only when an archive actually needs it, so normal
/// folders remain ordinary, broadly compatible ZIP files.
private enum FolderArchiveWriter {
    private enum EntryKind: Equatable { case file, directory }

    private struct SourceEntry {
        let source: URL
        let path: String
        let kind: EntryKind
        let size: UInt64
    }

    private struct WrittenEntry {
        let source: SourceEntry
        let offset: UInt64
        let crc32: UInt32
    }

    private static let utf8Flag: UInt16 = 1 << 11
    private static let dataDescriptorFlag: UInt16 = 1 << 3
    private static let zip64Magic32 = UInt32.max

    static func writeFolder(at folder: URL, to archive: URL) throws {
        var sources: [SourceEntry] = []
        try collect(
            folder,
            path: safeComponent(folder.lastPathComponent.isEmpty ? "Folder" : folder.lastPathComponent),
            into: &sources
        )

        guard FileManager.default.createFile(atPath: archive.path, contents: nil) else {
            throw archiveError("Couldn't create the temporary folder archive.")
        }
        let output = try FileHandle(forWritingTo: archive)
        defer { try? output.close() }

        var written: [WrittenEntry] = []
        for source in sources {
            let offset = try output.offset()
            let name = Data(source.path.utf8)
            guard name.count <= Int(UInt16.max) else {
                throw archiveError("A folder item has a name that is too long to package.")
            }

            switch source.kind {
            case .directory:
                output.write(localHeader(
                    name: name, flags: utf8Flag, versionNeeded: 20,
                    crc32: 0, compressedSize: 0, uncompressedSize: 0, extra: Data()
                ))
                written.append(WrittenEntry(source: source, offset: offset, crc32: 0))

            case .file:
                let needsZip64 = source.size > UInt64(UInt32.max)
                let extra = needsZip64 ? zip64SizeExtra(uncompressed: source.size, compressed: source.size) : Data()
                output.write(localHeader(
                    name: name,
                    flags: utf8Flag | dataDescriptorFlag,
                    versionNeeded: needsZip64 ? 45 : 20,
                    crc32: 0,
                    compressedSize: needsZip64 ? zip64Magic32 : 0,
                    uncompressedSize: needsZip64 ? zip64Magic32 : 0,
                    extra: extra
                ))

                let checksum = try copy(source: source.source, expectedSize: source.size, to: output)
                output.write(dataDescriptor(crc32: checksum, size: source.size, zip64: needsZip64))
                written.append(WrittenEntry(source: source, offset: offset, crc32: checksum))
            }
        }

        let centralOffset = try output.offset()
        for entry in written {
            output.write(centralHeader(for: entry))
        }
        let centralEnd = try output.offset()
        let centralSize = centralEnd - centralOffset
        let needsZip64 = written.count > Int(UInt16.max)
            || centralOffset > UInt64(UInt32.max)
            || centralSize > UInt64(UInt32.max)
            || written.contains { entry in
                entry.source.size > UInt64(UInt32.max) || entry.offset > UInt64(UInt32.max)
            }

        if needsZip64 {
            let zip64EndOffset = try output.offset()
            output.write(zip64EndOfCentralDirectory(
                entryCount: UInt64(written.count),
                centralSize: centralSize,
                centralOffset: centralOffset
            ))
            output.write(zip64Locator(zip64EndOffset: zip64EndOffset))
            output.write(endOfCentralDirectory(
                entryCount: UInt16.max,
                centralSize: UInt32.max,
                centralOffset: UInt32.max
            ))
        } else {
            output.write(endOfCentralDirectory(
                entryCount: UInt16(written.count),
                centralSize: UInt32(centralSize),
                centralOffset: UInt32(centralOffset)
            ))
        }
    }

    private static func collect(_ source: URL, path: String, into entries: inout [SourceEntry]) throws {
        let values = try source.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        // Links can escape the granted folder or loop back into it. A portable
        // folder archive has no useful representation for a symlink anyway.
        guard values.isSymbolicLink != true else { return }

        if values.isDirectory == true {
            entries.append(SourceEntry(source: source, path: path + "/", kind: .directory, size: 0))
            let children = try FileManager.default.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil,
                options: []
            ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for child in children {
                try collect(child, path: path + "/" + safeComponent(child.lastPathComponent), into: &entries)
            }
            return
        }

        guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize >= 0 else {
            // Devices, sockets, and special filesystem nodes cannot be encoded
            // meaningfully as a folder share. Ignore them like Finder does.
            return
        }
        entries.append(SourceEntry(source: source, path: path, kind: .file, size: UInt64(fileSize)))
    }

    private static func copy(source: URL, expectedSize: UInt64, to output: FileHandle) throws -> UInt32 {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        var crc = CRC32()
        var bytesCopied: UInt64 = 0
        while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
            output.write(chunk)
            crc.update(chunk)
            bytesCopied += UInt64(chunk.count)
        }
        guard bytesCopied == expectedSize else {
            throw archiveError("A folder item changed while Easy Share was packaging it.")
        }
        return crc.finalized
    }

    private static func localHeader(
        name: Data,
        flags: UInt16,
        versionNeeded: UInt16,
        crc32: UInt32,
        compressedSize: UInt32,
        uncompressedSize: UInt32,
        extra: Data
    ) -> Data {
        var data = Data()
        data.appendLE(UInt32(0x0403_4b50))
        data.appendLE(versionNeeded)
        data.appendLE(flags)
        data.appendLE(UInt16(0)) // stored, not compressed
        data.appendLE(UInt16(0)) // DOS time: 00:00
        data.appendLE(UInt16(0)) // DOS date: 1980-01-01
        data.appendLE(crc32)
        data.appendLE(compressedSize)
        data.appendLE(uncompressedSize)
        data.appendLE(UInt16(name.count))
        data.appendLE(UInt16(extra.count))
        data.append(name)
        data.append(extra)
        return data
    }

    private static func centralHeader(for entry: WrittenEntry) -> Data {
        let name = Data(entry.source.path.utf8)
        let needsZip64 = entry.source.size > UInt64(UInt32.max) || entry.offset > UInt64(UInt32.max)
        let extra = needsZip64
            ? zip64CentralExtra(
                uncompressed: entry.source.size,
                compressed: entry.source.size,
                offset: entry.offset
            )
            : Data()

        var data = Data()
        data.appendLE(UInt32(0x0201_4b50))
        data.appendLE(UInt16(needsZip64 ? 45 : 20)) // version made by
        data.appendLE(UInt16(needsZip64 ? 45 : 20)) // version needed
        data.appendLE(utf8Flag | (entry.source.kind == .file ? dataDescriptorFlag : 0))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(0))
        data.appendLE(entry.crc32)
        data.appendLE(needsZip64 ? zip64Magic32 : UInt32(entry.source.size))
        data.appendLE(needsZip64 ? zip64Magic32 : UInt32(entry.source.size))
        data.appendLE(UInt16(name.count))
        data.appendLE(UInt16(extra.count))
        data.appendLE(UInt16(0)) // comment length
        data.appendLE(UInt16(0)) // start disk
        data.appendLE(UInt16(0)) // internal attributes
        data.appendLE(entry.source.kind == .directory ? UInt32(0x10) : UInt32(0))
        data.appendLE(needsZip64 ? zip64Magic32 : UInt32(entry.offset))
        data.append(name)
        data.append(extra)
        return data
    }

    private static func dataDescriptor(crc32: UInt32, size: UInt64, zip64: Bool) -> Data {
        var data = Data()
        data.appendLE(UInt32(0x0807_4b50))
        data.appendLE(crc32)
        if zip64 {
            data.appendLE(size)
            data.appendLE(size)
        } else {
            data.appendLE(UInt32(size))
            data.appendLE(UInt32(size))
        }
        return data
    }

    private static func zip64SizeExtra(uncompressed: UInt64, compressed: UInt64) -> Data {
        var data = Data()
        data.appendLE(UInt16(0x0001))
        data.appendLE(UInt16(16))
        data.appendLE(uncompressed)
        data.appendLE(compressed)
        return data
    }

    private static func zip64CentralExtra(uncompressed: UInt64, compressed: UInt64, offset: UInt64) -> Data {
        var data = Data()
        data.appendLE(UInt16(0x0001))
        data.appendLE(UInt16(24))
        data.appendLE(uncompressed)
        data.appendLE(compressed)
        data.appendLE(offset)
        return data
    }

    private static func zip64EndOfCentralDirectory(
        entryCount: UInt64,
        centralSize: UInt64,
        centralOffset: UInt64
    ) -> Data {
        var data = Data()
        data.appendLE(UInt32(0x0606_4b50))
        data.appendLE(UInt64(44))
        data.appendLE(UInt16(45))
        data.appendLE(UInt16(45))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0))
        data.appendLE(entryCount)
        data.appendLE(entryCount)
        data.appendLE(centralSize)
        data.appendLE(centralOffset)
        return data
    }

    private static func zip64Locator(zip64EndOffset: UInt64) -> Data {
        var data = Data()
        data.appendLE(UInt32(0x0706_4b50))
        data.appendLE(UInt32(0))
        data.appendLE(zip64EndOffset)
        data.appendLE(UInt32(1))
        return data
    }

    private static func endOfCentralDirectory(
        entryCount: UInt16,
        centralSize: UInt32,
        centralOffset: UInt32
    ) -> Data {
        var data = Data()
        data.appendLE(UInt32(0x0605_4b50))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(0))
        data.appendLE(entryCount)
        data.appendLE(entryCount)
        data.appendLE(centralSize)
        data.appendLE(centralOffset)
        data.appendLE(UInt16(0))
        return data
    }

    private static func safeComponent(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 0...31, 127: return "_"
            default:
                return scalar.value == 47 || scalar.value == 92 ? "_" : String(scalar)
            }
        }.joined()
        switch cleaned {
        case "", ".", "..": return "Folder"
        default: return cleaned
        }
    }

    private static func archiveError(_ description: String) -> NSError {
        NSError(domain: "dev.easyshare.archive", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}

private struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? (value >> 1) ^ 0xedb8_8320 : value >> 1
        }
        return value
    }

    private var value: UInt32 = UInt32.max

    mutating func update(_ data: Data) {
        for byte in data {
            value = Self.table[Int((value ^ UInt32(byte)) & 0xff)] ^ (value >> 8)
        }
    }

    var finalized: UInt32 { value ^ UInt32.max }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt64) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
