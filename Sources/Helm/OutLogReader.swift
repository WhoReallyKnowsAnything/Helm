import Foundation

/// Reads the complete new lines of one growing file (D-06). Blocking file IO: call it off the main actor.
/// It keeps a byte offset and any unfinished last line, and does no parsing.
final class OutLogReader {
    struct Result: Equatable {
        var lines: [String] = []
        /// The file vanished or got shorter than what was read. The caller drops state folded from the old content.
        var reset = false
    }

    private let path: String
    /// Bytes of the file consumed so far, including `partial`.
    private var offset: UInt64 = 0
    /// Bytes after the last newline. Held as bytes so a multi-byte character cut by a read stays whole.
    private var partial = Data()

    init(path: String) { self.path = path }

    func read() -> Result {
        var result = Result()
        guard let handle = FileHandle(forReadingAtPath: path) else {
            result.reset = rewind()
            return result
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { result.reset = rewind() }
        guard size > offset, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(size - offset)), !data.isEmpty else { return result }
        offset += UInt64(data.count)
        var buffer = partial
        buffer.append(data)
        result.lines = buffer.withUnsafeBytes { raw -> [String] in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress else { return [] }
            var lines: [String] = []
            var start = 0
            while start < bytes.count, let hit = memchr(base + start, 0x0A, bytes.count - start) {
                let end = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                if end > start { lines.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)) }
                start = end + 1
            }
            partial = Data(bytes[start...])
            return lines
        }
        return result
    }

    /// Back to byte 0. True when there was something to forget.
    private func rewind() -> Bool {
        let hadState = offset > 0
        offset = 0
        partial = Data()
        return hadState
    }
}

extension String {
    /// True when the UTF-8 bytes hold any of `needles`. A byte search, far cheaper than Foundation's `contains` on long lines.
    func utf8Contains(anyOf needles: [StaticString]) -> Bool {
        var copy = self
        return copy.withUTF8 { buffer in
            guard let base = buffer.baseAddress else { return false }
            return needles.contains { needle in
                memmem(base, buffer.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
            }
        }
    }
}
