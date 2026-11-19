import AppKit
import Testing
@testable import Helm

@MainActor
struct ShellAccessibilityTests {
    @Test func theShellViewIsATextAreaWithTheScreenText() {
        let view = ShellKeyView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .textArea)
        view.feed(text: "hello\r\n")
        let value = view.accessibilityValue() as? String
        #expect(value?.contains("hello") == true)
    }
}
