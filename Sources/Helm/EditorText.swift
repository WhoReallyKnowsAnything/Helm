import Foundation

/// What the editor can show for one file: its text, or the reason it cannot.
enum EditorTextResult: Equatable {
    case text(String)
    case unsupported(String)
}

/// D-04, D-05: loads a file for the editor. Above `maxBytes` the screen shows the reason and the VS Code button, since
/// the whole text is coloured on each edit.
enum EditorText {
    static let maxBytes = 524_288

    static func load(_ url: URL, read: (URL) throws -> Data = { try Data(contentsOf: $0) }) -> EditorTextResult {
        let data: Data
        do { data = try read(url) } catch { return .unsupported("cannot be read") }
        if data.count > maxBytes {
            return .unsupported("larger than 512 KB (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))")
        }
        if data.contains(0) { return .unsupported("contains a NUL byte, so it is not text") }
        guard let text = String(data: data, encoding: .utf8) else { return .unsupported("not valid UTF-8 text") }
        return .text(text)
    }

    /// The UTF-16 range of the 1-based `line`, without its newline. Nil for line 0, a negative line or a line past the end.
    static func lineRange(_ line: Int, in text: String) -> NSRange? {
        guard line >= 1 else { return nil }
        let ns = text as NSString
        var current = 1
        var start = 0
        while current < line {
            let next = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            if next.location == NSNotFound { return nil }
            start = next.location + 1
            current += 1
        }
        // A trailing newline ends the last line; it does not open another.
        if start == ns.length && start > 0 && line > 1 { return nil }
        let end = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
        let stop = end.location == NSNotFound ? ns.length : end.location
        return NSRange(location: start, length: stop - start)
    }
}
