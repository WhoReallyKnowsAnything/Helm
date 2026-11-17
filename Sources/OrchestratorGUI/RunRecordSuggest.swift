import Foundation

/// `planning.mjs trace suggest [--phase N]`: tweaks (`kind: suggest`) and receipts (`kind: info`) in seam order,
/// relayed unchanged (D-01, D-03). Separate from `CadenceSuggest`, which the board chip builds from.
struct RunRecordSuggest: Equatable {
    struct Entry: Equatable {
        var subject: String
        var evidence: String
        var action: String?
        var current: String?
        var direction: String?
        var proposed: String?

        /// A button is offered only when the seam priced a target.
        var isPriced: Bool { action != nil && proposed != nil }
    }

    var file: String
    var scope: String?
    var eventsRead: Int
    var tweaks: [Entry]
    var receipts: [Entry]

    static func run(_ scripts: CadenceLocator.Scripts, project: String, phase: String?) -> Result<RunRecordSuggest, CadenceLocator.Failure> {
        RunRecordSeam.run("suggest", scripts, project: project, phase: phase, parse: parse)
    }

    static func parse(_ text: String) -> Result<RunRecordSuggest, CadenceLocator.Failure> {
        switch RunRecordSeam.object(text, name: "suggest") {
        case .failure(let failure): return .failure(failure)
        case .success(let root):
            guard let list = root["suggestions"] as? [[String: Any]] else {
                return .failure(.init(reason: "Cadence trace suggest has no suggestion list."))
            }
            var tweaks: [Entry] = [], receipts: [Entry] = []
            for item in list {
                let entry = Entry(subject: RunRecordSeam.text(item["subject"]) ?? "", evidence: RunRecordSeam.text(item["evidence"]) ?? "",
                                  action: RunRecordSeam.text(item["action"]), current: RunRecordSeam.text(item["current"]),
                                  direction: RunRecordSeam.text(item["direction"]), proposed: RunRecordSeam.text(item["proposed"]))
                switch item["kind"] as? String {
                case "suggest": tweaks.append(entry)
                case "info": receipts.append(entry)
                default: break
                }
            }
            return .success(RunRecordSuggest(
                file: RunRecordSeam.text(root["file"]) ?? "", scope: RunRecordSeam.text(root["scope"]),
                eventsRead: (root["events_read"] as? NSNumber)?.intValue ?? 0, tweaks: tweaks, receipts: receipts))
        }
    }
}
