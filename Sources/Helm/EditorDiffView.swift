import SwiftUI

/// D-06: the saved file's change against HEAD, one row per line. Lazy, so a long diff stays responsive.
struct EditorDiffView: View {
    let blocks: [DiffBlock]

    var body: some View {
        if blocks.isEmpty {
            KitNotice(text: "No changes against HEAD")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.none) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        if index > 0 { Divider().overlay(Ink.border) }
                        ForEach(Array(block.lines.enumerated()), id: \.offset) { _, line in
                            row(line)
                        }
                    }
                }
            }
            .background(Ink.background)
        }
    }

    private func row(_ line: DiffLine) -> some View {
        let (marker, fill, colour): (String, Color, Color) = switch line.kind {
        case .added: ("+", Ink.diffAddedFill, Ink.diffAddedText)
        case .removed: ("-", Ink.diffRemovedFill, Ink.diffRemovedText)
        case .unchanged: (" ", Color.clear, Ink.text)
        }
        return Text(marker + " " + line.text)
            .kitType(.body)
            .foregroundStyle(colour)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.sm)
            .background(fill)
    }
}
