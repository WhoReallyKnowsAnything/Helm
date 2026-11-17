import Foundation

enum SyntaxRole: CaseIterable {
    case keyword, string, comment, number, key, heading
}

enum SyntaxLanguage: Equatable {
    case swift, markdown, json, yaml, shell, plain
}

/// One coloured run, in UTF-16 units (what `NSTextView` uses). Anything not covered by a token is plain.
struct SyntaxToken: Equatable {
    var range: NSRange
    var role: SyntaxRole
}

/// D-04: a small hand-written tokenizer per language, no package. One forward scan, so a multi-line comment or string
/// needs no per-line state, and tokens come out in order without overlap.
enum SyntaxTokenizer {
    static func language(forExtension ext: String) -> SyntaxLanguage {
        switch ext.lowercased() {
        case "swift": .swift
        case "md": .markdown
        case "json", "jsonl": .json
        case "yml", "yaml": .yaml
        case "sh", "bash", "zsh", "command", "tool": .shell
        default: .plain
        }
    }

    // shortcut: whole-text pass on each edit, upgrade to changed-line passes if typing lags
    static func tokenize(_ text: String, language: SyntaxLanguage) -> [SyntaxToken] {
        let u = Array(text.utf16)
        switch language {
        case .swift: return swift(u)
        case .shell: return shell(u)
        case .json: return json(u)
        case .yaml: return yaml(u)
        case .markdown: return markdown(u)
        case .plain: return []
        }
    }

    private static let swiftKeywords: Set<String> = [
        "import", "let", "var", "func", "class", "struct", "enum", "protocol", "extension", "if", "else", "guard", "switch",
        "case", "default", "for", "while", "repeat", "return", "break", "continue", "in", "where", "do", "try", "catch",
        "throw", "throws", "async", "await", "init", "self", "Self", "super", "nil", "true", "false", "public", "private",
        "internal", "fileprivate", "open", "static", "final", "override", "mutating", "some", "any", "typealias",
        "associatedtype", "inout", "is", "as", "defer", "lazy", "weak", "unowned", "indirect", "nonisolated", "actor",
    ]
    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function",
        "select", "return", "exit", "break", "continue", "export", "local", "readonly", "declare", "unset", "set", "shift",
        "source", "alias",
    ]
    private static let literalWords: Set<String> = ["true", "false", "null"]

    // MARK: languages

    private static func swift(_ u: [UInt16]) -> [SyntaxToken] {
        var out: [SyntaxToken] = []
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == ch("/"), at(u, i + 1) == ch("/") {
                let e = lineEnd(u, i)
                out.append(tok(i, e, .comment)); i = e
            } else if c == ch("/"), at(u, i + 1) == ch("*") {
                let e = end(of: "*/", in: u, from: i + 2)
                out.append(tok(i, e, .comment)); i = e
            } else if starts(u, i, "\"\"\"") {
                let e = end(of: "\"\"\"", in: u, from: i + 3)
                out.append(tok(i, e, .string)); i = e
            } else if c == ch("\"") {
                let e = stringEnd(u, i, escapes: true)
                out.append(tok(i, e, .string)); i = e
            } else if isDigit(c) {
                let e = numberEnd(u, i)
                out.append(tok(i, e, .number)); i = e
            } else if isIdentStart(c) {
                let e = wordEnd(u, i)
                if swiftKeywords.contains(word(u, i, e)) { out.append(tok(i, e, .keyword)) }
                i = e
            } else {
                i += 1
            }
        }
        return out
    }

    private static func shell(_ u: [UInt16]) -> [SyntaxToken] {
        var out: [SyntaxToken] = []
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == ch("#"), i == 0 || isShellBoundary(u[i - 1]) {
                let e = lineEnd(u, i)
                out.append(tok(i, e, .comment)); i = e
            } else if c == ch("$") {
                i += at(u, i + 1) == ch("#") ? 2 : 1
            } else if c == ch("\\") {
                i += 2
            } else if c == ch("\"") || c == ch("'") {
                let e = stringEnd(u, i, escapes: c == ch("\""))
                out.append(tok(i, e, .string)); i = e
            } else if isIdentStart(c) {
                let e = wordEnd(u, i)
                if shellKeywords.contains(word(u, i, e)) { out.append(tok(i, e, .keyword)) }
                i = e
            } else {
                i += 1
            }
        }
        return out
    }

    private static func json(_ u: [UInt16]) -> [SyntaxToken] {
        var out: [SyntaxToken] = []
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == ch("\"") {
                let e = stringEnd(u, i, escapes: true)
                var j = e
                while j < u.count, isSpace(u[j]) { j += 1 }
                out.append(tok(i, e, at(u, j) == ch(":") ? .key : .string)); i = e
            } else if isDigit(c) || (c == ch("-") && isDigit(at(u, i + 1))) {
                var e = i + 1
                while e < u.count, isDigit(u[e]) || [ch("."), ch("e"), ch("E"), ch("+"), ch("-")].contains(u[e]) { e += 1 }
                out.append(tok(i, e, .number)); i = e
            } else if isIdentStart(c) {
                let e = wordEnd(u, i)
                if literalWords.contains(word(u, i, e)) { out.append(tok(i, e, .keyword)) }
                i = e
            } else {
                i += 1
            }
        }
        return out
    }

    private static func yaml(_ u: [UInt16]) -> [SyntaxToken] {
        var out: [SyntaxToken] = []
        var i = 0
        var lineStart = true // only indentation and list dashes seen since the newline
        while i < u.count {
            let c = u[i]
            if c == ch("\n") { lineStart = true; i += 1; continue }
            if isSpace(c) { i += 1; continue }
            if c == ch("-"), lineStart, at(u, i + 1) == 0 || isSpace(at(u, i + 1)) || at(u, i + 1) == ch("\n") {
                i += 1; continue
            }
            if c == ch("#"), i == 0 || isSpace(u[i - 1]) || u[i - 1] == ch("\n") {
                let e = lineEnd(u, i)
                out.append(tok(i, e, .comment)); i = e; continue
            }
            if c == ch("\"") || c == ch("'") {
                let e = stringEnd(u, i, escapes: c == ch("\""))
                out.append(tok(i, e, lineStart && at(u, e) == ch(":") ? .key : .string)); i = e
            } else if lineStart, let colon = keyColon(u, i) {
                var e = colon
                while e > i, isSpace(u[e - 1]) { e -= 1 }
                out.append(tok(i, e, .key)); i = colon + 1
            } else if isIdentStart(c) || isDigit(c) || c == ch("-") || c == ch(".") {
                var e = i + 1
                while e < u.count, isIdent(u[e]) || u[e] == ch(".") || u[e] == ch("-") { e += 1 }
                let w = word(u, i, e)
                if literalWords.contains(w) { out.append(tok(i, e, .keyword)) }
                else if Double(w) != nil { out.append(tok(i, e, .number)) }
                i = e
            } else {
                i += 1
            }
            lineStart = false
        }
        return out
    }

    private static func markdown(_ u: [UInt16]) -> [SyntaxToken] {
        var out: [SyntaxToken] = []
        var inFence = false
        var fenceStart = 0
        var ls = 0
        while ls <= u.count {
            let le = lineEnd(u, ls)
            if starts(u, ls, "```") {
                if inFence { out.append(tok(fenceStart, le, .string)) } else { fenceStart = ls }
                inFence.toggle()
            } else if !inFence {
                var hashes = 0
                while ls + hashes < le, u[ls + hashes] == ch("#") { hashes += 1 }
                if (1...6).contains(hashes), ls + hashes == le || u[ls + hashes] == ch(" ") {
                    out.append(tok(ls, le, .heading))
                } else {
                    var j = ls
                    while j < le {
                        if u[j] == ch("`"), let k = (j + 1..<le).first(where: { u[$0] == ch("`") }) {
                            out.append(tok(j, k + 1, .string)); j = k + 1
                        } else {
                            j += 1
                        }
                    }
                }
            }
            ls = le + 1
        }
        if inFence { out.append(tok(fenceStart, u.count, .string)) }
        return out
    }

    // MARK: scanning helpers

    private static func ch(_ s: Unicode.Scalar) -> UInt16 { UInt16(s.value) }
    private static func at(_ u: [UInt16], _ i: Int) -> UInt16 { i < u.count ? u[i] : 0 }
    private static func tok(_ a: Int, _ b: Int, _ role: SyntaxRole) -> SyntaxToken {
        SyntaxToken(range: NSRange(location: a, length: b - a), role: role)
    }
    private static func word(_ u: [UInt16], _ a: Int, _ b: Int) -> String { String(decoding: u[a..<b], as: UTF16.self) }
    private static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private static func isIdentStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
    private static func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) }
    private static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 }
    private static func isShellBoundary(_ c: UInt16) -> Bool {
        isSpace(c) || c == 10 || c == ch(";") || c == ch("|") || c == ch("&") || c == ch("(")
    }
    private static func wordEnd(_ u: [UInt16], _ i: Int) -> Int {
        var e = i + 1
        while e < u.count, isIdent(u[e]) { e += 1 }
        return e
    }
    private static func numberEnd(_ u: [UInt16], _ i: Int) -> Int {
        var e = i + 1
        while e < u.count, isIdent(u[e]) || (u[e] == ch(".") && isDigit(at(u, e + 1))) { e += 1 }
        return e
    }
    /// The index of the next newline, or the end of the text.
    private static func lineEnd(_ u: [UInt16], _ i: Int) -> Int {
        var e = i
        while e < u.count, u[e] != 10 { e += 1 }
        return e
    }
    private static func starts(_ u: [UInt16], _ i: Int, _ s: String) -> Bool {
        let p = Array(s.utf16)
        return i + p.count <= u.count && Array(u[i..<i + p.count]) == p
    }
    /// The index just after the next `s` at or after `from`, or the end of the text when it never closes.
    private static func end(of s: String, in u: [UInt16], from: Int) -> Int {
        var j = from
        while j < u.count { if starts(u, j, s) { return j + s.utf16.count }; j += 1 }
        return u.count
    }
    /// The index after the closing quote, or the end of the text when the string never closes.
    private static func stringEnd(_ u: [UInt16], _ i: Int, escapes: Bool) -> Int {
        let quote = u[i]
        var j = i + 1
        while j < u.count {
            if escapes, u[j] == ch("\\") { j += 2; continue }
            if u[j] == quote { return j + 1 }
            j += 1
        }
        return u.count
    }
    /// The colon that ends a YAML key starting at `i`: followed by a space or the line end, before any comment.
    private static func keyColon(_ u: [UInt16], _ i: Int) -> Int? {
        var j = i + 1 // a colon at `i` would make an empty key
        while j < u.count, u[j] != 10 {
            if u[j] == ch(":"), j + 1 >= u.count || isSpace(u[j + 1]) || u[j + 1] == 10 { return j }
            if u[j] == ch("#"), j > i, isSpace(u[j - 1]) { return nil }
            j += 1
        }
        return nil
    }
}
