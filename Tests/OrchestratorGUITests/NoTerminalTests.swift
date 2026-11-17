import Foundation
import Testing

/// D-17: the app never types into or reads a tmux pane, and SwiftTerm stays out of the repo.
/// The tokens are built from parts so this file does not match its own scan.
struct NoTerminalTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    private static let paneTokens = ["send-" + "keys", "paste-" + "buffer", "load-" + "buffer", "capture-" + "pane"]
    private static let importToken = "import " + "Swift" + "Term"

    /// Each `.swift` file under `folder` (or the one file) holding a token, as `file: token`.
    private func hits(in folder: String, tokens: [String]) -> [String] {
        let paths: [String]
        if folder.hasSuffix(".swift") {
            paths = [folder]
        } else {
            guard let walker = FileManager.default.enumerator(atPath: folder) else { return ["\(folder): cannot be read"] }
            paths = walker.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.map { folder + "/" + $0 }
        }
        return paths.flatMap { path -> [String] in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return ["\(path): cannot be read"] }
            return tokens.filter(text.contains).map { "\(path): \($0)" }
        }
    }

    @Test func noSourceFileNamesATmuxPaneCommand() {
        #expect(hits(in: Self.root + "/Sources", tokens: Self.paneTokens) == [])
    }

    @Test func nothingImportsSwiftTerm() {
        let found = ["/Sources", "/Tests", "/Package.swift"].flatMap { hits(in: Self.root + $0, tokens: [Self.importToken]) }
        #expect(found == [])
    }
}
