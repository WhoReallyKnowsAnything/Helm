import Foundation
import Testing
@testable import Helm

struct MilestoneLandTagsTests {
    private func runner(tags: String = "", remote: String = "origin\n", lsRemote: String = "") -> MilestoneLandTags.RunGit {
        { args in
            if args.contains("tag") { return ProcessResult(status: 0, stdout: tags, stderr: "") }
            if args.contains("ls-remote") { return ProcessResult(status: 0, stdout: lsRemote, stderr: "") }
            return ProcessResult(status: 0, stdout: remote, stderr: "")
        }
    }

    @Test func vFourAndFourZeroZeroMatchVersionFour() {
        #expect(MilestoneLandTags.local(version: "4", project: "/p", runGit: runner(tags: "v4\n")) == .present("v4"))
        #expect(MilestoneLandTags.local(version: "4", project: "/p", runGit: runner(tags: "4.0.0\n")) == .present("4.0.0"))
    }

    @Test func vFortyAndVFiveDoNotMatchVersionFour() {
        #expect(MilestoneLandTags.local(version: "4", project: "/p", runGit: runner(tags: "v40\nv5\n")) == .absent)
    }

    @Test func presentLocallyAndAbsentOnOriginShowApart() {
        let git = runner(tags: "v4\n", lsRemote: "abc\trefs/tags/v3\n")
        #expect(MilestoneLandTags.local(version: "4", project: "/p", runGit: git) == .present("v4"))
        #expect(MilestoneLandTags.origin(version: "4", project: "/p", runGit: git) == .absent)
    }

    @Test func aPeeledLineIsIgnored() {
        let git = runner(lsRemote: "abc\trefs/tags/v3\ndef\trefs/tags/v4^{}\n")
        #expect(MilestoneLandTags.origin(version: "4", project: "/p", runGit: git) == .absent)
        let both = runner(lsRemote: "abc\trefs/tags/v4\ndef\trefs/tags/v4^{}\n")
        #expect(MilestoneLandTags.origin(version: "4", project: "/p", runGit: both) == .present("v4"))
    }

    @Test func noVersionGivesUnknownNotAbsent() {
        #expect(MilestoneLandTags.local(version: nil, project: "/p", runGit: runner()) == .unknown(MilestoneLandTags.noVersion))
        #expect(MilestoneLandTags.origin(version: nil, project: "/p", runGit: runner()) == .unknown(MilestoneLandTags.noVersion))
    }

    @Test func anEmptyRemoteListIsAbsentAndNoOriginIsUnknown() {
        #expect(MilestoneLandTags.origin(version: "4", project: "/p", runGit: runner()) == .absent)
        #expect(MilestoneLandTags.origin(version: "4", project: "/p", runGit: runner(remote: "")) == .unknown("no origin"))
    }

    @Test func aFailingRunnerGivesItsReason() {
        let failing: MilestoneLandTags.RunGit = { _ in ProcessResult(status: 128, stdout: "", stderr: "fatal: unable to access\nmore") }
        #expect(MilestoneLandTags.local(version: "4", project: "/p", runGit: failing) == .unknown("fatal: unable to access"))
        #expect(MilestoneLandTags.origin(version: "4", project: "/p", runGit: failing) == .unknown("fatal: unable to access"))
    }

    @Test func versionComesFromRoadmapThenProject() {
        let files = ["/p/.planning/ROADMAP.md": "x\nMilestone v4: name\n", "/p/.planning/PROJECT.md": "Milestone v2: old"]
        #expect(MilestoneLandTags.version(project: "/p", worktree: nil, read: { files[$0] }) == "4")
        #expect(MilestoneLandTags.version(project: "/p", worktree: nil, read: { $0.hasSuffix("PROJECT.md") ? files[$0] : nil }) == "2")
        #expect(MilestoneLandTags.version(project: "/p", worktree: nil, read: { _ in "Milestone v4.1. done" }) == "4.1")
        #expect(MilestoneLandTags.version(project: "/p", worktree: nil, read: { _ in nil }) == nil)
    }
}
