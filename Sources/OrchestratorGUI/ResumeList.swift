import Foundation

/// One past conversation of a session folder (D-09).
struct ResumeRow: Equatable, Identifiable {
    let id: String
    let title: String
    let date: Date
    let isCurrent: Bool
}

/// Lists `<projects>/<slug>/*.jsonl` for a session cwd (D-09). Blocking file IO: callers run it off the main actor.
enum ResumeList {
    static let maxRows = 50
    static let defaultProjects = NSHomeDirectory() + "/.claude/projects"

    /// The launcher's rule: `pwd -P` of the cwd, every non-alphanumeric character replaced by `-`.
    static func slug(_ cwd: String) -> String {
        String(FolderCheck.realPath(cwd).unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
    }

    static func rows(cwd: String, currentId: String?, projects: String = defaultProjects) -> [ResumeRow] {
        guard !cwd.isEmpty else { return [] }
        let dir = URL(fileURLWithPath: projects).appendingPathComponent(slug(cwd))
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.filter { $0.pathExtension == "jsonl" }.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        return dated.sorted { $0.1 > $1.1 }.prefix(maxRows).map { url, date in
            let id = url.deletingPathExtension().lastPathComponent
            return ResumeRow(id: id, title: title(of: url) ?? id, date: date, isCurrent: id == currentId)
        }
    }

    private static let aiTitle = Data(#""type":"ai-title""#.utf8)
    private static let lastPrompt = Data(#""type":"last-prompt""#.utf8)

    /// The last `aiTitle`, else the last `lastPrompt`. Only lines that hold a title record are parsed as JSON.
    static func title(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var ai: String?, prompt: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let isAi = line.range(of: aiTitle) != nil
            guard isAi || line.range(of: lastPrompt) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if isAi, let text = object["aiTitle"] as? String, !text.isEmpty { ai = text }
            if !isAi, let text = object["lastPrompt"] as? String, !text.isEmpty { prompt = text }
        }
        return ai ?? prompt
    }
}
