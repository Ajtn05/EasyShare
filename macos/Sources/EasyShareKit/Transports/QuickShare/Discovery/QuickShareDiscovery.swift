import Foundation
import Network

/// A Wi-Fi-LAN Quick Share endpoint. It intentionally has no persistent
/// identity: the Everyone-visible discovery format only provides an ephemeral
/// endpoint name and an untrusted display name.
public struct QuickSharePeer: Identifiable, Equatable {
    public let id: String
    public let displayName: String
    /// Whether Quick Share supplied a meaningful public name for this peer.
    /// Hidden peers are retained for QR-token matching but should not be shown
    /// as individually selectable destination rows.
    public let hasDisplayName: Bool
    public let host: String
    public let port: UInt16
    /// Bonjour service endpoints are intentionally retained until the sender
    /// connects. Resolving one by opening a throwaway TCP connection can
    /// consume Android's short-lived QR listener before the real transfer.
    let serviceEndpoint: NWEndpoint?
    /// The QR TLV from the discovered endpoint. It is deliberately exposed as
    /// opaque data so a QR session can verify ownership before connecting.
    public let qrCodeData: Data?
    /// An opaque, public marker from the current advertisement. It supports a
    /// local recipient preference only; it is neither secret nor authenticated.
    public let advertisingIdentity: Data

    public var address: String {
        if serviceEndpoint != nil { return "Nearby" }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Creates a peer from a concrete endpoint. This is retained for loopback
    /// tests and a possible future explicit-address handoff; Bonjour discovery
    /// itself preserves its service endpoint until the sender connects.
    public init(
        id: String = UUID().uuidString,
        displayName: String,
        host: String,
        port: UInt16,
        hasDisplayName: Bool = true,
        qrCodeData: Data? = nil,
        advertisingIdentity: Data = Data()
    ) {
        self.id = PeerText.identifier(id)
        self.displayName = PeerText.displayName(displayName, fallback: "Quick Share device")
        self.host = host
        self.port = port
        self.hasDisplayName = hasDisplayName
        self.qrCodeData = qrCodeData
        self.advertisingIdentity = advertisingIdentity
        self.serviceEndpoint = nil
    }

    init(
        id: String,
        displayName: String,
        serviceEndpoint: NWEndpoint,
        hasDisplayName: Bool,
        qrCodeData: Data?,
        advertisingIdentity: Data
    ) {
        self.id = PeerText.identifier(id)
        self.displayName = PeerText.displayName(displayName, fallback: "Quick Share device")
        self.host = ""
        self.port = 0
        self.hasDisplayName = hasDisplayName
        self.qrCodeData = qrCodeData
        self.advertisingIdentity = advertisingIdentity
        self.serviceEndpoint = serviceEndpoint
    }

    func renamed(_ displayName: String) -> QuickSharePeer {
        if let serviceEndpoint {
            return QuickSharePeer(
                id: id,
                displayName: displayName,
                serviceEndpoint: serviceEndpoint,
                hasDisplayName: true,
                qrCodeData: qrCodeData,
                advertisingIdentity: advertisingIdentity
            )
        }
        return QuickSharePeer(
            id: id,
            displayName: displayName,
            host: host,
            port: port,
            hasDisplayName: true,
            qrCodeData: qrCodeData,
            advertisingIdentity: advertisingIdentity
        )
    }

    public static func == (lhs: QuickSharePeer, rhs: QuickSharePeer) -> Bool {
        lhs.id == rhs.id
            && lhs.displayName == rhs.displayName
            && lhs.hasDisplayName == rhs.hasDisplayName
            && lhs.host == rhs.host
            && lhs.port == rhs.port
            && lhs.qrCodeData == rhs.qrCodeData
            && lhs.advertisingIdentity == rhs.advertisingIdentity
            && lhs.serviceEndpoint?.debugDescription == rhs.serviceEndpoint?.debugDescription
    }
}

/// Browses the public `_FC9F5ED42C8A._tcp` service. Android normally starts
/// advertising this service only while its Quick Share receive UI is active;
/// the caller should keep browsing instead of treating an initially empty set
/// as proof that no Android peer exists.
public final class QuickShareDiscovery {
    /// Called on the discovery queue whenever the discovered peer set changes.
    public var onChange: (([QuickSharePeer]) -> Void)?
    public var onFailure: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "dev.easyshare.quickshare.discovery")
    private var browser: NWBrowser?
    private var peers: [String: QuickSharePeer] = [:]

    public init() {}

    public func start() {
        stop()
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: QuickShareEndpointInfo.serviceType, domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error): self.onFailure?(error)
            case .waiting(let error): self.onFailure?(error)
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handle(results)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        if !peers.isEmpty {
            peers.removeAll()
            onChange?([])
        }
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        var seen = Set<String>()
        var changed = false
        for result in results {
            guard case .bonjour(let txt) = result.metadata,
                  let value = txt["n"],
                  let endpoint = QuickShareEndpointInfo(txtRecordValue: value)
            else { continue }

            // The service instance is a base64 URL string, so it is safe to
            // use as the pre-resolution key and is stable for this advertising
            // session. Never use a peer's display name as an identifier.
            let key = result.endpoint.debugDescription
            seen.insert(key)
            let peer = QuickSharePeer(
                id: key,
                displayName: endpoint.displayName,
                serviceEndpoint: result.endpoint,
                hasDisplayName: endpoint.hasDisplayName,
                qrCodeData: endpoint.qrCodeData,
                advertisingIdentity: endpoint.advertisingIdentity
            )
            // A QR activation can update the TXT record on an existing
            // Bonjour service instead of creating a second service. Publish
            // that new token immediately so the QR session can connect.
            if peers[key] != peer {
                peers[key] = peer
                changed = true
            }
        }

        let vanished = peers.keys.filter { !seen.contains($0) }
        for key in vanished {
            peers[key] = nil
            changed = true
        }
        if changed { onChange?(Array(peers.values)) }
    }
}
