import Foundation

/// The fixed line the UAT screen sends into the verify worker, and the compare of what Cadence recorded (pure, no I/O).
enum UATResult {
    enum Kind: String, Equatable, CaseIterable {
        case pass, fail, skip, blocked

        /// The status word Cadence writes for this result.
        var recordedStatus: String { self == .skip ? "skipped" : rawValue }
        var needsText: Bool { self != .pass }
    }

    enum Built: Equatable {
        case line(String)
        case refused(String)
    }

    /// `UAT item <k>: pass` or `UAT item <k>: <kind> - <text>`. Only the current item is accepted (D-01).
    /// Text is flattened to one line and refused when empty or over the cap, never cut.
    static func build(item: String, kind: Kind, text: String?, firstPending: Int?) -> Built {
        guard !item.isEmpty, item.allSatisfy({ $0.isASCII && $0.isNumber }), let k = Int(item) else {
            return .refused("The item number is not a plain number.")
        }
        guard k == firstPending else { return .refused("Only the current item can get a result.") }
        guard kind.needsText else { return .line("UAT item \(k): pass") }
        guard let cleaned = InboxDelivery.clean(text ?? "", cap: InboxDelivery.requestMaxLength + 1) else {
            return .refused("Write a note first.")
        }
        guard cleaned.unicodeScalars.count <= InboxDelivery.requestMaxLength else {
            return .refused("The note is longer than \(InboxDelivery.requestMaxLength) characters.")
        }
        return .line("UAT item \(k): \(kind.rawValue) - \(cleaned)")
    }

    /// Whether the Send button of a note field may be on: the text is non-empty after cleaning.
    static func canSend(_ text: String) -> Bool {
        InboxDelivery.clean(text, cap: InboxDelivery.requestMaxLength + 1) != nil
    }

    enum Readback: Equatable {
        /// The item is still pending (or not in the file yet).
        case waiting
        case recorded(status: String, note: String?)
        case mismatch(String)

        /// The line drawn under the row.
        var text: String {
            switch self {
            case .waiting: return "waiting for the worker to record it"
            case .recorded(let status, _): return "recorded as \(status)"
            case .mismatch(let why): return "mismatch: \(why)"
            }
        }
    }

    /// Compares the status word only. The recorded note is shown as written, never compared.
    static func readback(sent: Kind, item: Int, items: [UATFile.Item]) -> Readback {
        guard let found = items.first(where: { $0.k == item }), found.status != "pending" else { return .waiting }
        guard found.status == sent.recordedStatus else {
            return .mismatch("sent \(sent.rawValue), recorded \(found.status)")
        }
        if sent.needsText, sent != .fail, (found.note ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return .mismatch("recorded without a reason")
        }
        return .recorded(status: found.status, note: found.note)
    }
}
