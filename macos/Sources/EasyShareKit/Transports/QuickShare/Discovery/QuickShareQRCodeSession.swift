import CryptoKit
import Foundation

/// A short-lived QR activation session for Android Quick Share.
public final class QuickShareQRCodeSession {
    public let url: URL

    private let signingKey: P256.Signing.PrivateKey
    private let advertisingToken: Data
    private let nameEncryptionKey: SymmetricKey

    public init() throws {
        let signingKey = P256.Signing.PrivateKey()
        let publicKey = signingKey.publicKey.x963Representation
        guard publicKey.count == 65, publicKey.first == 0x04 else {
            throw QuickShareError.cryptography("could not encode the Quick Share QR key")
        }

        // QR encodes a compressed P-256 point with a 32-byte X coordinate.
        let prefix: UInt8 = (publicKey[64] & 1) == 0 ? 0x02 : 0x03
        let payload = Data([0x00, 0x00, prefix]) + Data(publicKey[1..<33])
        let encoded = QuickShareEndpointInfo.base64URL(payload)
        guard let url = URL(string: "https://quickshare.google/qrcode#key=\(encoded)") else {
            throw QuickShareError.malformed("could not create the Quick Share QR URL")
        }

        let input = SymmetricKey(data: payload)
        self.signingKey = signingKey
        self.advertisingToken = Self.derive(input, context: "advertisingContext")
        self.nameEncryptionKey = SymmetricKey(data: Self.derive(input, context: "encryptionKey"))
        self.url = url
    }

    /// Resolves only an advertisement activated by this QR session.
    public func resolvedPeer(from peer: QuickSharePeer) -> QuickSharePeer? {
        guard let data = peer.qrCodeData else { return nil }
        if data == advertisingToken { return peer }
        guard data.count >= 28,
              let box = try? AES.GCM.SealedBox(combined: data),
              let plaintext = try? AES.GCM.open(
                box, using: nameEncryptionKey, authenticating: advertisingToken
              ),
              let name = String(data: plaintext, encoding: .utf8)
        else { return nil }
        return peer.renamed(name)
    }

    func handshakeSignature(for authenticationKey: Data) throws -> Data {
        try signingKey.signature(for: authenticationKey).rawRepresentation
    }

    private static func derive(_ input: SymmetricKey, context: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: input,
            salt: Data(),
            info: Data(context.utf8),
            outputByteCount: 16
        )
        return key.withUnsafeBytes { Data($0) }
    }
}
