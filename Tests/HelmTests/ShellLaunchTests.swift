import Foundation
import Testing
@testable import Helm

struct ShellLaunchTests {
    private let parent = ["CLAUDE_GUI": "1", "TERM": "dumb", "HOME": "/h"]

    @Test func environmentSetsTermDropsClaudeGuiKeepsRest() {
        let launch = ShellLaunch(folder: "/tmp", parentEnvironment: parent)
        #expect(launch.environment.contains("TERM=xterm-256color"))
        #expect(!launch.environment.contains("TERM=dumb"))
        #expect(!launch.environment.contains { $0.hasPrefix("CLAUDE_GUI") })
        #expect(launch.environment.contains("HOME=/h"))
    }

    @Test func loginZshInTheGivenFolder() {
        let launch = ShellLaunch(folder: "/some/where", parentEnvironment: parent)
        #expect(launch.executable == "/bin/zsh")
        #expect(launch.arguments == ["-l"])
        #expect(launch.folder == "/some/where")
    }

    @Test func homeLaunchUsesNSHomeDirectory() {
        #expect(ShellLaunch.home(parentEnvironment: parent).folder == NSHomeDirectory())
    }
}
