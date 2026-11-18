import Foundation

/// What the file-open helper does with one resolved file.
enum FileOpenDecision: Equatable {
    case editor
    case defaultApp
    case refused(String)
}

/// Facts about one resolved file. `ext` is the extension of the real path, in any case.
struct FileFacts: Equatable {
    var ext: String
    var isDirectory: Bool
    var isPackage: Bool
    var isExecutable: Bool
}

/// D-09: which files open in the editor, which in their default app, and which are refused.
/// Data-driven: a later type is one entry in a set.
enum FileOpenPolicy {
    static let notOnListReason = "type not on open list"

    static let codeExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "py", "rb", "go", "rs", "java", "kt", "c", "h", "m", "cpp", "cs",
        "sh", "bash", "zsh", "command", "tool", "json", "yml", "yaml", "toml", "xml", "plist", "md", "txt",
        "log", "csv", "html", "css", "sql",
        "mjs", "cjs", "jsonl", "ini", "cfg",
    ]

    static let refusedExtensions: Set<String> = [
        "terminal", "workflow", "action", "pkg", "mpkg", "jar", "webloc", "inetloc", "url", "fileloc", "dmg",
        "mobileconfig",
    ]

    static let defaultAppExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "pdf",
        "rtf", "docx", "xlsx", "pptx", "key", "pages", "numbers",
    ]

    static func decide(_ facts: FileFacts) -> FileOpenDecision {
        let ext = facts.ext.lowercased()
        if facts.isDirectory || facts.isPackage { return .refused("folders and packages are not opened") }
        if refusedExtensions.contains(ext) { return .refused("\(ext) files are not opened") }
        if codeExtensions.contains(ext) { return .editor }
        if facts.isExecutable { return .refused("executable files are not opened") }
        if defaultAppExtensions.contains(ext) { return .defaultApp }
        return .refused(notOnListReason)
    }
}
