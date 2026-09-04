import CommonCrypto
import CryptoKit
import Foundation
import Security
import SwiftProtobuf

/// Keys for an ephemeral Nearby Connections session.
public struct QuickShareD2DKeys: Sendable {
    fileprivate let decryptKey: Data
    fileprivate let receiveHMACKey: SymmetricKey
    fileprivate let encryptKey: Data
    fileprivate let sendHMACKey: SymmetricKey

    static func deriving(from nextProtocolSecret: Data, role: QuickShareRole) -> QuickShareD2DKeys {
        // Fixed P-256/SHA-512 D2D salt.
        let d2dSalt = Data([
            0x82, 0xAA, 0x55, 0xA0, 0xD3, 0x97, 0xF8, 0x83,
            0x46, 0xCA, 0x1C, 0xEE, 0x8D, 0x39, 0x09, 0xB9,
            0x5F, 0x13, 0xFA, 0x7D, 0xEB, 0x1D, 0x4A, 0xB3,
            0x83, 0x76, 0xB8, 0x25, 0x6D, 0xA8, 0x55, 0x10,
        ])
        let secureMessageSalt = Data(SHA256.hash(data: Data("SecureMessage".utf8)))

        let client = hkdf(nextProtocolSecret, salt: d2dSalt, info: "client", length: 32)
        let server = hkdf(nextProtocolSecret, salt: d2dSalt, info: "server", length: 32)

        let clientEncryption = hkdf(client, salt: secureMessageSalt, info: "ENC:2", length: 32)
        let clientSignature = hkdf(client, salt: secureMessageSalt, info: "SIG:1", length: 32)
        let serverEncryption = hkdf(server, salt: secureMessageSalt, info: "ENC:2", length: 32)
        let serverSignature = hkdf(server, salt: secureMessageSalt, info: "SIG:1", length: 32)

        switch role {
        case .initiator:
            return QuickShareD2DKeys(
                decryptKey: serverEncryption,
                receiveHMACKey: SymmetricKey(data: serverSignature),
                encryptKey: clientEncryption,
                sendHMACKey: SymmetricKey(data: clientSignature)
            )
        case .responder:
            return QuickShareD2DKeys(
                decryptKey: clientEncryption,
                receiveHMACKey: SymmetricKey(data: clientSignature),
                encryptKey: serverEncryption,
                sendHMACKey: SymmetricKey(data: serverSignature)
            )
        }
    }
}

public enum QuickShareRole: Sendable {
    case initiator
    case responder
}

/// AES-CBC helpers for the D2D codec.
enum QuickShareAESCBC {
    static func encrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(operation: CCOperation(kCCEncrypt), input: plaintext, key: key, iv: iv)
    }

    static func decrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(operation: CCOperation(kCCDecrypt), input: ciphertext, key: key, iv: iv)
    }

    private static func crypt(operation: CCOperation, input: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else {
            throw QuickShareError.cryptography("invalid AES-256-CBC key or IV length")
        }

        var output = Data(count: input.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var written = 0
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outputBuffer in
            input.withUnsafeBytes { inputBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress,
                            key.count,
                            ivBuffer.baseAddress,
                            inputBuffer.baseAddress,
                            input.count,
                            outputBuffer.baseAddress,
                            outputCapacity,
                            &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw QuickShareError.cryptography("AES-CBC operation failed (\(status))")
        }
        return output.prefix(written)
    }
}

/// Authenticates, encrypts, and sequence-checks post-UKEY2 frames.
public final class QuickShareD2DCodec {
    private let keys: QuickShareD2DKeys
    private var sentSequence: Int32 = 0
    private var receivedSequence: Int32 = 0

    public init(keys: QuickShareD2DKeys) {
        self.keys = keys
    }

    public func seal(_ offlineFrame: Location_Nearby_Connections_OfflineFrame) throws -> Data {
        sentSequence = try checkedIncrement(sentSequence)

        var d2d = Securegcm_DeviceToDeviceMessage()
        d2d.sequenceNumber = sentSequence
        d2d.message = try offlineFrame.serializedData()

        let iv = try randomBytes(count: kCCBlockSizeAES128)
        let encrypted = try QuickShareAESCBC.encrypt(
            try d2d.serializedData(), key: keys.encryptKey, iv: iv
        )

        var metadata = Securegcm_GcmMetadata()
        metadata.version = 1
        metadata.type = .deviceToDeviceMessage

        var header = Securemessage_Header()
        header.signatureScheme = .hmacSha256
        header.encryptionScheme = .aes256Cbc
        header.iv = iv
        header.publicMetadata = try metadata.serializedData()

        var headerAndBody = Securemessage_HeaderAndBody()
        headerAndBody.header = header
        headerAndBody.body = encrypted
        let signedBytes = try headerAndBody.serializedData()

        var secure = Securemessage_SecureMessage()
        secure.headerAndBody = signedBytes
        secure.signature = Data(HMAC<SHA256>.authenticationCode(for: signedBytes, using: keys.sendHMACKey))
        return try secure.serializedData()
    }

    public func open(_ serializedSecureMessage: Data) throws -> Location_Nearby_Connections_OfflineFrame {
        let secure = try Securemessage_SecureMessage(serializedBytes: serializedSecureMessage)
        guard secure.hasHeaderAndBody, secure.hasSignature else {
            throw QuickShareError.malformed("SecureMessage is missing required fields")
        }
        guard HMAC<SHA256>.isValidAuthenticationCode(
            secure.signature, authenticating: secure.headerAndBody, using: keys.receiveHMACKey
        ) else {
            throw QuickShareError.cryptography("SecureMessage HMAC did not verify")
        }

        let headerAndBody = try Securemessage_HeaderAndBody(serializedBytes: secure.headerAndBody)
        guard headerAndBody.hasHeader, headerAndBody.hasBody,
              headerAndBody.header.signatureScheme == .hmacSha256,
              headerAndBody.header.encryptionScheme == .aes256Cbc,
              headerAndBody.header.iv.count == kCCBlockSizeAES128
        else {
            throw QuickShareError.malformed("unsupported SecureMessage header")
        }

        let metadata = try Securegcm_GcmMetadata(serializedBytes: headerAndBody.header.publicMetadata)
        guard metadata.version == 1, metadata.type == .deviceToDeviceMessage else {
            throw QuickShareError.malformed("unexpected D2D public metadata")
        }

        let plaintext = try QuickShareAESCBC.decrypt(
            headerAndBody.body, key: keys.decryptKey, iv: headerAndBody.header.iv
        )
        let d2d = try Securegcm_DeviceToDeviceMessage(serializedBytes: plaintext)
        guard d2d.hasSequenceNumber, d2d.hasMessage else {
            throw QuickShareError.malformed("D2D message is missing sequence number or payload")
        }

        let expected = try checkedIncrement(receivedSequence)
        guard d2d.sequenceNumber == expected else {
            throw QuickShareError.malformed("unexpected D2D sequence \(d2d.sequenceNumber), expected \(expected)")
        }
        receivedSequence = expected
        return try Location_Nearby_Connections_OfflineFrame(serializedBytes: d2d.message)
    }

    private func checkedIncrement(_ value: Int32) throws -> Int32 {
        guard value < Int32.max else { throw QuickShareError.cryptography("D2D sequence exhausted") }
        return value + 1
    }
}

func hkdf(_ input: Data, salt: Data, info: String, length: Int) -> Data {
    hkdf(input, salt: salt, info: Data(info.utf8), length: length)
}

func hkdf(_ input: Data, salt: Data, info: Data, length: Int) -> Data {
    let key = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: input), salt: salt,
        info: info, outputByteCount: length
    )
    return key.withUnsafeBytes { Data($0) }
}

func randomBytes(count: Int) throws -> Data {
    var bytes = Data(count: count)
    let status = bytes.withUnsafeMutableBytes { buffer in
        SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
    }
    guard status == errSecSuccess else {
        throw QuickShareError.cryptography("secure random generation failed (\(status))")
    }
    return bytes
}
