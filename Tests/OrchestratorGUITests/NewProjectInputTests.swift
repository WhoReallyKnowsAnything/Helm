import Testing
@testable import OrchestratorGUI

struct NewProjectInputTests {
    @Test(arguments: ["a", "A1", "my-app_2.0", String(repeating: "a", count: 64)])
    func validNames(name: String) {
        #expect(NewProjectInput.isValidName(name))
    }

    @Test(arguments: ["", " ", "-x", ".x", "_x", "a b", "a/b", "é", "ab\n", String(repeating: "a", count: 65)])
    func invalidNames(name: String) {
        #expect(!NewProjectInput.isValidName(name))
    }

    @Test func githubChoicesComeInOrderWithTheLauncherWords() {
        #expect(GithubChoice.allCases.map(\.rawValue) == ["private", "public", "skip"])
        #expect(GithubChoice.allCases.map(\.label) == ["Private", "Public", "Skip"])
    }
}
