import Foundation

/// State of the "New project" flow. Every step arrives as a closure, so tests use stubs and the blocking
/// ones run off the main actor. Only one start runs at a time (D-11), for the whole model.
@MainActor
final class NewProjectModel: ObservableObject {
    @Published private(set) var isRunning = false
    /// Why the last start stopped, or nil.
    @Published private(set) var reason: String?
    /// The base session of the last start that reached the selection; the view closes its sheet on it.
    @Published private(set) var startedBase: String?
    /// The folder that is not a git repo yet; the view asks whether to initialise it.
    @Published private(set) var initOffer: String?
    /// The name of a new project whose folder already exists; the view offers Select project.
    @Published private(set) var existingProject: String?
    /// The `warning:` lines of the last create, set before the row is selected so the view can show them once.
    @Published private(set) var warnings: [String] = []

    private let check: @Sendable (_ folder: String) -> FolderKind
    private let initRepo: @Sendable (_ folder: String) throws -> Void
    private let baseName: @Sendable (_ folder: String) throws -> String
    private let claim: @Sendable (_ base: String, _ folder: String) throws -> SessionClaim
    private let capture: @Sendable () throws -> String
    private let launch: @Sendable (_ folder: String, _ envText: String) throws -> LaunchResult
    private let launchRoot: @Sendable (_ envText: String) throws -> LaunchResult
    private let createProject: @Sendable (_ name: String, _ github: GithubChoice, _ envText: String) throws -> LaunchResult
    private let isReady: @Sendable (_ base: String) -> Bool
    /// Refreshes the session store once; true when the store now holds a row for the base.
    private let refresh: @MainActor (_ base: String) async -> Bool
    private let select: @MainActor (_ base: String) -> Void

    init(
        check: @escaping @Sendable (String) -> FolderKind,
        initRepo: @escaping @Sendable (String) throws -> Void,
        baseName: @escaping @Sendable (String) throws -> String,
        claim: @escaping @Sendable (String, String) throws -> SessionClaim,
        capture: @escaping @Sendable () throws -> String,
        launch: @escaping @Sendable (String, String) throws -> LaunchResult,
        launchRoot: @escaping @Sendable (String) throws -> LaunchResult,
        createProject: @escaping @Sendable (String, GithubChoice, String) throws -> LaunchResult,
        isReady: @escaping @Sendable (String) -> Bool,
        refresh: @escaping @MainActor (String) async -> Bool,
        select: @escaping @MainActor (String) -> Void
    ) {
        self.check = check
        self.initRepo = initRepo
        self.baseName = baseName
        self.claim = claim
        self.capture = capture
        self.launch = launch
        self.launchRoot = launchRoot
        self.createProject = createProject
        self.isReady = isReady
        self.refresh = refresh
        self.select = select
    }

    func start(folder: String) async {
        guard !isRunning, !folder.isEmpty else { return }
        isRunning = true
        reason = nil
        startedBase = nil
        initOffer = nil
        clearCreateNotices()
        defer { isRunning = false }
        let check = self.check
        do {
            switch try await off({ check(folder) }) {
            case .repo: if try await nameIsFree(folder) { await launchFlow(folder: folder) }
            case .nonRepo: if try await nameIsFree(folder) { initOffer = folder }
            case .insideRepo(let top):
                reason = "This folder is inside the git repository at \(top). Choose that folder, or another one."
            case .unreadable(let text): reason = "Git cannot read this folder: \(text)"
            }
        } catch {
            reason = error.localizedDescription
        }
    }

    /// A plain solo session in the home folder. The folder checks and the git offer do not apply to it.
    func startRoot() async {
        guard !isRunning else { return }
        isRunning = true
        reason = nil
        startedBase = nil
        initOffer = nil
        clearCreateNotices()
        defer { isRunning = false }
        let home = NSHomeDirectory()
        do {
            if try await nameIsFree(home) { await launchFlow(folder: home, root: true) }
        } catch {
            reason = error.localizedDescription
        }
    }

    /// The user accepted the offer: `git init` plus an empty first commit, then the same start as any repo.
    /// The folder comes from the caller, so a dismiss that clears `initOffer` first cannot cancel an accepted offer.
    func confirmInit(folder: String) async {
        guard !isRunning else { return }
        isRunning = true
        reason = nil
        initOffer = nil
        clearCreateNotices()
        defer { isRunning = false }
        let initRepo = self.initRepo
        do {
            try await off { try initRepo(folder) }
            await launchFlow(folder: folder)
        } catch {
            reason = error.localizedDescription
        }
    }

    func cancelInit() { initOffer = nil }

    /// D-10, before anything is captured or launched, and before an init is offered. True when the name is free.
    /// The same project does not launch: its running row is selected instead. Anything else stops with a reason.
    private func nameIsFree(_ folder: String) async throws -> Bool {
        let baseName = self.baseName, claim = self.claim
        let base = try await off { try baseName(folder) }
        let found = try await off { try claim(base, folder) }
        switch found {
        case .free: return true
        case .sameProject: await selectWhenListed(base)
        case .inUse: reason = "Cannot start: " + (found.inUseText ?? "")
        }
        return false
    }

    /// Creates `~/Documents/Projects/<name>` through the launcher, then starts it like any folder.
    func create(name: String, github: GithubChoice) async {
        guard !isRunning else { return }
        reason = nil
        startedBase = nil
        initOffer = nil
        clearCreateNotices()
        guard NewProjectInput.isValidName(name) else {
            reason = "Use 1 to 64 letters, digits, dots, dashes or underscores. Start with a letter or a digit."
            return
        }
        isRunning = true
        defer { isRunning = false }
        let capture = self.capture, createProject = self.createProject
        do {
            let envText = try await off { try capture() }
            let result = try await off { try createProject(name, github, envText) }
            guard let folder = result.folder else {
                reason = "The launcher did not report the project folder."
                return
            }
            warnings = result.warnings
            try await finish(result, folder: folder)
        } catch let exists as ProjectExists {
            reason = exists.localizedDescription
            existingProject = exists.name
        } catch {
            reason = error.localizedDescription
        }
    }

    /// Clears the failure of an earlier start, so the New project sheet opens without it.
    func clearFailure() {
        reason = nil
        clearCreateNotices()
    }

    private func clearCreateNotices() {
        existingProject = nil
        warnings = []
    }

    private func launchFlow(folder: String, root: Bool = false) async {
        let capture = self.capture, launch = self.launch, launchRoot = self.launchRoot
        do {
            let envText = try await off { try capture() }
            let result = try await off { root ? try launchRoot(envText) : try launch(folder, envText) }
            try await finish(result, folder: folder)
        } catch {
            reason = error.localizedDescription
        }
    }

    /// The tail every start shares: claim check for a reused session, refresh, readiness, selection.
    private func finish(_ result: LaunchResult, folder: String) async throws {
        let isReady = self.isReady, claim = self.claim
        if result.reused {
            // Another project with the same name may have started between the first check and the launch.
            let found = try await off { try claim(result.base, folder) }
            guard found == .sameProject else {
                reason = "Cannot start: " + (found.inUseText ?? "the session ended before it could be opened")
                return
            }
        }
        // The row shows without waiting for the 2 second poll. This is the existing refresh, not a push channel (D-13).
        _ = await refresh(result.base)
        guard try await off({ isReady(result.base) }) else {
            let output = result.output.isEmpty ? "" : "\n" + result.output
            reason = "The orchestrator started, but its dashboard stopped at once. Is claude on your PATH?" + output
            return
        }
        await selectWhenListed(result.base)
    }

    /// Selects only after the row is in the store: `ContentView` latches "Session ended" for a selected id with no row.
    /// A refresh that overlaps the 2 second poll does nothing, so ask again for a short while.
    private func selectWhenListed(_ base: String) async {
        for _ in 0..<10 {
            if await refresh(base) {
                startedBase = base
                select(base)
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        reason = "The orchestrator started, but \(base) did not appear in the list."
    }

    private func off<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached { try work() }.value
    }
}
