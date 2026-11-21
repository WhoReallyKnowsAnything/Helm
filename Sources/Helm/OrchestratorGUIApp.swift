import SwiftUI
import UserNotifications

/// Asks which running orchestrators to stop before the app quits (PROJ-04). Also receives banner clicks (D-08, D-15).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set by the app once the store exists. Without it a quit goes ahead.
    var store: SessionStore?
    /// Set by the app. A banner click puts its focus request here.
    var alerts: AlertStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First: nothing may run an orchestrator script before the runtime copy is current.
        OrchestratorRuntime.syncBundled()
        AlertNotifier.center?.delegate = self
        AlertNotifier.requestAuthorization()
    }

    /// A banner shows even while the app is frontmost, because the user may be looking at another project.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    /// A click only brings the app forward with that worker's node selected. It never decides a hold (D-08).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let focus = AlertBanner.focus(from: response.notification.request.content.userInfo)
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let focus { alerts?.pendingFocus = focus }
            completionHandler()
        }
    }

    /// Runs once the quit is final (after any Cancel), on every quit path. `QuitModel` does not cover the shell (D-07).
    func applicationWillTerminate(_ notification: Notification) {
        ShellStore.shared.stopAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        // shouldQuit returns on every path, so the reply below is sent exactly once.
        Task { @MainActor in
            let quit = await Self.shouldQuit(store)
            if !quit {
                // Cancel must not leave a minimised or hidden app that looks quit.
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.isMiniaturized {
                    window.deminiaturize(nil)
                    window.makeKeyAndOrderFront(nil)
                }
            }
            sender.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }

    private static func shouldQuit(_ store: SessionStore) async -> Bool {
        await store.refresh()
        guard !store.rows.isEmpty else { return true }
        let model = QuitModel(snapshot: store.snapshot) { id, folder in
            try await ProjectTeardown.stopOffMain(folder: folder, sessionId: id)
        }
        guard QuitDialog.ask(model: model) else { return false }
        let failures = await model.confirm()
        if failures.isEmpty { return true }
        // Stay open so the user sees what is still running and can quit again.
        QuitDialog.showFailures(failures)
        return false
    }
}

/// Sizes its window to the main screen's visible frame (not full-screen mode) on every launch, over any saved frame.
private struct FillScreen: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FillView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class FillView: NSView {
        private var monitor: Any?

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        override func viewDidMoveToWindow() {
            guard let window, let screen = NSScreen.main else { return }
            WindowChrome.allowFullScreen(window)
            // The system zooms on a title-bar double-click only when the Dock setting says so. The user wants it always.
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak window] event in
                    guard let window, event.window === window, event.clickCount == 2,
                          event.locationInWindow.y > window.contentLayoutRect.maxY else { return event }
                    WindowChrome.toggleZoom(window)
                    return nil
                }
            }
            // No grey macOS band: the title bar stays (buttons and name) but shows the app's own colour.
            // Content starts below the title bar, so it cannot paint over the buttons and name.
            window.styleMask.remove(.fullSizeContentView)
            window.backgroundColor = Ink.sidebarNS
            // One run-loop turn later, so SwiftUI has restored its saved frame first and this one wins.
            DispatchQueue.main.async { window.setFrame(screen.visibleFrame, display: true) }
        }
    }
}

/// Mirrors whether Back applies into a menu item. Commands do not observe a view's `@State`, so ContentView writes
/// here and the App passes the value into the commands. `back` is set by ContentView and read again when the item fires.
@MainActor final class BackMenu: ObservableObject {
    static let shared = BackMenu()
    @Published var canGoBack = false
    var back: () -> Void = {}
}

private struct GoCommands: Commands {
    let canGoBack: Bool

    var body: some Commands {
        CommandMenu("Go") {
            Button("Back") { BackMenu.shared.back() }
                .keyboardShortcut("[")
                .disabled(!canGoBack)
        }
    }
}

@main
struct OrchestratorGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = SessionStore()
    @ObservedObject private var backMenu = BackMenu.shared
    @StateObject private var alerts = AlertStore(
        onAlert: { AlertNotifier.post($0) }, onCount: { AlertNotifier.setBadge($0) })

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, alerts: alerts)
                // Dark only (D-07), as AppSettingsView already does.
                .preferredColorScheme(.dark)
                .kitAccentRoot()
                .background(FillScreen())
                // SwiftUI owns titlebarAppearsTransparent and resets a value set on the window, so ask it here.
                .toolbarBackground(.hidden, for: .windowToolbar)
                .onAppear {
                    delegate.store = store
                    delegate.alerts = alerts
                    alerts.follow(store)
                }
        }
        .commands { GoCommands(canGoBack: backMenu.canGoBack) }
        // The accent root is needed here too: a scene does not inherit it from the WindowGroup.
        Settings { AppSettingsView().kitAccentRoot() }
            .windowResizability(.contentSize)
    }
}
