import SwiftUI

/// One phase on the workflow board, left to right: cursor mark, phase number and name, stage, an optional worker status
/// mark, an optional read-only hold mark, and the row's action buttons at the right end. The hold mark has no buttons:
/// Approve and Deny stay in the project hold bar (D-02).
struct KitBoardRow<Actions: View>: View {
    let number: String
    let name: String
    let stage: String
    var cursor = false
    /// Status colour and the overlay's own text, because `KitStatusText` prints the raw status word.
    var status: (status: WorkerStatus, text: String)?
    var holdText: String?
    let actions: Actions

    init(number: String, name: String, stage: String, cursor: Bool = false,
         status: (status: WorkerStatus, text: String)? = nil, holdText: String? = nil,
         @ViewBuilder actions: () -> Actions) {
        self.number = number
        self.name = name
        self.stage = stage
        self.cursor = cursor
        self.status = status
        self.holdText = holdText
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(cursor ? ">" : "").kitType(.meta).foregroundStyle(Ink.accent.text)
                .frame(width: Space.md, alignment: .leading)
            Text("\(number) \(name)").kitType(.label).foregroundStyle(Ink.text).lineLimit(1)
            Text(stage).kitType(.meta).foregroundStyle(Ink.textSecondary).lineLimit(1)
            if let status {
                HStack(spacing: Space.xs) {
                    KitStatusDot(status: status.status)
                    Text(status.text).kitType(.meta).foregroundStyle(status.status.ink)
                }
            }
            if let holdText {
                HStack(spacing: Space.xs) {
                    Circle().fill(Ink.waiting).frame(width: Metric.statusDot, height: Metric.statusDot).accessibilityHidden(true)
                    Text(holdText).kitType(.meta).foregroundStyle(Ink.waiting)
                }
            }
            Spacer(minLength: Space.sm)
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
