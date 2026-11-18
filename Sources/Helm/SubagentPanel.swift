import SwiftUI

extension Array where Element == Subagent {
    var running: [Subagent] { filter(\.running) }
}

/// Lists the session's running subagents and shows the picked one's own messages and tool calls. Drawn over the chat.
struct SubagentPanel: View {
    let subagents: [Subagent]
    let onClose: () -> Void
    @State private var pickedId: String?

    private var picked: Subagent? { subagents.first { $0.id == pickedId } ?? subagents.first }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.none) {
            HStack {
                Text("Subagents").kitType(.label).foregroundStyle(Ink.textSecondary)
                Spacer(minLength: Space.none)
                Button("Close", action: onClose).buttonStyle(.kit)
            }
            .padding(Space.md)
            if subagents.isEmpty {
                KitNotice(text: "no subagents yet")
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: Space.sm) {
                        ForEach(subagents) { agent in
                            Button(Self.label(agent)) { pickedId = agent.id }
                                .buttonStyle(.kit)
                                .opacity(agent.id == picked?.id ? 1 : Fade.disabled)
                        }
                    }
                    .padding(.horizontal, Space.md)
                }
                if let picked { ConversationView(items: picked.items) }
            }
            Spacer(minLength: Space.none)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ink.background)
    }

    /// The panel stays open only while a subagent runs.
    static func isOpen(_ open: Bool, running: Int) -> Bool { open && running > 0 }

    static func label(_ agent: Subagent) -> String {
        let kind = agent.type.isEmpty ? "" : " (\(agent.type))"
        return "\(agent.title)\(kind) - \(agent.running ? "running" : "done")"
    }
}
