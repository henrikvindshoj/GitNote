import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var workspaces: [Workspace]
    @Published var selectedWorkspaceID: Workspace.ID?
    @Published private(set) var githubUser: GitHubUser?
    @Published private(set) var remoteRepositories: [GitHubRepository] = []
    @Published private(set) var filesByWorkspace: [Workspace.ID: [MarkdownFile]] = [:]
    @Published private(set) var changesByWorkspace: [Workspace.ID: [RepositoryChange]] = [:]
    @Published private(set) var hasStoredToken: Bool
    @Published private(set) var isBusy = false
    @Published private(set) var busyMessage: String?
    @Published var errorMessage: String?

    private let github = GitHubClient()
    private let git = GitEngine()
    private let files = WorkspaceFileService()
    private let keychain = KeychainStore()
    private let metadata = WorkspaceMetadataStore()

    init() {
        let loaded = metadata.load().filter {
            FileManager.default.fileExists(atPath: WorkspacePaths.repositoryURL(for: $0).path)
        }
        workspaces = loaded
        selectedWorkspaceID = loaded.first?.id
        hasStoredToken = keychain.readToken() != nil
    }

    var selectedWorkspace: Workspace? {
        guard let selectedWorkspaceID else { return nil }
        return workspaces.first { $0.id == selectedWorkspaceID }
    }

    func bootstrap() async {
        do {
            try await files.prepareRoot()
            if hasStoredToken {
                try await refreshGitHubConnection()
            }
            if let selectedWorkspace {
                await refresh(selectedWorkspace)
            }
        } catch {
            present(error)
        }
    }

    func connect(token rawToken: String) async -> Bool {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            errorMessage = "Enter a GitHub personal access token."
            return false
        }

        return await performBusy(message: "Connecting to GitHub…") {
            let user = try await github.currentUser(token: token)
            try keychain.saveToken(token)
            hasStoredToken = true
            githubUser = user
            remoteRepositories = try await github.repositories(token: token)
        }
    }

    func disconnect() {
        do {
            try keychain.deleteToken()
            hasStoredToken = false
            githubUser = nil
            remoteRepositories = []
        } catch {
            present(error)
        }
    }

    func refreshGitHubConnection() async throws {
        guard let token = keychain.readToken() else { return }
        let user = try await github.currentUser(token: token)
        let repositories = try await github.repositories(token: token)
        githubUser = user
        remoteRepositories = repositories
    }

    func refreshRemoteRepositories() async {
        guard let token = keychain.readToken() else {
            errorMessage = "Connect GitHub in Account settings first."
            return
        }
        _ = await performBusy(message: "Refreshing repositories…") {
            githubUser = try await github.currentUser(token: token)
            remoteRepositories = try await github.repositories(token: token)
        }
    }

    func resolveRepository(_ input: String) async -> GitHubRepository? {
        guard let address = RepositoryAddress(input) else {
            errorMessage = "Use the format owner/repository or a GitHub HTTPS URL."
            return nil
        }
        do {
            return try await github.repository(address: address, token: keychain.readToken())
        } catch {
            present(error)
            return nil
        }
    }

    func clone(_ repository: GitHubRepository) async -> Bool {
        guard !repository.isPrivate else {
            errorMessage = "Private cloning is not enabled in this MVP. GitNote will add secure credential callbacks next."
            return false
        }
        guard !workspaces.contains(where: { $0.repositoryID == repository.id }) else {
            errorMessage = "This repository is already cloned."
            return false
        }

        return await performBusy(message: "Cloning \(repository.fullName)…") {
            try await files.prepareRoot()
            let folderName = repository.fullName.replacingOccurrences(of: "/", with: "--")
            let workspace = Workspace(repository: repository, localFolderName: folderName)
            try await git.clone(from: repository.cloneURL, to: WorkspacePaths.repositoryURL(for: workspace))
            workspaces.append(workspace)
            workspaces.sort { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
            try metadata.save(workspaces)
            selectedWorkspaceID = workspace.id
            await refresh(workspace)
        }
    }

    func refresh(_ workspace: Workspace) async {
        do {
            async let scannedFiles = files.markdownFiles(in: workspace)
            async let changes = git.changes(at: WorkspacePaths.repositoryURL(for: workspace))
            filesByWorkspace[workspace.id] = try await scannedFiles
            changesByWorkspace[workspace.id] = try await changes
        } catch {
            present(error)
        }
    }

    func read(_ file: MarkdownFile, in workspace: Workspace) async -> String? {
        do {
            return try await files.read(file, in: workspace)
        } catch {
            present(error)
            return nil
        }
    }

    func save(_ text: String, to file: MarkdownFile, in workspace: Workspace) async -> Bool {
        do {
            try await files.write(text, to: file, in: workspace)
            await refresh(workspace)
            return true
        } catch {
            present(error)
            return false
        }
    }

    func createMarkdownFile(
        path input: String,
        contents: String,
        in workspace: Workspace
    ) async -> MarkdownFile? {
        guard let relativePath = MarkdownRelativePath(input) else {
            errorMessage = "Enter a safe repository-relative path ending in .md or .markdown. A missing extension will become .md."
            return nil
        }

        do {
            let file = try await files.createMarkdownFile(
                at: relativePath,
                contents: contents,
                in: workspace
            )
            await refresh(workspace)
            return file
        } catch {
            present(error)
            return nil
        }
    }

    func remove(_ workspace: Workspace) async {
        do {
            try await files.remove(workspace)
            workspaces.removeAll { $0.id == workspace.id }
            filesByWorkspace[workspace.id] = nil
            changesByWorkspace[workspace.id] = nil
            try metadata.save(workspaces)
            if selectedWorkspaceID == workspace.id {
                selectedWorkspaceID = workspaces.first?.id
            }
        } catch {
            present(error)
        }
    }

    func repositoryURL(for workspace: Workspace) -> URL {
        WorkspacePaths.repositoryURL(for: workspace)
    }

    @discardableResult
    private func performBusy(message: String, operation: () async throws -> Void) async -> Bool {
        isBusy = true
        busyMessage = message
        defer {
            isBusy = false
            busyMessage = nil
        }
        do {
            try await operation()
            return true
        } catch {
            present(error)
            return false
        }
    }

    private func present(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
