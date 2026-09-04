import Foundation
import SwiftProtobuf

/// The Nearby Connections TCP transport is a sequence of protobuf messages,
/// each preceded by an unsigned, four-byte, big-endian length. This framing is
/// deliberately separate from `NWConnection`: it is also used by transcript
/// tests and makes an oversized peer frame fail before it reaches protobuf.
public enum QuickShareFraming {

    /// Control frames and file chunks are bounded independently. A peer cannot
    /// make the receiver allocate an arbitrary amount merely by advertising a
    /// length in four bytes.
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

    /// Decodes exactly one complete frame. Connection code may buffer partial
    /// reads and call this once all four length bytes and the advertised body
    /// are available.
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
    /// The peer closed a real Quick Share session. The stage is deliberately
    /// user-readable so a device-side generic error can be tied to the
    /// protocol exchange that immediately preceded it.
    case connectionClosedDuring(String)
    /// The receiver did not confirm it had drained the final payload before
    /// the safe-disconnect deadline. A local socket write is not delivery.
    case deliveryConfirmationTimedOut
    /// A Quick Share endpoint was discovered but did not accept the TCP
    /// connection promptly. Keeping this distinct from a closed connection
    /// lets the UI suggest a QR retry instead of leaving a spinner forever.
    case connectionTimedOut
    /// Scanning a Quick Share QR code must open its `quickshare.google` link
    /// before Android publishes its temporary LAN endpoint. This is an
    /// activation timeout, not a transfer timeout.
    case qrCodeActivationTimedOut
}
