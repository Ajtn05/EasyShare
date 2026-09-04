import Foundation
import Network
import SwiftProtobuf

/// A file offered through an ephemeral Quick Share session.
public struct QuickShareOutgoingFile {
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

/// Sends files through Quick Share's Wi-Fi LAN transport.
public final class QuickShareSender {
    public typealias Progress = (_ fileIndex: Int, _ fraction: Double) -> Void
    public typealias VerificationPIN = (_ pin: String) -> Void

    private let peer: QuickSharePeer
    private let localEndpoint: QuickShareEndpointInfo
    private let qrCodeSession: QuickShareQRCodeSession?
    private let connection: NWConnection
    private let writer: QuickShareSessionWriter
    private let queue = DispatchQueue(label: "dev.easyshare.quickshare.sender")
    private var keepAliveTask: Task<Void, Never>?
    private var didStart = false
    private var incomingBytes: [Int64: Data] = [:]
    private var stage = "opening the Quick Share connection"
    private var safeDisconnectionEnabled = false

    private static let connectionTimeout: DispatchTimeInterval = .seconds(12)
    private static let safeDisconnectionTimeout: DispatchTimeInterval = .milliseconds(1_500)

    public init(
        peer: QuickSharePeer,
        displayName: String,
        qrCodeSession: QuickShareQRCodeSession? = nil
    ) throws {
        self.peer = peer
        self.qrCodeSession = qrCodeSession
        self.localEndpoint = try QuickShareEndpointInfo(
            endpointID: QuickShareEndpointInfo.newEndpointID(), displayName: displayName
        )
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection: NWConnection
        if let serviceEndpoint = peer.serviceEndpoint {
            // Preserve the DNS-SD endpoint; probing can consume a QR listener.
            connection = NWConnection(to: serviceEndpoint, using: parameters)
        } else {
            guard let port = NWEndpoint.Port(rawValue: peer.port) else {
                throw QuickShareError.malformed("Quick Share peer advertised an invalid port")
            }
            connection = NWConnection(
                to: .hostPort(host: NWEndpoint.Host(peer.host), port: port), using: parameters
            )
        }
        self.connection = connection
        self.writer = QuickShareSessionWriter(connection: connection)
    }

    deinit {
        keepAliveTask?.cancel()
        let writer = writer
        Task { await writer.close() }
    }

    public func send(
        files: [QuickShareOutgoingFile],
        verificationPIN: @escaping VerificationPIN = { _ in },
        progress: @escaping Progress = { _, _ in }
    ) async throws {
        guard !files.isEmpty, files.count <= QuickShareLimits.maxFilesPerOffer else {
            throw QuickShareError.unsupported("Quick Share needs between 1 and \(QuickShareLimits.maxFilesPerOffer) files")
        }
        guard files.allSatisfy({ $0.size >= 0 }) else {
            throw QuickShareError.malformed("a local file has a negative size")
        }
        guard !didStart else { throw QuickShareError.malformed("Quick Share sender instances are single-use") }
        didStart = true

        advance(to: "opening the temporary Quick Share connection")
        try await connect()
        defer { cancel() }
        try Task.checkCancellation()

        advance(to: "starting the security handshake")
        try await sendConnectionRequest()

        var ukey = QuickShareUKEY2Initiator()
        try await writer.sendPlain(try ukey.makeClientInit())
        advance(to: "waiting for the phone's security handshake")
        let serverInit = try await receiveRawFrame()
        let ukeyResult = try ukey.receiveServerInit(serverInit)
        verificationPIN(ukeyResult.result.pin)
        try await writer.sendPlain(ukeyResult.clientFinish)

        // The server response precedes the client response in Nearby's UKEY2 exchange.
        advance(to: "waiting for the phone's connection acknowledgement")
        let connectionResponse = try Location_Nearby_Connections_OfflineFrame(serializedBytes: await receiveRawFrame())
        guard connectionResponse.version == .v1,
              connectionResponse.v1.type == .connectionResponse,
              connectionResponse.v1.connectionResponse.response == .accept
        else { throw QuickShareError.peerRejected }
        safeDisconnectionEnabled = connectionResponse.v1.connectionResponse.safeToDisconnectVersion >= 1
        try await sendPlainConnectionAcceptance()

        await writer.activate(keys: ukeyResult.result.d2dKeys)
        startKeepAlive()
        advance(to: "verifying the QR session")
        try await completePairedKeyExchange(authenticationKey: ukeyResult.result.authenticationKey)

        let payloadIDs = try files.map { _ in try randomPayloadID() }
        advance(to: "offering the selected files")
        try await sendIntroduction(files: files, payloadIDs: payloadIDs)
        advance(to: "waiting for the phone to accept the file offer")
        let offerResponse = try await receiveTransferSetupFrame()
        guard offerResponse.version == .v1, offerResponse.v1.type == .response else {
            throw QuickShareError.malformed("expected Quick Share offer response")
        }
        switch offerResponse.v1.connectionResponse.status {
        case .accept:
            break
        case .notEnoughSpace:
            throw QuickShareError.insufficientSpace
        case .reject, .timedOut:
            throw QuickShareError.peerRejected
        default:
            throw QuickShareError.unsupported("Quick Share receiver rejected this attachment type")
        }

        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            advance(to: "uploading \(file.name)")
            try await sendFile(file, payloadID: payloadIDs[index], index: index, progress: progress)
        }

        advance(to: "finishing the file transfer")
        try await sendDisconnection(requestSafeToDisconnect: safeDisconnectionEnabled)
        if safeDisconnectionEnabled {
            advance(to: "waiting for the phone to finish writing the file")
            try await awaitSafeDisconnectionAcknowledgement()
        }
    }

    public func cancel() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        let writer = writer
        Task { await writer.close() }
    }

    // MARK: - Connection and encryption setup

    private func connect() async throws {
        let connection = connection
        let operation = stage
        try await withCheckedThrowingContinuation { continuation in
            var completed = false
            let finish: (Result<Void, Error>) -> Void = { result in
                guard !completed else { return }
                completed = true
                connection.stateUpdateHandler = nil
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(QuickShareError.connectionClosedDuring(operation)))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + Self.connectionTimeout) {
                guard !completed else { return }
                connection.cancel()
                finish(.failure(QuickShareError.connectionTimedOut))
            }
        }
    }

    private func sendConnectionRequest() async throws {
        var request = Location_Nearby_Connections_ConnectionRequestFrame()
        request.endpointID = localEndpoint.endpointID
        request.endpointName = localEndpoint.displayName
        request.endpointInfo = localEndpoint.serialized()
        request.mediums = [.wifiLan]
        request.keepAliveIntervalMillis = 10_000
        request.keepAliveTimeoutMillis = 30_000

        var frame = Location_Nearby_Connections_OfflineFrame()
        frame.version = .v1
        frame.v1.type = .connectionRequest
        frame.v1.connectionRequest = request
        try await writer.sendPlain(try frame.serializedData())
    }

    private func sendPlainConnectionAcceptance() async throws {
        var response = Location_Nearby_Connections_ConnectionResponseFrame()
        response.response = .accept
        response.status = 0
        // Enables safe-disconnect negotiation.
        response.safeToDisconnectVersion = 1
        var os = Location_Nearby_Connections_OsInfo()
        os.type = .apple
        response.osInfo = os

        var frame = Location_Nearby_Connections_OfflineFrame()
        frame.version = .v1
        frame.v1.type = .connectionResponse
        frame.v1.connectionResponse = response
        try await writer.sendPlain(try frame.serializedData())
    }

    private func completePairedKeyExchange(authenticationKey: Data) async throws {
        let receiverEncryption = try await receiveTransferSetupFrame()
        guard receiverEncryption.version == .v1, receiverEncryption.v1.type == .pairedKeyEncryption else {
            throw QuickShareError.malformed("expected Quick Share paired-key encryption frame")
        }
        try await sendPairedKeyEncryption(authenticationKey: authenticationKey)

        let receiverResult = try await receiveTransferSetupFrame()
        guard receiverResult.version == .v1, receiverResult.v1.type == .pairedKeyResult else {
            throw QuickShareError.malformed("expected Quick Share paired-key result frame")
        }
        try await sendPairedKeyResult()
    }

    private func sendPairedKeyEncryption(authenticationKey: Data) async throws {
        var payload = Nearby_Sharing_Service_Proto_PairedKeyEncryptionFrame()
        payload.secretIDHash = try randomBytes(count: 6)
        payload.signedData = try randomBytes(count: 72)
        if let qrCodeSession {
            payload.qrCodeHandshakeData = try qrCodeSession.handshakeSignature(for: authenticationKey)
        }
        var frame = Nearby_Sharing_Service_Proto_Frame()
        frame.version = .v1
        frame.v1.type = .pairedKeyEncryption
        frame.v1.pairedKeyEncryption = payload
        try await sendTransferSetupFrame(frame)
    }

    private func sendPairedKeyResult() async throws {
        var result = Nearby_Sharing_Service_Proto_PairedKeyResultFrame()
        // Public-mode senders do not implement paired-key exchange.
        result.status = .unable
        var frame = Nearby_Sharing_Service_Proto_Frame()
        frame.version = .v1
        frame.v1.type = .pairedKeyResult
        frame.v1.pairedKeyResult = result
        try await sendTransferSetupFrame(frame)
    }

    // MARK: - Offer and payloads

    private func sendIntroduction(files: [QuickShareOutgoingFile], payloadIDs: [Int64]) async throws {
        var introduction = Nearby_Sharing_Service_Proto_IntroductionFrame()
        // Android rejects an UNKNOWN use case.
        introduction.useCase = .nearbyShare
        introduction.fileMetadata = try zip(files, payloadIDs).map { file, payloadID in
            var metadata = Nearby_Sharing_Service_Proto_FileMetadata()
            metadata.name = file.name
            metadata.type = fileType(for: file.mimeType)
            metadata.payloadID = payloadID
            metadata.size = file.size
            metadata.mimeType = file.mimeType
            metadata.id = try randomPayloadID()
            metadata.attachmentHash = try randomPayloadID()
            return metadata
        }

        var frame = Nearby_Sharing_Service_Proto_Frame()
        frame.version = .v1
        frame.v1.type = .introduction
        frame.v1.introduction = introduction
        try await sendTransferSetupFrame(frame)
    }

    private func sendFile(
        _ file: QuickShareOutgoingFile, payloadID: Int64, index: Int, progress: @escaping Progress
    ) async throws {
        guard let stream = InputStream(url: file.url) else {
            throw QuickShareError.malformed("could not open \(file.name) for reading")
        }
        stream.open()
        defer { stream.close() }
        if stream.streamStatus == .error {
            throw stream.streamError ?? QuickShareError.malformed("could not read \(file.name)")
        }

        var header = Location_Nearby_Connections_PayloadTransferFrame.PayloadHeader()
        header.id = payloadID
        header.type = .file
        header.totalSize = file.size
        header.fileName = file.name

        var offset: Int64 = 0
        let chunkSize = 512 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while offset < file.size {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBufferPointer { stream.read($0.baseAddress!, maxLength: chunkSize) }
            if count < 0 { throw stream.streamError ?? QuickShareError.connectionClosed }
            guard count > 0 else {
                throw QuickShareError.malformed("\(file.name) changed while Quick Share was reading it")
            }
            let data = Data(buffer.prefix(count))
            guard Int64(data.count) <= file.size - offset else {
                throw QuickShareError.malformed("\(file.name) grew while Quick Share was reading it")
            }
            var chunk = Location_Nearby_Connections_PayloadTransferFrame.PayloadChunk()
            chunk.offset = offset
            chunk.flags = 0
            chunk.body = data
            try await sendPayload(header: header, chunk: chunk)
            offset += Int64(data.count)
            progress(index, file.size == 0 ? 1 : Double(offset) / Double(file.size))
        }
        guard offset == file.size else {
            throw QuickShareError.malformed("\(file.name) ended before its advertised size")
        }
        var finalChunk = Location_Nearby_Connections_PayloadTransferFrame.PayloadChunk()
        finalChunk.offset = offset
        finalChunk.flags = 1
        try await sendPayload(header: header, chunk: finalChunk)
        progress(index, 1)
    }

    private func sendTransferSetupFrame(_ frame: Nearby_Sharing_Service_Proto_Frame) async throws {
        try await sendBytesPayload(try frame.serializedData(), payloadID: randomPayloadID())
    }

    private func sendBytesPayload(_ bytes: Data, payloadID: Int64) async throws {
        var header = Location_Nearby_Connections_PayloadTransferFrame.PayloadHeader()
        header.id = payloadID
        header.type = .bytes
        header.totalSize = Int64(bytes.count)

        var body = Location_Nearby_Connections_PayloadTransferFrame.PayloadChunk()
        body.offset = 0
        body.flags = 0
        body.body = bytes
        try await sendPayload(header: header, chunk: body)

        var finalChunk = Location_Nearby_Connections_PayloadTransferFrame.PayloadChunk()
        finalChunk.offset = Int64(bytes.count)
        finalChunk.flags = 1
        try await sendPayload(header: header, chunk: finalChunk)
    }

    private func sendPayload(
        header: Location_Nearby_Connections_PayloadTransferFrame.PayloadHeader,
        chunk: Location_Nearby_Connections_PayloadTransferFrame.PayloadChunk
    ) async throws {
        var transfer = Location_Nearby_Connections_PayloadTransferFrame()
        transfer.packetType = .data
        transfer.payloadHeader = header
        transfer.payloadChunk = chunk
        var frame = Location_Nearby_Connections_OfflineFrame()
        frame.version = .v1
        frame.v1.type = .payloadTransfer
        frame.v1.payloadTransfer = transfer
        try await writer.sendEncrypted(frame)
    }

    private func sendDisconnection(
        requestSafeToDisconnect: Bool = false,
        acknowledgeSafeToDisconnect: Bool = false
    ) async throws {
        var frame = Location_Nearby_Connections_OfflineFrame()
        frame.version = .v1
        frame.v1.type = .disconnection
        frame.v1.disconnection.requestSafeToDisconnect = requestSafeToDisconnect
        frame.v1.disconnection.ackSafeToDisconnect = acknowledgeSafeToDisconnect
        try await writer.sendEncrypted(frame)
    }

    // MARK: - Incoming encrypted frames

    private func receiveRawFrame(timeout: DispatchTimeInterval? = nil) async throws -> Data {
        let prefix = try await receiveExactly(4, timeout: timeout)
        let length = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= QuickShareFraming.maximumFrameLength else {
            throw QuickShareError.frameTooLarge(Int(length))
        }
        return try await receiveExactly(Int(length), timeout: timeout)
    }

    private func receiveExactly(_ length: Int, timeout: DispatchTimeInterval? = nil) async throws -> Data {
        try Task.checkCancellation()
        let operation = stage
        let connection = connection
        return try await withCheckedThrowingContinuation { continuation in
            var completed = false
            let finish: (Result<Data, Error>) -> Void = { result in
                guard !completed else { return }
                completed = true
                switch result {
                case .success(let data): continuation.resume(returning: data)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, complete, error in
                if let error { finish(.failure(error)); return }
                guard !complete, let data, data.count == length else {
                    finish(.failure(QuickShareError.connectionClosedDuring(operation)))
                    return
                }
                finish(.success(data))
            }
            if let timeout {
                queue.asyncAfter(deadline: .now() + timeout) {
                    guard !completed else { return }
                    connection.cancel()
                    finish(.failure(QuickShareError.deliveryConfirmationTimedOut))
                }
            }
        }
    }

    private func receiveTransferSetupFrame() async throws -> Nearby_Sharing_Service_Proto_Frame {
        while true {
            let frame = try await receiveEncryptedFrame()
            switch frame.v1.type {
            case .keepAlive:
                if !frame.v1.keepAlive.ack { try await sendKeepAlive(ack: true) }
            case .disconnection:
                throw QuickShareError.connectionClosedDuring(stage)
            case .payloadTransfer:
                let transfer = frame.v1.payloadTransfer
                guard transfer.packetType == .data, transfer.hasPayloadHeader, transfer.hasPayloadChunk,
                      transfer.payloadHeader.type == .bytes, transfer.payloadHeader.hasID,
                      transfer.payloadHeader.hasTotalSize, transfer.payloadHeader.totalSize >= 0,
                      transfer.payloadChunk.hasOffset, transfer.payloadChunk.hasFlags
                else { throw QuickShareError.malformed("expected Quick Share bytes payload") }
                let header = transfer.payloadHeader
                var bytes = incomingBytes[header.id] ?? Data()
                guard header.totalSize <= Int64(QuickShareFraming.maximumFrameLength),
                      transfer.payloadChunk.offset == bytes.count
                else { throw QuickShareError.malformed("invalid Quick Share bytes payload offset") }
                if transfer.payloadChunk.hasBody { bytes.append(transfer.payloadChunk.body) }
                guard bytes.count <= header.totalSize else {
                    throw QuickShareError.malformed("Quick Share bytes payload exceeds its advertised size")
                }
                if (transfer.payloadChunk.flags & 1) == 1 {
                    guard bytes.count == header.totalSize else {
                        throw QuickShareError.malformed("Quick Share bytes payload ended short")
                    }
                    incomingBytes[header.id] = nil
                    return try Nearby_Sharing_Service_Proto_Frame(serializedBytes: bytes)
                }
                incomingBytes[header.id] = bytes
            default:
                throw QuickShareError.malformed("unexpected encrypted Quick Share frame")
            }
        }
    }

    private func receiveEncryptedFrame(timeout: DispatchTimeInterval? = nil) async throws -> Location_Nearby_Connections_OfflineFrame {
        try await writer.open(try await receiveRawFrame(timeout: timeout))
    }

    private func awaitSafeDisconnectionAcknowledgement() async throws {
        while true {
            let frame = try await receiveEncryptedFrame(timeout: Self.safeDisconnectionTimeout)
            guard frame.version == .v1 else {
                throw QuickShareError.malformed("unknown offline frame version while finishing Quick Share")
            }
            switch frame.v1.type {
            case .keepAlive:
                if !frame.v1.keepAlive.ack { try await sendKeepAlive(ack: true) }
            case .payloadTransfer:
                // Payload acknowledgements do not complete safe-disconnect.
                guard frame.v1.payloadTransfer.packetType == .payloadAck,
                      frame.v1.payloadTransfer.hasPayloadHeader,
                      frame.v1.payloadTransfer.payloadHeader.hasID
                else {
                    throw QuickShareError.malformed("unexpected Quick Share frame while finishing the transfer")
                }
            case .disconnection:
                if frame.v1.disconnection.ackSafeToDisconnect {
                    return
                }
                // Accept receiver-initiated safe-disconnect for Android interop.
                guard frame.v1.disconnection.requestSafeToDisconnect else {
                    throw QuickShareError.connectionClosedDuring(stage)
                }
                try await sendDisconnection(acknowledgeSafeToDisconnect: true)
                return
            default:
                throw QuickShareError.malformed("unexpected Quick Share frame while waiting for delivery confirmation")
            }
        }
    }

    private func sendKeepAlive(ack: Bool) async throws {
        var keepAlive = Location_Nearby_Connections_KeepAliveFrame()
        keepAlive.ack = ack
        var frame = Location_Nearby_Connections_OfflineFrame()
        frame.version = .v1
        frame.v1.type = .keepAlive
        frame.v1.keepAlive = keepAlive
        try await writer.sendEncrypted(frame)
    }

    private func startKeepAlive() {
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                do { try await self.sendKeepAlive(ack: false) }
                catch { self.cancel(); return }
            }
        }
    }

    private func randomPayloadID() throws -> Int64 {
        let bytes = try randomBytes(count: 8)
        return Int64(bitPattern: bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
    }

    private func advance(to stage: String) {
        self.stage = stage
        NSLog("[EasyShare.QuickShare] \(stage)")
    }

    private func fileType(for mimeType: String) -> Nearby_Sharing_Service_Proto_FileMetadata.TypeEnum {
        if mimeType.hasPrefix("image/") { return .image }
        if mimeType.hasPrefix("video/") { return .video }
        if mimeType.hasPrefix("audio/") { return .audio }
        return .document
    }
}

/// Serializes encrypted traffic to preserve D2D sequence ordering.
private actor QuickShareSessionWriter {
    private let connection: NWConnection
    private var codec: QuickShareD2DCodec?

    init(connection: NWConnection) { self.connection = connection }

    func activate(keys: QuickShareD2DKeys) { codec = QuickShareD2DCodec(keys: keys) }

    func sendPlain(_ payload: Data) async throws {
        try await send(QuickShareFraming.encode(payload))
    }

    func sendEncrypted(_ frame: Location_Nearby_Connections_OfflineFrame) async throws {
        guard let codec else { throw QuickShareError.malformed("D2D codec is not ready") }
        try await send(QuickShareFraming.encode(try codec.seal(frame)))
    }

    func open(_ payload: Data) throws -> Location_Nearby_Connections_OfflineFrame {
        guard let codec else { throw QuickShareError.malformed("D2D codec is not ready") }
        return try codec.open(payload)
    }

    func close() { connection.cancel() }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
