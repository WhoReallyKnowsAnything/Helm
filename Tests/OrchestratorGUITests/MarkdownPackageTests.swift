import Testing
import Markdown

struct MarkdownPackageTests {
    @Test func parsesHeadingThenParagraph() {
        let doc = Document(parsing: "# Title\n\nSome text.")
        let kids = Array(doc.children)
        #expect(kids.count == 2)
        #expect(kids[0] is Heading)
        #expect(kids[1] is Paragraph)
    }
}
