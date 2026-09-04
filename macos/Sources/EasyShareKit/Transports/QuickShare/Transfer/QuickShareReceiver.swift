import Foundation
import Network
import OSLog
import SwiftProtobuf

public struct QuickShareIncomingFile: Sendable {
    public let name: String
    public let size: Int64
    public let mimeType: String
}

public struct QuickShareIncomingOffer: Sendable {
    public let transferID: String
    public let senderName: String
    public let verificationPIN: String
    public let files: [QuickShareIncomingFile]
    public let totalSize: Int64
}

/// Delivers Quick Share offers and transfer results to the app layer.
public protocol QuickShareReceiverDelegate: AnyObject {
    func quickShareReceiverShouldAccept(_ offer: QuickShareIncomingOffer) async -> Bool
    func quickShareReceiverDidReceiveFile(at url: URL, from senderName: String)
    func quickShareReceiverDidFinishTransfer(from senderName: String)
    func quickShareReceiverDidFail(_ error: Error, from senderName: String?)
}

public final class QuickShareReceiver {
    public enum State: Equatable {
        case stopped
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    public private(set) var state = State.stopped { didSet { onStateChange?(state) } }
    public var onStateChange: ((State) -> Void)?
    public weak var delegate: QuickShareReceiverDelegate?

    private let endpoint: QuickShareEndpointInfo
    private let downloadsDirectory: URL
    private let queue = DispatchQueue(label: "dev.easyshare.quickshare.receiver")
    private var listener: NWListener?
    private var connections = Set<QuickShareReceiverConnection>()

    public init(displayName: String, downloadsDirectory: URL, delegate: QuickShareReceiverDelegate? = nil) throws {
        self.endpoint = try QuickShareEndpointInfo(
            endpointID: QuickShareEndpointInfo.newEndpointID(), displayName: displayName
        )
        self.downloadsDirectory = downloadsDirectory
        self.delegate = delegate
    }

    public func start() throws {
        stop()
        state = .starting

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let listener, let port = listener.port?.rawValue else { return }
                // Advertise only after the listener is ready.
                listener.service = NWListener.Service(
                    name: self.endpoint.advertisementName(), type: QuickShareEndpointInfo.serviceType,
                    txtRecord: self.endpoint.txtRecord()
                )
                self.state = .ready(port: port)
            case .failed(let error):
                self.state = .failed(error.localizedDescription)
            case .cancelled:
                self.state = .stopped
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        state = .stopped
    }

    private func accept(_ connection: NWConnection) {
        let handler = QuickShareReceiverConnection(
            connection: connection,
            downloadsDirectory: downloadsDirectory,
            queue: queue,
            delegate: delegate
        ) { [weak self] handler in
            self?.connections.remove(handler)
        }
        connections.insert(handler)
        handler.start()
    }
}

private final class QuickShareReceiverConnection: Hashable, @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.easyshare.app", category: "QuickShareReceiver")

    private enum Stage: Equatable {
        case awaitRequest
        case awaitClientInit
        case awaitClientFinish
        case awaitClientResponse
        case awaitPairedKeyEncryption
        case awaitPairedKeyResult
        case awaitIntroduction
        case awaitingDecision
        case receiving
        case awaitingSafeDisconnection
        case closed
    }

    private final class StagedPayload {
        let id: Int64
        let expectedType: Location_Nearby_Connections_PayloadTransferFrame.PayloadHeader.PayloadType
        let descriptor: QuickShareIncomingFile
        let temporaryURL: URL
        var sink: QuickShareUploadSink?
        var bytesWritten: Int64 = 0
        var finished = false

        init(
            id: Int64,
            expectedType: Location_Nearby_Connections_PayloadTransferFrame.PayloadHeader.PayloadType,
            descriptor: QuickShareIncomingFile,
            temporaryURL: URL
        ) {
            self.id = id
            self.expectedType = expectedType
            self.descriptor = descriptor
            self.temporaryURL = temporaryURL
        }
    }

    private let connection: NWConnection
    private let downloadsDirectory: URL
    private let queue: DispatchQueue
    private weak var delegate: QuickShareReceiverDelegate?
    private let onFinish: (QuickShareReceiverConnection) -> Void
    private let id = UUID().uuidString

    private var stage: Stage = .awaitRequest
    private var senderName: String?
    private var ukey = QuickShareUKEY2Responder()
    private var codec: QuickShareD2DCodec?
    private var verificationPIN: String?
    private var safeDisconnectionEnabled = false
    private var keepAlive: DispatchSourceTimer?
    private var bytePayloads: [Int64: Data] = [:]
    private var stagedPayloads: [Int64: StagedPayload] = [:]
    private var temporaryDirectory: URL?
    private var finished = false

    init(
        connection: NWConnection,
        downloadsDirectory: URL,
        queue: DispatchQueue,
        delegate: QuickShareReceiverDelegate?,
        onFinish: @escaping (QuickShareReceiverConnection) -> Void
    ) {
        self.connection = connection
        self.downloadsDirectory = downloadsDirectory
        self.queue = queue
        self.delegate = delegate
        self.onFinish = onFinish
    }

    func start() {
        Self.logger.debug("Accepted incoming Quick Share connection")
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error): self?.close(error: error)
            case .cancelled: self?.close(error: nil)
            default: break
            }
        }
        connection.start(queue: queue)
        receiveLength()
    }

    func cancel() { close(error: nil) }

    private func receiveLength() {
        guard stage != .closed else { return }
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error { self.close(error: error); return }
            guard !complete, let data, data.count == 4 else { self.close(error: nil); return }
            let length = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length <= QuickShareFraming.maximumFrameLength else {
                self.close(error: QuickShareError.frameTooLarge(Int(length)))
                return
            }
            self.receiveBody(length: Int(length))
        }
    }

    private func receiveBody(length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error { self.close(error: error); return }
            guard !complete, let data, data.count == length else { self.close(error: nil); return }
            do {
                try self.process(data)
                self.receiveLength()
            } catch {
                self.close(error: error)
            }
        }
    }

    private func process(_ data: Data) throws {
        switch stage {
        case .awaitRequest:
            let frame = try Location_Nearby_Connections_OfflineFrame(serializedBytes: data)
            guard frame.version == .v1, frame.v1.type == .connectionRequest,
                  let endpoint = QuickShareEndpointInfo(connectionRequest: frame.v1.connectionRequest)
            else { throw QuickShareError.malformed("expected Quick Share connection request") }
            senderName = endpoint.displayName
            stage = .awaitClientInit
            Self.logger.debug("Quick Share phase: received connection request")

        case .awaitClientInit:
            try sendPlain(ukey.receiveClientInit(data))
            stage = .awaitClientFinish
            Self.logger.debug("Quick Share phase: sent UKEY2 server init")

        case .awaitClientFinish:
            let result = try ukey.receiveClientFinish(data)
            codec = QuickShareD2DCodec(keys: result.d2dKeys)
            verificationPIN = result.pin
            // The receiver sends the final plaintext acknowledgement first.
            try sendPlainConnectionAcceptance()
            stage = .awaitClientResponse
            Self.logger.debug("Quick Share phase: sent connection acknowledgement")

        case .awaitClientResponse:
            let frame = try Location_Nearby_Connections_OfflineFrame(serializedBytes: data)
            guard frame.version == .v1, frame.v1.type == .connectionResponse,
                  frame.v1.connectionResponse.response == .accept
            else { throw QuickShareError.peerRejected }
            safeDisconnectionEnabled = frame.v1.connectionResponse.safeToDisconnectVersion >= 1
            startKeepAlive()
            try sendPairedKeyEncryption()
            stage = .awaitPairedKeyEncryption
            Self.logger.debug("Quick Share phase: sent paired-key encryption")

        case .closed:
            return

        default:
            guard let codec else { throw QuickShareError.malformed("encrypted data before UKEY2") }
            try processEncrypted(try codec.open(data))
        }
    }

    private func processEncrypted(_ frame: Location_Nearby_Connections_OfflineFrame) throws {
        guard frame.version == .v1 else { throw QuickShareError.malformed("unknown offline frame version") }
        switch frame.v1.type {
        case .keepAlive:
            try sendKeepAlive(ack: true)
        case .disconnection:
            let disconnection = frame.v1.disconnection
            guard safeDisconnectionEnabled else {
                close(error: nil)
                return
            }

            if disconnection.ackSafeToDisconnect {
                // The sender confirmed it drained the final FILE frame.
                Self.logger.notice("Quick Share delivery confirmation received")
                closeAfterFlush()
            } else if disconnection.requestSafeToDisconnect {
                // Support sender-initiated safe disconnect.
                try sendSafeDisconnectionAcknowledgement()
                Self.logger.notice("Quick Share sender requested delivery confirmation")
                closeAfterFlush()
            } else {
                close(error: nil)
            }
        case .payloadTransfer:
            try processPayload(frame.v1.payloadTransfer)
        case .bandwidthUpgradeRetry:
            try handleBandwidthUpgradeRetry(frame.v1.bandwidthUpgradeRetry)
        default:
            throw QuickShareError.unsupported(
                "unsupported encrypted Quick Share frame type \(frame.v1.type.rawValue)"
            )
        }
    }

    /// Declines optional bandwidth upgrades while retaining the LAN channel.
    private func handleBandwidthUpgradeRetry(
        _ request: Location_Nearby_Connections_BandwidthUpgradeRetryFrame
    ) throws {
        guard request.isRequest else {
            Self.logger.debug("Received unsolicited Quick Share bandwidth-upgrade capability list")
            return
        }

        var response = Location_Nearby_Connections_BandwidthUpgradeRetryFrame()
        response.isRequest = false

        var frame = Location_Nearby_Connections_OfflineFrame()
        frame.version = .v1
        frame.v1.type = .bandwidthUpgradeRetry
        frame.v1.bandwidthUpgradeRetry = response
        try sendEncrypted(frame)
        Self.logger.debug("Replied to Quick Share bandwidth-upgrade retry with no alternate media")
    }

    private func processPayload(_ transfer: Location_Nearby_Connections_PayloadTransferFrame) throws {
        guard transfer.packetType == .data, transfer.hasPayloadHeader, transfer.hasPayloadChunk,
              transfer.payloadHeader.hasID, transfer.payloadHeader.hasType,
              transfer.payloadHeader.hasTotalSize, transfer.payloadChunk.hasOffset,
              transfer.payloadChunk.hasFlags, transfer.payloadHeader.totalSize >= 0
        else { throw QuickShareError.malformed("incomplete Quick Share payload") }

        let header = transfer.payloadHeader
        let chunk = transfer.payloadChunk
        if let staged = stagedPayloads[header.id] {
            try write(chunk: chunk, header: header, to: staged)
            return
        }

        guard header.type == .bytes, header.totalSize <= Int64(QuickShareFraming.maximumFrameLength) else {
            throw QuickShareError.unsupported("unexpected Quick Share payload type")
        }
        var bytes = bytePayloads[header.id] ?? Data()
        guard chunk.offset == bytes.count else {
            throw QuickShareError.malformed("Quick Share bytes payload offset is not contiguous")
        }
        if chunk.hasBody { bytes.append(chunk.body) }
        guard bytes.count <= header.totalSize else {
            throw QuickShareError.malformed("Quick Share bytes payload exceeds declared size")
        }
        if (chunk.flags & 1) == 1 {
            guard bytes.count == header.totalSize else {
                throw QuickShareError.malformed("Quick Share bytes payload ended short")
            }
            bytePayloads[header.id] = nil
            try processTransferSetupFrame(try Nearby_Sharing_Service_Proto_Frame(serializedBytes: bytes))
        } else {
            bytePayloads[header.id] = bytes
        }
    }

    private func processTransferSetupFrame(_ frame: Nearby_Sharing_Service_Proto_Frame) throws {
        guard frame.version == .v1 else { throw QuickShareError.malformed("unknown Quick Share frame version") }
        Self.logger.debug(
            "Received Quick Share setup frame type \(frame.v1.type.rawValue, privacy: .public) during \(self.phaseName, privacy: .public)"
        )
        switch stage {
        case .awaitPairedKeyEncryption:
            guard frame.v1.type == .pairedKeyEncryption else {
                throw QuickShareError.malformed("expected paired-key encryption frame")
            }
            try sendPairedKeyResult()
            stage = .awaitPairedKeyResult

        case .awaitPairedKeyResult:
            guard frame.v1.type == .pairedKeyResult else {
                throw QuickShareError.malformed("expected paired-key result frame")
            }
            stage = .awaitIntroduction

        case .awaitIntroduction:
            if frame.v1.type == .introduction, frame.v1.hasIntroduction {
                try receiveIntroduction(frame.v1.introduction)
            } else if frame.v1.type == .cancel {
                close(error: QuickShareError.cancelled)
            } else {
                // Ignore non-terminal control frames before the offer.
                Self.logger.debug("Ignoring pre-offer Quick Share control frame")
            }

        case .receiving, .awaitingDecision:
            if frame.v1.type == .cancel {
                close(error: QuickShareError.cancelled)
            } else {
                // Ignore non-terminal control frames while awaiting consent.
                Self.logger.debug("Ignoring Quick Share control frame while transfer state is unchanged")
            }

        default:
            throw QuickShareError.malformed("Quick Share setup frame arrived out of order")
        }
    }

    private func receiveIntroduction(_ introduction: Nearby_Sharing_Service_Proto_IntroductionFrame) throws {
        guard introduction.fileMetadata.count + introduction.textMetadata.count > 0,
              introduction.fileMetadata.count + introduction.textMetadata.count <= QuickShareLimits.maxFilesPerOffer
        else { throw QuickShareError.unsupported("Quick Share offer has an unsupported item count") }

        var seenPayloadIDs = Set<Int64>()
        var offered: [(Int64, Location_Nearby_Connections_PayloadTransferFrame.PayloadHeader.PayloadType, QuickShareIncomingFile)] = []
        for file in introduction.fileMetadata {
            guard file.hasPayloadID, file.hasSize, file.size >= 0, seenPayloadIDs.insert(file.payloadID).inserted else {
                throw QuickShareError.malformed("invalid Quick Share file metadata")
            }
            offered.append((
                file.payloadID, .file,
                QuickShareIncomingFile(
                    name: IncomingFilename.sanitize(file.name), size: file.size,
                    mimeType: file.hasMimeType ? file.mimeType : "application/octet-stream"
                )
            ))
        }
        for (index, text) in introduction.textMetadata.enumerated() {
            guard text.hasPayloadID, text.hasSize, text.size >= 0, seenPayloadIDs.insert(text.payloadID).inserted else {
                throw QuickShareError.malformed("invalid Quick Share text metadata")
            }
            let title = text.hasTextTitle ? text.textTitle : "Quick Share text \(index + 1)"
            offered.append((
                text.payloadID, .bytes,
                QuickShareIncomingFile(
                    name: IncomingFilename.sanitize(title + ".txt"), size: text.size, mimeType: "text/plain"
                )
            ))
        }
        guard let offeredSize = totalSize(offered.map(\.2)),
              offeredSize <= QuickShareLimits.maximumTotalBytes
        else {
            throw QuickShareError.malformed("Quick Share offer is too large")
        }
        if let available = availableCapacity(), available < offeredSize {
            try sendOfferResponse(.notEnoughSpace)
            closeAfterFlush()
            return
        }

        let result = try makeStagingDirectory(for: offered)
        stagedPayloads = result
        let offer = QuickShareIncomingOffer(
            transferID: id,
            senderName: senderName ?? "Quick Share device",
            verificationPIN: ukeyPIN,
            files: offered.map(\.2),
            totalSize: offeredSize
        )
        stage = .awaitingDecision

        guard let delegate else {
            try decide(accepted: false)
            return
        }
        Task { [weak self] in
            let accepted = await delegate.quickShareReceiverShouldAccept(offer)
            self?.queue.async { self?.decideFromQueue(accepted: accepted) }
        }
    }

    private var ukeyPIN: String {
        verificationPIN ?? ""
    }

    private func decideFromQueue(accepted: Bool) {
        guard stage == .awaitingDecision else { return }
        do { try decide(accepted: accepted) }
        catch { close(error: error) }
    }

    private func decide(accepted: Bool) throws {
        if !accepted {
            try sendOfferResponse(.reject)
            closeAfterFlush()
            return
        }
        for payload in stagedPayloads.values {
            payload.sink = try QuickShareUploadSink(url: payload.temporaryURL, limit: payload.descriptor.size)
        }
        try sendOfferResponse(.accept)
        stage = .receiving
    }

    private func write(
        chunk: Location_Nearby_Connections_PayloadTransferFrame.PayloadChunk,
        header: Location_Nearby_Connections_PayloadTransferFrame.PayloadHeader,
        to payload: StagedPayload
    ) throws {
        guard stage == .receiving, header.type == payload.expectedType,
              header.totalSize == payload.descriptor.size, chunk.offset == payload.bytesWritten,
              !payload.finished, let sink = payload.sink
        else { throw QuickShareError.malformed("invalid Quick Share file chunk") }
        if chunk.hasBody {
            try sink.write(chunk.body)
            payload.bytesWritten += Int64(chunk.body.count)
        }
        guard payload.bytesWritten <= payload.descriptor.size else {
            throw QuickShareError.malformed("Quick Share file exceeds its accepted size")
        }
        if (chunk.flags & 1) == 1 {
            guard payload.bytesWritten == payload.descriptor.size else {
                throw QuickShareError.malformed("Quick Share file ended short")
            }
            sink.close()
            payload.finished = true
            if stagedPayloads.values.allSatisfy(\.finished) { try completeTransfer() }
        }
    }

    private func completeTransfer() throws {
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        var destinations: [URL] = []
        do {
            for payload in stagedPayloads.values.sorted(by: { $0.descriptor.name < $1.descriptor.name }) {
                let destination = IncomingFilename.uniqueURL(for: payload.descriptor.name, in: downloadsDirectory)
                try FileManager.default.moveItem(at: payload.temporaryURL, to: destination)
                destinations.append(destination)
            }
        } catch {
            throw error
        }

        let sender = senderName ?? "Quick Share device"
        for destination in destinations { delegate?.quickShareReceiverDidReceiveFile(at: destination, from: sender) }
        delegate?.quickShareReceiverDidFinishTransfer(from: sender)
        // Request safe disconnect only after committing every file.
        if safeDisconnectionEnabled {
            stage = .awaitingSafeDisconnection
            try sendSafeDisconnectionRequest()
            Self.logger.notice("Quick Share file committed; requested delivery confirmation")
        } else {
            sendDisconnectionAndClose()
        }
    }

    private func makeStagingDirectory(
        for offered: [(Int64, Location_Nearby_Connections_PayloadTransferFrame.PayloadHeader.PayloadType, QuickShareIncomingFile)]
    ) throws -> [Int64: StagedPayload] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasyShare-QuickShare-Incoming", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
        return Dictionary(uniqueKeysWithValues: offered.enumerated().map { index, item in
            (item.0, StagedPayload(
                id: item.0, expectedType: item.1, descriptor: item.2,
                temporaryURL: directory.appendingPathComponent("payload-\(index)")
            ))
        })
    }

    private func totalSize(_ files: [QuickShareIncomingFile]) -> Int64? {
        var total: Int64 = 0
        for file in files {
            let (next, overflow) = total.addingReportingOverflow(file.size)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    private func availableCapacity() -> Int64? {
        let values = try? downloadsDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func sendPlainConnectionAcceptance() throws {
        var response = Location_Nearby_Connections_ConnectionResponseFrame()
        response.response = .accept
        response.status = 0
        response.safeToDisconnectVersion = 1
        var os = Location_Nearby_Connections_OsInfo()
        os.type = .apple
        response.osInfo = os

        var frame = Location_Nearby_Connections_OfflineFrame()
        frame.version = .v1
        frame.v1.type = .connectionResponse
        frame.v1.connectionResponse = response
        try sendPlain(frame.serializedData())
    }

    private func sendPairedKeyEncryption() throws {
        var payload = Nearby_Sharing_Service_Proto_PairedKeyEncryptionFrame()
        payload.secretIDHash = try randomBytes(count: 6)
        payload.signedData = try randomBytes(count: 72)
        var frame = Nearby_Sharing_Service_Proto_Frame()
        frame.version = .v1
        frame.v1.type = .pairedKeyEncryption
        frame.v1.pairedKeyEncryption = payload
        try sendTransferSetupFrame(frame)
    }

    private func sendPairedKeyResult() throws {
        var result = Nearby_Sharing_Service_Proto_PairedKeyResultFrame()
        result.status = .unable
        var frame = Nearby_Sharing_Service_Proto_Frame()
        frame.version = .v1
        frame.v1.type = .pairedKeyResult
        frame.v1.pairedKeyResult = result
        try sendTransferSetupFrame(frame)
    }

    private func sendOfferResponse(_ status: Nearby_Sharing_Service_Proto_ConnectionResponseFrame.Status) throws {
        var response = Nearby_Sharing_Service_Proto_ConnectionResponseFrame()
        response.status = status
        var frame = Nearby_Sharing_Service_Proto_Frame()
        frame.version = .v1
        frame.v1.type = .response
        frame.v1.connectionResponse = response
        try sendTransferSetupFrame(frame)
    }

    private func sendTransferSetupFrame(_ frame: Nearby_Sharing_Service_Proto_Frame) throws {
        try sendBytesPayload(try frame.serializedData(), payloadID: randomPayloadID())
    }

    private func sendBytesPayload(_ bytes: Data, payloadID: Int64) throws {
        var header = Location_Nearby_Connections_PayloadTransferFrame.PayloadHeader()
        header.id = payloadID
        header.type = .bytes
        header.totalSize = Int64(bytes.count)

        var firstChunk = Location_Nearby_Connections_PayloadTransferFrame.PayloadChunk()
        firstChunk.offset = 0
        firstChunk.flags = 0
        firstChunk.body = bytes
        try sendPayload(header: header, chunk: firstChunk)

        var finalChunk = Location_Nearby_Connections_PayloadTransferFrame.PayloadChunk()
        finalChunk.offset = Int64(bytes.count)
        finalChunk.flags = 1
        try sendPayload(header: header, chunk: finalChunk)
    }

    private func sendPayload(
        header: Location_Nearby_Connections_PayloadTransferFrame.PayloadHeader,
        chunk: Location_Nearby_Connections_PayloadTransferFrame.PayloadChunk
    ) throws {
        var transfer = Location_Nearby_Connections_PayloadTransferFrame()
        transfer.packetType = .data
        transfer.payloadHeader = header
        transfer.payloadChunk = chunk
        var frame = Location_Nearby_Connections_OfflineFrame()
        frame.version = .v1
        frame.v1.type = .payloadTransfer
        frame.v1.payloadTransfer = transfer
        try sendEncrypted(frame)
    }

    private func sendKeepAlive(ack: Bool) throws {
        var keepAlive = Location_Nearby_Connections_KeepAliveFrame()
        keepAlive.ack = ack
        var frame = Location_Nearby_Connections_OfflineFrame()
        frame.version = .v1
        frame.v1.type = .keepAlive
        frame.v1.keepAlive = keepAlive
        try sendEncrypted(frame)
    }

    private func sendEncrypted(_ frame: Location_Nearby_Connections_OfflineFrame) throws {
        guard let codec else { throw QuickShareError.malformed("D2D codec is not ready") }
        try sendPlain(codec.seal(frame))
    }

    private func sendPlain(_ payload: Data) throws {
        connection.send(content: try QuickShareFraming.encode(payload), completion: .contentProcessed { [weak self] error in
            if let error { self?.close(error: error) }
        })
    }

    private func startKeepAlive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self, self.stage != .closed else { return }
            do { try self.sendKeepAlive(ack: false) }
            catch { self.close(error: error) }
        }
        timer.resume()
        keepAlive = timer
    }

    private func randomPayloadID() -> Int64 {
        let bytes = (try? randomBytes(count: 8)) ?? Data(repeating: 0, count: 8)
        let unsigned = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int64(bitPattern: unsigned)
    }

    private func sendDisconnectionAndClose() {
        var frame = Location_Nearby_Connections_OfflineFrame()
        frame.version = .v1
        frame.v1.type = .disconnection
        try? sendEncrypted(frame)
        closeAfterFlush()
    }

    private func sendSafeDisconnectionAcknowledgement() throws {
        var frame = Location_Nearby_Connections_OfflineFrame()
        frame.version = .v1
        frame.v1.type = .disconnection
        frame.v1.disconnection.ackSafeToDisconnect = true
        try sendEncrypted(frame)
    }

    private func sendSafeDisconnectionRequest() throws {
        var frame = Location_Nearby_Connections_OfflineFrame()
        frame.version = .v1
        frame.v1.type = .disconnection
        frame.v1.disconnection.requestSafeToDisconnect = true
        try sendEncrypted(frame)
    }

    private func closeAfterFlush() {
        connection.send(content: nil, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.close(error: nil) })
    }

    private func close(error: Error?) {
        guard !finished else { return }
        if let error {
            Self.logger.error("Quick Share failed during \(self.phaseName, privacy: .public): \(String(describing: error), privacy: .public)")
        } else {
            Self.logger.debug("Quick Share connection closed during \(self.phaseName, privacy: .public)")
        }
        finished = true
        stage = .closed
        keepAlive?.cancel()
        keepAlive = nil
        stagedPayloads.values.forEach { $0.sink?.close() }
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        connection.cancel()
        if let error { delegate?.quickShareReceiverDidFail(error, from: senderName) }
        onFinish(self)
    }

    private var phaseName: String {
        switch stage {
        case .awaitRequest: return "connection request"
        case .awaitClientInit: return "UKEY2 client init"
        case .awaitClientFinish: return "UKEY2 client finish"
        case .awaitClientResponse: return "connection acknowledgement"
        case .awaitPairedKeyEncryption: return "paired-key encryption"
        case .awaitPairedKeyResult: return "paired-key result"
        case .awaitIntroduction: return "file offer"
        case .awaitingDecision: return "local consent"
        case .receiving: return "file upload"
        case .awaitingSafeDisconnection: return "delivery confirmation"
        case .closed: return "closed connection"
        }
    }

    static func == (lhs: QuickShareReceiverConnection, rhs: QuickShareReceiverConnection) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
