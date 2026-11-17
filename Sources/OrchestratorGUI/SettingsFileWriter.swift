import Foundation

/// D-01: changes one member of a Claude Code settings file and keeps every other byte.
/// A small scanner finds the member's byte range. The file is never serialized whole, because a mangled
/// `~/.claude/settings.json` breaks the git gate registration (`onFailure: "block"`) and blocks every shell call.
enum SettingsFileWriter {
    struct Refusal: Error { let reason: String }

    /// Sets the member at `path` (`["model"]` or `["permissions", "defaultMode"]`) to the JSON text `value`.
    /// Returns the reason when a check fails. The file is then untouched.
    static func set(_ path: [String], to value: String, in file: String) -> String? {
        guard let expected = parse(Data(value.utf8)) else { return "Not a JSON value: \(value)" }
        return write(file) { try setting(path, to: value, in: $0) } check: { _, new in
            (lookup(new, path) as AnyObject?)?.isEqual(expected) == true
        }
    }

    /// A JSON string literal. `/` stays unescaped, because rules hold paths.
    static func jsonString(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    /// Replaces the member's value, or inserts the missing member after the last member of its object.
    static func setting(_ path: [String], to value: String, in bytes: [UInt8]) throws -> [UInt8] {
        let scan = Scan(b: bytes)
        var object = try scan.object(scan.space(0))
        for (depth, key) in path.enumerated() {
            guard let member = object.members.last(where: { $0.key == key }) else {
                return insert(path[depth...], value, into: object, bytes)
            }
            if depth == path.count - 1 { return splice(bytes, member.value, value) }
            object = try scan.object(member.value.lowerBound)
        }
        throw Refusal(reason: "No key to change.")
    }

    /// Inserts `"path[0]": value` with the indent and key gap of the last sibling, so a 1-line file stays 1 line.
    /// A longer path nests: a missing `permissions` gets an object holding only the target member.
    private static func insert(_ path: ArraySlice<String>, _ value: String, into object: Scan.Object, _ bytes: [UInt8]) -> [UInt8] {
        guard let sibling = object.members.last else {
            return splice(bytes, at: object.open + 1, Array(member(path, value, gap: ":").utf8))
        }
        let indent = String(decoding: Self.indent(before: sibling.keyStart, in: bytes), as: UTF8.self)
        let gap = String(decoding: bytes[sibling.keyEnd..<sibling.value.lowerBound], as: UTF8.self)
        return splice(bytes, at: sibling.value.upperBound, Array(("," + indent + member(path, value, gap: gap)).utf8))
    }

    private static func member(_ path: ArraySlice<String>, _ value: String, gap: String) -> String {
        let inner = path.dropFirst().reversed().reduce(value) { "{" + jsonString($1) + gap + $0 + "}" }
        return jsonString(path[path.startIndex]) + gap + inner
    }

    /// The blanks before `index`: the indent a new sibling copies.
    private static func indent(before index: Int, in bytes: [UInt8]) -> [UInt8] {
        var start = index
        while start > 0, Scan.blanks.contains(bytes[start - 1]) { start -= 1 }
        return Array(bytes[start..<index])
    }

    // MARK: - Permission rules

    /// Appends `rule` to `permissions.<list>` (allow, ask or deny). Returns the reason when it is refused.
    static func addRule(_ rule: String, to list: String, in file: String) -> String? {
        if let reason = invalid(rule) { return reason }
        return write(file) { try changingRule(rule, list, add: true, in: $0) } check: { ruleCheck(list, $0, $1) { $0 + [rule] } }
    }

    /// Removes `rule` and its separator, so a remove after an add gives back the original bytes.
    static func removeRule(_ rule: String, from list: String, in file: String) -> String? {
        write(file) { try changingRule(rule, list, add: false, in: $0) } check: { ruleCheck(list, $0, $1) { $0.filter { $0 != rule } } }
    }

    private static func invalid(_ rule: String) -> String? {
        if rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "A rule cannot be empty." }
        if rule.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return "A rule cannot hold a control character."
        }
        return nil
    }

    /// The new file must be the old one with only the list changed.
    private static func ruleCheck(_ list: String, _ old: [String: Any], _ new: [String: Any], change: ([String]) -> [String]) -> Bool {
        var permissions = old["permissions"] as? [String: Any] ?? [:]
        permissions[list] = change(permissions[list] as? [String] ?? [])
        var expected = old
        expected["permissions"] = permissions
        return (new as NSDictionary).isEqual(to: expected)
    }

    static func changingRule(_ rule: String, _ list: String, add: Bool, in bytes: [UInt8]) throws -> [UInt8] {
        let scan = Scan(b: bytes)
        let root = try scan.object(scan.space(0))
        let permissions = try root.members.last { $0.key == "permissions" }.map { try scan.object($0.value.lowerBound) }
        guard let array = permissions?.members.last(where: { $0.key == list }) else {
            guard add else { throw Refusal(reason: "\(rule) is not in \(list).") }
            return try setting(["permissions", list], to: "[" + jsonString(rule) + "]", in: bytes)
        }
        let elements = try scan.array(array.value.lowerBound)
        let at = elements.firstIndex { (try? JSONSerialization.jsonObject(with: Data(bytes[$0]), options: .fragmentsAllowed)) as? String == rule }
        if add {
            guard at == nil else { throw Refusal(reason: "\(rule) is already in \(list).") }
            let text = Array(jsonString(rule).utf8)
            guard let last = elements.last else { return splice(bytes, at: array.value.lowerBound + 1, text) }
            return splice(bytes, at: last.upperBound, [UInt8(ascii: ",")] + indent(before: last.lowerBound, in: bytes) + text)
        }
        guard let at else { throw Refusal(reason: "\(rule) is not in \(list).") }
        let cut = at > 0 ? elements[at - 1].upperBound..<elements[at].upperBound
            : elements.count > 1 ? elements[0].lowerBound..<elements[1].lowerBound : elements[0]
        return Array(bytes[..<cut.lowerBound]) + Array(bytes[cut.upperBound...])
    }

    // MARK: - File

    /// Reads, edits, checks, then writes a temp file with the original mode and renames it over the target.
    private static func write(_ file: String, edit: ([UInt8]) throws -> [UInt8],
                              check: (_ old: [String: Any], _ new: [String: Any]) -> Bool) -> String? {
        let fm = FileManager.default
        // The real path, so a symlinked settings file stays a link and its target gets the change.
        let target = FolderCheck.realPath(file)
        guard fm.fileExists(atPath: target) else { return create(target, edit: edit, check: check) }
        guard let original = fm.contents(atPath: target) else { return "Cannot read \(target)." }
        guard let old = parse(original) as? [String: Any] else { return "\(target) is not a JSON object, so it was not changed." }
        let changed: Data
        do { changed = Data(try edit([UInt8](original))) } catch {
            return (error as? Refusal)?.reason ?? "\(target) could not be read as settings, so it was not changed."
        }
        guard let new = parse(changed) as? [String: Any], check(old, new) else {
            return "The edit did not check out, so \(target) was not changed."
        }
        guard let mode = (try? fm.attributesOfItem(atPath: target))?[.posixPermissions] as? Int else {
            return "Cannot read the mode of \(target)."
        }
        let folder = (target as NSString).deletingLastPathComponent
        let temp = folder + "/.settings-\(UUID().uuidString).tmp"
        guard fm.createFile(atPath: temp, contents: changed, attributes: [.posixPermissions: mode]) else {
            return "Cannot write in \(folder)."
        }
        guard fm.contents(atPath: target) == original else {
            try? fm.removeItem(atPath: temp)
            return "\(target) changed while the edit ran, so it was not changed."
        }
        guard rename(temp, target) == 0 else {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(atPath: temp)
            return "Cannot replace \(target): \(reason)"
        }
        return nil
    }

    /// A missing file (D-07): only the target member, mode 0600, and its folder (`.claude`) when that is missing.
    /// `link` refuses when a file appeared meanwhile, so a file written by someone else is never replaced.
    private static func create(_ target: String, edit: ([UInt8]) throws -> [UInt8],
                               check: (_ old: [String: Any], _ new: [String: Any]) -> Bool) -> String? {
        let fm = FileManager.default
        let folder = (target as NSString).deletingLastPathComponent
        let created: Data
        do { created = Data(try edit(Array("{}".utf8))) } catch { return (error as? Refusal)?.reason ?? "Cannot build \(target)." }
        guard let new = parse(created) as? [String: Any], check([:], new) else { return "The new file did not check out." }
        do { try fm.createDirectory(atPath: folder, withIntermediateDirectories: true) } catch {
            return "Cannot create \(folder): \(error.localizedDescription)"
        }
        let temp = folder + "/.settings-\(UUID().uuidString).tmp"
        guard fm.createFile(atPath: temp, contents: created, attributes: [.posixPermissions: 0o600]) else {
            return "Cannot write in \(folder)."
        }
        defer { try? fm.removeItem(atPath: temp) }
        guard link(temp, target) == 0 else { return "Cannot create \(target): \(String(cString: strerror(errno)))" }
        return nil
    }

    // MARK: - Bytes

    private static func parse(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    private static func lookup(_ root: [String: Any], _ path: [String]) -> Any? {
        path.dropLast().reduce(root as Any?) { ($0 as? [String: Any])?[$1] }
            .flatMap { ($0 as? [String: Any])?[path[path.count - 1]] }
    }

    private static func splice(_ bytes: [UInt8], _ range: Range<Int>, _ text: String) -> [UInt8] {
        Array(bytes[..<range.lowerBound]) + Array(text.utf8) + Array(bytes[range.upperBound...])
    }

    private static func splice(_ bytes: [UInt8], at index: Int, _ text: [UInt8]) -> [UInt8] {
        Array(bytes[..<index]) + text + Array(bytes[index...])
    }

    /// Byte ranges of JSON values. It knows strings (escapes included), literals, numbers and nesting,
    /// so a `"model"` inside a string or inside another object is never taken for a member.
    struct Scan {
        struct Member { let key: String; let keyStart: Int; let keyEnd: Int; let value: Range<Int> }
        struct Object { let open: Int; let members: [Member]; let close: Int }

        let b: [UInt8]
        private static let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        private static let openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}")
        private static let openBracket = UInt8(ascii: "["), closeBracket = UInt8(ascii: "]")
        private static let comma = UInt8(ascii: ","), colon = UInt8(ascii: ":")
        static let blanks: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        private var bad: Refusal { Refusal(reason: "The file could not be read as settings, so it was not changed.") }

        func space(_ start: Int) -> Int {
            var i = start
            while i < b.count, Self.blanks.contains(b[i]) { i += 1 }
            return i
        }

        /// `start` is on the opening quote. Returns the index after the closing quote.
        func stringEnd(_ start: Int) throws -> Int {
            var i = start + 1
            while i < b.count {
                if b[i] == Self.backslash { i += 2 } else if b[i] == Self.quote { return i + 1 } else { i += 1 }
            }
            throw bad
        }

        func valueEnd(_ start: Int) throws -> Int {
            guard start < b.count else { throw bad }
            if b[start] == Self.quote { return try stringEnd(start) }
            if b[start] == Self.openBrace || b[start] == Self.openBracket {
                var depth = 0, i = start
                while i < b.count {
                    if b[i] == Self.quote { i = try stringEnd(i); continue }
                    if b[i] == Self.openBrace || b[i] == Self.openBracket { depth += 1 }
                    if b[i] == Self.closeBrace || b[i] == Self.closeBracket {
                        depth -= 1
                        if depth == 0 { return i + 1 }
                    }
                    i += 1
                }
                throw bad
            }
            var i = start
            while i < b.count, ![Self.comma, Self.closeBrace, Self.closeBracket].contains(b[i]), !Self.blanks.contains(b[i]) { i += 1 }
            guard i > start else { throw bad }
            return i
        }

        /// The element ranges of the array whose `[` is at `open`.
        func array(_ open: Int) throws -> [Range<Int>] {
            guard open < b.count, b[open] == Self.openBracket else {
                throw Refusal(reason: "The rule list is not an array, so the file was not changed.")
            }
            var elements: [Range<Int>] = []
            var i = space(open + 1)
            if i < b.count, b[i] == Self.closeBracket { return [] }
            while true {
                let end = try valueEnd(i)
                elements.append(i..<end)
                i = space(end)
                guard i < b.count else { throw bad }
                if b[i] == Self.closeBracket { return elements }
                guard b[i] == Self.comma else { throw bad }
                i = space(i + 1)
            }
        }

        /// The members of the object whose `{` is at `open`.
        func object(_ open: Int) throws -> Object {
            guard open < b.count, b[open] == Self.openBrace else {
                throw Refusal(reason: "The settings value is not an object, so the file was not changed.")
            }
            var members: [Member] = []
            var i = space(open + 1)
            if i < b.count, b[i] == Self.closeBrace { return Object(open: open, members: [], close: i) }
            while true {
                guard i < b.count, b[i] == Self.quote else { throw bad }
                let keyEnd = try stringEnd(i)
                guard let key = (try? JSONSerialization.jsonObject(with: Data(b[i..<keyEnd]), options: .fragmentsAllowed)) as? String else { throw bad }
                var j = space(keyEnd)
                guard j < b.count, b[j] == Self.colon else { throw bad }
                j = space(j + 1)
                let end = try valueEnd(j)
                members.append(Member(key: key, keyStart: i, keyEnd: keyEnd, value: j..<end))
                i = space(end)
                guard i < b.count else { throw bad }
                if b[i] == Self.closeBrace { return Object(open: open, members: members, close: i) }
                guard b[i] == Self.comma else { throw bad }
                i = space(i + 1)
            }
        }
    }
}
