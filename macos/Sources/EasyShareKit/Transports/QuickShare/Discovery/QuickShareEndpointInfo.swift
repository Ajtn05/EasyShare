import Foundation
import Network

/// Endpoint data carried in Quick Share discovery and connection requests.
struct QuickShareEndpointInfo {
    static let serviceType = "_FC9F5ED42C8A._tcp"
    private static let serviceID: [UInt8] = [0xFC, 0x9F, 0x5E]

    let endpointID: String
    let displayName: String
    let hasDisplayName: Bool
    let qrCodeData: Data?
    private let opaqueIdentityBytes: Data

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
        guard data.count >= 17 else { return nil }
        let hidden = (data[0] & 0x10) != 0
        let advertisingIdentity = Data(data[1..<17])
        var offset = 17
        let displayName: String
        let hasDisplayName: Bool
        if hidden || offset == data.count {
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
