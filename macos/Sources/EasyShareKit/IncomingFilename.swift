import Foundation

/// Reduces a peer-supplied filename to a safe path component.
public enum IncomingFilename {

    public static let fallback = "file"
    /// A byte limit leaves room for a collision suffix on APFS.
    public static let maxLength = 200

    public static func sanitize(_ raw: String) -> String {
        var name = raw
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            name = String(name[name.index(after: slash)...])
        }

        name = String(name.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && scalar != "/"
                && scalar != "\\"
                && scalar != "\0"
        })

        name = name.replacingOccurrences(of: ":", with: "-")

        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        while name.hasPrefix(".") {
            name.removeFirst()
        }

        name = name.trimmingCharacters(in: .whitespaces)

        if name.isEmpty { return fallback }

        return truncatePreservingExtension(name, to: maxLength)
    }

    static func truncatePreservingExtension(_ name: String, to limit: Int) -> String {
        guard name.utf8.count > limit else { return name }

        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, ext.utf8.count <= 10 else {
            return truncateUTF8(name, to: limit)
        }

        let base = (name as NSString).deletingPathExtension
        let room = limit - ext.utf8.count - 1
        guard room > 0 else { return truncateUTF8(name, to: limit) }
        return truncateUTF8(base, to: room) + "." + ext
    }

    private static func truncateUTF8(_ value: String, to limit: Int) -> String {
        var result = ""
        for character in value {
            let bytes = String(character).utf8.count
            guard result.utf8.count + bytes <= limit else { break }
            result.append(character)
        }
        return result
    }

    /// Returns a Finder-style available name; callers must still create atomically.
    public static func uniqueURL(
        for sanitizedName: String,
        in directory: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let candidate = directory.appendingPathComponent(sanitizedName)
        guard fileExists(candidate) else { return candidate }

        let ext = (sanitizedName as NSString).pathExtension
        let base = (sanitizedName as NSString).deletingPathExtension

        var n = 2
        while n < 10_000 {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            let url = directory.appendingPathComponent(name)
            if !fileExists(url) { return url }
            n += 1
        }
        let unique = ext.isEmpty ? "\(base) \(UUID().uuidString)" : "\(base) \(UUID().uuidString).\(ext)"
        return directory.appendingPathComponent(unique)
    }
}
