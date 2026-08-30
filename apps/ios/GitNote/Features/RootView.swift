import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingAddRepository = false
    @State private var showingAccount = false
    @State private var workspaceToDelete: Workspace?

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedWorkspaceID) {
                Section("Working copies") {
                    ForEach(model.workspaces) { workspace in
                        WorkspaceRow(
                            workspace: workspace,
                            changeCount: model.changesByWorkspace[workspace.id]?.count
                        )
                            .tag(workspace.id)
                            .contextMenu {
                                Button("Remove local copy", role: .destructive) {
                                    workspaceToDelete = workspace
                                }
                            }
                    }
                }
            }
            .navigationTitle("GitNote")
            .overlay {
                if model.workspaces.isEmpty {
                    ContentUnavailableView {
                        Label("No repositories", systemImage: "folder.badge.plus")
                    } description: {
                        Text("Clone a public Markdown repository to get started.")
                    } actions: {
                        Button("Add Repository") { showingAddRepository = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Account", systemImage: "person.crop.circle") {
                        showingAccount = true
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Repository", systemImage: "plus") {
                        showingAddRepository = true
                    }
                }
            }
        } detail: {
            if let workspace = model.selectedWorkspace {
                RepositoryView(workspace: workspace)
                    .id(workspace.id)
            } else {
                ContentUnavailableView("Select a repository", systemImage: "books.vertical")
            }
        }
        .task { await model.bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.refreshAllWorkspaces() }
        }
        .sheet(isPresented: $showingAddRepository) {
            AddRepositoryView()
        }
        .sheet(isPresented: $showingAccount) {
            AccountView()
        }
        .alert("GitNote", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            "Remove local working copy?",
            isPresented: Binding(
                get: { workspaceToDelete != nil },
                set: { if !$0 { workspaceToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let workspaceToDelete {
                Button("Remove \(workspaceToDelete.displayName)", role: .destructive) {
                    Task {
                        await model.remove(workspaceToDelete)
                        self.workspaceToDelete = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) { workspaceToDelete = nil }
        } message: {
            Text("This deletes only the clone on this device. The GitHub repository is not affected.")
        }
        .overlay {
            if model.isBusy {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                        Text(model.busyMessage ?? "Working…")
                            .font(.callout)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
    }
}

private struct WorkspaceRow: View {
    let workspace: Workspace
    let changeCount: Int?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "book.closed")
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.displayName).font(.headline)
                Text(workspace.ownerName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let changeCount, changeCount > 0 {
                Text("\(changeCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange, in: Capsule())
                    .accessibilityLabel("\(changeCount) uncommitted changes")
            }
        }
        .accessibilityValue(dirtyDescription)
    }

    private var dirtyDescription: String {
        guard let changeCount else { return "Checking for changes" }
        return changeCount == 0
            ? "Working copy clean"
            : "Working copy has \(changeCount) uncommitted change\(changeCount == 1 ? "" : "s")"
    }
}
