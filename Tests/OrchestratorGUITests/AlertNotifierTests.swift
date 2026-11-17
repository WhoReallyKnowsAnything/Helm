import Foundation
import Testing
@testable import OrchestratorGUI

struct AlertNotifierTests {
    private func alert(_ kind: Alert.Kind, command: String? = nil) -> Alert {
        Alert(kind: kind, projectId: "proj-1", projectTitle: "My Project", label: "bravo", key: "k:1", command: command)
    }

    @Test func aHoldAlertMapsToABannerWithTheCleanedOpTextAndAUserInfoThatDecodesBack() {
        let banner = AlertBanner.content(for: alert(.hold, command: "Bash: git push origin main"))
        #expect(banner.body == "Bash: git push origin main")
        #expect(banner.title == "bravo needs approval" && banner.subtitle == "My Project")
        #expect(banner.identifier == "k:1")
        #expect(AlertBanner.focus(from: banner.userInfo) == FocusRequest(projectId: "proj-1", label: "bravo"))
    }

    @Test func aLongOpTextIsCutForTheBanner() {
        let banner = AlertBanner.content(for: alert(.hold, command: String(repeating: "x", count: 5000)))
        #expect(banner.body.count == AlertBanner.maxBody + 3 && banner.body.hasSuffix("..."))
    }

    @Test func blockedAndFinishedBannersNameTheWorker() {
        #expect(AlertBanner.content(for: alert(.blocked)).title == "bravo is waiting on you")
        #expect(AlertBanner.content(for: alert(.finished)).title == "bravo finished")
    }

    @Test func userInfoWithAMissingOrMalformedValueDecodesToNothing() {
        #expect(AlertBanner.focus(from: ["project": "p"]) == nil)
        #expect(AlertBanner.focus(from: ["label": "l"]) == nil)
        #expect(AlertBanner.focus(from: ["project": "p", "label": ""]) == nil)
        #expect(AlertBanner.focus(from: ["project": 3, "label": "l"]) == nil)
        #expect(AlertBanner.focus(from: [:]) == nil)
    }

    @Test func theAppAsksForAlertsAndTheBadgeAndNothingElse() {
        #expect(AlertNotifier.authorizationOptions == [.alert, .badge])
    }

    @Test func countsMapToBadgeText() {
        #expect(AlertBanner.badge(for: 0) == nil)
        #expect(AlertBanner.badge(for: 1) == "1")
        #expect(AlertBanner.badge(for: 12) == "12")
    }
}
