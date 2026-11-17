import AppKit
import SwiftUI
import Testing
@testable import OrchestratorGUI

private final class Recorder: WorkspaceOpening, @unchecked Sendable {
    var plainOpens = 0
    var appOpens = 0
    func applicationURL(bundleIdentifier: String) -> URL? { URL(fileURLWithPath: "/Applications/Visual Studio Code.app") }
    func plainTextEditorURL() -> URL? { nil }
    func open(_ file: URL) { plainOpens += 1 }
    func open(_ file: URL, withApplicationAt app: URL) { appOpens += 1 }
}

@MainActor
@Suite struct EditorViewTests {
    private let ten = (1...10).map { "line \($0)" }.joined(separator: "\n")

    private func distinctColours(_ view: some View, dark: Bool) throws -> Int {
        let size = CGSize(width: 600, height: 300)
        let host = NSHostingView(rootView: AnyView(view.background(Ink.background).frame(width: size.width, height: size.height)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var seen = Set<[UInt8]>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                seen.insert([UInt8(c.redComponent * 255), UInt8(c.greenComponent * 255), UInt8(c.blueComponent * 255)])
            }
        }
        return seen.count
    }

    @Test func lightAndDarkSnapshotsRender() throws {
        let file = EditorScreenBody(path: "/p/Sources/a.swift", line: 2, project: "/p", result: .text("import Foundation\nlet a = 1\n"))
        let notice = EditorScreenBody(path: "/p/big.log", line: nil, project: "/p", result: .unsupported("larger than 512 KB"))
        for dark in [false, true] {
            #expect(try distinctColours(file, dark: dark) > 1)
            #expect(try distinctColours(notice, dark: dark) > 1)
        }
    }

    @Test func saveIsOnOnlyForADirtyEditableFile() {
        let readOnly = EditorAccess.readOnly("in the worktree of worker w1, which is still live")
        #expect(EditorView.canSave(isDirty: true, access: .editable))
        #expect(!EditorView.canSave(isDirty: false, access: .editable))
        #expect(!EditorView.canSave(isDirty: true, access: readOnly))
    }

    @Test func readOnlyAndDirtyHeadersRenderInBothAppearances() throws {
        let text = EditorTextResult.text("let a = 1\n")
        let readOnly = EditorScreenBody(path: "/p/a.swift", line: nil, project: "/p", result: text,
                                        access: .readOnly("in the worktree of worker w1, which is still live"))
        let dirty = EditorScreenBody(path: "/p/a.swift", line: nil, project: "/p", result: text, isDirty: true,
                                     saveFailure: "disk full")
        for dark in [false, true] {
            #expect(try distinctColours(readOnly, dark: dark) > 1)
            #expect(try distinctColours(dirty, dark: dark) > 1)
        }
    }

    @Test func workerNameShowsForAnyStatusAndNotForProjectFiles() throws {
        let tree = NSTemporaryDirectory() + "wn-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tree) }
        let file = tree + "/a.swift"
        let live = WorkerRow(agentId: "w-live", status: "running", taskTitle: nil, lastEvent: nil, worktreePath: tree)
        let merged = WorkerRow(agentId: "w-old", status: "merged", taskTitle: nil, lastEvent: nil, worktreePath: tree)
        #expect(EditorView.workerName(path: file, rows: [live]) == "w-live")
        #expect(EditorView.workerName(path: file, rows: [merged]) == "w-old")
        #expect(EditorView.workerName(path: "/p/a.swift", rows: [live, merged]) == nil)
        #expect(EditorAccess.resolve(URL(fileURLWithPath: file), project: URL(fileURLWithPath: "/p"), rows: [merged]).isEditable)
        let text = EditorTextResult.text("let a = 1\n")
        let named = EditorScreenBody(path: file, line: nil, project: "/p", result: text, workerName: "w-old")
        let plain = EditorScreenBody(path: file, line: nil, project: "/p", result: text)
        for dark in [false, true] {
            #expect(try pixels(named, dark: dark) != pixels(plain, dark: dark))
        }
    }

    private func pixels(_ view: some View, dark: Bool) throws -> Data {
        let size = CGSize(width: 600, height: 300)
        let host = NSHostingView(rootView: AnyView(view.background(Ink.background).frame(width: size.width, height: size.height)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func draftBannerChangesTheDrawingInBothAppearances() throws {
        let text = EditorTextResult.text("let a = 1\n")
        let plain = EditorScreenBody(path: "/p/a.swift", line: nil, project: "/p", result: text)
        let banner = EditorScreenBody(path: "/p/a.swift", line: nil, project: "/p", result: text, pendingDraft: "let a = 2\n")
        for dark in [false, true] {
            #expect(try pixels(plain, dark: dark) != pixels(banner, dark: dark))
        }
    }

    @Test func bannerButtonsCallTheirActionOnce() {
        var restores = 0, discards = 0
        let banner = EditorDraftBanner(onRestore: { restores += 1 }, onDiscard: { discards += 1 })
        banner.onRestore()
        #expect(restores == 1 && discards == 0)
        banner.onDiscard()
        #expect(restores == 1 && discards == 1)
    }

    @Test func diskBannerDisablesSaveCallsItsButtonsAndChangesTheDrawing() throws {
        #expect(!EditorView.canSave(isDirty: true, access: .editable, changedOnDisk: true))
        #expect(EditorView.canSave(isDirty: true, access: .editable, changedOnDisk: false))
        var reloads = 0, keeps = 0
        let banner = EditorDiskBanner(onReload: { reloads += 1 }, onKeepMine: { keeps += 1 })
        banner.onReload()
        #expect(reloads == 1 && keeps == 0)
        banner.onKeepMine()
        #expect(reloads == 1 && keeps == 1)
        let text = EditorTextResult.text("let a = 1\n")
        let normal = EditorScreenBody(path: "/p/a.swift", line: nil, project: "/p", result: text, isDirty: true)
        let flagged = EditorScreenBody(path: "/p/a.swift", line: nil, project: "/p", result: text, isDirty: true, changedOnDisk: true)
        for dark in [false, true] {
            #expect(try pixels(normal, dark: dark) != pixels(flagged, dark: dark))
        }
    }

    @Test func twelveStateSnapshotsRenderDistinctlyAndAreWritten() throws {
        let swift = EditorTextResult.text("import Foundation\n\n// a comment\nlet a = \"text\" + String(1)\nfunc f() { return }\n")
        let blocks = [DiffBlock(path: nil, lines: [DiffLine(kind: .unchanged, text: "import Foundation"),
                                                   DiffLine(kind: .removed, text: "let a = 1"),
                                                   DiffLine(kind: .added, text: "let a = 2")])]
        let states: [(String, EditorScreenBody)] = [
            ("text", EditorScreenBody(path: "/p/a.swift", line: nil, project: "/p", result: swift)),
            ("diff", EditorScreenBody(path: "/p/a.swift", line: nil, project: "/p", result: swift,
                                      showsDiff: true, diff: .blocks(blocks))),
            ("readonly-worker", EditorScreenBody(path: "/w/a.swift", line: nil, project: "/p", result: swift,
                                                 access: .readOnly("in the worktree of worker w1, which is still live"),
                                                 workerName: "w1")),
            ("draft-banner", EditorScreenBody(path: "/p/a.swift", line: nil, project: "/p", result: swift, pendingDraft: "draft")),
            ("disk-banner", EditorScreenBody(path: "/p/a.swift", line: nil, project: "/p", result: swift, isDirty: true,
                                             changedOnDisk: true)),
            ("unsupported", EditorScreenBody(path: "/p/big.log", line: nil, project: "/p", result: .unsupported("larger than 512 KB")))
        ]
        try FileManager.default.createDirectory(at: RenderSupport.out, withIntermediateDirectories: true)
        for dark in [false, true] {
            var seen: [Data] = []
            for (name, view) in states {
                #expect(try distinctColours(view, dark: dark) > 1)
                let png = try pixels(view, dark: dark)
                #expect(!seen.contains(png), "\(name) equals another state")
                seen.append(png)
                try png.write(to: RenderSupport.out.appendingPathComponent("editor-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    @Test func buttonOpensVSCodeOnceForACodeFile() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("a.swift")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let ws = Recorder()
        let outcome = EditorView.openInVSCode(path: file.path, project: project.path, workspace: ws)
        #expect(outcome == .opened(root: .project, app: "Visual Studio Code"))
        #expect(ws.appOpens == 1 && ws.plainOpens == 0)
        #expect(EditorView.openInVSCode(path: "/etc/hosts", project: project.path, workspace: ws) == .refused("outside the project and the worktree"))
    }

    @Test func goToLineSelectsAValidLineAndIgnoresTheRest() {
        let scroll = EditorTextView.makeScrollView()
        EditorTextView.setText(ten, language: .plain, in: scroll)
        let textView = scroll.documentView as! NSTextView
        let request = EditorView.goToLine("5", in: ten, token: 1)
        #expect(request == EditorScrollRequest(line: 5, token: 1))
        EditorTextView.select(line: request!.line, in: scroll)
        #expect(textView.selectedRange() == (ten as NSString).range(of: "line 5"))
        #expect(EditorView.goToLine("99", in: ten, token: 2) == nil)
        #expect(EditorView.goToLine("abc", in: ten, token: 2) == nil)
        #expect(EditorView.goToLine("0", in: ten, token: 2) == nil)
        #expect(textView.selectedRange() == (ten as NSString).range(of: "line 5"))
    }
}
