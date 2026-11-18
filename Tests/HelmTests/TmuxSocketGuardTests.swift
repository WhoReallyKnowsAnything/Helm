import Foundation
import Testing

/// D-06: no test touches the user's real tmux server. A test file that creates a tmux session must name
/// the private socket (`-L` or `-S`) it talks to. A new bare call fails this test.
struct TmuxSocketGuardTests {
    @Test func everyTestThatRunsTmuxNamesAPrivateSocket() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let me = URL(fileURLWithPath: #filePath).lastPathComponent
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") && $0 != me }
        var bare: [String] = []
        for file in files {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            guard text.contains("new-session") else { continue }
            let hasSocket = text.contains("\"-L\"") || text.contains("\"-S\"") || text.contains(" -L ")
                || text.contains(" -S ")
            if !hasSocket { bare.append(file) }
        }
        #expect(bare.isEmpty, "tmux without a private socket in: \(bare.sorted())")
    }
}
