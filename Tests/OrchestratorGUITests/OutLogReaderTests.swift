import Foundation
import Testing
@testable import OrchestratorGUI

struct OutLogReaderTests {
    private func tempPath() -> String {
        NSTemporaryDirectory() + "outlog-" + UUID().uuidString + ".jsonl"
    }

    private func append(_ data: Data, to path: String) throws {
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func append(_ text: String, to path: String) throws { try append(Data(text.utf8), to: path) }

    @Test func firstReadGivesAllLinesAndTheNextOnlyTheAppendedOnes() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try append("a\nb\n", to: path)
        let reader = OutLogReader(path: path)
        #expect(reader.read() == .init(lines: ["a", "b"]))
        #expect(reader.read() == .init())
        try append("c\n", to: path)
        #expect(reader.read() == .init(lines: ["c"]))
    }

    @Test func aPartialLastLineIsWithheldThenReleasedWhole() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try append("a\nhal", to: path)
        let reader = OutLogReader(path: path)
        #expect(reader.read().lines == ["a"])
        try append("f\n", to: path)
        #expect(reader.read().lines == ["half"])
    }

    @Test func aLineOf200KBComesBackIntact() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let line = String(repeating: "x", count: 200_000)
        try append(line + "\n", to: path)
        #expect(OutLogReader(path: path).read().lines == [line])
    }

    @Test func aFourByteCharacterSplitAcrossAppendsComesBackIntact() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let bytes = Array("a😀b\n".utf8)
        try append(Data(bytes[0..<3]), to: path)
        let reader = OutLogReader(path: path)
        #expect(reader.read().lines.isEmpty)
        try append(Data(bytes[3...]), to: path)
        #expect(reader.read().lines == ["a😀b"])
    }

    @Test func aTruncatedFileReportsAResetAndReadsFromZero() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try append("one\ntwo\nthree\n", to: path)
        let reader = OutLogReader(path: path)
        _ = reader.read()
        try Data("new\n".utf8).write(to: URL(fileURLWithPath: path))
        #expect(reader.read() == .init(lines: ["new"], reset: true))
    }

    @Test func aMissingFileReportsNothingAndReadsFromZeroOnceCreated() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let reader = OutLogReader(path: path)
        #expect(reader.read() == .init())
        try append("a\n", to: path)
        #expect(reader.read() == .init(lines: ["a"]))
    }
}
