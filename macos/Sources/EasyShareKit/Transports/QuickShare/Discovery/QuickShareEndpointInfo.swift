import Foundation
import Network

/// The compact endpoint information carried in Quick Share's Bonjour TXT `n`
/// value and in a connection request. Unlike EasyShare discovery, it does not
/// contain a certificate or a stable peer identity; Everyone visibility is
/// intentionally anonymous.
struct QuickShareEndpointInfo {
    static let serviceType = "_FC9F5ED42C8A._tcp"
    private static let serviceID: [UInt8] = [0xFC, 0x9F, 0x5E]

    let endpointID: String
    let displayName: String
    /// `false` means the peer intentionally withheld its name. Such a peer is
    /// usable only through a QR session that identifies its advertised token.
    let hasDisplayName: Bool
    /// Present only after an Android device has scanned a Quick Share QR
    /// session. It is an untrusted discovery token, not a credential.
    let qrCodeData: Data?
    private let opaqueIdentityBytes: Data

    /// A public Everyone advertisement includes 16 opaque bytes after its
    /// visibility flags. They are not a credential or a durable Quick Share
    /// pairing identity, but retaining them lets a local UI preference bind a
    /// previously QR-confirmed phone to its current anonymous advertisement.
    var advertisingIdentity: Data { opaqueIdentityBytes }

    init(endpointID: String, displayName: String) throws {
        self.endpointID = endpointID
        self.displayName = PeerText.displayName(displayName, fallback: "Mac")
        self.hasDisplayName = true
        self.qrCodeData = nil
        self.opaqueIdentityBytes = try randomBytes(count: 16)
    }

    init?(connectionRequest: Location_Nearby_Connections_ConnectionRequestFrame) {
        guard connectionRequest.hasEndpointInfo,
              let parsed = Self.parse(connectionRequest.endpointInfo)
        else { return nil }
        self.endpointID = PeerText.identifier(connectionRequest.endpointID)
        self.displayName = parsed.displayName
        self.hasDisplayName = parsed.hasDisplayName
        self.qrCodeData = nil
        self.opaqueIdentityBytes = parsed.advertisingIdentity
    }

    init?(txtRecordValue: String) {
        guard let data = Self.dataFromBase64URL(txtRecordValue),
              let parsed = Self.parse(data)
        else { return nil }
        self.endpointID = ""
        self.displayName = parsed.displayName
        self.hasDisplayName = parsed.hasDisplayName
        self.qrCodeData = parsed.qrCodeData
        self.opaqueIdentityBytes = parsed.advertisingIdentity
    }

    func serialized() -> Data {
        // version=0, visibility=Everyone, type=laptop (3 << 1); the next 16
        // bytes are opaque on the unauthenticated Everyone path.
        var data = Data([0x06])
        data.append(opaqueIdentityBytes)
        let utf8 = Array(displayName.utf8.prefix(255))
        data.append(UInt8(utf8.count))
        data.append(contentsOf: utf8)
        return data
    }

    func advertisementName() -> String {
        let endpoint = Array(endpointID.utf8.prefix(4))
        let padded = endpoint + Array(repeating: UInt8(ascii: "0"), count: max(0, 4 - endpoint.count))
        let bytes = Data([0x23] + padded + Self.serviceID + [0, 0])
        return Self.base64URL(bytes)
    }

    func txtRecord() -> NWTXTRecord {
        NWTXTRecord(["n": Self.base64URL(serialized())])
    }

    private struct Parsed {
        let displayName: String
        let hasDisplayName: Bool
        let qrCodeData: Data?
        let advertisingIdentity: Data
    }

    private static func parse(_ data: Data) -> Parsed? {
        // One flags byte followed by 16 opaque identity bytes. Public devices
        // then have a name, while QR-triggered hidden receivers instead begin
        // their TLV list immediately at byte 17.
        guard data.count >= 17 else { return nil }
        let hidden = (data[0] & 0x10) != 0
        let advertisingIdentity = Data(data[1..<17])
        var offset = 17
        let displayName: String
        let hasDisplayName: Bool
        if hidden || offset == data.count {
            // Some current Android builds publish an anonymous 17-byte
            // endpoint-info value. It has neither a name nor a QR TLV, but is
            // still a valid service record and must not poison the browser's
            // state for the next QR-activated advertisement.
            displayName = "Quick Share device"
            hasDisplayName = false
        } else {
            let nameLength = Int(data[offset])
            let nameStart = offset + 1
            let nameEnd = nameStart + nameLength
            if data.count >= nameEnd,
               let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) {
                displayName = PeerText.displayName(name, fallback: "Quick Share device")
                hasDisplayName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                offset = nameEnd
            } else {
                // A few Android versions omit the visibility bit while still
                // omitting the clear-text name for a QR handoff. In that
                // layout byte 17 is the first TLV type (normally 1), not a
                // name length. Treat it as anonymous and let the TLV parser
                // below authenticate the QR advertising token.
                displayName = "Quick Share device"
                hasDisplayName = false
            }
        }

        var qrCodeData: Data?
        while offset < data.count {
            guard data.count >= offset + 2 else { return nil }
            let type = data[offset]
            let length = Int(data[offset + 1])
            offset += 2
            guard data.count >= offset + length else { return nil }
            if type == 1 { qrCodeData = Data(data[offset..<(offset + length)]) }
            offset += length
        }
        return Parsed(
            displayName: displayName,
            hasDisplayName: hasDisplayName,
            qrCodeData: qrCodeData,
            advertisingIdentity: advertisingIdentity
        )
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func dataFromBase64URL(_ value: String) -> Data? {
        var padded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        padded.append(String(repeating: "=", count: (4 - padded.count % 4) % 4))
        return Data(base64Encoded: padded)
    }

    static func newEndpointID() throws -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        let bytes = try randomBytes(count: 4)
        return String(bytes.map { Character(UnicodeScalar(alphabet[Int($0) % alphabet.count])) })
    }
}
