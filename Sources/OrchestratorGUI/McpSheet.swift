import SwiftUI

/// The read-only `/mcp` list (D-02): one row per server, in the order the session gave. The list comes from init or an `mcp_status` reply.
struct McpSheet: View {
    let servers: [McpServer]
    var loading = false

    /// The rows the sheet draws, as `(name, status, source)`, so a test checks them without drawing.
    static func rows(_ servers: [McpServer]) -> [(name: String, status: String, source: String)] {
        servers.map { ($0.name, $0.status, $0.source) }
    }

    var body: some View {
        if servers.isEmpty {
            KitNotice(text: loading ? "Loading MCP servers" : "No MCP servers in this session's init.")
        } else {
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(Array(Self.rows(servers).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: Space.md) {
                        Text(row.name).kitType(.body).foregroundStyle(Ink.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.status).kitType(.meta).foregroundStyle(Ink.textSecondary)
                        Text(row.source).kitType(.meta).foregroundStyle(Ink.muted)
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }
}
