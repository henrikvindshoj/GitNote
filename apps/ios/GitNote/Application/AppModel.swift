import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var workspaces: [Workspace]
    @Published var selectedWorkspaceID: Workspace.ID?
    @Published private(set) var githubUser: GitHubUser?
    @Published private(set) var remoteRepositories: [GitHubRepository] = []
    @Published private(set) var filesByWorkspace: [Workspace.ID: [MarkdownFile]] = [:]
    @Published private(set) var directoriesByWorkspace: [Workspace.ID: [RepositoryDirectory]] = [:]
    @Published private(set) var changesByWorkspace: [Workspace.ID: [RepositoryChange]] = [:]
    @Published private(set) var hasStoredToken: Bool
    @Published private(set) var githubDeviceAuthorization: GitHubDeviceAuthorization?
    @Published private(set) var isGitHubSignInInProgress = false
    @Published private(set) var isBusy = false
    @Published private(set) var busyMessage: String?
    @Published var errorMessage: String?

    private let github = GitHubClient()
    private let githubOAuth = GitHubOAuthClient()
    private let git = GitEngine()
    private let files = WorkspaceFileService()
    private let keychain = KeychainStore()
    private let metadata = WorkspaceMetadataStore()
    private var githubSignInTask: Task<Void, Never>?
    private var githubSignInID: UUID?

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
            await refreshAllWorkspaces()
        } catch {
            present(error)
        }
    }

    func startGitHubSignIn() {
        guard githubSignInTask == nil else { return }

        errorMessage = nil
        let signInID = UUID()
        githubSignInID = signInID
        isGitHubSignInInProgress = true
        githubSignInTask = Task { [weak self] in
            await self?.runGitHubSignIn(id: signInID)
        }
    }

    func cancelGitHubSignIn() {
        githubSignInTask?.cancel()
        githubSignInTask = nil
        githubSignInID = nil
        githubDeviceAuthorization = nil
        isGitHubSignInInProgress = false
    }

    private func runGitHubSignIn(id: UUID) async {
        defer { finishGitHubSignIn(id: id) }

        guard let clientID = GitHubOAuthClient.configuredClientID() else {
            present(GitHubOAuthClient.OAuthError.missingClientID)
            return
        }

        do {
            let authorization = try await githubOAuth.begin(clientID: clientID)
            try Task.checkCancellation()
            guard githubSignInID == id else { return }
            githubDeviceAuthorization = authorization

            let token = try await githubOAuth.waitForToken(
                authorization: authorization,
                clientID: clientID
            )
            try Task.checkCancellation()
            let user = try await github.currentUser(token: token)
            try Task.checkCancellation()

            // Persist as soon as GitHub has validated the token. Repository
            // discovery is useful account data, but it must not decide whether
            // a successful authorization survives an API or connectivity error.
            try keychain.saveToken(token)
            guard keychain.readToken() == token else {
                throw KeychainStore.KeychainError.tokenNotPersisted
            }
            hasStoredToken = true
            githubUser = user

            do {
                remoteRepositories = try await github.repositories(token: token)
            } catch {
                present(error)
            }
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    private func finishGitHubSignIn(id: UUID) {
        guard githubSignInID == id else { return }
        githubSignInTask = nil
        githubSignInID = nil
        githubDeviceAuthorization = nil
        isGitHubSignInInProgress = false
    }

    func disconnect() {
        cancelGitHubSignIn()
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
        githubUser = user
        remoteRepositories = try await github.repositories(token: token)
    }

    func refreshRemoteRepositories() async {
        guard let token = keychain.readToken() else {
            errorMessage = "Sign in with GitHub from Account settings first."
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
        let token = keychain.readToken()
        guard !repository.isPrivate || token != nil else {
            errorMessage = "Sign in with GitHub from Account settings before cloning a private repository."
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
            try await git.clone(
                from: repository.cloneURL,
                to: WorkspacePaths.repositoryURL(for: workspace),
                token: token
            )
            workspaces.append(workspace)
            workspaces.sort { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
            try metadata.save(workspaces)
            selectedWorkspaceID = workspace.id
            await refresh(workspace)
        }
    }

    func refresh(_ workspace: Workspace) async {
        do {
            async let scannedContents = files.contents(in: workspace)
            async let changes = git.changes(at: WorkspacePaths.repositoryURL(for: workspace))
            let contents = try await scannedContents
            filesByWorkspace[workspace.id] = contents.markdownFiles
            directoriesByWorkspace[workspace.id] = contents.directories
            changesByWorkspace[workspace.id] = try await changes
        } catch {
            present(error)
        }
    }

    func refreshAllWorkspaces() async {
        for workspace in workspaces {
            await refresh(workspace)
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

    func createDirectory(path input: String, in workspace: Workspace) async -> RepositoryDirectory? {
        guard let relativePath = DirectoryRelativePath(input) else {
            errorMessage = "Enter a safe repository-relative directory path without hidden or parent components."
            return nil
        }

        do {
            let directory = try await files.createDirectory(at: relativePath, in: workspace)
            await refresh(workspace)
            return directory
        } catch {
            present(error)
            return nil
        }
    }

    func sync(
        _ workspace: Workspace,
        message rawMessage: String,
        authorName rawAuthorName: String,
        authorEmail rawAuthorEmail: String
    ) async -> RepositorySyncResult? {
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorName = rawAuthorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorEmail = rawAuthorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !authorName.isEmpty, authorEmail.contains("@") else {
            errorMessage = "Enter a commit message, author name, and valid author email."
            return nil
        }

        let currentChanges = changesByWorkspace[workspace.id] ?? []
        guard !currentChanges.contains(where: { $0.kind == .conflicted }) else {
            errorMessage = "This working copy contains conflicts. Conflict resolution will be added in a later update."
            return nil
        }
        guard let token = keychain.readToken(), !token.isEmpty else {
            errorMessage = "Sign in with GitHub in Account settings before syncing."
            return nil
        }

        do {
            let result = try await git.syncAll(
                at: WorkspacePaths.repositoryURL(for: workspace),
                message: message,
                authorName: authorName,
                authorEmail: authorEmail,
                token: token
            )
            await refresh(workspace)
            return result
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
            directoriesByWorkspace[workspace.id] = nil
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
