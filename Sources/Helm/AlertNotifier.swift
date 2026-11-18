import AppKit
import UserNotifications

/// The pure part of the banners: what an alert says, how a click is read back, what the badge shows. No system call.
enum AlertBanner {
    struct Content: Equatable {
        let title: String
        let subtitle: String
        let body: String
        /// The alert's dedupe key, so macOS replaces a banner instead of stacking a second one.
        let identifier: String
        let userInfo: [String: String]
    }

    /// A banner is short. The op text of a hold is untrusted and can be long, so only its start is shown.
    static let maxBody = 300
    private static let projectKey = "project", labelKey = "label"

    static func content(for alert: Alert) -> Content {
        let title: String, body: String
        switch alert.kind {
        case .hold:
            title = "\(alert.label) needs approval"
            let op = alert.command ?? ""
            body = op.count > maxBody ? String(op.prefix(maxBody)) + "..." : op
        case .blocked:
            title = "\(alert.label) is waiting on you"
            body = "The pane shows a prompt."
        case .finished:
            title = "\(alert.label) finished"
            body = "The worker is done."
        }
        return Content(title: title, subtitle: alert.projectTitle, body: body, identifier: alert.key,
                       userInfo: [projectKey: alert.projectId, labelKey: alert.label])
    }

    /// nil when a value is missing, not text or empty.
    static func focus(from userInfo: [AnyHashable: Any]) -> FocusRequest? {
        guard let project = userInfo[projectKey] as? String, !project.isEmpty,
              let label = userInfo[labelKey] as? String, !label.isEmpty else { return nil }
        return FocusRequest(projectId: project, label: label)
    }

    /// nil removes the badge.
    static func badge(for count: Int) -> String? { count > 0 ? String(count) : nil }
}

/// The system calls. A process without an app bundle (`swift run`, `swift test`) cannot have a notification center,
/// so banners are skipped there. The Dock badge still works.
@MainActor
enum AlertNotifier {
    static let center: UNUserNotificationCenter? = Bundle.main.bundlePath.hasSuffix(".app") ? .current() : nil

    /// What the app asks for. macOS hides the Dock badge of an app that did not ask for `.badge`, even when it is allowed alerts.
    /// No sound, and the banners carry the default action and nothing else (D-08).
    static let authorizationOptions: UNAuthorizationOptions = [.alert, .badge]

    static func requestAuthorization() {
        center?.requestAuthorization(options: authorizationOptions) { _, _ in }
    }

    static func post(_ alert: Alert) {
        guard let center else { return }
        let banner = AlertBanner.content(for: alert)
        let content = UNMutableNotificationContent()
        content.title = banner.title
        content.subtitle = banner.subtitle
        content.body = banner.body
        content.userInfo = banner.userInfo
        center.add(UNNotificationRequest(identifier: banner.identifier, content: content, trigger: nil))
    }

    static func setBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = AlertBanner.badge(for: count)
    }
}
