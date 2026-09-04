import Foundation
import SwiftProtobuf

/// Four-byte, big-endian framing for Nearby Connections messages.
public enum QuickShareFraming {

    /// Independent size caps for control frames and chunks.
    public static let maximumFrameLength = 5 * 1024 * 1024

    public static func encode<Message: SwiftProtobuf.Message>(_ message: Message) throws -> Data {
        try encode(message.serializedData())
    }

    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= maximumFrameLength else {
            throw QuickShareError.frameTooLarge(payload.count)
        }

        let length = UInt32(payload.count)
        var framed = Data()
        framed.reserveCapacity(payload.count + 4)
        framed.append(UInt8(truncatingIfNeeded: length >> 24))
        framed.append(UInt8(truncatingIfNeeded: length >> 16))
        framed.append(UInt8(truncatingIfNeeded: length >> 8))
        framed.append(UInt8(truncatingIfNeeded: length))
        framed.append(payload)
        return framed
    }

    public static func decode(_ framed: Data) throws -> Data {
        guard framed.count >= 4 else { throw QuickShareError.truncatedFrame }
        let prefix = framed.prefix(4)
        let length = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= maximumFrameLength else {
            throw QuickShareError.frameTooLarge(Int(length))
        }
        guard framed.count == Int(length) + 4 else { throw QuickShareError.truncatedFrame }
        return Data(framed.dropFirst(4))
    }
}

public enum QuickShareError: Error, Equatable, Sendable {
    case frameTooLarge(Int)
    case truncatedFrame
    case malformed(String)
    case unsupported(String)
    case cryptography(String)
    case peerRejected
    case insufficientSpace
    case cancelled
    case connectionClosed
    case connectionClosedDuring(String)
    case deliveryConfirmationTimedOut
    case connectionTimedOut
    case qrCodeActivationTimedOut
}
