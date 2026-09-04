import CryptoKit
import Foundation
import EasyShareKit

private var passed = 0
private var failed = 0

private func section(_ title: String) {
    print("\n\(title)")
}

private func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
    if condition() {
        passed += 1
    } else {
        failed += 1
        print("FAIL: \(description)")
    }
}

section("Incoming filename safety")
for (input, expected) in [
    ("photo.jpg", "photo.jpg"),
    ("../../../.zshrc", "zshrc"),
    ("..\\..\\windows\\system32\\evil.dll", "evil.dll"),
    (".hidden", "hidden"),
    ("two\nlines.txt", "twolines.txt"),
    ("", IncomingFilename.fallback),
    ("..", IncomingFilename.fallback),
] {
    expect(IncomingFilename.sanitize(input) == expected, "sanitizes \(input.debugDescription)")
}
let longJPG = String(repeating: "a", count: 500) + ".jpg"
expect(IncomingFilename.sanitize(longJPG).count <= IncomingFilename.maxLength, "caps filename length")
expect(IncomingFilename.sanitize(longJPG).hasSuffix(".jpg"), "preserves ordinary extension when truncating")
let multiByteName = String(repeating: "😀", count: 100) + ".jpg"
let sanitizedMultiByteName = IncomingFilename.sanitize(multiByteName)
expect(sanitizedMultiByteName.utf8.count <= IncomingFilename.maxLength, "caps filename UTF-8 byte length")
expect(sanitizedMultiByteName.hasSuffix(".jpg"), "preserves extension for a multi-byte filename")

section("Quick Share framing and encryption")
do {
    let payload = Data([0x08, 0x01])
    let framed = try QuickShareFraming.encode(payload)
    expect(framed == Data([0, 0, 0, 2, 0x08, 0x01]), "uses a four-byte big-endian length")
    let decoded = try QuickShareFraming.decode(framed)
    expect(decoded == payload, "round-trips a framed payload")

    do {
        _ = try QuickShareFraming.decode(Data([0, 0, 0, 2, 0x08]))
        expect(false, "rejects a truncated frame")
    } catch QuickShareError.truncatedFrame {
        expect(true, "rejects a truncated frame")
    } catch {
        expect(false, "reports truncated framing correctly")
    }

    var initiator = QuickShareUKEY2Initiator()
    var responder = QuickShareUKEY2Responder()
    let clientInit = try initiator.makeClientInit()
    let serverInit = try responder.receiveClientInit(clientInit)
    let initiatorResult = try initiator.receiveServerInit(serverInit)
    let responderResult = try responder.receiveClientFinish(initiatorResult.clientFinish)
    expect(initiatorResult.result.pin == responderResult.pin, "derives the same verification PIN")
    expect(initiatorResult.result.authenticationKey == responderResult.authenticationKey, "derives the same authentication key")

    var keepAlive = Location_Nearby_Connections_OfflineFrame()
    keepAlive.version = .v1
    keepAlive.v1.type = .keepAlive
    keepAlive.v1.keepAlive.ack = false
    let sender = QuickShareD2DCodec(keys: initiatorResult.result.d2dKeys)
    let receiver = QuickShareD2DCodec(keys: responderResult.d2dKeys)
    let encrypted = try sender.seal(keepAlive)
    let decrypted = try receiver.open(encrypted)
    expect(decrypted.v1.type == .keepAlive && !decrypted.v1.keepAlive.ack, "encrypts and decrypts an offline frame")

    var tampered = encrypted
    tampered[tampered.startIndex] ^= 0x01
    do {
        _ = try receiver.open(tampered)
        expect(false, "rejects a tampered encrypted frame")
    } catch {
        expect(true, "rejects a tampered encrypted frame")
    }
} catch {
    expect(false, "Quick Share security handshake: \(error)")
}

section("Quick Share QR activation")
do {
    let session = try QuickShareQRCodeSession()
    guard let fragment = URLComponents(url: session.url, resolvingAgainstBaseURL: false)?.fragment else {
        throw QuickShareError.malformed("QR URL has no fragment")
    }
    expect(fragment.hasPrefix("key="), "uses the Quick Share key fragment")

    var encoded = String(fragment.dropFirst(4))
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    encoded.append(String(repeating: "=", count: (4 - encoded.count % 4) % 4))
    guard let payload = Data(base64Encoded: encoded) else {
        throw QuickShareError.malformed("QR key was not base64url")
    }
    expect(payload.count == 35, "encodes a versioned compressed P-256 point")

    let tokenKey = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: payload), salt: Data(),
        info: Data("advertisingContext".utf8), outputByteCount: 16
    )
    let matching = QuickSharePeer(
        id: "qr-test", displayName: "Android", host: "192.0.2.1", port: 4242,
        qrCodeData: tokenKey.withUnsafeBytes { Data($0) }
    )
    expect(session.resolvedPeer(from: matching) == matching, "accepts only the matching QR advertisement")
    expect(session.resolvedPeer(from: QuickSharePeer(
        id: "other", displayName: "Other", host: "192.0.2.2", port: 4242,
        qrCodeData: Data(repeating: 0, count: 16)
    )) == nil, "rejects another device's QR advertisement")
} catch {
    expect(false, "Quick Share QR activation: \(error)")
}

// MARK: - Loopback transport

private struct LoopbackSnapshot: Sendable {
    var acceptedOffer: QuickShareIncomingOffer?
    var received: [URL]
    var failure: String?
    var finished: Bool
}

private actor LoopbackState {
    private var port: UInt16?
    private var acceptedOffer: QuickShareIncomingOffer?
    private var received: [URL] = []
    private var failure: String?
    private var finished = false

    func markReady(port: UInt16) { self.port = port }
    func listenerPort() -> UInt16? { port }
    func accept(_ offer: QuickShareIncomingOffer) { acceptedOffer = offer }
    func receive(_ url: URL) { received.append(url) }
    func fail(_ error: Error) { failure = error.localizedDescription; finished = true }
    func finish() { finished = true }
    func snapshot() -> LoopbackSnapshot {
        LoopbackSnapshot(acceptedOffer: acceptedOffer, received: received, failure: failure, finished: finished)
    }
}

private final class LoopbackDelegate: QuickShareReceiverDelegate {
    private let state: LoopbackState
    init(state: LoopbackState) { self.state = state }
    func quickShareReceiverShouldAccept(_ offer: QuickShareIncomingOffer) async -> Bool {
        await state.accept(offer)
        return true
    }
    func quickShareReceiverDidReceiveFile(at url: URL, from senderName: String) {
        Task { await state.receive(url) }
    }
    func quickShareReceiverDidFinishTransfer(from senderName: String) {
        Task { await state.finish() }
    }
    func quickShareReceiverDidFail(_ error: Error, from senderName: String?) {
        Task { await state.fail(error) }
    }
}

private func waitUntil(_ condition: @escaping @Sendable () async -> Bool, timeout: Duration) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

section("Quick Share loopback transfer")
private let sandbox = FileManager.default.temporaryDirectory
    .appendingPathComponent("easyshare-quickshare-selftest-\(UUID().uuidString)", isDirectory: true)
private let downloads = sandbox.appendingPathComponent("downloads", isDirectory: true)
private let source = sandbox.appendingPathComponent("hello-from-mac.txt")
private let loopbackState = LoopbackState()
private let loopbackDelegate = LoopbackDelegate(state: loopbackState)

do {
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    let sourceBytes = Data("Quick Share loopback\n".utf8)
    try sourceBytes.write(to: source)
    let receiver = try QuickShareReceiver(
        displayName: "Loopback Mac", downloadsDirectory: downloads, delegate: loopbackDelegate
    )
    receiver.onStateChange = { state in
        if case .ready(let port) = state { Task { await loopbackState.markReady(port: port) } }
    }
    try receiver.start()
    defer {
        receiver.stop()
        try? FileManager.default.removeItem(at: sandbox)
    }

    guard await waitUntil({ await loopbackState.listenerPort() != nil }, timeout: .seconds(5)),
          let port = await loopbackState.listenerPort()
    else {
        throw QuickShareError.connectionClosed
    }
    expect(true, "listener becomes ready")

    let peer = QuickSharePeer(id: "loopback", displayName: "Loopback Android", host: "127.0.0.1", port: port)
    let sender = try QuickShareSender(peer: peer, displayName: "Loopback Mac")
    do {
        try await sender.send(files: [QuickShareOutgoingFile(
            url: source, name: "hello-from-mac.txt", size: Int64(sourceBytes.count), mimeType: "text/plain"
        )])
        expect(true, "initiator completes the send")
    } catch {
        expect(false, "initiator completes the send: \(error)")
    }

    let receiverFinished = await waitUntil({ await loopbackState.snapshot().finished }, timeout: .seconds(10))
    expect(receiverFinished, "receiver completes the transfer")
    let snapshot = await loopbackState.snapshot()
    expect(snapshot.failure == nil, "receiver reports no failure")
    expect(snapshot.acceptedOffer?.verificationPIN.count == 4, "exposes a four-digit verification PIN")
    expect(snapshot.received.first?.lastPathComponent == "hello-from-mac.txt", "preserves filename")
    expect(snapshot.received.first.flatMap { try? Data(contentsOf: $0) } == sourceBytes, "preserves file bytes")
} catch {
    expect(false, "loopback setup: \(error)")
    try? FileManager.default.removeItem(at: sandbox)
}

print("\n\(passed)/\(passed + failed) checks passed")
if failed > 0 { exit(1) }
