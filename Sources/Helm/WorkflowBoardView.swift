import SwiftUI

/// The Board tab: the stage action row (Next is the one primary), then the workflow state. On a failure it shows the reason and nothing else.
struct WorkflowBoardView: View {
    let board: WorkflowBoard?
    let failure: String?
    var panel: WorkflowPanel?
    var message: String?
    var overlays: [String: WorkflowOverlay] = [:]
    /// A label a refused press found held: the Clear offer.
    var held: String?
    var onClear: (String) -> Void = { _ in }
    /// The picked phase. Next acts on the cursor's target, so it is off for any other phase.
    var phase: String?
    var executePhases: Set<String> = []
    var onOpenExecute: (String) -> Void = { _ in }
    /// Gate holds shown read-only on their phase row. Approve and Deny stay in the project hold bar (D-02).
    var holds: [GateHold] = []
    var onPress: () -> Void = {}
    var onChip: (CadenceChip) -> Void = { _ in }
    /// True when the line was sent, so the field clears. The reason lives only in this view's state.
    var onOverride: (String) async -> Bool = { _ in false }
    @State private var overriding = false
    @State private var reason = ""
    @State private var collapsed = false
    @State private var showDetails = false
    @State private var showConfig = false

    var body: some View {
        if let failure {
            KitFooterLine { Text(failure).fixedSize(horizontal: false, vertical: true) }
        } else if let board {
            VStack(alignment: .leading, spacing: Space.sm) {
                KitStageActionRow(primaryTitle: panel?.next.map { "Next: \($0.stage.rawValue.capitalized)" } ?? "Next",
                                  primaryReason: primaryReason, menuTitle: menuChips.isEmpty ? nil : "Suggested",
                                  onPrimary: onPress, secondary: { secondary(board) }, menu: { chipItems(menuChips) })
                VStack(alignment: .leading, spacing: Space.sm) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(board.milestone).kitType(.title).foregroundStyle(Ink.text)
                        Text(WorkflowBoardRows.progress(board)).kitType(.body).foregroundStyle(Ink.textSecondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    if let health = board.health { healthStrip(health) }
                    if !collapsed { details(board) }
                }
                .padding(.horizontal, Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var primaryReason: String? { panel.nextReason(phase: phase) }
    private var menuChips: [CadenceChip] {
        board.map { WorkflowBoardRows.splitChips($0.chips, rows: $0.rows).menu } ?? []
    }

    @ViewBuilder private func secondary(_ board: WorkflowBoard) -> some View {
        if panel?.override != nil {
            if overriding {
                TextField("Reason for the override", text: $reason).textFieldStyle(.roundedBorder)
                Button { Task { if await onOverride(reason) { reason = ""; overriding = false } } } label: { Text("Send") }
                    .buttonStyle(.kit)
            } else {
                Button { overriding = true } label: { Text("Override") }.buttonStyle(.kit)
            }
        }
        Button { collapsed.toggle() } label: { Text(collapsed ? "Show" : "Hide") }.buttonStyle(.kit)
    }

    @ViewBuilder private func chipItems(_ chips: [CadenceChip]) -> some View {
        ForEach(chips, id: \.label) { chip in
            let name = chip.skill.replacingOccurrences(of: "/cadence:", with: "")
            let head = chip.phase.map { "\(name) \($0)" } ?? name
            Button { onChip(chip) } label: {
                Text([head, chip.rule, panel?.utilityText, chip.innerRole].compactMap { $0 }.joined(separator: "  |  "))
            }
            .disabled(panel?.chipsOff != nil)
        }
    }

    private func details(_ board: WorkflowBoard) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let check = board.configCheck { configCheck(check) }
            let split = WorkflowBoardRows.splitChips(board.chips, rows: board.rows)
            ForEach(Array(board.rows.enumerated()), id: \.offset) { _, row in
                let overlay = overlays[row.n]
                let hold = WorkflowBoardRows.holds(holds, phase: row.n).first
                KitBoardRow(number: row.n, name: row.name, stage: label(row.display), cursor: row.n == panel?.next?.phase,
                            status: overlay.map(WorkflowBoardRows.mark), holdText: hold.map { "hold: \($0.label)" }) {
                    if let overlay, overlay.state == .dead { clearButton(overlay.label) }
                    if executePhases.contains(row.n) {
                        Button { onOpenExecute(row.n) } label: { Text("Open Execute") }.buttonStyle(.kit)
                    }
                    ForEach(split.onRows[row.n] ?? [], id: \.label) { chipButton($0) }
                }
            }
            if let held, !overlays.values.contains(where: { $0.label == held && $0.state == .dead }) { clearButton(held) }
            if let message { Text(message).kitType(.body).foregroundStyle(Ink.textSecondary) }
            DisclosureGroup(isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    if let target = panel?.next { Text(target.routingText) }
                    if let config = board.config { Text("plan check: \(config.planCheck ? "on" : "off")") }
                    if let ahead = board.skipAhead { Text(aheadLine(ahead)) }
                    ForEach(panel?.roles ?? [], id: \.name) { role in Text("\(role.name): \(role.text)") }
                    if let why = panel?.chipsOff, !board.chips.isEmpty { Text(why) }
                    if let reason = board.suggestReason { Text("suggest: \(reason)") }
                }
                .kitType(.meta).foregroundStyle(Ink.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Space.xs)
            } label: {
                Text(board.next.map { nextLine($0, hint: board.status?.cursorNext) } ?? "Details")
                    .kitType(.body).foregroundStyle(Ink.text)
            }
            .kitAnimation(.reveal, value: showDetails)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func healthStrip(_ health: CadenceHealth) -> some View {
        HStack(spacing: Space.md) {
            ForEach(health.lines, id: \.label) { line in
                Text("\(line.label): \(line.text)")
                    .kitType(.meta)
                    .foregroundStyle(line.warning ? Ink.waiting : Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func configCheck(_ check: Result<CadenceConfigCheck, CadenceLocator.Failure>) -> some View {
        let differing: Int? = { if case .success(let found) = check { return found.rows.filter(\.differs).count } else { return nil } }()
        DisclosureGroup(isExpanded: $showConfig) {
          VStack(alignment: .leading, spacing: Space.xs) {
            switch check {
            case .failure(let problem):
                Text(problem.reason).kitType(.meta).foregroundStyle(Ink.textSecondary)
            case .success(let found):
                let fixOff = panel?.chipsOff != nil || panel?.configHold != nil
                ForEach(found.rows, id: \.key) { row in
                    HStack(spacing: Space.sm) {
                        Text("\(row.differs ? "!" : " ") \(row.key): \(row.current?.text ?? "unset") (recommended \(row.recommended.text))")
                            .kitType(.meta)
                            .foregroundStyle(row.differs ? Ink.waiting : Ink.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let fix = found.fixChip(key: row.key) {
                            Button { onChip(fix) } label: { Text("Fix") }.buttonStyle(.kit).disabled(fixOff)
                        }
                    }
                }
                if let fixAll = found.fixAllChip() {
                    Button { onChip(fixAll) } label: { Text("Fix All") }.buttonStyle(.kit).disabled(fixOff)
                }
                if let hold = panel?.configHold {
                    Text("\(WorkflowStore.configLabel): \(hold.holdText). Fix is off until it is merged or cleared.")
                        .kitType(.meta).foregroundStyle(Ink.textSecondary)
                    clearButton(WorkflowStore.configLabel)
                }
                ForEach(found.warnings, id: \.self) { Text($0).kitType(.meta).foregroundStyle(Ink.waiting) }
            }
          }
          .padding(.top, Space.xs)
        } label: {
            let text = differing.map { $0 == 0 ? "Config: all as recommended" : "Config: \($0) differ" } ?? "Config: unreadable"
            Text(text).kitType(.body).foregroundStyle((differing ?? 1) > 0 ? Ink.waiting : Ink.text)
        }
        .kitAnimation(.reveal, value: showConfig)
    }

    private func chipButton(_ chip: CadenceChip) -> some View {
        Button { onChip(chip) } label: { Text(chip.skill.replacingOccurrences(of: "/cadence:cad-", with: "")) }
            .buttonStyle(.kit)
            .disabled(panel?.chipsOff != nil)
            .help([chip.rule, panel?.utilityText, chip.innerRole].compactMap { $0 }.joined(separator: " | "))
    }

    private func clearButton(_ label: String) -> some View {
        Button { onClear(label) } label: { Text("Clear \(label)") }
            .buttonStyle(.kit)
            .help("Stops the worker and frees the label. The branch stays as an orphaned session branch.")
    }

    private func nextLine(_ next: WorkflowGates.Next, hint: String?) -> String {
        guard let stage = next.stage else { return "next: none. \(next.reason ?? "")" }
        let phase = next.phase.map { " (phase \($0))" } ?? ""
        return "next: \(stage.rawValue)\(phase)" + (hint.map { "  Cadence hint: \($0)" } ?? "")
    }

    private func aheadLine(_ ahead: WorkflowBoard.SkipAhead) -> String {
        switch ahead.verdict {
        case .allowed: return "after that: \(ahead.stage.rawValue), allowed"
        case .blocked(let reason): return "after that: \(ahead.stage.rawValue), blocked. \(reason)"
        }
    }

    private func label(_ display: WorkflowStageMap.Display) -> String {
        switch display {
        case .stage(let stage): return stage.rawValue
        case .unknown(let text): return text
        }
    }
}

extension Optional where Wrapped == WorkflowPanel {
    /// Why the Next press is off for the picked phase, or nil. Next acts on the cursor's target, never on another phase.
    func nextReason(phase: String?) -> String? {
        guard let panel = self else { return "no next step" }
        if case .off(let why) = panel.button { return why }
        if let phase, let target = panel.next, target.phase != phase {
            return "Next acts on phase \(target.phase), not phase \(phase)"
        }
        return nil
    }
}
