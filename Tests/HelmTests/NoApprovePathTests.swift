import Foundation
import Testing

/// AC4, the static half: the only way to Approve or Deny is a click or key press in the app's view (CONTEXT D-08).
/// The app exposes no listening socket, URL scheme, AppleScript, App Intent, Service or notification action. This does
/// not claim that a worker cannot approve its own hold through the orchestrator's script: that refusal is the
/// orchestrator's, and the app only promises it adds no path of its own.
enum ApprovePathScan {
    struct Rule {
        let token: String
        /// nil: any file under the folder. Else only the file with this name.
        let file: String?
        /// The one file the rule does not apply to (D-02: the named answer writer).
        var except: String? = nil
    }

    /// One array, so the test is easy to extend. Taken from the D-08 wording.
    static let rules: [Rule] =
        ["AppIntent", "AppShortcutsProvider", "UNNotificationAction", "NSAppleScript", "NSServices",
         "NWListener", "HTTPServer", "CFMessagePort", "NSXPCListener", "listen(", "bind("].map { Rule(token: $0, file: nil) }
        // The decider takes its script path only as a parameter: no environment variable and no config file chooses it.
        + ["ProcessInfo", "getenv", "UserDefaults", "FileManager", "contentsOf"].map { Rule(token: $0, file: "HoldDecider.swift") }
        // D-02: the answer keys appear only in the one named answer writer.
        + ["behavior", "updatedInput"].map { Rule(token: $0, file: nil, except: "ControlAnswerWriter.swift") }

    static let forbiddenPlistKeys = ["CFBundleURLTypes", "NSAppleScriptEnabled", "OSAScriptingDefinition", "NSServices"]

    /// "file: token" for every rule that a `.swift` file under `folder` breaks. The token must start at a word boundary,
    /// so `sqlite3_bind(` or `rebind(` is not `bind(`.
    static func violations(in folder: String) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: folder) else { return ["\(folder): cannot be read"] }
        var found: [String] = []
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            let name = (relative as NSString).lastPathComponent
            guard let text = try? String(contentsOfFile: folder + "/" + relative, encoding: .utf8) else {
                found.append("\(name): cannot be read")
                continue
            }
            for rule in rules where (rule.file == nil || rule.file == name) && rule.except != name {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: rule.token)
                if text.range(of: pattern, options: .regularExpression) != nil { found.append("\(name): \(rule.token)") }
            }
        }
        return found.sorted()
    }

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    static var sources: String { root + "/Sources/Helm" }
    static var plist: String { root + "/Resources/Info.plist" }
}

struct NoApprovePathTests {
    @Test func infoPlistHasNoUrlSchemeAppleScriptOrServicesKey() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: ApprovePathScan.plist))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(!plist.isEmpty)
        for key in ApprovePathScan.forbiddenPlistKeys { #expect(plist[key] == nil, "Info.plist has \(key)") }
    }

    @Test func noSourceFileHasASecondApprovePath() {
        let found = ApprovePathScan.violations(in: ApprovePathScan.sources)
        #expect(found.isEmpty, "A second approve path appeared: \(found)")
    }

    @Test func theScanSeesAnEntryThatIsAddedToACopyOfASourceFile() throws {
        let folder = NSTemporaryDirectory() + "gui-test-scan-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for name in ["AlertNotifier.swift", "HoldDecider.swift"] {
            let original = try String(contentsOfFile: ApprovePathScan.sources + "/" + name, encoding: .utf8)
            try (original + "\nlet extra = UNNotificationAction.self\n").write(
                toFile: folder + "/" + name, atomically: true, encoding: .utf8)
        }
        try (try String(contentsOfFile: ApprovePathScan.sources + "/AlertTracker.swift", encoding: .utf8) + "\nlet other = ProcessInfo.self\n")
            .write(toFile: folder + "/AlertTracker.swift", atomically: true, encoding: .utf8)
        let found = ApprovePathScan.violations(in: folder)
        #expect(found.contains("AlertNotifier.swift: UNNotificationAction"))
        #expect(found.contains("HoldDecider.swift: UNNotificationAction"))
        // ProcessInfo is only forbidden in the decider: another file may use it.
        #expect(!found.contains { $0.hasPrefix("AlertTracker.swift") })
        #expect(!found.contains { $0.contains("ProcessInfo") })
    }

    @Test func theAnswerKeyIsFlaggedInAnotherFileAndAllowedInTheWriter() throws {
        let folder = NSTemporaryDirectory() + "gui-test-scan-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let writer = try String(contentsOfFile: ApprovePathScan.sources + "/ControlAnswerWriter.swift", encoding: .utf8)
        try writer.write(toFile: folder + "/ControlAnswerWriter.swift", atomically: true, encoding: .utf8)
        let other = try String(contentsOfFile: ApprovePathScan.sources + "/AlertTracker.swift", encoding: .utf8)
        try (other + "\nlet x = \"behavior\"\n").write(toFile: folder + "/AlertTracker.swift", atomically: true, encoding: .utf8)
        #expect(ApprovePathScan.violations(in: folder) == ["AlertTracker.swift: behavior"])
    }

    @Test func aWordThatOnlyEndsInTheTokenIsNotAMatch() throws {
        let folder = NSTemporaryDirectory() + "gui-test-scan-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try "let a = sqlite3_bind(x)\nlet b = rebind(y)\n".write(toFile: folder + "/A.swift", atomically: true, encoding: .utf8)
        #expect(ApprovePathScan.violations(in: folder).isEmpty)
        try "let a = server.bind(x)\n".write(toFile: folder + "/B.swift", atomically: true, encoding: .utf8)
        #expect(ApprovePathScan.violations(in: folder) == ["B.swift: bind("])
    }
}
