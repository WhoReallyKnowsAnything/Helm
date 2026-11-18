import Foundation
import Testing
@testable import Helm

@Suite(.serialized) struct GateHoldReaderTests {
    private func holds(_ project: FixtureProject) -> [GateHold] {
        guard case .holds(let list) = GateHoldReader.read(project: project.path) else { return [] }
        return list
    }

    private func make() throws -> (FixtureHolds, FixtureProject) {
        let fx = try FixtureProject.make(withDatabase: false)
        return (FixtureHolds(fx), fx)
    }

    @Test func twoLiveHoldsComeBackOldestFirst() throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        try fixture.add(id: "toolu_B", command: "git push origin dev", epoch: "200")
        try fixture.add(id: "toolu_A", command: "git push origin main", epoch: "100")
        let list = holds(fx)
        #expect(list.map(\.id) == ["toolu_A", "toolu_B"])
        #expect(list.allSatisfy { $0.state == .live && $0.label == "bravo" })
        #expect(list.map(\.command) == ["Bash: git push origin main", "Bash: git push origin dev"])
    }

    @Test func eachStateIsClassifiedFromRealFiles() throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        try fixture.add(id: "live", epoch: "1")
        try fixture.add(id: "decided", epoch: "2", decision: { "allow \($0)\n" })
        try fixture.add(id: "ghost", epoch: "3", hook: .dead)
        try fixture.add(id: "tampered", epoch: "4", altered: "Bash: git push --force")
        try fixture.add(id: "badcr", epoch: "5", decision: { "allow \($0)\r\n" })
        let states = Dictionary(uniqueKeysWithValues: holds(fx).map { ($0.id, $0.state) })
        #expect(states == ["live": .live, "decided": .decided, "ghost": .ghost, "tampered": .tampered, "badcr": .live])
    }

    @Test func aPidWithAnotherStartTimeIsAGhost() throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        try fixture.add(id: "a")
        let path = fixture.folder + "/a.pending"
        var lines = try String(contentsOfFile: path, encoding: .utf8).components(separatedBy: "\n")
        lines[5] = "Mon Jan 1 00:00:00 1990"
        try lines.joined(separator: "\n").write(toFile: path, atomically: false, encoding: .utf8)
        #expect(holds(fx).map(\.state) == [.ghost])
    }

    @Test func aMissingFolderGivesAnEmptyList() throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        #expect(GateHoldReader.read(project: fx.path) == .holds([]))
        #expect(GateHoldReader.read(project: fx.path + "/nope") == .holds([]))
    }

    @Test func anUnreadableFolderGivesAFailureNotAnEmptyList() throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        try fixture.add(id: "a")
        chmod(fixture.folder, 0o000)
        defer { chmod(fixture.folder, 0o755) }
        guard case .failed(let text) = GateHoldReader.read(project: fx.path) else {
            Issue.record("expected a failure")
            return
        }
        #expect(!text.isEmpty)
    }

    @Test func tmpAndNotifiedFilesAndOddNamesAreIgnored() throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        try fixture.add(id: "good")
        let pending = try String(contentsOfFile: fixture.folder + "/good.pending", encoding: .utf8)
        for name in [".tmp.good.pending", "good.notified", "good.pending.tmp", "bad.name.pending", "a b.pending", "readme.txt"] {
            try pending.write(toFile: fixture.folder + "/" + name, atomically: false, encoding: .utf8)
        }
        #expect(holds(fx).map(\.id) == ["good"])
    }

    @Test func aSymlinkedOrNonRegularPendingFileIsSkipped() throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        try fixture.add(id: "real")
        let target = fixture.folder + "/real.pending"
        try FileManager.default.createSymbolicLink(atPath: fixture.folder + "/link.pending", withDestinationPath: target)
        mkfifo(fixture.folder + "/pipe.pending", 0o644)
        try FileManager.default.createDirectory(atPath: fixture.folder + "/dir.pending", withIntermediateDirectories: false)
        #expect(holds(fx).map(\.id) == ["real"])
    }

    @Test func aFileOverTheSizeCapIsSkipped() throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        try fixture.add(id: "big", command: String(repeating: "a", count: GateHoldReader.maxFileBytes))
        #expect(holds(fx).isEmpty)
    }

    @Test func readHoldFindsOneHoldAndNilWhenItsFilesAreGone() throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        try fixture.add(id: "a")
        #expect(GateHoldReader.readHold(project: fx.path, id: "a")?.state == .live)
        try FileManager.default.removeItem(atPath: fixture.folder + "/a.pending")
        #expect(GateHoldReader.readHold(project: fx.path, id: "a") == nil)
    }

    @Test func readingChangesNothingOnDisk() throws {
        let (fixture, fx) = try make()
        defer { fixture.remove() }
        try fixture.add(id: "a", epoch: "1")
        try fixture.add(id: "b", epoch: "2", decision: { "deny \($0)" })
        try fixture.add(id: "c", epoch: "3", hook: .dead)
        func snapshot() throws -> [String: Date] {
            var result: [String: Date] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: fixture.folder) + [""] {
                let attributes = try FileManager.default.attributesOfItem(atPath: fixture.folder + "/" + name)
                result[name] = attributes[.modificationDate] as? Date
            }
            return result
        }
        let before = try snapshot()
        _ = holds(fx)
        _ = GateHoldReader.readHold(project: fx.path, id: "a")
        #expect(try snapshot() == before)
    }
}
