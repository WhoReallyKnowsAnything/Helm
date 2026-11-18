import AppKit
import SwiftUI

/// Sidebar control that starts an orchestrator in a chosen folder. It owns the model, so a start in
/// progress is not cancelled by closing the sheet.
struct NewProjectView: View {
    @StateObject private var model: NewProjectModel
    @State private var showing = false
    @State private var name = ""
    @State private var github = GithubChoice.skip
    /// The folder of the start that may need the git init answer.
    @State private var folder = ""
    @State private var choosing = false
    @State private var folders: [String] = []
    /// The failure alert of a Select project or Root session start: which button, and why.
    @State private var failureTitle = ""
    @State private var failure: String?

    /// How long a sheet takes to close before a popover or an alert can show in its place.
    private static let sheetCloseDelay: UInt64 = 400_000_000

    /// A render test sets this to draw the running state without starting a project. Nil takes the model's own state.
    private let runningOverride: Bool?

    private var startShows: Bool { runningOverride ?? model.isRunning }

    init(store: SessionStore, onStarted: @escaping (String) -> Void, runningOverride: Bool? = nil) {
        self.runningOverride = runningOverride
        _model = StateObject(wrappedValue: NewProjectModel(
            check: { FolderCheck.classify($0) },
            initRepo: { try FolderCheck.initRepo($0) },
            baseName: { try ProjectSession.baseName(for: $0) },
            claim: { base, folder in try ProjectSession.claim(base: base, folder: folder) },
            capture: { EnvironmentCapture.fileText(try EnvironmentCapture.capture()) },
            launch: { folder, envText in try ProjectLauncher.launch(folder: folder, envText: envText) },
            launchRoot: { envText in try ProjectLauncher.launchRoot(envText: envText) },
            createProject: { name, github, envText in
                try ProjectLauncher.newProject(name: name, github: github, envText: envText)
            },
            isReady: { base in ProjectReadiness.isReady(base: base) },
            refresh: { base in
                await store.refresh()
                return store.rows.contains { $0.id == base }
            },
            select: onStarted))
    }

    var body: some View {
        // Always one row (D-19 item 3). A narrow sidebar shortens the labels, and the Starting text never decides which form shows.
        ViewThatFits(in: .horizontal) {
            buttonRow(short: false, starting: startShows)
            buttonRow(short: false, starting: false)
            buttonRow(short: true, starting: startShows)
            buttonRow(short: true, starting: false)
        }
        .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
        .frame(maxWidth: .infinity, minHeight: Metric.newProjectRowMinHeight, alignment: .leading)
        .onChange(of: model.startedBase) {
            guard model.startedBase != nil else { return }
            showing = false
            let warnings = model.warnings
            // The alert comes after the sheet has gone, because an alert requested while a sheet closes may be dropped.
            if !warnings.isEmpty {
                Task {
                    try? await Task.sleep(nanoseconds: Self.sheetCloseDelay)
                    failureTitle = "Project created with warnings"
                    failure = warnings.joined(separator: "\n")
                }
            }
        }
        .sheet(isPresented: $showing) { sheet }
        .alert(failureTitle, isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
        .confirmationDialog(
            "Initialize a git repository?",
            isPresented: Binding(get: { model.initOffer != nil }, set: { if !$0 { model.cancelInit() } }),
            titleVisibility: .visible
        ) {
            Button("Initialize and Start") {
                Task { await model.confirmInit(folder: folder); failure = model.reason }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(folder) is not a git repository. This runs git init and makes an empty first commit, then starts the orchestrator.")
        }
    }

    /// The three buttons, then the Starting text at the trailing end when `starting`. Both belong to the one row.
    func buttonRow(short: Bool, starting: Bool) -> some View {
        HStack(spacing: Space.sm) {
            buttons(short: short)
            Spacer(minLength: Space.none)
            if starting { Text("Starting").kitType(.meta).foregroundStyle(Ink.muted) }
        }
    }

    @ViewBuilder private func buttons(short: Bool) -> some View {
        Button(short ? "+New" : "+ New Project") { model.clearFailure(); showing = true }
            .buttonStyle(.kit)
            .accessibilityLabel("New project")
        Button(short ? "Select" : "Select Project") { folders = ProjectFolders.list(); choosing.toggle() }
            .buttonStyle(.kit)
            .disabled(model.isRunning)
            .help("Start a project from your projects folder, \(ProjectFolders.defaultRoot)")
            .accessibilityLabel("Select project")
            .popover(isPresented: $choosing) { folderList }
        Button(short ? "Root" : "Root Session") {
            failureTitle = "Root session"
            Task { await model.startRoot(); failure = model.reason }
        }
            .buttonStyle(.kit)
            .disabled(model.isRunning)
            .help("Start a plain Claude session in your home folder")
            .accessibilityLabel("New root session")
    }

    /// One row per folder under the projects folder, shown verbatim.
    private var folderList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xs) {
                if folders.isEmpty { KitNote(text: "No folders in the projects folder") }
                ForEach(folders, id: \.self) { path in
                    row(URL(fileURLWithPath: path).lastPathComponent) { choosing = false; start(path) }
                }
                row("other folder...") {
                    choosing = false
                    // After the popover has gone, so it does not stay in front of the panel.
                    Task { if let path = pickFolder() { start(path) } }
                }
            }
            .padding(Space.sm)
        }
        .frame(width: Metric.folderPopoverWidth, height: Metric.folderPopoverHeight).background(Ink.panel)
    }

    private func row(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(verbatim: title).kitType(.body).foregroundStyle(Ink.text).lineLimit(1) }
            .buttonStyle(KitSidebarRowStyle(selected: false))
    }

    private var sheet: some View {
        NewProjectSheetContent(
            name: $name, github: $github, failure: model.reason, isRunning: model.isRunning,
            onCreate: { Task { await model.create(name: name, github: github) } }, onClose: { showing = false },
            offersSelect: model.existingProject != nil,
            onSelectProject: {
                showing = false
                Task {
                    try? await Task.sleep(nanoseconds: Self.sheetCloseDelay)
                    folders = ProjectFolders.list()
                    choosing = true
                }
            }
        )
    }

    /// Starts a project in the folder through the unchanged model. A failure shows in the alert.
    private func start(_ path: String) {
        folder = path
        failureTitle = "Select project"
        Task { await model.start(folder: path); failure = model.reason }
    }

    private func pickFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

/// What the New project sheet draws, from plain data and actions, so a render test needs no model or folder panel.
struct NewProjectSheetContent: View {
    @Binding var name: String
    @Binding var github: GithubChoice
    let failure: String?
    let isRunning: Bool
    let onCreate: () -> Void
    let onClose: () -> Void
    /// The folder of this name exists: the failure line is followed by a button that opens Select project.
    var offersSelect = false
    var onSelectProject: () -> Void = {}

    static func canCreate(name: String, isRunning: Bool) -> Bool {
        NewProjectInput.isValidName(name) && !isRunning
    }

    var body: some View {
        KitSheetFrame(
            title: "New Project", width: SheetWidth.medium, failure: offersSelect ? nil : failure,
            progress: isRunning ? "Creating the project" : nil,
            primaryTitle: isRunning ? "Creating" : "Create", primaryEnabled: Self.canCreate(name: name, isRunning: isRunning),
            cancelTitle: "Close", cancel: onClose, primary: onCreate
        ) {
            VStack(alignment: .leading, spacing: Space.sm) {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                if !name.isEmpty && !NewProjectInput.isValidName(name) {
                    Text("Use 1 to 64 letters, digits, dots, dashes or underscores. Start with a letter or a digit.")
                        .kitType(.meta).foregroundStyle(Ink.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("GitHub").kitType(.meta).foregroundStyle(Ink.muted)
                Picker("GitHub", selection: $github) {
                    ForEach(GithubChoice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                // The frame draws the failure line below this content, so with the offer the line is drawn here, above its button.
                if offersSelect, let failure {
                    Text(verbatim: failure).kitType(.meta).foregroundStyle(Ink.textSecondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button("Select Project", action: onSelectProject).buttonStyle(.kit)
                }
            }
        }
    }
}
