import SwiftUI

struct RepositoryView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case changes = "Changes"
        var id: Self { self }
    }

    @EnvironmentObject private var model: AppModel
    let workspace: Workspace
    @State private var section: Pane = .notes
    @State private var showingSync = false

    private var changes: [RepositoryChange] {
        model.changesByWorkspace[workspace.id] ?? []
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Repository section", selection: $section) {
                    ForEach(Pane.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                switch section {
                case .notes:
                    RepositoryDirectoryContentsView(workspace: workspace, directoryPath: "")
                case .changes:
                    changesList
                }
            }
            .navigationTitle(workspace.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Sync Changes", systemImage: "arrow.triangle.2.circlepath") {
                        showingSync = true
                    }
                    ShareLink(item: model.repositoryURL(for: workspace)) {
                        Label("Share working copy", systemImage: "square.and.arrow.up")
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refresh(workspace) }
                    }
                }
            }
            .navigationDestination(for: RepositoryDirectory.self) { directory in
                RepositoryDirectoryContentsView(
                    workspace: workspace,
                    directoryPath: directory.relativePath
                )
                .navigationTitle(directory.name)
            }
        }
        .task(id: workspace.id) { await model.refresh(workspace) }
        .sheet(isPresented: $showingSync) {
            SyncChangesView(workspace: workspace, changeCount: changes.count)
        }
    }

    private var changesList: some View {
        List {
            if !changes.isEmpty {
                Section {
                    ForEach(changes) { change in
                        HStack(spacing: 12) {
                            Image(systemName: change.kind.symbol)
                                .foregroundStyle(color(for: change.kind))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.path)
                                    .lineLimit(2)
                                Text(change.isStaged ? "Staged · \(change.kind.label)" : change.kind.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Sync stages every change, creates a Git commit, and pushes the current branch to origin.")
                }
            }
        }
        .overlay {
            if changes.isEmpty {
                ContentUnavailableView(
                    "Working tree clean",
                    systemImage: "checkmark.circle",
                    description: Text("No file changes are waiting. You can still sync to retry an unpublished commit.")
                )
            }
        }
    }

    private func color(for kind: RepositoryChange.Kind) -> Color {
        switch kind {
        case .added: .green
        case .modified, .renamed, .typeChanged: .orange
        case .deleted, .conflicted, .unreadable: .red
        case .unknown: .secondary
        }
    }
}

private struct RepositoryDirectoryContentsView: View {
    @EnvironmentObject private var model: AppModel
    let workspace: Workspace
    let directoryPath: String
    @State private var search = ""
    @State private var showingNewFile = false
    @State private var showingNewDirectory = false

    private var files: [MarkdownFile] {
        let files = (model.filesByWorkspace[workspace.id] ?? []).filter {
            ($0.folder ?? "") == directoryPath
        }
        guard !search.isEmpty else { return files }
        return files.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var directories: [RepositoryDirectory] {
        let directories = (model.directoriesByWorkspace[workspace.id] ?? []).filter {
            $0.parentPath == directoryPath
        }
        guard !search.isEmpty else { return directories }
        return directories.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            ForEach(directories) { directory in
                NavigationLink(value: directory) {
                    Label(directory.name, systemImage: "folder.fill")
                        .foregroundStyle(.primary)
                }
            }

            ForEach(files) { file in
                NavigationLink {
                    MarkdownEditorView(workspace: workspace, file: file)
                } label: {
                    Label(file.name, systemImage: "doc.richtext")
                }
            }
        }
        .searchable(text: $search, prompt: "Search this directory")
        .overlay {
            if files.isEmpty, directories.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView(
                        directoryPath.isEmpty ? "No notes or directories" : "Empty directory",
                        systemImage: "folder",
                        description: Text("Create a directory or Markdown file here to get started.")
                    )
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Create", systemImage: "plus") {
                    Button("New Markdown File", systemImage: "doc.badge.plus") {
                        showingNewFile = true
                    }
                    Button("New Directory", systemImage: "folder.badge.plus") {
                        showingNewDirectory = true
                    }
                }
            }
        }
        .sheet(isPresented: $showingNewFile) {
            NewMarkdownFileView(workspace: workspace, parentDirectory: directoryPath)
        }
        .sheet(isPresented: $showingNewDirectory) {
            NewDirectoryView(workspace: workspace, parentDirectory: directoryPath)
        }
    }
}

private struct SyncChangesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("git.author.name") private var authorName = ""
    @AppStorage("git.author.email") private var authorEmail = ""
    let workspace: Workspace
    let changeCount: Int
    @State private var message = "Update notes"
    @State private var isSyncing = false
    @State private var syncResult: RepositorySyncResult?

    private var canSync: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && authorEmail.contains("@")
            && !isSyncing
    }

    var body: some View {
        NavigationStack {
            if let syncResult {
                ContentUnavailableView {
                    Label("Synced with GitHub", systemImage: "checkmark.circle.fill")
                } description: {
                    if let commitID = syncResult.commitID {
                        Text("Created and pushed commit \(String(commitID.prefix(8))).")
                    } else {
                        Text("Pushed the current branch to GitHub.")
                    }
                } actions: {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Form {
                    Section {
                        TextField("Commit message", text: $message, axis: .vertical)
                    } header: {
                        Text("Commit")
                    } footer: {
                        if changeCount == 0 {
                            Text("There are no file changes. Sync will retry pushing any unpublished local commit.")
                        } else {
                            Text("This stages all \(changeCount) change\(changeCount == 1 ? "" : "s"), creates one commit, and pushes the current branch to GitHub. It does not fetch or merge.")
                        }
                    }

                    Section("Author") {
                        TextField("Name", text: $authorName)
                        TextField("Email", text: $authorEmail)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                    }
                }
                .navigationTitle("Sync Changes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Sync") { sync() }
                            .disabled(!canSync)
                    }
                }
            }
        }
        .onAppear {
            if authorName.isEmpty, let login = model.githubUser?.login {
                authorName = login
            }
            if authorEmail.isEmpty, let login = model.githubUser?.login {
                authorEmail = "\(login)@users.noreply.github.com"
            }
        }
        .interactiveDismissDisabled(isSyncing)
    }

    private func sync() {
        isSyncing = true
        Task {
            syncResult = await model.sync(
                workspace,
                message: message,
                authorName: authorName,
                authorEmail: authorEmail
            )
            isSyncing = false
        }
    }
}

private struct NewMarkdownFileView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let workspace: Workspace
    let parentDirectory: String
    @State private var path = ""
    @State private var contents = ""
    @State private var isCreating = false

    private var normalizedPath: MarkdownRelativePath? {
        MarkdownRelativePath(repositoryRelativePath)
    }

    private var repositoryRelativePath: String {
        parentDirectory.isEmpty ? path : "\(parentDirectory)/\(path)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("idea.md", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(parentDirectory.isEmpty ? "Repository-relative path" : "File name")
                } footer: {
                    if let normalizedPath {
                        Text("Creates \(normalizedPath.value)")
                    } else {
                        Text("Folders are optional. If you omit the extension, GitNote adds .md.")
                    }
                }

                Section("Initial contents") {
                    TextEditor(text: $contents)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 180)
                }
            }
            .navigationTitle("New Markdown File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(normalizedPath == nil || isCreating)
                }
            }
        }
        .interactiveDismissDisabled(isCreating)
    }

    private func create() {
        isCreating = true
        Task {
            if await model.createMarkdownFile(
                path: repositoryRelativePath,
                contents: contents,
                in: workspace
            ) != nil {
                dismiss()
            }
            isCreating = false
        }
    }
}

private struct NewDirectoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let workspace: Workspace
    let parentDirectory: String
    @State private var name = ""
    @State private var isCreating = false

    private var repositoryRelativePath: String {
        parentDirectory.isEmpty ? name : "\(parentDirectory)/\(name)"
    }

    private var normalizedPath: DirectoryRelativePath? {
        DirectoryRelativePath(repositoryRelativePath)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Directory name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("New directory")
                } footer: {
                    if let normalizedPath {
                        Text("Creates \(normalizedPath.value). Empty directories remain local until they contain a committed file.")
                    } else {
                        Text("Use a safe name without hidden or parent path components.")
                    }
                }
            }
            .navigationTitle("New Directory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(normalizedPath == nil || isCreating)
                }
            }
        }
        .interactiveDismissDisabled(isCreating)
    }

    private func create() {
        isCreating = true
        Task {
            if await model.createDirectory(path: repositoryRelativePath, in: workspace) != nil {
                dismiss()
            }
            isCreating = false
        }
    }
}
