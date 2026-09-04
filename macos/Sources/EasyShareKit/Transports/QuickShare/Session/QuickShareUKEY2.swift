import CryptoKit
import Foundation
import SwiftProtobuf

/// Implements the P-256/SHA-512 UKEY2 branch Quick Share uses for its LAN
/// medium. The state machines deliberately take and return serialized protobuf
/// messages, which preserves the exact bytes UKEY2 binds into its HKDF context.
public struct QuickShareUKEY2Initiator {
    private let privateKey = P256.KeyAgreement.PrivateKey()
    private var clientInit: Data?
    private var clientFinish: Data?

    public init() {}

    public mutating func makeClientInit() throws -> Data {
        guard clientInit == nil else { throw QuickShareError.malformed("client init sent twice") }

        let finish = try wrap(
            type: .clientFinish,
            message: try makeClientFinished(publicKey: privateKey.publicKey)
        )
        let commitment = Data(SHA512.hash(data: finish))

        var commitmentFrame = Securegcm_Ukey2ClientInit.CipherCommitment()
        commitmentFrame.handshakeCipher = .p256Sha512
        commitmentFrame.commitment = commitment

        var initFrame = Securegcm_Ukey2ClientInit()
        initFrame.version = 1
        initFrame.random = try randomBytes(count: 32)
        initFrame.cipherCommitments = [commitmentFrame]
        initFrame.nextProtocol = "AES_256_CBC-HMAC_SHA256"

        let serialized = try wrap(type: .clientInit, message: initFrame)
        clientInit = serialized
        clientFinish = finish
        return serialized
    }

    public mutating func receiveServerInit(_ serialized: Data) throws -> QuickShareUKEY2InitiatorResult {
        guard let clientInit, let clientFinish else {
            throw QuickShareError.malformed("server init arrived before client init")
        }

        let envelope = try Securegcm_Ukey2Message(serializedBytes: serialized)
        guard envelope.messageType == .serverInit, envelope.hasMessageData else {
            throw QuickShareError.malformed("expected UKEY2 server init")
        }
        let serverInit = try Securegcm_Ukey2ServerInit(serializedBytes: envelope.messageData)
        guard serverInit.version == 1, serverInit.random.count == 32,
              serverInit.handshakeCipher == .p256Sha512, serverInit.hasPublicKey
        else {
            throw QuickShareError.unsupported("unsupported UKEY2 server init")
        }

        let remote = try publicKey(from: serverInit.publicKey)
        let result = try deriveResult(
            local: privateKey, remote: remote, clientInit: clientInit, serverInit: serialized, role: .initiator
        )
        return QuickShareUKEY2InitiatorResult(clientFinish: clientFinish, result: result)
    }
}

public struct QuickShareUKEY2InitiatorResult {
    public let clientFinish: Data
    public let result: QuickShareUKEY2Result
}

public struct QuickShareUKEY2Responder {
    private var privateKey: P256.KeyAgreement.PrivateKey?
    private var clientInit: Data?
    private var serverInit: Data?
    private var expectedCommitment: Data?

    public init() {}

    public mutating func receiveClientInit(_ serialized: Data) throws -> Data {
        guard clientInit == nil else { throw QuickShareError.malformed("client init received twice") }

        let envelope = try Securegcm_Ukey2Message(serializedBytes: serialized)
        guard envelope.messageType == .clientInit, envelope.hasMessageData else {
            throw QuickShareError.malformed("expected UKEY2 client init")
        }
        let initFrame = try Securegcm_Ukey2ClientInit(serializedBytes: envelope.messageData)
        guard initFrame.version == 1, initFrame.random.count == 32,
              initFrame.nextProtocol == "AES_256_CBC-HMAC_SHA256",
              let commitment = initFrame.cipherCommitments.first(where: {
                  $0.handshakeCipher == .p256Sha512 && $0.commitment.count == SHA512.Digest.byteCount
              })?.commitment
        else {
            throw QuickShareError.unsupported("unsupported UKEY2 client init")
        }

        let privateKey = P256.KeyAgreement.PrivateKey()
        var response = Securegcm_Ukey2ServerInit()
        response.version = 1
        response.random = try randomBytes(count: 32)
        response.handshakeCipher = .p256Sha512
        response.publicKey = try genericPublicKey(for: privateKey.publicKey).serializedData()

        let serializedResponse = try wrap(type: .serverInit, message: response)
        self.privateKey = privateKey
        self.clientInit = serialized
        self.serverInit = serializedResponse
        self.expectedCommitment = commitment
        return serializedResponse
    }

    public mutating func receiveClientFinish(_ serialized: Data) throws -> QuickShareUKEY2Result {
        guard let privateKey, let clientInit, let serverInit, let expectedCommitment else {
            throw QuickShareError.malformed("client finish arrived before server init")
        }
        let envelope = try Securegcm_Ukey2Message(serializedBytes: serialized)
        // UKEY2 requires checking the message type before checking the
        // ClientFinished commitment. A peer that rejects our ServerInit sends
        // an Alert here; hashing that alert first disguises its useful error
        // code as a commitment mismatch and makes an interoperability failure
        // impossible to diagnose. An alert still always terminates the
        // handshake -- it is never accepted as a ClientFinished message.
        if envelope.messageType == .alert {
            guard envelope.hasMessageData else {
                throw QuickShareError.unsupported("Android rejected UKEY2 server init with an empty alert")
            }
            let alert = try Securegcm_Ukey2Alert(serializedBytes: envelope.messageData)
            throw QuickShareError.unsupported(
                "Android rejected UKEY2 server init with alert code \(alert.type.rawValue)"
            )
        }
        guard envelope.messageType == .clientFinish, envelope.hasMessageData else {
            // The numeric type is safe metadata, unlike a peer-provided alert
            // string or public key. It distinguishes a valid Android alert
            // from a connection-response or retry frame sent by another
            // Nearby handshake branch.
            throw QuickShareError.malformed(
                "expected UKEY2 client finish, received message type \(envelope.messageType.rawValue)"
            )
        }
        guard Data(SHA512.hash(data: serialized)) == expectedCommitment else {
            throw QuickShareError.cryptography("UKEY2 client-finish commitment did not verify")
        }
        let finish = try Securegcm_Ukey2ClientFinished(serializedBytes: envelope.messageData)
        guard finish.hasPublicKey else { throw QuickShareError.malformed("UKEY2 client key missing") }

        return try deriveResult(
            local: privateKey, remote: publicKey(from: finish.publicKey),
            clientInit: clientInit, serverInit: serverInit, role: .responder
        )
    }
}

public struct QuickShareUKEY2Result {
    public let d2dKeys: QuickShareD2DKeys
    public let authenticationKey: Data
    public let pin: String
}

private func makeClientFinished(publicKey: P256.KeyAgreement.PublicKey) throws -> Securegcm_Ukey2ClientFinished {
    var finish = Securegcm_Ukey2ClientFinished()
    finish.publicKey = try genericPublicKey(for: publicKey).serializedData()
    return finish
}

private func wrap<Message: SwiftProtobuf.Message>(
    type: Securegcm_Ukey2Message.TypeEnum, message: Message
) throws -> Data {
    var envelope = Securegcm_Ukey2Message()
    envelope.messageType = type
    envelope.messageData = try message.serializedData()
    return try envelope.serializedData()
}

private func genericPublicKey(for publicKey: P256.KeyAgreement.PublicKey) throws -> Securemessage_GenericPublicKey {
    let x963 = publicKey.x963Representation
    guard x963.count == 65, x963.first == 0x04 else {
        throw QuickShareError.cryptography("unexpected P-256 public-key representation")
    }
    var point = Securemessage_EcP256PublicKey()
    point.x = Data(x963[1..<33])
    point.y = Data(x963[33..<65])

    var generic = Securemessage_GenericPublicKey()
    generic.type = .ecP256
    generic.ecP256PublicKey = point
    return generic
}

private func publicKey(from serialized: Data) throws -> P256.KeyAgreement.PublicKey {
    let generic = try Securemessage_GenericPublicKey(serializedBytes: serialized)
    guard generic.type == .ecP256, generic.hasEcP256PublicKey else {
        throw QuickShareError.unsupported("UKEY2 peer did not supply a P-256 key")
    }

    let x = try normalizedCoordinate(generic.ecP256PublicKey.x)
    let y = try normalizedCoordinate(generic.ecP256PublicKey.y)
    return try P256.KeyAgreement.PublicKey(x963Representation: Data([0x04]) + x + y)
}

private func normalizedCoordinate(_ value: Data) throws -> Data {
    var result = value
    while result.count > 32, result.first == 0 { result.removeFirst() }
    guard result.count <= 32 else { throw QuickShareError.malformed("oversized P-256 coordinate") }
    return Data(repeating: 0, count: 32 - result.count) + result
}

private func deriveResult(
    local: P256.KeyAgreement.PrivateKey,
    remote: P256.KeyAgreement.PublicKey,
    clientInit: Data,
    serverInit: Data,
    role: QuickShareRole
) throws -> QuickShareUKEY2Result {
    let shared = try local.sharedSecretFromKeyAgreement(with: remote)
    let rawShared = shared.withUnsafeBytes { Data($0) }
    let secret = Data(SHA256.hash(data: rawShared))
    let context = clientInit + serverInit
    let auth = hkdf(secret, salt: Data("UKEY2 v1 auth".utf8), info: context, length: 32)
    let next = hkdf(secret, salt: Data("UKEY2 v1 next".utf8), info: context, length: 32)
    return QuickShareUKEY2Result(
        d2dKeys: QuickShareD2DKeys.deriving(from: next, role: role),
        authenticationKey: auth,
        pin: quickSharePIN(authenticationKey: auth)
    )
}

private func quickSharePIN(authenticationKey: Data) -> String {
    var hash = 0
    var multiplier = 1
    for byte in authenticationKey {
        hash = (hash + Int(Int8(bitPattern: byte)) * multiplier) % 9_973
        multiplier = (multiplier * 31) % 9_973
    }
    return String(format: "%04d", abs(hash))
}
