import Foundation

// Text typed into a terminal when files are dropped on it, in iTerm's backslash style.
// A dropped file name is untrusted input that reaches a shell or a Claude prompt, so every
// character outside the safe set gets a backslash, and a path that cannot be made inert is dropped.
enum DroppedFiles {
    private static let safePunctuation = Set("._/+-@%,:=".unicodeScalars)

    /// Escaped absolute paths of the file URLs, joined by single spaces, with no newline (a drop never submits).
    static func pasteText(for urls: [URL]) -> String {
        urls.compactMap { url in
            guard url.isFileURL else { return nil }
            return escapedPath(url.path)
        }.joined(separator: " ")
    }

    /// `text` wrapped in bracketed-paste markers when `bracketed` is true, otherwise unchanged.
    static func wrapped(_ text: String, bracketed: Bool) -> String {
        bracketed ? "\u{1b}[200~\(text)\u{1b}[201~" : text
    }

    /// True when the path is absolute (a leading `-` would read as an option) and holds no control character
    /// other than tab. A backslash cannot make a newline, CR or ESC inert, and ESC could close the bracketed paste early.
    static func isSafePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\t" }
    }

    /// Nil when `isSafePath` fails (this also covers an empty path).
    private static func escapedPath(_ path: String) -> String? {
        guard isSafePath(path) else { return nil }
        var out = String.UnicodeScalarView()
        for scalar in path.unicodeScalars {
            let safe = scalar.isASCII
                ? (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || safePunctuation.contains(scalar))
                : true
            if !safe { out.append("\\") }
            out.append(scalar)
        }
        return String(out)
    }
}
