import Foundation
import Testing
@testable import Helm

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    func count(_ prefix: String) -> Int { all.filter { $0.hasPrefix(prefix) }.count }
}

@Suite @MainActor struct NewProjectModelTests {
    struct Boom: LocalizedError { var errorDescription: String? { "disk is full" } }

    private func model(
        _ log: Log,
        launch: @escaping @Sendable () throws -> LaunchResult = { LaunchResult(base: "proj", reused: false, output: "") },
        create: @escaping @Sendable (String, GithubChoice) throws -> LaunchResult = { _, _ in
            LaunchResult(base: "proj", reused: false, output: "", folder: "/p/proj")
        },
        ready: Bool = true,
        kind: FolderKind = .repo,
        initRepo: @escaping @Sendable () throws -> Void = {},
        name: @escaping @Sendable () throws -> String = { "proj" },
        firstClaim: SessionClaim = .free,
        laterClaim: SessionClaim = .sameProject
    ) -> NewProjectModel {
        NewProjectModel(
            check: { _ in log.add("check"); return kind },
            initRepo: { _ in log.add("init"); try initRepo() },
            baseName: { _ in log.add("name"); return try name() },
            claim: { _, _ in log.add("claim"); return log.count("claim") == 1 ? firstClaim : laterClaim },
            capture: { log.add("capture"); return "PATH=/bin\n" },
            launch: { _, _ in log.add("launch"); return try launch() },
            launchRoot: { _ in log.add("launchRoot"); return try launch() },
            createProject: { name, github, _ in log.add("create:\(name):\(github.rawValue)"); return try create(name, github) },
            isReady: { _ in log.add("ready"); return ready },
            refresh: { _ in log.add("refresh"); return true },
            select: { log.add("select:\($0)") })
    }

    @Test func stepsRunInOrderAndSelectLast() async {
        let log = Log()
        let model = model(log)
        await model.start(folder: "/tmp/proj")
        #expect(log.all == ["check", "name", "claim", "capture", "launch", "refresh", "ready", "refresh", "select:proj"])
        #expect(model.reason == nil)
        #expect(model.startedBase == "proj")
    }

    @Test func aReadyFailureNeverSelectsAndShowsTheLauncherOutput() async {
        let log = Log()
        let model = model(
            log, launch: { LaunchResult(base: "proj", reused: false, output: "claude: command not found") }, ready: false)
        await model.start(folder: "/tmp/proj")
        #expect(log.count("select") == 0)
        #expect(model.startedBase == nil)
        #expect(model.reason?.contains("claude: command not found") == true)
    }

    @Test func aLaunchFailureStopsTheFlowAndShowsTheReason() async {
        let log = Log()
        let model = model(log, launch: { throw LaunchFailure(reason: "no good") })
        await model.start(folder: "/tmp/proj")
        #expect(log.all == ["check", "name", "claim", "capture", "launch"])
        #expect(model.reason == "no good")
    }

    @Test func aCaptureFailureLaunchesNothing() async {
        let log = Log()
        let model = NewProjectModel(
            check: { _ in .repo }, initRepo: { _ in }, baseName: { _ in "proj" }, claim: { _, _ in .free },
            capture: { throw Boom() }, launch: { _, _ in log.add("launch"); throw Boom() },
            launchRoot: { _ in log.add("launchRoot"); throw Boom() },
            createProject: { _, _, _ in throw Boom() },
            isReady: { _ in true }, refresh: { _ in true }, select: { _ in log.add("select") })
        await model.start(folder: "/tmp/proj")
        #expect(log.all.isEmpty)
        #expect(model.reason == "disk is full")
    }

    /// Select project passes the listed path to `start(folder:)` as it is (D-14, AC8).
    @Test func aListedFolderReachesTheLaunchStepUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("listed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try #require(ProjectFolders.list(root: root.path).first)
        let log = Log()
        let model = NewProjectModel(
            check: { _ in .repo }, initRepo: { _ in }, baseName: { _ in "proj" }, claim: { _, _ in .free },
            capture: { "PATH=/bin\n" },
            launch: { launched, _ in log.add("launch:\(launched)"); return LaunchResult(base: "proj", reused: false, output: "") },
            launchRoot: { _ in throw Boom() },
            createProject: { _, _, _ in throw Boom() },
            isReady: { _ in true }, refresh: { _ in true }, select: { log.add("select:\($0)") })
        await model.start(folder: folder)
        #expect(log.all == ["launch:\(folder)", "select:proj"])
        #expect(model.reason == nil)
    }

    @Test func aNonRepoOffersInitAndCancelChangesNothing() async {
        let log = Log()
        let model = model(log, kind: .nonRepo)
        await model.start(folder: "/tmp/plain")
        #expect(model.initOffer == "/tmp/plain")
        model.cancelInit()
        #expect(model.initOffer == nil)
        #expect(log.count("init") == 0)
        #expect(log.count("launch") == 0)
    }

    @Test func acceptingTheOfferInitialisesOnceThenLaunches() async {
        let log = Log()
        let model = model(log, kind: .nonRepo)
        await model.start(folder: "/tmp/plain")
        await model.confirmInit(folder: "/tmp/plain")
        #expect(log.all == ["check", "name", "claim", "init", "capture", "launch", "refresh", "ready", "refresh", "select:proj"])
        #expect(model.initOffer == nil)
    }

    @Test func aFailedInitStopsBeforeTheLaunch() async {
        let log = Log()
        let model = model(log, kind: .nonRepo, initRepo: { throw Boom() })
        await model.start(folder: "/tmp/plain")
        await model.confirmInit(folder: "/tmp/plain")
        #expect(log.count("launch") == 0)
        #expect(model.reason == "disk is full")
    }

    @Test func aFolderInsideAnotherRepoOffersNoInitAndNamesTheTopLevel() async {
        let log = Log()
        let model = model(log, kind: .insideRepo(top: "/work/outer"))
        await model.start(folder: "/work/outer/sub")
        #expect(model.initOffer == nil)
        #expect(log.count("init") == 0)
        #expect(log.count("launch") == 0)
        #expect(model.reason?.contains("/work/outer") == true)
    }

    @Test func anUnreadableFolderShowsGitsText() async {
        let log = Log()
        let model = model(log, kind: .unreadable("detected dubious ownership"))
        await model.start(folder: "/work/x")
        #expect(log.count("launch") == 0)
        #expect(model.reason?.contains("detected dubious ownership") == true)
    }

    @Test func exitThreeSelectsLikeExitZero() async {
        let log = Log()
        let model = model(log, launch: { LaunchResult(base: "proj", reused: true, output: "") })
        await model.start(folder: "/tmp/proj")
        #expect(log.all.last == "select:proj")
    }

    @Test func aSecondStartWhileTheFirstAwaitsDoesNotLaunchAgain() async {
        let log = Log()
        let gate = DispatchSemaphore(value: 0)
        let model = model(log, launch: { gate.wait(); return LaunchResult(base: "proj", reused: false, output: "") })
        let first = Task { await model.start(folder: "/tmp/proj") }
        while !model.isRunning { await Task.yield() }
        await model.start(folder: "/tmp/proj")
        gate.signal()
        await first.value
        #expect(log.count("launch") == 1)
        #expect(!model.isRunning)
    }

    @Test func anInUseNameCapturesAndLaunchesNothing() async {
        let log = Log()
        let model = model(log, firstClaim: .inUse("/work/other"))
        await model.start(folder: "/tmp/proj")
        #expect(log.count("capture") == 0)
        #expect(log.count("launch") == 0)
        #expect(model.reason?.contains("name already in use") == true)
        #expect(model.reason?.contains("/work/other") == true)
    }

    @Test func anInUseNameOffersNoInit() async {
        let log = Log()
        let model = model(log, kind: .nonRepo, firstClaim: .inUse("/work/other"))
        await model.start(folder: "/tmp/plain")
        #expect(model.initOffer == nil)
        #expect(model.reason?.contains("name already in use") == true)
    }

    @Test func exitThreeThenInUseNeverReadiesOrSelects() async {
        let log = Log()
        let model = model(
            log, launch: { LaunchResult(base: "proj", reused: true, output: "") }, laterClaim: .inUse("/work/other"))
        await model.start(folder: "/tmp/proj")
        #expect(log.count("ready") == 0)
        #expect(log.count("select") == 0)
        #expect(model.startedBase == nil)
        #expect(model.reason?.contains("name already in use") == true)
    }

    @Test func exitThreeThenSameProjectSelectsLikeExitZero() async {
        let log = Log()
        let model = model(log, launch: { LaunchResult(base: "proj", reused: true, output: "") })
        await model.start(folder: "/tmp/proj")
        #expect(log.all.last == "select:proj")
        #expect(log.count("ready") == 1)
    }

    @Test func theSameProjectLaunchesNothingAndSelectsOnce() async {
        let log = Log()
        let model = model(log, firstClaim: .sameProject)
        await model.start(folder: "/tmp/proj")
        #expect(log.count("launch") == 0)
        #expect(log.count("capture") == 0)
        #expect(log.count("select") == 1)
        #expect(model.reason == nil)
    }

    @Test func anEmptyDerivedNameStopsWithAReason() async {
        let log = Log()
        let model = model(log, name: { throw SessionCheckFailure(reason: "The orchestrator gave no session name.") })
        await model.start(folder: "/tmp/proj")
        #expect(log.count("claim") == 0)
        #expect(log.count("launch") == 0)
        #expect(model.reason == "The orchestrator gave no session name.")
    }

    @Test func rootStartSkipsFolderChecksAndUsesTheRootLauncher() async {
        let log = Log()
        let model = model(log)
        await model.startRoot()
        #expect(log.all == ["name", "claim", "capture", "launchRoot", "refresh", "ready", "refresh", "select:proj"])
        #expect(model.reason == nil)
        #expect(model.startedBase == "proj")
    }

    @Test func aRunningRootSessionIsSelectedNotLaunchedAgain() async {
        let log = Log()
        let model = model(log, firstClaim: .sameProject)
        await model.startRoot()
        #expect(log.count("launchRoot") == 0)
        #expect(log.all.last == "select:proj")
    }

    @Test func aRootLaunchFailureShowsTheReason() async {
        let log = Log()
        let model = model(log, launch: { throw LaunchFailure(reason: "no good") })
        await model.startRoot()
        #expect(model.reason == "no good")
        #expect(log.count("select") == 0)
    }

    @Test func aRowThatNeverAppearsIsReportedNotSelected() async {
        let log = Log()
        let model = NewProjectModel(
            check: { _ in .repo }, initRepo: { _ in }, baseName: { _ in "proj" }, claim: { _, _ in .free },
            capture: { "PATH=/bin\n" }, launch: { _, _ in LaunchResult(base: "proj", reused: false, output: "") },
            launchRoot: { _ in LaunchResult(base: "proj", reused: false, output: "") },
            createProject: { _, _, _ in LaunchResult(base: "proj", reused: false, output: "") },
            isReady: { _ in true }, refresh: { _ in false }, select: { _ in log.add("select") })
        await model.start(folder: "/tmp/proj")
        #expect(log.count("select") == 0)
        #expect(model.reason?.contains("did not appear") == true)
    }

    // Create a project (`create(name:github:)`).

    @Test func aValidCreateRunsTheSameTailAndSelectsLast() async {
        let log = Log()
        let model = model(log)
        await model.create(name: "proj", github: .skip)
        #expect(log.all == ["capture", "create:proj:skip", "refresh", "ready", "refresh", "select:proj"])
        #expect(model.reason == nil)
        #expect(model.startedBase == "proj")
        #expect(!model.isRunning)
    }

    @Test(arguments: GithubChoice.allCases) func theClosureGetsTheExactNameAndChoice(choice: GithubChoice) async {
        let log = Log()
        let model = model(log)
        await model.create(name: "my-app.1", github: choice)
        #expect(log.all.contains("create:my-app.1:\(choice.rawValue)"))
    }

    @Test func anInvalidNameSetsAReasonAndRunsNothing() async {
        let log = Log()
        let model = model(log)
        await model.create(name: "a b", github: .skip)
        #expect(model.reason != nil)
        #expect(log.all.isEmpty)
    }

    @Test func aCreateFailureShowsItsReasonAndNeverSelects() async {
        let log = Log()
        let model = model(log, create: { _, _ in throw LaunchFailure(reason: "boom") })
        await model.create(name: "proj", github: .skip)
        #expect(model.reason == "boom")
        #expect(model.existingProject == nil)
        #expect(log.count("select") == 0)
    }

    @Test func alreadyExistsSetsTheOfferAndALaterStartClearsIt() async {
        let log = Log()
        let model = model(log, create: { name, _ in throw ProjectExists(name: name) })
        await model.create(name: "proj", github: .skip)
        #expect(model.reason?.contains("already exists") == true)
        #expect(model.existingProject == "proj")
        #expect(log.count("select") == 0)
        await model.startRoot()
        #expect(model.existingProject == nil)
    }

    @Test func aResultWithNoFolderIsAFailure() async {
        let log = Log()
        let model = model(log, create: { _, _ in LaunchResult(base: "proj", reused: false, output: "") })
        await model.create(name: "proj", github: .skip)
        #expect(model.reason != nil)
        #expect(log.count("select") == 0)
    }

    @Test func aReusedResultSelectsOnlyForTheSameProject() async {
        let reused: @Sendable (String, GithubChoice) throws -> LaunchResult = { _, _ in
            LaunchResult(base: "proj", reused: true, output: "", folder: "/p/proj")
        }
        let same = Log()
        await self.model(same, create: reused, firstClaim: .sameProject).create(name: "proj", github: .skip)
        #expect(same.all.last == "select:proj")

        let other = Log()
        let model = self.model(other, create: reused, firstClaim: .inUse("/work/other"))
        await model.create(name: "proj", github: .skip)
        #expect(model.reason?.hasPrefix("Cannot start:") == true)
        #expect(other.count("select") == 0)
    }

    @Test func aCreateThatIsNotReadyShowsTheLauncherOutputAndNeverSelects() async {
        let log = Log()
        let model = model(
            log, create: { _, _ in LaunchResult(base: "proj", reused: false, output: "claude: command not found", folder: "/p/proj") },
            ready: false)
        await model.create(name: "proj", github: .skip)
        #expect(model.reason?.contains("claude: command not found") == true)
        #expect(log.count("select") == 0)
    }

    @Test func warningsAtExitZeroReachTheModelBeforeTheRowIsSelected() async {
        let log = Log()
        let model = model(log, create: { _, _ in
            LaunchResult(base: "proj", reused: false, output: "", folder: "/p/proj", warnings: ["warning: github: gh repo create failed"])
        })
        await model.create(name: "proj", github: .privateRepo)
        #expect(model.warnings == ["warning: github: gh repo create failed"])
        #expect(model.startedBase == "proj")
    }

    @Test func noWarningsLeavesNothingToShow() async {
        let model = model(Log())
        await model.create(name: "proj", github: .skip)
        #expect(model.warnings.isEmpty)
        #expect(model.startedBase == "proj")
    }

    @Test func clearFailureEmptiesTheReasonLeftByAFailedStart() async {
        let log = Log()
        let model = model(log, launch: { throw LaunchFailure(reason: "no good") })
        await model.startRoot()
        #expect(model.reason == "no good")
        model.clearFailure()
        #expect(model.reason == nil)
    }
}
