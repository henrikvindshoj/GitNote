import SwiftUI

struct AddRepositoryView: View {
    private enum Source: String, CaseIterable, Identifiable {
        case account = "GitHub account"
        case address = "Public address"
        var id: Self { self }
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var source: Source = .address
    @State private var address = ""
    @State private var search = ""

    private var filteredRepositories: [GitHubRepository] {
        let repositories = model.remoteRepositories.filter { repository in
            !model.workspaces.contains { $0.repositoryID == repository.id }
        }
        guard !search.isEmpty else { return repositories }
        return repositories.filter {
            $0.fullName.localizedCaseInsensitiveContains(search)
                || ($0.summary?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Source", selection: $source) {
                    ForEach(Source.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                switch source {
                case .address:
                    publicAddressForm
                case .account:
                    accountRepositories
                }
            }
            .navigationTitle("Add Repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var publicAddressForm: some View {
        Form {
            Section {
                TextField("owner/repository", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { cloneAddress() }
                Button("Find and Clone") { cloneAddress() }
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Public GitHub repository")
            } footer: {
                Text("You can also paste a full https://github.com URL. A real Git working copy will be stored under Files → GitNote → Repositories.")
            }
        }
    }

    @ViewBuilder
    private var accountRepositories: some View {
        if !model.hasStoredToken {
            ContentUnavailableView {
                Label("Sign in with GitHub", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("Sign in from Account settings to browse your repositories.")
            }
        } else {
            List(filteredRepositories) { repository in
                Button {
                    clone(repository)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: repository.isPrivate ? "lock.fill" : "book.closed")
                            .foregroundStyle(repository.isPrivate ? Color.secondary : Color.indigo)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(repository.fullName)
                                .foregroundStyle(.primary)
                            if let summary = repository.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        if repository.isPrivate {
                            Text("Coming next")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(repository.isPrivate)
            }
            .searchable(text: $search, prompt: "Search repositories")
            .refreshable { await model.refreshRemoteRepositories() }
            .overlay {
                if filteredRepositories.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
    }

    private func cloneAddress() {
        Task {
            guard let repository = await model.resolveRepository(address) else { return }
            if await model.clone(repository) { dismiss() }
        }
    }

    private func clone(_ repository: GitHubRepository) {
        Task {
            if await model.clone(repository) { dismiss() }
        }
    }
}
