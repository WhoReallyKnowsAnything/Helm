import Foundation
import Testing
@testable import OrchestratorGUI

@Suite struct FileOpenPolicyTests {
    private func facts(_ ext: String, dir: Bool = false, pkg: Bool = false, exec: Bool = false) -> FileFacts {
        FileFacts(ext: ext, isDirectory: dir, isPackage: pkg, isExecutable: exec)
    }

    private func isRefused(_ d: FileOpenDecision) -> Bool {
        if case .refused(let reason) = d { return !reason.isEmpty }
        return false
    }

    @Test func scriptsOpenInEditorEvenWithExecutableBit() {
        #expect(FileOpenPolicy.decide(facts("sh", exec: true)) == .editor)
        #expect(FileOpenPolicy.decide(facts("command", exec: true)) == .editor)
    }

    @Test func defaultAppTypes() {
        #expect(FileOpenPolicy.decide(facts("PNG")) == .defaultApp)
        #expect(FileOpenPolicy.decide(facts("pdf")) == .defaultApp)
        #expect(FileOpenPolicy.decide(facts("docx")) == .defaultApp)
    }

    @Test func executableDefaultAppTypesAreRefused() {
        #expect(isRefused(FileOpenPolicy.decide(facts("png", exec: true))))
        #expect(isRefused(FileOpenPolicy.decide(facts("pdf", exec: true))))
    }

    @Test func foldersPackagesAndRefusedTypes() {
        #expect(isRefused(FileOpenPolicy.decide(facts("", dir: true))))
        #expect(isRefused(FileOpenPolicy.decide(facts("app", dir: true, pkg: true))))
        #expect(isRefused(FileOpenPolicy.decide(facts("app", pkg: true))))
        #expect(isRefused(FileOpenPolicy.decide(facts("webloc"))))
        #expect(isRefused(FileOpenPolicy.decide(facts("dmg"))))
    }

    @Test func unlistedTypesGiveNotOnListReason() {
        let expected = FileOpenDecision.refused("type not on open list")
        for ext in ["", "svg", "htm", "webarchive", "pl", "scpt", "fish"] {
            #expect(FileOpenPolicy.decide(facts(ext)) == expected, "\(ext)")
        }
    }

    @Test func unlistedExecutablesAreRefused() {
        #expect(isRefused(FileOpenPolicy.decide(facts("", exec: true))))
        #expect(isRefused(FileOpenPolicy.decide(facts("pl", exec: true))))
    }

    @Test func everyListedExtensionIsChecked() {
        for ext in FileOpenPolicy.codeExtensions {
            #expect(FileOpenPolicy.decide(facts(ext)) == .editor, "\(ext)")
            #expect(FileOpenPolicy.decide(facts(ext.uppercased())) == .editor, "\(ext)")
        }
        for ext in FileOpenPolicy.defaultAppExtensions {
            #expect(FileOpenPolicy.decide(facts(ext)) == .defaultApp, "\(ext)")
        }
        for ext in FileOpenPolicy.refusedExtensions {
            #expect(isRefused(FileOpenPolicy.decide(facts(ext))), "\(ext)")
        }
    }
}
