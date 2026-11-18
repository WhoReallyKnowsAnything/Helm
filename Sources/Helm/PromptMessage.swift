import Foundation

/// Builds the stream-json user message for a typed prompt plus dropped files. An image file becomes a base64
/// image block that Claude sees. Any other file goes into the text as its absolute path, for Claude to read.
/// A dropped name is untrusted, so a path must pass `DroppedFiles.isSafePath`. The text goes to a Claude
/// prompt, not a shell, so nothing is shell-escaped.
enum PromptMessage {
    /// The API takes an image up to 5 MB.
    static let maxImageBytes = 5_000_000

    private static let imageTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                                     "gif": "image/gif", "webp": "image/webp"]

    enum Failure: Error, Equatable, LocalizedError {
        case badPath(String)
        case tooBig(name: String, bytes: Int)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .badPath(let path): return "Not attached: \"\(InboxDelivery.clean(path, cap: 80) ?? "?")\" is not a usable absolute path."
            case .tooBig(let name, let bytes):
                return "Not attached: \(name) is \(String(format: "%.1f", Double(bytes) / 1_000_000)) MB. An image can be 5 MB at most."
            case .unreadable(let name): return "Not attached: \(name) could not be read."
            }
        }
    }

    static func isImage(_ url: URL) -> Bool { imageTypes[url.pathExtension.lowercased()] != nil }

    /// Throws when the file cannot be sent: an unsafe path, or an image that is missing, not a file, or over the cap.
    static func check(_ url: URL) throws {
        guard url.isFileURL, DroppedFiles.isSafePath(url.path) else { throw Failure.badPath(url.path) }
        if isImage(url) { _ = try imageSize(url) }
    }

    /// The inbox line (an object, not yet serialized). No files gives a plain string content, as before.
    static func build(text: String, files: [URL]) throws -> [String: Any] {
        for url in files { try check(url) }
        let images = files.filter(isImage)
        let paths = files.filter { !isImage($0) }.map(\.path)
        var body = text
        if !paths.isEmpty {
            let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            body = (typed.isEmpty ? "" : typed + "\n\n") + "Attached files:\n" + paths.joined(separator: "\n")
        }
        guard !images.isEmpty else { return wrap(body) }

        var blocks: [[String: Any]] = []
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(["type": "text", "text": body]) }
        for url in images {
            let name = url.lastPathComponent
            blocks.append(["type": "text", "text": "[image: \(name)]"])
            blocks.append(["type": "image", "source": ["type": "base64", "media_type": imageTypes[url.pathExtension.lowercased()]!,
                                                       "data": try read(url).base64EncodedString()]])
        }
        return wrap(blocks)
    }

    private static func imageSize(_ url: URL) throws -> Int {
        let name = url.lastPathComponent
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let bytes = values.fileSize else { throw Failure.unreadable(name) }
        guard bytes <= maxImageBytes else { throw Failure.tooBig(name: name, bytes: bytes) }
        return bytes
    }

    /// The size is checked before the bytes load, so a huge file never fills memory.
    private static func read(_ url: URL) throws -> Data {
        _ = try imageSize(url)
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(url.lastPathComponent) }
        return data
    }

    private static func wrap(_ content: Any) -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content": content]]
    }
}
