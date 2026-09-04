import Foundation
import Network

/// A Wi-Fi LAN Quick Share endpoint.
public struct QuickSharePeer: Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let hasDisplayName: Bool
    public let host: String
    public let port: UInt16
    let serviceEndpoint: NWEndpoint?
    public let qrCodeData: Data?
    public let advertisingIdentity: Data

    public var address: String {
        if serviceEndpoint != nil { return "Nearby" }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

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

/// Browses the public Quick Share DNS-SD service.
public final class QuickShareDiscovery {
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
