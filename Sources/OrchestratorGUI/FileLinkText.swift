import Foundation

/// One piece of free text: plain text (kept verbatim, so joining all pieces gives the input back) or a path candidate.
enum FileLinkPiece: Equatable {
    case plain(String)
    case candidate(String)
}

/// Cuts free text into plain and path-candidate pieces. Splits on whitespace, so a path with a space cannot be linked.
enum FileLinkText {
    private static let leading = Set("`([{'\"")
    private static let trailing = Set("`)]}'\".,;:")
    private static let nameDotExt = #"^[A-Za-z0-9_\-]+(\.[A-Za-z0-9_\-]+)*\.[A-Za-z][A-Za-z0-9]*(:\d+(-\d+)?(,\d+(-\d+)?)*(:\d+)?)?$"#

    static func split(_ text: String) -> [FileLinkPiece] {
        var pieces: [FileLinkPiece] = []
        func addPlain(_ s: String) {
            guard !s.isEmpty else { return }
            if case .plain(let last)? = pieces.last { pieces[pieces.count - 1] = .plain(last + s) } else { pieces.append(.plain(s)) }
        }
        var token = ""
        func flush() {
            guard !token.isEmpty else { return }
            var core = Substring(token)
            var head = "", tail = ""
            // Strip until nothing changes.
            while let c = core.first, leading.contains(c) { head.append(c); core = core.dropFirst() }
            while let c = core.last, trailing.contains(c) { tail = String(c) + tail; core = core.dropLast() }
            if isCandidate(core) {
                addPlain(head)
                pieces.append(.candidate(String(core)))
                addPlain(tail)
            } else {
                addPlain(token)
            }
            token = ""
        }
        for ch in text {
            if ch.isWhitespace { flush(); addPlain(String(ch)) } else { token.append(ch) }
        }
        flush()
        return pieces
    }

    private static func isCandidate(_ s: Substring) -> Bool {
        !s.isEmpty && (s.contains("/") || s.range(of: nameDotExt, options: .regularExpression) != nil)
    }
}
