import Foundation

/// Limits and normalization shared by the public Quick Share implementation.
/// They live beside the transport so it has no dependency on the removed TLS
/// receiver or its pairing model.
enum QuickShareLimits {
    static let maxFilesPerOffer = 512
    static let maximumTotalBytes: Int64 = 100 * 1024 * 1024 * 1024
}

/// Peer-supplied device names and endpoint ids are displayed back to the user.
/// Strip formatting controls and cap the UTF-8 length before they reach AppKit
/// or a Bonjour TXT record.
public enum PeerText {
    public static let maxDisplayNameBytes = 63

    public static func displayName(_ raw: String, fallback: String = "Unknown device") -> String {
        let cleaned = String(raw.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !(0x202A...0x202E).contains(scalar.value)
                && !(0x2066...0x2069).contains(scalar.value)
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        let result = truncateUTF8(cleaned, to: maxDisplayNameBytes)
        if !result.isEmpty { return result }
        let safeFallback = truncateUTF8(fallback, to: maxDisplayNameBytes)
        return safeFallback.isEmpty ? "Unknown device" : safeFallback
    }

    public static func identifier(_ raw: String, limit: Int = 128) -> String {
        let cleaned = raw.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !CharacterSet.whitespaces.contains(scalar)
        }
        return String(String(cleaned).prefix(limit))
    }

    private static func truncateUTF8(_ value: String, to maximumBytes: Int) -> String {
        var result = ""
        result.reserveCapacity(min(value.count, maximumBytes))
        for character in value {
            let bytes = String(character).utf8.count
            guard result.utf8.count + bytes <= maximumBytes else { break }
            result.append(character)
        }
        return result
    }
}

/// A staged incoming file with a strict advertised-size ceiling. This protects
/// the Downloads move from a sender that continues writing after its offer.
final class QuickShareUploadSink: @unchecked Sendable {
    private let handle: FileHandle
    private let limit: Int64
    private(set) var written: Int64 = 0

    init(url: URL, limit: Int64) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw QuickShareError.malformed("could not create staged Quick Share file")
        }
        self.handle = try FileHandle(forWritingTo: url)
        self.limit = limit
    }

    func write<D: DataProtocol>(_ data: D) throws {
        let count = Int64(data.count)
        guard written + count <= limit else {
            throw QuickShareError.malformed("Quick Share file exceeded its advertised size")
        }
        try handle.write(contentsOf: data)
        written += count
    }

    func close() {
        try? handle.close()
    }
}
