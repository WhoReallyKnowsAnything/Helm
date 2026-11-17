import Foundation

/// The questions of an AskUserQuestion request, decoded from its `input` (field names from PROBE.md).
/// Raw text is kept as received because the answer map is keyed by the question text; `display` fields are escaped for the screen.
enum QuestionInput {
    struct Option: Equatable {
        let label: String
        let description: String
        var labelDisplay: String { GateHold.displayText(label) }
        var descriptionDisplay: String { GateHold.displayText(description) }
    }

    struct Question: Equatable {
        let text: String
        let header: String?
        let options: [Option]
        let multiSelect: Bool
        var display: String { GateHold.displayText(text) }
        var headerDisplay: String? { header.map(GateHold.displayText) }
    }

    /// Empty when the input is not a card that can be answered: no questions, a question without text or options,
    /// an option without a label, or two questions with the same text (the answer map could not tell them apart).
    static func decode(_ input: Data) -> [Question] {
        guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let raw = object["questions"] as? [[String: Any]], !raw.isEmpty else { return [] }
        var questions: [Question] = []
        for item in raw {
            guard let text = item["question"] as? String, !text.isEmpty,
                  let rawOptions = item["options"] as? [[String: Any]], !rawOptions.isEmpty else { return [] }
            var options: [Option] = []
            for option in rawOptions {
                guard let label = option["label"] as? String, !label.isEmpty else { return [] }
                options.append(Option(label: label, description: option["description"] as? String ?? ""))
            }
            questions.append(Question(
                text: text, header: item["header"] as? String, options: options,
                multiSelect: item["multiSelect"] as? Bool ?? false))
        }
        return Set(questions.map(\.text)).count == questions.count ? questions : []
    }
}
