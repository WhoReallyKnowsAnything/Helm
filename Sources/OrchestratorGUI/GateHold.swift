import CryptoKit
import Foundation

/// One gate hold as the orchestrator's hook wrote it to `<project>/.claude/gate-holds/<id>.pending` (D-01).
/// Hold files are untrusted input (D-07): every field here has passed its pattern, and only `.live` may be answered.
struct GateHold: Equatable {
    /// Checked in this order: decided, ghost, tampered, else live (D-02, D-03, D-07).
    enum State: Equatable { case live, decided, ghost, tampered }

    let id: String
    let label: String
    /// Line 2 as written. A live hold's is 64 lowercase hex characters and equals the sha256 of the op text.
    let hash: String
    /// nil when line 4 is not a number: such a hold sorts last.
    let epoch: Int?
    let state: State
    /// The whole op text for display, control characters made visible. Never the raw bytes.
    let command: String

    /// The identity a button is drawn with. Two holds with one id but another hash are two holds.
    var key: String { "gate:\(id):\(hash)" }

    /// What a card says about a hold that cannot be answered. A live hold needs no line.
    var stateLine: String? {
        switch state {
        case .live: nil
        case .decided: "decided"
        case .tampered: "tampered hold"
        case .ghost: "hook ended"
        }
    }

    /// The pure part: no disk. `isHookLive` gets the PID and the start time of line 6 and is only asked for a hold
    /// that is not decided. nil means there is nothing safe to show or press (bad id, bad label, short header).
    static func parse(
        id: String, pending: Data, decision: Data?, isHookLive: (Int32, String) -> Bool
    ) -> GateHold? {
        guard matches(id, first: idChar, rest: idChar, max: 128) else { return nil }
        var lines: [String] = []
        var cut = pending.startIndex
        for index in pending.indices where pending[index] == 0x0A {
            lines.append(String(decoding: pending[cut..<index], as: UTF8.self))
            cut = pending.index(after: index)
            if lines.count == 6 { break }
        }
        guard lines.count == 6, matches(lines[0], first: labelFirst, rest: labelRest, max: .max) else { return nil }
        // Every raw byte after the 6th LF. The gate hashes these bytes, not the cleaned text.
        let op = pending[cut...]
        let hash = lines[1]
        let state: State
        if isDecided(decision, hash: hash) {
            state = .decided
        } else if !hookIsLive(pid: lines[2], started: lines[5], check: isHookLive) {
            state = .ghost
        } else if !isHash(hash) || sha256Hex(op) != hash {
            state = .tampered
        } else {
            state = .live
        }
        let epoch = lines[3].allSatisfy(\.isASCII) && lines[3].allSatisfy(\.isNumber) ? Int(lines[3]) : nil
        let text = String(decoding: op, as: UTF8.self)
        return GateHold(id: id, label: lines[0], hash: hash, epoch: epoch, state: state,
                        command: displayText(text))
    }

    /// Oldest first (D-13), ties by id, a non-numeric epoch last.
    static func isOrderedBefore(_ a: GateHold, _ b: GateHold) -> Bool {
        switch (a.epoch, b.epoch) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.id < b.id
        }
    }

    /// Exactly `allow <hash>` or `deny <hash>`, at most one trailing LF. A CR, other case, a wrong or short hash, or extra tokens: not decided.
    static func isDecided(_ decision: Data?, hash: String) -> Bool {
        guard var bytes = decision.map({ Array($0) }) else { return false }
        if bytes.last == 0x0A { bytes.removeLast() }
        return bytes == Array("allow \(hash)".utf8) || bytes == Array("deny \(hash)".utf8)
    }

    /// The whole op, nothing removed or cut. Control (Cc), format (Cf, which hold the bidi marks), line and paragraph
    /// separators and spaces other than " " are shown as `\n`, `\t`, `\r` or `\u{XXXX}`, so no character is hidden.
    static func displayText(_ raw: String) -> String {
        var text = ""
        for scalar in raw.unicodeScalars {
            switch (scalar, scalar.properties.generalCategory) {
            case ("\n", _): text += "\\n"
            case ("\t", _): text += "\\t"
            case ("\r", _): text += "\\r"
            case (_, .control), (_, .format), (_, .lineSeparator), (_, .paragraphSeparator): text += escape(scalar)
            case (_, .spaceSeparator) where scalar != " ": text += escape(scalar)
            default: text.unicodeScalars.append(scalar)
            }
        }
        return text
    }

    private static func escape(_ scalar: Unicode.Scalar) -> String { "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}" }

    static func isHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    private static func sha256Hex(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// `^[1-9][0-9]*$`, not 1, then the injected check.
    private static func hookIsLive(pid text: String, started: String, check: (Int32, String) -> Bool) -> Bool {
        guard matches(text, first: { $0 >= 0x31 && $0 <= 0x39 }, rest: { $0 >= 0x30 && $0 <= 0x39 }, max: 10),
              let pid = Int32(text), pid != 1 else { return false }
        return check(pid, started)
    }

    private static let idChar: (UInt8) -> Bool = {
        ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2D
    }
    private static let labelFirst: (UInt8) -> Bool = {
        ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2E || $0 == 0x5F
    }
    private static let labelRest: (UInt8) -> Bool = { labelFirst($0) || $0 == 0x2D }

    private static func matches(_ text: String, first: (UInt8) -> Bool, rest: (UInt8) -> Bool, max: Int) -> Bool {
        let bytes = Array(text.utf8)
        guard let head = bytes.first, bytes.count <= max, first(head) else { return false }
        return bytes.dropFirst().allSatisfy(rest)
    }
}
