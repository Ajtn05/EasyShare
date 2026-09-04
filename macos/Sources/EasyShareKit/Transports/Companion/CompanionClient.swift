import Foundation
import Network
import Security
import CryptoKit

public struct CompanionOutgoingFile {
    public let url: URL
    public let name: String
    public let size: Int64
    public let mimeType: String

    public init(url: URL, name: String, size: Int64, mimeType: String) {
        self.url = url
        self.name = name
        self.size = size
        self.mimeType = mimeType
    }
}

public enum CompanionError: LocalizedError {
    case invalidPeer
    case connectionTimedOut
    case connectionClosed
    case certificateChanged
    case invalidResponse(String)
    case rejected(String)
    case cancelled
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidPeer: return "The Android companion advertised an invalid address."
        case .connectionTimedOut: return "The Android companion did not respond."
        case .connectionClosed: return "The Android companion closed the connection."
        case .certificateChanged: return "The Android companion's identity does not match the paired device."
        case .invalidResponse(let message): return "The Android companion sent an invalid response: \(message)"
        case .rejected(let message): return message
        case .cancelled: return "Easy Share was cancelled."
        case .keychain(let status): return "Easy Share could not save the pairing credentials (Keychain error \(status))."
        }
    }
}

/// A short-lived pairing session. The caller displays `comparisonCode`, then
/// calls `confirm()` only after the human has compared it with Android's local
/// notification. The certificate captured here, not the mDNS TXT record, is
/// the certificate that becomes pinned.
public final class CompanionPairingAttempt {
    public let peer: CompanionPeer
    public let comparisonCode: String

    private let client: CompanionClient
    private let session: String
    private let fingerprint: String

    fileprivate init(peer: CompanionPeer, comparisonCode: String, client: CompanionClient, session: String, fingerprint: String) {
        self.peer = peer
        self.comparisonCode = comparisonCode
        self.client = client
        self.session = session
        self.fingerprint = fingerprint
    }

    deinit { client.cancel() }

    public func confirm() async throws -> (record: StoredCompanion, token: Data) {
        try await client.writeEnvelope(["v": 1, "op": "pair-confirm", "session": session])
        let reply = try await client.readEnvelope()
        if reply["op"] as? String == "failure" {
            throw CompanionError.rejected((reply["message"] as? String) ?? "Pairing was declined.")
        }
        guard reply["op"] as? String == "paired",
              let encoded = reply["token"] as? String,
              let token = Data(base64Encoded: encoded), token.count == 32
        else { throw CompanionError.invalidResponse("expected pairing credentials") }
        client.cancel()
        return (StoredCompanion(displayName: peer.displayName, fingerprint: fingerprint), token)
    }

    public func cancel() { client.cancel() }
}

/// TLS 1.3 client for the intentionally small companion protocol. Pinned
/// sends accept exactly the certificate paired in person; they never fall back
/// to the system trust store or an mDNS-provided certificate fingerprint.
public final class CompanionClient {
    public typealias Progress = (_ fileIndex: Int, _ fraction: Double) -> Void

    private let peer: CompanionPeer
    private let expectedFingerprint: String?
    private let queue = DispatchQueue(label: "dev.easyshare.companion.client")
    private let connection: NWConnection
    private var started = false

    private static let timeout: DispatchTimeInterval = .seconds(15)
    private static let maximumEnvelopeBytes = 1_048_576
    private static let maximumFiles = 512
    private static let maximumTotalBytes: Int64 = 100 * 1024 * 1024 * 1024

    private init(peer: CompanionPeer, expectedFingerprint: String?) throws {
        self.peer = peer
        self.expectedFingerprint = expectedFingerprint?.lowercased()
        let tls = NWProtocolTLS.Options()
        let expected = self.expectedFingerprint
        let capture = LockedFingerprint()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            // This verify callback runs before Network has necessarily built the
            // trust chain. Ask SecTrust for the peer's leaf directly so the
            // first (unpinned) pairing connection can capture its fingerprint.
            let certificate = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first
            let fingerprint = certificate.map { Self.fingerprint(of: $0) }
            capture.value = fingerprint
            if let expected {
                complete(fingerprint == expected)
            } else {
                // Pairing does not grant trust merely because this connection
                // opens: the separately displayed code binds this exact cert.
                complete(fingerprint != nil)
            }
        }, queue)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = true
        if let serviceEndpoint = peer.serviceEndpoint {
            connection = NWConnection(to: serviceEndpoint, using: parameters)
        } else {
            guard let port = NWEndpoint.Port(rawValue: peer.port) else { throw CompanionError.invalidPeer }
            connection = NWConnection(to: .hostPort(host: NWEndpoint.Host(peer.host), port: port), using: parameters)
        }
        captured = capture
    }

    // Stored separately so the TLS verification callback can assign before the
    // connection-ready callback resumes its async continuation.
    private let captured: LockedFingerprint

    public static func beginPairing(to peer: CompanionPeer, macName: String) async throws -> CompanionPairingAttempt {
        let client = try CompanionClient(peer: peer, expectedFingerprint: nil)
        do {
            try await client.connect()
            guard let fingerprint = client.captured.value else { throw CompanionError.invalidResponse("missing TLS certificate") }
            let challenge = try randomBytes(count: 32)
            let code = comparisonCode(challenge: challenge, fingerprint: fingerprint)
            try await client.writeEnvelope([
                "v": 1,
                "op": "pair-begin",
                "challenge": challenge.base64EncodedString(),
                "macName": PeerText.displayName(macName, fallback: "Mac"),
            ])
            let reply = try await client.readEnvelope()
            if reply["op"] as? String == "failure" {
                throw CompanionError.rejected((reply["message"] as? String) ?? "Android declined pairing.")
            }
            guard reply["op"] as? String == "pairing-ready", let session = reply["session"] as? String,
                  !session.isEmpty, session.utf8.count <= 128
            else { throw CompanionError.invalidResponse("expected pairing-ready") }
            return CompanionPairingAttempt(peer: peer, comparisonCode: code, client: client, session: session, fingerprint: fingerprint)
        } catch {
            client.cancel()
            throw error
        }
    }

    public static func send(
        to peer: CompanionPeer,
        record: StoredCompanion,
        token: Data,
        files: [CompanionOutgoingFile],
        sender: String,
        progress: @escaping Progress = { _, _ in }
    ) async throws {
        guard peer.fingerprint == record.fingerprint else { throw CompanionError.certificateChanged }
        guard token.count == 32 else { throw CompanionError.invalidResponse("missing pairing token") }
        guard !files.isEmpty, files.count <= maximumFiles else {
            throw CompanionError.invalidResponse("select between 1 and \(maximumFiles) files")
        }
        var total: Int64 = 0
        for file in files {
            guard file.size >= 0, total <= maximumTotalBytes - file.size else {
                throw CompanionError.invalidResponse("the selected files are too large")
            }
            total += file.size
        }
        let client = try CompanionClient(peer: peer, expectedFingerprint: record.fingerprint)
        try await withTaskCancellationHandler(operation: {
            do {
                try await client.connect()
                let metadata: [[String: Any]] = files.map {
                    ["name": $0.name, "size": $0.size, "mime": $0.mimeType.prefix(255).description]
                }
                try await client.writeEnvelope([
                    "v": 1,
                    "op": "send",
                    "token": token.base64EncodedString(),
                    "sender": PeerText.displayName(sender, fallback: "Mac"),
                    "files": metadata,
                ])
                let accepted = try await client.readEnvelope()
                if accepted["op"] as? String == "failure" {
                    throw CompanionError.rejected((accepted["message"] as? String) ?? "Android declined the transfer.")
                }
                guard accepted["op"] as? String == "accepted" else {
                    throw CompanionError.invalidResponse("expected transfer approval")
                }
                for (index, file) in files.enumerated() {
                    try Task.checkCancellation()
                    try await client.writeFile(file, index: index, progress: progress)
                }
                let completed = try await client.readEnvelope()
                if completed["op"] as? String == "failure" {
                    throw CompanionError.rejected((completed["message"] as? String) ?? "Android could not save the files.")
                }
                guard completed["op"] as? String == "complete" else {
                    throw CompanionError.invalidResponse("expected completion")
                }
                client.cancel()
            } catch {
                client.cancel()
                if error is CancellationError { throw CompanionError.cancelled }
                throw error
            }
        }, onCancel: {
            client.cancel()
        })
    }

    public func cancel() { connection.cancel() }

    private func connect() async throws {
        guard !started else { throw CompanionError.invalidResponse("connection is already in use") }
        started = true
        let activeConnection = connection
        let workQueue = queue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = ConnectionCompletion(connection: activeConnection, continuation: continuation)
            activeConnection.stateUpdateHandler = { state in
                switch state {
                case .ready: completion.finish(.success(()))
                case .failed: completion.finish(.failure(CompanionError.connectionClosed))
                case .cancelled: completion.finish(.failure(CompanionError.cancelled))
                default: break
                }
            }
            activeConnection.start(queue: workQueue)
            workQueue.asyncAfter(deadline: .now() + Self.timeout) {
                if completion.finish(.failure(CompanionError.connectionTimedOut)) {
                    activeConnection.cancel()
                }
            }
        }
    }

    fileprivate func writeEnvelope(_ value: [String: Any]) async throws {
        let payload = try JSONSerialization.data(withJSONObject: value, options: [])
        guard payload.count <= Self.maximumEnvelopeBytes else { throw CompanionError.invalidResponse("envelope is too large") }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        try await write(frame)
    }

    fileprivate func readEnvelope() async throws -> [String: Any] {
        let lengthBytes = try await readExactly(4)
        let length = lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length >= 2, length <= UInt32(Self.maximumEnvelopeBytes) else {
            throw CompanionError.invalidResponse("invalid envelope length")
        }
        let payload = try await readExactly(Int(length))
        guard let result = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw CompanionError.invalidResponse("envelope is not an object")
        }
        return result
    }

    private func writeFile(_ file: CompanionOutgoingFile, index: Int, progress: @escaping Progress) async throws {
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        var sent: Int64 = 0
        while sent < file.size {
            try Task.checkCancellation()
            let requested = Int(min(Int64(256 * 1024), file.size - sent))
            guard let data = try handle.read(upToCount: requested), !data.isEmpty else {
                throw CompanionError.invalidResponse("\(file.name) changed while it was being sent")
            }
            try await write(data)
            sent += Int64(data.count)
            progress(index, file.size == 0 ? 1 : Double(sent) / Double(file.size))
        }
        progress(index, 1)
    }

    private func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func readExactly(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let needed = count - result.count
            let (data, complete) = try await receive(atMost: needed)
            guard let data else { throw CompanionError.connectionClosed }
            result.append(data)
            if complete && result.count < count { throw CompanionError.connectionClosed }
        }
        return result
    }

    private func receive(atMost count: Int) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: count) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (data, complete)) }
            }
        }
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw CompanionError.invalidResponse("could not generate pairing challenge")
        }
        return Data(bytes)
    }

    private static func fingerprint(of certificate: SecCertificate) -> String {
        let data = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func comparisonCode(challenge: Data, fingerprint: String) -> String {
        let digest = SHA256.hash(data: challenge + Data(fingerprint.lowercased().utf8))
        let value = digest.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return String(format: "%06llu", value % 1_000_000)
    }
}

private final class LockedFingerprint: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// NWConnection invokes both the state callback and our timeout on the same
/// serial queue. The lock makes the one-resume invariant explicit anyway and
/// keeps this bridge safe if Network changes its callback delivery.
private final class ConnectionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Void, Error>?

    init(connection: NWConnection, continuation: CheckedContinuation<Void, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    @discardableResult
    func finish(_ result: Result<Void, Error>) -> Bool {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { continuation = nil }
            return continuation
        }
        guard let pending else { return false }
        connection.stateUpdateHandler = nil
        switch result {
        case .success: pending.resume()
        case .failure(let error): pending.resume(throwing: error)
        }
        return true
    }
}
