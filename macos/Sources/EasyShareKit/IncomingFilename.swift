import Foundation

/// Sanitizes a filename supplied by a remote peer.
///
/// This is security-critical and is the reason it lives in its own file with
/// real tests. The sender controls `name` entirely; a hostile peer will send
/// `../../../.zshrc`, `.bashrc`, or a 4000-character name to see what happens.
/// Everything written to disk goes through here first.
public enum IncomingFilename {

    public static let fallback = "file"
    /// Conservative — HFS+/APFS allow 255 *bytes*, and we leave room for a
    /// " (12)" collision suffix. This is deliberately a byte count, rather
    /// than a Swift `Character` count: a remote name can use multi-byte UTF-8
    /// characters too.
    public static let maxLength = 200

    /// Reduce an untrusted name to a single safe path component.
    public static func sanitize(_ raw: String) -> String {
        // Take the last component only. This alone defeats "../../x" and
        // "/etc/passwd", but we still scrub afterwards rather than relying on it.
        var name = raw
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            name = String(name[name.index(after: slash)...])
        }

        // Strip control characters, path separators, and the NUL that truncates
        // C-string APIs further down the stack.
        name = String(name.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && scalar != "/"
                && scalar != "\\"
                && scalar != "\0"
        })

        // ":" is a path separator to Carbon-era APIs and displays as "/" in Finder.
        name = name.replacingOccurrences(of: ":", with: "-")

        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // "." and ".." are traversal; a leading dot hides the file, which is a
        // nasty surprise in a Downloads folder.
        while name.hasPrefix(".") {
            name.removeFirst()
        }

        name = name.trimmingCharacters(in: .whitespaces)

        if name.isEmpty { return fallback }

        return truncatePreservingExtension(name, to: maxLength)
    }

    /// Truncate the base name, keeping the extension, so "verylong….jpg" stays
    /// a jpg and still opens in Preview.
    static func truncatePreservingExtension(_ name: String, to limit: Int) -> String {
        guard name.utf8.count > limit else { return name }

        let ext = (name as NSString).pathExtension
        // A 30-char "extension" is not an extension, it's part of the name.
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

    /// Pick a name that doesn't collide in `directory`, Finder-style:
    /// photo.jpg, photo (2).jpg, photo (3).jpg …
    ///
    /// - Note: inherently racy against other writers. The caller must still
    ///   create the file with `O_EXCL` semantics and retry on collision;
    ///   `FileManager.moveItem` throwing is the backstop.
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
        // Pathological directory. Fall back to something that cannot collide.
        let unique = ext.isEmpty ? "\(base) \(UUID().uuidString)" : "\(base) \(UUID().uuidString).\(ext)"
        return directory.appendingPathComponent(unique)
    }
}
