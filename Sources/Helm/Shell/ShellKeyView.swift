import AppKit
import SwiftTerm

/// The shell view: file drops type their escaped paths, and Option is Meta only for functional keys.
/// The old Shift+Return shim is left out: it typed an escape sequence for tmux prompts, and plain zsh would print it as text.
final class ShellKeyView: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        optionAsMetaKey = false
        optionAsMetaKeyForFunctionalKeys = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        optionAsMetaKey = false
        optionAsMetaKeyForFunctionalKeys = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
    }

    // SwiftTerm has no macOS accessibility overrides, so without these the view exposes no AX element.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "Terminal" }

    override func accessibilityValue() -> Any? {
        visibleRowsText(0..<terminalStateSnapshot().dimensions.rows)
            .map { $0.replacingOccurrences(of: " +$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }

    override func setAccessibilityFocused(_ focused: Bool) {
        if focused { window?.makeFirstResponder(self) }
    }

    private func droppedFileURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    // Only file drags are accepted. The paste text never ends in a newline, so a drop only types into the prompt.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let text = DroppedFiles.pasteText(for: droppedFileURLs(sender))
        guard !text.isEmpty else { return false }
        let bracketed = terminalStateSnapshot().bracketedPasteMode
        send(source: self, data: ArraySlice(Array(DroppedFiles.wrapped(text, bracketed: bracketed).utf8)))
        return true
    }
}
