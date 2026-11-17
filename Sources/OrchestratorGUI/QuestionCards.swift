import SwiftUI

/// How a card reaches the question side of the request store. `none` is a store with no questions, so every request
/// draws the allow/deny card.
struct QuestionBinding {
    var questions: (RequestStore.Entry) -> [QuestionInput.Question] = { _ in [] }
    var picks: (_ key: String) -> [String: [String]] = { _ in [:] }
    var canSend: (RequestStore.Entry) -> Bool = { _ in false }
    var onPick: (_ key: String, _ question: String, _ label: String) -> Void = { _, _, _ in }
    var onSend: (_ key: String) -> Void = { _ in }
    /// The highlighted row of a card and the key entry point of the store. With the defaults no key is handled.
    var highlight: (_ key: String) -> Int? = { _ in nil }
    var onKey: (_ key: String, _ press: RequestStore.KeyPress) -> Bool = { _, _ in false }

    /// Typed text as the answer of one question. Nil by default: only a screen that asks for it (execute) draws the text field.
    var onType: ((_ key: String, _ question: String, _ text: String) -> Void)?

    /// Decline needs a second click ("Confirm Decline"). Nil by default: a card with no store declines at once.
    var onDecline: ((_ key: String) -> Void)?
    var declineArmed: (_ key: String) -> Bool = { _ in false }

    static let none = QuestionBinding()

    /// This binding with the typed-answer handler set from `store`.
    @MainActor func withTypedAnswers(_ store: RequestStore) -> QuestionBinding {
        var copy = self
        copy.onType = { store.typeAnswer($0, question: $1, text: $2) }
        return copy
    }

    @MainActor init(_ store: RequestStore) {
        questions = store.questions(for:)
        picks = store.picks(for:)
        canSend = store.canSend(_:)
        onPick = { store.pick($0, question: $1, label: $2) }
        onSend = store.send
        highlight = store.highlight(for:)
        onDecline = store.declineClicked
        declineArmed = store.isDeclineArmed
        onKey = { store.handle($1, for: $0) }
    }

    init() {}
}

extension RequestStore.KeyPress {
    init(_ press: SwiftUI.KeyPress) {
        let modified = !press.modifiers.isDisjoint(with: [.command, .control, .option])
        switch press.key {
        case .upArrow: self.init(key: .up, modified: modified)
        case .downArrow: self.init(key: .down, modified: modified)
        case .return: self.init(key: .enter, modified: modified)
        default:
            if let n = Int(press.characters), (1...9).contains(n) { self.init(key: .digit(n), modified: modified) }
            else { self.init(key: .other, modified: modified) }
        }
    }
}

/// Makes a card focusable and routes its key-downs (UAT 8). Escape never goes to the store: `onEscape` interrupts the
/// session (D-08), and with no `onEscape` the key travels on. Every other key travels on unless the store used it.
struct CardKeys: ViewModifier {
    let key: String
    let binding: QuestionBinding
    var onEscape: (() -> Void)?
    @FocusState private var focused: Bool

    /// Handles one key. A test calls it without a key event.
    static func route(_ press: RequestStore.KeyPress, isEscape: Bool, key: String, binding: QuestionBinding,
                      onEscape: (() -> Void)?) -> Bool {
        if isEscape {
            guard let onEscape else { return false }
            onEscape()
            return true
        }
        return binding.onKey(key, press)
    }

    /// A half-typed message is never taken over: no claim while a text view in the key window holds text.
    /// Only an editable view counts: the read-only transcript holds text and often the focus, and must not block the box.
    @MainActor static func mayClaimFocus(in window: NSWindow? = NSApp.keyWindow) -> Bool {
        guard let text = window?.firstResponder as? NSTextView, text.isEditable else { return true }
        return text.string.isEmpty
    }

    /// A text field inside the card is being edited: its keys stay in the field (digits, arrows and Return pick nothing).
    @MainActor static func fieldIsEditing(in window: NSWindow? = NSApp.keyWindow) -> Bool {
        (window?.firstResponder as? NSTextView)?.isEditable == true
    }

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(phases: .down) { press in
                if press.key != .escape, Self.fieldIsEditing() { return .ignored }
                return Self.route(.init(press), isEscape: press.key == .escape, key: key, binding: binding, onEscape: onEscape)
                    ? .handled : .ignored
            }
            .onAppear { if Self.mayClaimFocus() { focused = true } }
            .simultaneousGesture(TapGesture().onEnded { focused = true })
    }
}

/// One AskUserQuestion card (D-03), built on `KitHoldCard`. Options only select; Send and Decline are the only buttons that answer.
/// Keys (arrows, digits, Return) go through `CardKeys` to the store; there is no default action. No arming delay: a pick is a
/// deliberate choice on text that is already shown.
struct QuestionCard: View {
    let entry: RequestStore.Entry
    let state: RequestStore.Card
    let binding: QuestionBinding
    let onDecline: (_ key: String) -> Void
    var onScreen = true
    /// Called for Escape on a focused card (D-08). Nil: Escape travels on.
    var onEscape: (() -> Void)?
    /// `RequestStore.stamp`, so a pick redraws a mounted card.
    var stamp = 0

    /// What a click does. A test calls these without a click.
    func pick(_ question: String, _ label: String) { binding.onPick(entry.key, question, label) }
    func send() { binding.onSend(entry.key) }
    func decline() { onDecline(entry.key) }

    /// The whole option text: label and description, never cut.
    static func optionText(_ option: QuestionInput.Option, selected: Bool, highlighted: Bool = false) -> String {
        let text = option.description.isEmpty ? option.labelDisplay : "\(option.labelDisplay) - \(option.descriptionDisplay)"
        return (highlighted ? "> " : "") + (selected ? "[x] " : "[ ] ") + text
    }

    /// The row of an option in the flat list the highlight walks.
    private func row(_ question: QuestionInput.Question, _ option: QuestionInput.Option, in all: [QuestionInput.Question]) -> Int {
        let before = all.prefix { $0.text != question.text }.reduce(0) { $0 + $1.options.count }
        return before + (question.options.firstIndex { $0.label == option.label } ?? 0)
    }

    var body: some View {
        let questions = binding.questions(entry)
        let chosen = binding.picks(entry.key)
        let high = binding.highlight(entry.key)
        KitHoldCard(stateLine: state.stateLine, outcome: state.outcome) {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(questions, id: \.text) { question in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        if let header = question.headerDisplay {
                            Text(header).kitType(.section).foregroundStyle(Ink.text)
                        }
                        Text(question.display).kitType(.meta).foregroundStyle(Ink.textSecondary)
                        if state.showsButtons || state.outcome != nil {
                            ForEach(question.options, id: \.label) { option in
                                optionButton(question, option, selected: chosen[question.text]?.contains(option.label) == true,
                                             highlighted: high == row(question, option, in: questions))
                            }
                            if binding.onType != nil { typedField(question) }
                        }
                    }
                }
            }
        } decision: {
            if state.showsButtons {
                KitButtonPair {
                    Button { send() } label: { Text("Send") }
                        .buttonStyle(.kit)
                        .disabled(!(binding.canSend(entry) && onScreen))
                        .accessibilityLabel("Send answers \(entry.request.toolName)")
                    Button { decline() } label: { Text(binding.declineArmed(entry.key) ? "Confirm Decline" : "Decline") }
                        .buttonStyle(.kit)
                        .disabled(!state.enabled)
                        .accessibilityLabel("Decline \(entry.request.toolName)")
                }
            }
        }
        .modifier(CardKeys(key: entry.key, binding: binding, onEscape: onEscape))
    }

    @State private var typed: [String: String] = [:]

    /// What the "Use this answer" button does. A test calls it without a click.
    func useTyped(_ question: String, _ text: String) { binding.onType?(entry.key, question, text) }

    private func typedField(_ question: QuestionInput.Question) -> some View {
        HStack(spacing: Space.xs) {
            TextField("", text: Binding(get: { typed[question.text] ?? "" }, set: { typed[question.text] = $0 }),
                      prompt: Text("or type your own answer"))
                .disabled(!state.enabled)
            Button { useTyped(question.text, typed[question.text] ?? "") } label: { Text("Use This Answer") }
                .buttonStyle(.kit)
                .disabled(!state.enabled || (typed[question.text] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Use typed answer for \(question.display)")
        }
    }

    private func optionButton(_ question: QuestionInput.Question, _ option: QuestionInput.Option, selected: Bool,
                              highlighted: Bool) -> some View {
        Button { pick(question.text, option.label) } label: { Text(Self.optionText(option, selected: selected, highlighted: highlighted)) }
            .buttonStyle(.kitPrompt)
            .disabled(!state.enabled)
            .accessibilityLabel(option.labelDisplay)
            .accessibilityValue(selected ? "selected" : "not selected")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
