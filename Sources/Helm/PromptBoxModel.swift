import Foundation

/// State of one node's prompt box (D-13). The delivery arrives as a closure, so tests use a stub and the blocking
/// call runs off the main actor. The model owns the draft text and clears it only when a send goes through or a native command opens.
@MainActor
final class PromptBoxModel: ObservableObject {
    @Published private(set) var isSending = false
    /// Why the last send delivered nothing, or nil.
    @Published private(set) var message: String?
    /// True after a send went through; the view clears the draft.
    @Published private(set) var sent = false
    /// The native command the last send asked for (D-05). The view opens its sheet and clears it on close.
    @Published var command: SlashMenu.Native?

    /// The message being typed. It lives here, not in the view, so it survives a switch of session. A send or a command clears it.
    @Published var draft = ""

    /// Dropped files waiting for the next send, in drop order.
    @Published private(set) var attachments: [URL] = []

    private let deliver: @Sendable (_ text: String) -> InboxDelivery.Outcome
    private let deliverFiles: (@Sendable (_ text: String, _ files: [URL]) -> InboxDelivery.Outcome)?

    /// `deliverFiles` carries a send that has attachments. Nil: dropped files are refused.
    init(deliver: @escaping @Sendable (_ text: String) -> InboxDelivery.Outcome,
         deliverFiles: (@Sendable (_ text: String, _ files: [URL]) -> InboxDelivery.Outcome)? = nil) {
        self.deliver = deliver
        self.deliverFiles = deliverFiles
    }

    /// Adds dropped files. A file that cannot be sent is left out and the failure line says why.
    func attach(_ urls: [URL]) {
        guard deliverFiles != nil else { message = "This session cannot take files."; return }
        message = nil
        for url in urls where !attachments.contains(url) {
            do { try PromptMessage.check(url); attachments.append(url) } catch { message = error.localizedDescription }
        }
    }

    func detach(_ url: URL) { attachments.removeAll { $0 == url } }

    func send(_ text: String, terminalCommands: [String] = []) async {
        guard !isSending else { return }
        message = nil
        sent = false
        if attachments.isEmpty {
            switch SlashMenu.action(for: text, terminalCommands: terminalCommands) {
            case .native(let native): command = native; draft = ""; return
            case .note(let note): message = note; return
            case .send: break
            }
        }
        isSending = true
        defer { isSending = false }
        let deliver = self.deliver, deliverFiles = self.deliverFiles, files = attachments
        let outcome = await Task.detached { files.isEmpty ? deliver(text) : (deliverFiles?(text, files) ?? .failed("This session cannot take files.")) }.value
        switch outcome {
        case .sent: sent = true; attachments = []; draft = ""
        case .refused(let reason), .failed(let reason): message = reason
        }
    }
}
