import Foundation

enum FileRoot: String, Equatable {
    case project
    case worktree
}

struct ResolvedFile: Equatable {
    var url: URL
    var root: FileRoot
    var facts: FileFacts
}

struct FileRefusal: Error, Equatable {
    var reason: String
}

/// D-10: turns path text into one real file inside the project folder or the worktree, or a reason.
enum FilePathResolver {
    private static let lineReference = #":\d+(-\d+)?(,\d+(-\d+)?)*(:\d+)?$"#
    private static let urlScheme = #"^[A-Za-z][A-Za-z0-9+.\-]*:"#

    /// The first line number of a `path:12`, `path:12-20`, `path:12,15` or `path:12:3` reference, or nil with no suffix.
    static func lineNumber(in raw: String) -> Int? {
        guard let range = raw.range(of: lineReference, options: .regularExpression) else { return nil }
        return Int(raw[range].drop(while: { $0 == ":" }).prefix(while: \.isNumber))
    }

    static func resolve(_ raw: String, project: URL, worktree: URL?) -> Result<ResolvedFile, FileRefusal> {
        let fm = FileManager.default
        if raw.isEmpty || raw.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return .failure(FileRefusal(reason: "not a plain path"))
        }
        var text = raw
        if let range = text.range(of: lineReference, options: .regularExpression) { text.removeSubrange(range) }
        if text.isEmpty || text.range(of: urlScheme, options: .regularExpression) != nil {
            return .failure(FileRefusal(reason: "not a plain path"))
        }

        var isDir: ObjCBool = false
        let worktreeExists = worktree.map { fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue } ?? false
        let base = worktreeExists ? worktree! : project
        let candidate = text.hasPrefix("/") ? URL(fileURLWithPath: text) : base.appendingPathComponent(text)

        let real = canonical(candidate)
        let realProject = canonical(project)
        let realWorktree = worktreeExists ? canonical(worktree!) : nil
        // The worktree sits under the project, so test it first.
        let root: FileRoot
        if let realWorktree, isInside(real, realWorktree) {
            root = .worktree
        } else if isInside(real, realProject) {
            root = .project
        } else {
            return .failure(FileRefusal(reason: "outside the project and the worktree"))
        }

        guard let attributes = try? fm.attributesOfItem(atPath: real.path),
              let type = attributes[.type] as? FileAttributeType else {
            return .failure(FileRefusal(reason: "does not exist"))
        }
        guard type == .typeRegular || type == .typeDirectory else {
            return .failure(FileRefusal(reason: "not a regular file"))
        }
        let isPackage = (try? real.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        let facts = FileFacts(
            ext: real.pathExtension,
            isDirectory: type == .typeDirectory,
            isPackage: isPackage,
            isExecutable: type == .typeRegular && fm.isExecutableFile(atPath: real.path)
        )
        return .success(ResolvedFile(url: real, root: root, facts: facts))
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Whole path components, so `/proj-evil` is not inside `/proj`.
    private static func isInside(_ url: URL, _ root: URL) -> Bool {
        let a = url.pathComponents, b = root.pathComponents
        return a.count >= b.count && Array(a.prefix(b.count)) == b
    }
}
