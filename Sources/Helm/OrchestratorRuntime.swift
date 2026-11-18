import CryptoKit
import Foundation

/// Copies the bundled `orchestration` folder to the runtime folder, so scripts run outside the signed bundle.
/// The stamp file sits beside the runtime copy, never inside it, and nothing else in that folder is touched.
struct OrchestratorRuntime {
    let source: URL
    let destination: URL
    let stamp: URL

    /// The app's real sync: bundle resource to `OrchestratorPaths.orchestratorRepo/orchestration`.
    /// Does nothing when the bundle has no `orchestration` resource (`swift test`, `swift run`).
    @discardableResult
    static func syncBundled() -> Bool {
        guard let res = Bundle.main.resourceURL else { return false }
        let source = res.appendingPathComponent("orchestration")
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        let root = URL(fileURLWithPath: OrchestratorPaths.orchestratorRepo)
        return OrchestratorRuntime(
            source: source,
            destination: root.appendingPathComponent("orchestration"),
            stamp: root.appendingPathComponent(".orchestration.stamp")).sync()
    }

    /// True when the runtime copy matches the source afterwards. On failure keeps the old copy and old stamp.
    @discardableResult
    func sync() -> Bool {
        let fm = FileManager.default
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".orchestration.tmp-\(UUID().uuidString)")
        do {
            let print = try Self.fingerprint(of: source)
            let old = try? String(contentsOf: stamp, encoding: .utf8)
            if old == print, fm.fileExists(atPath: destination.path) { return true }
            try fm.createDirectory(at: temp.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: temp)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: destination)
            }
            try print.write(to: stamp, atomically: true, encoding: .utf8)
            return true
        } catch {
            try? fm.removeItem(at: temp)
            FileHandle.standardError.write(Data("OrchestratorRuntime: sync failed: \(error)\n".utf8))
            return false
        }
    }

    /// SHA-256 over each file's relative path, exec bit and bytes, in path order.
    static func fingerprint(of folder: URL) throws -> String {
        let fm = FileManager.default
        let base = folder.resolvingSymlinksInPath().path
        var files: [(rel: String, url: URL)] = []
        for case let url as URL in fm.enumerator(at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isRegularFileKey])! {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            files.append((String(url.resolvingSymlinksInPath().path.dropFirst(base.count)), url))
        }
        var hasher = SHA256()
        for file in files.sorted(by: { $0.rel < $1.rel }) {
            hasher.update(data: Data(file.rel.utf8))
            hasher.update(data: Data([fm.isExecutableFile(atPath: file.url.path) ? 1 : 0]))
            hasher.update(data: try Data(contentsOf: file.url))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
