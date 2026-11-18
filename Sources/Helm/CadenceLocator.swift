import Foundation

/// Finds node and the installed Cadence scripts. Read on every call and never cached, so a plugin update
/// (a new `installPath` in `installed_plugins.json`) is used by the next refresh with no rebuild.
enum CadenceLocator {
    struct Scripts: Equatable {
        var node: String
        var planning: String
        var config: String
    }

    static let defaultPluginsFile = NSHomeDirectory() + "/.claude/plugins/installed_plugins.json"

    /// The three paths, or one plain-language reason.
    static func locate(
        pluginsFile: String = defaultPluginsFile, nodeSearchPath: String = OrchestratorPaths.searchPath
    ) -> Result<Scripts, Failure> {
        guard let node = OrchestratorPaths.nodePath(searchPath: nodeSearchPath) else {
            return .failure(Failure(reason: "node is not on the search list (\(nodeSearchPath))."))
        }
        guard let data = FileManager.default.contents(atPath: pluginsFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any],
              let entries = plugins["cadence@cadence"] as? [[String: Any]],
              let install = entries.lazy.compactMap({ $0["installPath"] as? String }).first
        else {
            return .failure(Failure(reason: "No cadence@cadence entry in \(pluginsFile)."))
        }
        let planning = install + "/cadence-core/bin/planning.mjs"
        let config = install + "/cadence-core/bin/config.mjs"
        for script in [planning, config] where !isFile(script) {
            return .failure(Failure(reason: "Cadence script is missing: \(script)."))
        }
        return .success(Scripts(node: node, planning: planning, config: config))
    }

    struct Failure: Error, Equatable {
        var reason: String
    }

    private static func isFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
