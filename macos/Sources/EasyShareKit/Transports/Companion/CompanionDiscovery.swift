import Foundation
import Network

/// A live Android companion receiver discovered on the local network.
public struct CompanionPeer: Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let fingerprint: String
    public let host: String
    public let port: UInt16
    let serviceEndpoint: NWEndpoint?

    public var address: String {
        if serviceEndpoint != nil { return "Nearby" }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    public init(id: String = UUID().uuidString, displayName: String, fingerprint: String, host: String, port: UInt16) {
        self.id = PeerText.identifier(id)
        self.displayName = PeerText.displayName(displayName, fallback: "Android companion")
        self.fingerprint = fingerprint.lowercased()
        self.host = host
        self.port = port
        self.serviceEndpoint = nil
    }

    init(id: String, displayName: String, fingerprint: String, serviceEndpoint: NWEndpoint) {
        self.id = PeerText.identifier(id)
        self.displayName = PeerText.displayName(displayName, fallback: "Android companion")
        self.fingerprint = fingerprint.lowercased()
        self.host = ""
        self.port = 0
        self.serviceEndpoint = serviceEndpoint
    }

    public static func == (lhs: CompanionPeer, rhs: CompanionPeer) -> Bool {
        lhs.id == rhs.id && lhs.displayName == rhs.displayName && lhs.fingerprint == rhs.fingerprint
            && lhs.host == rhs.host && lhs.port == rhs.port
            && lhs.serviceEndpoint?.debugDescription == rhs.serviceEndpoint?.debugDescription
    }
}

public final class CompanionDiscovery {
    public var onChange: (([CompanionPeer]) -> Void)?
    public var onFailure: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "dev.easyshare.companion.discovery")
    private var browser: NWBrowser?
    private var observations: [String: Observation] = [:]
    private var peers: [String: CompanionPeer] = [:]

    private struct Observation {
        let peer: CompanionPeer
        let firstSeen: Date
        let hasStableServiceName: Bool
    }

    public init() {}

    public func start() {
        stop()
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_easyshare-companion._tcp", domain: nil), using: parameters
        )
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error), .waiting(let error): self?.onFailure?(error)
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.handle(results) }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        observations.removeAll()
        if !peers.isEmpty {
            peers.removeAll()
            onChange?([])
        }
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        let now = Date()
        var nextObservations: [String: Observation] = [:]
        for result in results {
            guard case .bonjour(let txt) = result.metadata,
                  txt["v"] == "1",
                  let encodedName = txt["n"],
                  let nameData = Self.dataFromBase64URL(encodedName),
                  let rawName = String(data: nameData, encoding: .utf8),
                  let value = txt["fp"],
                  let fingerprint = Self.validFingerprint(value)
            else { continue }
            let key = result.endpoint.debugDescription
            let peer = CompanionPeer(
                id: key, displayName: rawName, fingerprint: fingerprint, serviceEndpoint: result.endpoint
            )
            if let previous = observations[key], previous.peer == peer {
                nextObservations[key] = previous
            } else {
                nextObservations[key] = Observation(
                    peer: peer,
                    firstSeen: now,
                    hasStableServiceName: Self.hasStableServiceName(result.endpoint, fingerprint: fingerprint)
                )
            }
        }

        observations = nextObservations

        var newestByFingerprint: [String: Observation] = [:]
        for observation in nextObservations.values {
            guard let current = newestByFingerprint[observation.peer.fingerprint] else {
                newestByFingerprint[observation.peer.fingerprint] = observation
                continue
            }
            if (observation.hasStableServiceName && !current.hasStableServiceName) ||
                (observation.hasStableServiceName == current.hasStableServiceName && observation.firstSeen > current.firstSeen) ||
                (observation.hasStableServiceName == current.hasStableServiceName && observation.firstSeen == current.firstSeen
                    && observation.peer.id > current.peer.id) {
                newestByFingerprint[observation.peer.fingerprint] = observation
            }
        }
        let next = Dictionary(uniqueKeysWithValues: newestByFingerprint.map { ($0.key, $0.value.peer) })

        guard next != peers else { return }
        peers = next
        onChange?(Array(next.values))
    }

    private static func validFingerprint(_ value: String) -> String? {
        let normalized = value.lowercased()
        guard normalized.count == 64,
              normalized.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) })
        else { return nil }
        return normalized
    }

    private static func hasStableServiceName(_ endpoint: NWEndpoint, fingerprint: String) -> Bool {
        guard case .service(let name, _, _, _) = endpoint else { return false }
        return name == "EasyShare-\(fingerprint.prefix(12))"
    }

    private static func dataFromBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
