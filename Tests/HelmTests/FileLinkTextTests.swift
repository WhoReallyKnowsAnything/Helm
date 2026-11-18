import Foundation
import Testing
@testable import Helm

@Suite struct FileLinkTextTests {
    private func candidates(_ text: String) -> [String] {
        FileLinkText.split(text).compactMap { if case .candidate(let c) = $0 { return c } else { return nil } }
    }

    @Test func decisionEvidenceLine() {
        let line = "Evidence: `Sources/Helm/RequestStore.swift:172-177,273` and permission-hold.sh:101-109 (the hook) in the app."
        #expect(candidates(line) == ["Sources/Helm/RequestStore.swift:172-177,273", "permission-hold.sh:101-109"])
    }

    @Test func surroundingCharactersAreStripped() {
        #expect(candidates("\"a.md\"") == ["a.md"])
        #expect(candidates("'a.md'") == ["a.md"])
        #expect(candidates("(`a.md`),") == ["a.md"])
        #expect(candidates("see RequestStore.swift: the store") == ["RequestStore.swift"])
    }

    @Test func proseGivesNoCandidate() {
        #expect(candidates("Open the file now, then close it.").isEmpty)
    }

    @Test func piecesJoinBackToTheInput() {
        let text = "see  `a/b.md`, and x.\nnext"
        let joined = FileLinkText.split(text).map { p -> String in
            switch p { case .plain(let s), .candidate(let s): return s }
        }.joined()
        #expect(joined == text)
    }
}
