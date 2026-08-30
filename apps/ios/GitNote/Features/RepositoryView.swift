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
    @State private var search = ""
    @State private var showingNewFile = false

    private var files: [MarkdownFile] {
        let files = model.filesByWorkspace[workspace.id] ?? []
        guard !search.isEmpty else { return files }
        return files.filter { $0.relativePath.localizedCaseInsensitiveContains(search) }
    }

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
                    notesList
                case .changes:
                    changesList
                }
            }
            .navigationTitle(workspace.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("New Markdown File", systemImage: "doc.badge.plus") {
                        showingNewFile = true
                    }
                    ShareLink(item: model.repositoryURL(for: workspace)) {
                        Label("Share working copy", systemImage: "square.and.arrow.up")
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refresh(workspace) }
                    }
                }
            }
        }
        .task(id: workspace.id) { await model.refresh(workspace) }
        .sheet(isPresented: $showingNewFile) {
            NewMarkdownFileView(workspace: workspace)
        }
    }

    private var notesList: some View {
        List(files) { file in
            NavigationLink {
                MarkdownEditorView(workspace: workspace, file: file)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.richtext")
                        .foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                        if let folder = file.folder {
                            Text(folder)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search Markdown files")
        .overlay {
            if files.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView(
                        "No Markdown files",
                        systemImage: "doc",
                        description: Text("This working copy has no .md or .markdown files.")
                    )
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
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
                    Text("Commit and synchronization controls are the next MVP increment. Your edits already live in a real Git working tree.")
                }
            }
        }
        .overlay {
            if changes.isEmpty {
                ContentUnavailableView(
                    "Working tree clean",
                    systemImage: "checkmark.circle",
                    description: Text("No local changes are waiting to be committed.")
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

private struct NewMarkdownFileView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let workspace: Workspace
    @State private var path = ""
    @State private var contents = ""
    @State private var isCreating = false

    private var normalizedPath: MarkdownRelativePath? {
        MarkdownRelativePath(path)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("notes/idea.md", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Repository-relative path")
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
            if await model.createMarkdownFile(path: path, contents: contents, in: workspace) != nil {
                dismiss()
            }
            isCreating = false
        }
    }
}
