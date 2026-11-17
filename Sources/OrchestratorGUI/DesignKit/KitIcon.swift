import SwiftUI

/// Every icon the app uses. Views name a `KitIcon`; the SF Symbol strings appear only in this file.
/// One size and one weight (design/KIT.md). A selected row may use the filled form.
enum KitIcon: String, CaseIterable {
    case back = "chevron.left"
    case refresh = "arrow.clockwise"
    case reset = "arrow.counterclockwise"
    case merge = "arrow.triangle.merge"
    case openExternal = "arrow.up.right.square"
    case done = "checkmark.circle"
    case warning = "exclamationmark.triangle"
    case folder = "folder"
    case settings = "gear"
    case send = "paperplane"
    case run = "play.fill"
    case add = "plus"
    case stop = "stop.circle"
    case delete = "trash"
    case close = "xmark"

    static let size: CGFloat = 12
}

/// Replaces `Image(systemName:)`.
struct KitImage: View {
    let icon: KitIcon
    var filled = false

    init(_ icon: KitIcon, filled: Bool = false) {
        self.icon = icon
        self.filled = filled
    }

    var body: some View {
        Image(systemName: icon.rawValue)
            .symbolVariant(filled ? .fill : .none)
            .font(.system(size: KitIcon.size, weight: .regular))
    }
}

/// Replaces `Label(_, systemImage:)`. Only the icon gets the kit size, so the title keeps the font of its button.
struct KitLabel: View {
    let title: String
    let icon: KitIcon
    var filled = false

    init(_ title: String, icon: KitIcon, filled: Bool = false) {
        self.title = title
        self.icon = icon
        self.filled = filled
    }

    var body: some View {
        Label { Text(title) } icon: { KitImage(icon, filled: filled) }
    }
}
