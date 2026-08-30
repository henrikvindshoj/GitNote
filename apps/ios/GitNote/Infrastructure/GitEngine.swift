import Foundation
import SwiftGitX
import libgit2
import Darwin

private final class GitHubCredentialPayload: @unchecked Sendable {
    private let lock = NSLock()
    private let token: String
    private var hasProvidedToken = false

    init(token: String) {
        self.token = token
    }

    func takeToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !hasProvidedToken else { return nil }
        hasProvidedToken = true
        return token
    }
}

actor GitEngine {
    enum EngineError: LocalizedError {
        case destinationExists
        case conflictsUnsupported
        case gitOperation(operation: String, message: String)
        case noChanges

        var errorDescription: String? {
            switch self {
            case .destinationExists:
                "A local folder already exists for this repository."
            case .conflictsUnsupported:
                "This working copy contains conflicts. Conflict resolution will be added in a later update."
            case .gitOperation(let operation, let message):
                "Git could not \(operation): \(message)"
            case .noChanges:
                "There are no changes to commit."
            }
        }
    }

    func clone(from remoteURL: URL, to localURL: URL) async throws {
        guard !FileManager.default.fileExists(atPath: localURL.path) else {
            throw EngineError.destinationExists
        }
        _ = try await Repository.clone(from: remoteURL, to: localURL)
    }

    func changes(at localURL: URL) throws -> [RepositoryChange] {
        let repository = try Repository.open(at: localURL)
        return try repository.status().compactMap(Self.mapChange)
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func commitAll(
        at localURL: URL,
        message: String,
        authorName: String,
        authorEmail: String
    ) throws -> String {
        let repository = try Repository.open(at: localURL)
        guard try !repository.status().isEmpty else {
            throw EngineError.noChanges
        }

        try repository.config.set("user.name", to: authorName)
        try repository.config.set("user.email", to: authorEmail)
        try stageAll(at: localURL)

        // Reopen after writing the index so SwiftGitX cannot reuse an index
        // snapshot created while reading the pre-stage status.
        let stagedRepository = try Repository.open(at: localURL)
        let commit = try stagedRepository.commit(message: message)
        return commit.id.hex
    }

    func syncAll(
        at localURL: URL,
        message: String,
        authorName: String,
        authorEmail: String,
        token: String
    ) throws -> RepositorySyncResult {
        let repository = try Repository.open(at: localURL)
        let status = try repository.status()
        guard !status.contains(where: { entry in
            entry.status.contains(where: { if case .conflicted = $0 { true } else { false } })
        }) else {
            throw EngineError.conflictsUnsupported
        }
        let hasChanges = !status.isEmpty
        let commitID = hasChanges
            ? try commitAll(
                at: localURL,
                message: message,
                authorName: authorName,
                authorEmail: authorEmail
            )
            : nil

        try pushCurrentBranch(at: localURL, token: token)
        return RepositorySyncResult(commitID: commitID)
    }

    #if DEBUG
    func initializeRepository(at localURL: URL, isBare: Bool = false) throws {
        _ = try Repository.create(at: localURL, isBare: isBare)
    }

    func addOrigin(to localURL: URL, remoteURL: URL) throws {
        let repository = try Repository.open(at: localURL)
        try repository.remote.add(named: "origin", at: remoteURL)
    }

    func currentCommitID(at localURL: URL) throws -> String {
        var repositoryPointer: OpaquePointer?
        try check(git_repository_open(&repositoryPointer, localURL.path), operation: "open the repository")
        guard let repositoryPointer else {
            throw EngineError.gitOperation(operation: "open the repository", message: "No repository returned")
        }
        defer { git_repository_free(repositoryPointer) }

        var headPointer: OpaquePointer?
        try check(git_repository_head(&headPointer, repositoryPointer), operation: "read HEAD")
        guard let headPointer else {
            throw EngineError.gitOperation(operation: "read HEAD", message: "No reference returned")
        }
        defer { git_reference_free(headPointer) }

        guard let oid = git_reference_target(headPointer) else {
            throw EngineError.gitOperation(operation: "read HEAD", message: "HEAD has no commit")
        }
        var buffer = [CChar](repeating: 0, count: 41)
        guard git_oid_tostr(&buffer, buffer.count, oid) != nil else {
            throw EngineError.gitOperation(operation: "read HEAD", message: "Could not format the commit ID")
        }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
    #endif

    private func stageAll(at localURL: URL) throws {
        var repositoryPointer: OpaquePointer?
        try check(
            git_repository_open(&repositoryPointer, localURL.path),
            operation: "open the working copy"
        )
        guard let repositoryPointer else {
            throw EngineError.gitOperation(operation: "open the working copy", message: "No repository returned")
        }
        defer { git_repository_free(repositoryPointer) }

        var indexPointer: OpaquePointer?
        try check(
            git_repository_index(&indexPointer, repositoryPointer),
            operation: "open the index"
        )
        guard let indexPointer else {
            throw EngineError.gitOperation(operation: "open the index", message: "No index returned")
        }
        defer { git_index_free(indexPointer) }

        try check(
            git_index_add_all(indexPointer, nil, GIT_INDEX_ADD_DEFAULT.rawValue, nil, nil),
            operation: "stage new and modified files"
        )
        try check(
            git_index_update_all(indexPointer, nil, nil, nil),
            operation: "stage modified and deleted files"
        )
        try check(git_index_write(indexPointer), operation: "write the index")
    }

    private func pushCurrentBranch(at localURL: URL, token: String) throws {
        var repositoryPointer: OpaquePointer?
        try check(
            git_repository_open(&repositoryPointer, localURL.path),
            operation: "open the working copy"
        )
        guard let repositoryPointer else {
            throw EngineError.gitOperation(operation: "open the working copy", message: "No repository returned")
        }
        defer { git_repository_free(repositoryPointer) }

        var remotePointer: OpaquePointer?
        try check(
            git_remote_lookup(&remotePointer, repositoryPointer, "origin"),
            operation: "find the origin remote"
        )
        guard let remotePointer else {
            throw EngineError.gitOperation(operation: "find the origin remote", message: "No remote returned")
        }
        defer { git_remote_free(remotePointer) }

        var headPointer: OpaquePointer?
        try check(git_repository_head(&headPointer, repositoryPointer), operation: "find the current branch")
        guard let headPointer else {
            throw EngineError.gitOperation(operation: "find the current branch", message: "No branch returned")
        }
        defer { git_reference_free(headPointer) }

        guard git_reference_is_branch(headPointer) == 1,
              let rawBranchName = git_reference_name(headPointer) else {
            throw EngineError.gitOperation(
                operation: "push",
                message: "The working copy is not on a local branch"
            )
        }
        let branchName = String(cString: rawBranchName)

        var options = git_push_options()
        try check(
            git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION)),
            operation: "prepare the push"
        )

        let tokenPayload = Unmanaged.passRetained(GitHubCredentialPayload(token: token))
        defer { tokenPayload.release() }
        options.callbacks.payload = tokenPayload.toOpaque()
        options.callbacks.credentials = { credential, _, _, allowedTypes, payload in
            guard let payload,
                  allowedTypes & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0 else {
                return GIT_PASSTHROUGH.rawValue
            }

            let credentialPayload = Unmanaged<GitHubCredentialPayload>
                .fromOpaque(payload)
                .takeUnretainedValue()
            guard let token = credentialPayload.takeToken() else {
                return GIT_EAUTH.rawValue
            }
            return token.withCString { rawToken in
                "x-access-token".withCString { username in
                    git_credential_userpass_plaintext_new(credential, username, rawToken)
                }
            }
        }

        guard let branchCString = strdup(branchName) else {
            throw EngineError.gitOperation(operation: "prepare the push", message: "Could not allocate the branch refspec")
        }
        defer { free(branchCString) }

        let refspecStorage = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 1)
        defer { refspecStorage.deallocate() }
        refspecStorage.initialize(to: branchCString)
        var refspecs = git_strarray(strings: refspecStorage, count: 1)
        try check(
            git_remote_push(remotePointer, &refspecs, &options),
            operation: "push the current branch to GitHub"
        )
    }

    private func check(_ result: Int32, operation: String) throws {
        guard result >= 0 else {
            let message: String
            if let error = git_error_last(), let rawMessage = error.pointee.message {
                message = String(cString: rawMessage)
            } else {
                message = "libgit2 error \(result)"
            }
            throw EngineError.gitOperation(operation: operation, message: message)
        }
    }

    private static func mapChange(_ entry: StatusEntry) -> RepositoryChange? {
        let delta = entry.workingTree ?? entry.index
        guard let delta else { return nil }

        let newPath = delta.newFile.path
        let oldPath = delta.oldFile.path
        let path = newPath.isEmpty ? oldPath : newPath
        guard !path.isEmpty else { return nil }

        let staged = entry.status.contains { status in
            switch status {
            case .indexNew, .indexModified, .indexDeleted, .indexRenamed, .indexTypeChange:
                true
            default:
                false
            }
        }

        let kind: RepositoryChange.Kind
        if entry.status.contains(where: { if case .conflicted = $0 { true } else { false } }) {
            kind = .conflicted
        } else if entry.status.contains(where: { status in
            if case .workingTreeNew = status { return true }
            if case .indexNew = status { return true }
            return false
        }) {
            kind = .added
        } else if entry.status.contains(where: { status in
            if case .workingTreeDeleted = status { return true }
            if case .indexDeleted = status { return true }
            return false
        }) {
            kind = .deleted
        } else if entry.status.contains(where: { status in
            if case .workingTreeRenamed = status { return true }
            if case .indexRenamed = status { return true }
            return false
        }) {
            kind = .renamed
        } else if entry.status.contains(where: { status in
            if case .workingTreeTypeChange = status { return true }
            if case .indexTypeChange = status { return true }
            return false
        }) {
            kind = .typeChanged
        } else if entry.status.contains(where: { if case .workingTreeUnreadable = $0 { true } else { false } }) {
            kind = .unreadable
        } else if entry.status.contains(where: { status in
            if case .workingTreeModified = status { return true }
            if case .indexModified = status { return true }
            return false
        }) {
            kind = .modified
        } else {
            kind = .unknown
        }

        return RepositoryChange(path: path, kind: kind, isStaged: staged)
    }
}
