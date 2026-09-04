import CryptoKit
import Foundation

/// A short-lived QR handoff for Android's stock Quick Share receiver.
///
/// Android normally waits for a BLE fast-init advertisement before it starts
/// publishing its Wi-Fi-LAN endpoint. macOS cannot send that advertisement with
/// public APIs, but Android's Quick Share QR URL is an equivalent, supported
/// activation route. The token only associates the ensuing mDNS announcement
/// with this one share attempt; it does not authenticate the peer.
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

        // The QR format is a two-byte format version followed by a compressed
        // P-256 public point. The sign bit is carried in 0x02/0x03 and Android
        // rejects a padded coordinate, so retain exactly the 32-byte X value.
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

    /// Returns the phone peer only when the mDNS record was activated by this
    /// exact QR session. Hidden receivers encrypt their name with the session
    /// key; public receivers carry the token unchanged.
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

    /// The QR activation also lets Android verify that the sender which
    /// connected is the QR owner. Quick Share expects IEEE P1363 (R || S),
    /// which is CryptoKit's `rawRepresentation`.
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
