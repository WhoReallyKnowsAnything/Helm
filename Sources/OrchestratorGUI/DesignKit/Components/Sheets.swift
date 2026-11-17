import SwiftUI

/// The content scaffold of a sheet (Dispatch, Merge, Teardown, New project). The sheet window itself stays native (D-09).
/// `width` is one of `SheetWidth`. Controls in `content` take their height from `.controlSize`, never from a fixed height.
/// Escape runs Cancel and Return runs the primary action.
struct KitSheetFrame<Content: View>: View {
    let title: String
    let width: CGFloat
    var failure: String?
    var progress: String?
    /// Nil with a nil `primary` for a sheet whose rows carry their own action (Dispatch): only the cancel button shows.
    var primaryTitle: String?
    var primaryEnabled = true
    /// "Close" for a sheet with no primary action.
    var cancelTitle = "Cancel"
    /// False while a run cannot be abandoned (Merge, Teardown).
    var cancelEnabled = true
    let cancel: () -> Void
    var primary: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(title).kitType(.title).foregroundStyle(Ink.text)
            content
            if let failure {
                Text(verbatim: failure).kitType(.meta).foregroundStyle(Ink.textSecondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let progress {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text(progress).kitType(.meta).foregroundStyle(Ink.muted)
                }
            }
            HStack(spacing: Space.sm) {
                Spacer()
                Button(cancelTitle, action: cancel).buttonStyle(.kit).keyboardShortcut(.cancelAction)
                    .disabled(!cancelEnabled)
                if let primaryTitle, let primary {
                    Button(primaryTitle, action: primary).buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
                        .disabled(!primaryEnabled)
                }
            }
        }
        .padding(Space.xl)
        .frame(width: width)
        .background(Ink.panel)
    }
}
