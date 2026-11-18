import Foundation

/// What one load of the run record gives: both seams' figures, or the reasons and no figures from either (D-01).
struct RunRecordResult: Equatable {
    var render: RunRecordRender?
    var suggest: RunRecordSuggest?
    var reasons: [String] = []
}

enum RunRecordLoader {
    typealias Load = @Sendable (_ project: String, _ phase: String?) -> RunRecordResult

    /// Runs `trace render` and `trace suggest` for the scope. Either one failing drops both figure sets.
    static let live: Load = { project, phase in
        switch CadenceLocator.locate() {
        case .failure(let failure): return RunRecordResult(reasons: [failure.reason])
        case .success(let scripts):
            let render = RunRecordRender.run(scripts, project: project, phase: phase)
            let suggest = RunRecordSuggest.run(scripts, project: project, phase: phase)
            if case .success(let r) = render, case .success(let s) = suggest { return RunRecordResult(render: r, suggest: s) }
            var reasons: [String] = []
            if case .failure(let f) = render { reasons.append(f.reason) }
            if case .failure(let f) = suggest { reasons.append(f.reason) }
            return RunRecordResult(reasons: reasons)
        }
    }
}

/// Loads the run record on open, on a scope change and on `refresh`, and at no other time (D-07): no watcher, no
/// timer, no file read or write. A newer load drops the result of an older one.
@MainActor
final class RunRecordStore: ObservableObject {
    @Published private(set) var result: RunRecordResult?
    /// The picked phase text, nil for the whole record.
    @Published private(set) var phase: String?

    private let load: RunRecordLoader.Load
    private var project: String?
    private var generation = 0

    init(load: @escaping RunRecordLoader.Load = RunRecordLoader.live) { self.load = load }

    /// Opens the screen for a project on the whole record. The returned task is for tests.
    @discardableResult
    func open(project: String?) -> Task<Void, Never>? {
        self.project = project
        phase = nil
        result = nil
        return reload()
    }

    @discardableResult
    func select(phase: String?) -> Task<Void, Never>? {
        self.phase = phase
        return reload()
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? { reload() }

    private func reload() -> Task<Void, Never>? {
        generation += 1
        let current = generation
        guard let project else { return nil }
        let (phase, load) = (phase, load)
        return Task { [weak self] in
            let loaded = await Task.detached { load(project, phase) }.value
            self?.finish(loaded, generation: current)
        }
    }

    private func finish(_ loaded: RunRecordResult, generation done: Int) {
        guard done == generation else { return }
        result = loaded
    }
}
