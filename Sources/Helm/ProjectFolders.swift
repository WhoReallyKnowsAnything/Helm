import Foundation

/// The folders the Select project list offers: the ones directly under the projects root.
enum ProjectFolders {
    /// The same folder the launcher script calls `PROJECTS_DIR`.
    static var defaultRoot: String { NSHomeDirectory() + "/Documents/Projects" }

    /// Absolute paths, sorted by folder name. Files and hidden entries are left out. A root that cannot be read gives [].
    static func list(root: String = defaultRoot) -> [String] {
        let url = URL(fileURLWithPath: root, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        // Rebuilt from the root as given: the directory listing resolves symlinks such as /var to /private/var.
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { url.appendingPathComponent($0).path }
    }
}
