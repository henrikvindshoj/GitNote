import Foundation
import SwiftGitX
import libgit2
import Darwin

final class GitHubCredentialPayload: @unchecked Sendable {
    private let lock = NSLock()
    private let token: String?
    let expectedURL: URL
    private let deadline = Date().addingTimeInterval(120)
    private var checkoutBytes: UInt64 = 0
    private var checkoutFiles = 0
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    func withinBudget(bytes: Int = 0, objects: UInt32 = 0, checkoutSize: UInt64? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let checkoutSize { checkoutBytes += checkoutSize; checkoutFiles += 1 }
        return !cancelled && Date() < deadline && bytes <= 100_000_000 && objects <= 20_000
            && checkoutBytes <= 100_000_000 && checkoutFiles <= 10_000
            && (checkoutSize ?? 0) <= 20_000_000
    }
    private var hasProvidedToken = false

    init(token: String?, expectedURL: URL) {
        self.token = token
        self.expectedURL = expectedURL
    }

    func takeToken(for url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !hasProvidedToken, GitRemotePolicy.matches(url, expected: expectedURL) else { return nil }
        hasProvidedToken = true
        return token
    }
}

private final class CheckoutValidationPayload {
    let odb: OpaquePointer
    let budget: GitHubCredentialPayload
    init(odb: OpaquePointer, budget: GitHubCredentialPayload) { self.odb = odb; self.budget = budget }
}

actor GitEngine {
    #if DEBUG
    private let allowLocalTestRemotes: Bool
    init(allowLocalTestRemotes: Bool = false) { self.allowLocalTestRemotes = allowLocalTestRemotes }
    #endif

    private func validateRemote(_ url: URL, expected: URL) throws {
        #if DEBUG
        if allowLocalTestRemotes && url.isFileURL && expected.isFileURL && url == expected { return }
        #endif
        guard GitRemotePolicy.matches(url, expected: expected) else { throw EngineError.untrustedRemote }
    }

    enum EngineError: LocalizedError {
        case divergedHistory
        case localChangesNeedMerge
        case invalidCommitIdentity
        case untrustedRemote
        case resourceLimit
        case destinationExists
        case conflictsUnsupported
        case gitOperation(operation: String, message: String)
        case noChanges

        var errorDescription: String? {
            switch self {
            case .divergedHistory:
                "This device and GitHub both have commits the other does not have. Your local commits are preserved. Merge them using a Git client before syncing again."
            case .localChangesNeedMerge:
                "GitHub has newer commits and this device has unsaved-to-Git file changes. Your files have not been replaced. Preserve and merge those edits using a Git client, then sync again."
            case .invalidCommitIdentity:
                "Local changes need a commit message, author name, and valid email before they can be uploaded."
            case .untrustedRemote:
                "The Git remote does not match this workspace’s GitHub HTTPS repository. Restore its origin and push URL before syncing."
            case .resourceLimit:
                "Download stopped: cancelled, timed out, or exceeded the safety limit (100 MB transfer/checkout, 20,000 objects, 10,000 files, 20 MB per file)."
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

    func clone(from remoteURL: URL, to localURL: URL, token: String? = nil) async throws {
        try validateRemote(remoteURL, expected: remoteURL)
        guard !FileManager.default.fileExists(atPath: localURL.path) else {
            throw EngineError.destinationExists
        }

        try SwiftGitXRuntime.initialize()
        defer { _ = try? SwiftGitXRuntime.shutdown() }

        var options = git_clone_options()
        try check(
            git_clone_options_init(&options, UInt32(GIT_CLONE_OPTIONS_VERSION)),
            operation: "prepare the clone"
        )
        options.fetch_opts.follow_redirects = GIT_REMOTE_REDIRECT_NONE

        let budget = GitHubCredentialPayload(token: token, expectedURL: remoteURL)
        let tokenPayload = Unmanaged.passRetained(budget)
        defer { tokenPayload.release() }
        options.fetch_opts.callbacks.payload = tokenPayload.toOpaque()
        options.fetch_opts.callbacks.credentials = Self.githubCredentials
        options.fetch_opts.callbacks.certificate_check = Self.githubCertificate
        options.fetch_opts.callbacks.transfer_progress = Self.transferProgress
        options.checkout_opts.checkout_strategy = GIT_CHECKOUT_NONE.rawValue
        options.checkout_opts.notify_flags = GIT_CHECKOUT_NOTIFY_ALL.rawValue
        options.checkout_opts.notify_cb = Self.checkoutBudget
        options.checkout_opts.notify_payload = tokenPayload.toOpaque()

        var repositoryPointer: OpaquePointer?
        var result = await withTaskCancellationHandler {
            remoteURL.absoluteString.withCString { rawRemoteURL in
                localURL.path.withCString { rawLocalPath in
                    git_clone(&repositoryPointer, rawRemoteURL, rawLocalPath, &options)
                }
            }
        } onCancel: { budget.cancel() }
        if result >= 0, let repositoryPointer {
            do {
                try validateCheckout(repositoryPointer, budget: budget)
                options.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_RECREATE_MISSING.rawValue
                result = await withTaskCancellationHandler {
                    git_checkout_head(repositoryPointer, &options.checkout_opts)
                } onCancel: { budget.cancel() }
            } catch {
                git_repository_free(repositoryPointer)
                try? FileManager.default.removeItem(at: localURL)
                throw error
            }
        }
        if let repositoryPointer { git_repository_free(repositoryPointer) }
        if result < 0 {
            // This destination was absent before this operation; never leave a partial clone.
            try? FileManager.default.removeItem(at: localURL)
            if result == GIT_EUSER.rawValue { throw EngineError.resourceLimit }
        }
        try check(result, operation: "clone the repository")
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
        token: String,
        expectedRemoteURL: URL
    ) throws -> RepositorySyncResult {
        let repository = try Repository.open(at: localURL)
        try validateOrigin(at: localURL, expected: expectedRemoteURL)
        let status = try repository.status()
        guard !status.contains(where: { entry in
            entry.status.contains(where: { if case .conflicted = $0 { true } else { false } })
        }) else {
            throw EngineError.conflictsUnsupported
        }
        let update = try fetchAndIntegrate(at: localURL, token: token, expectedRemoteURL: expectedRemoteURL)
        // Re-read after network I/O: Files or another editor may have changed the copy.
        let hasChanges = try !Repository.open(at: localURL).status().isEmpty
        if hasChanges {
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  authorEmail.contains("@") else { throw EngineError.invalidCommitIdentity }
        }
        let commitID = hasChanges
            ? try commitAll(at: localURL, message: message, authorName: authorName, authorEmail: authorEmail)
            : nil
        let needsPush = hasChanges || update == .needsPush
        if needsPush {
            try pushCurrentBranch(at: localURL, token: token, expectedRemoteURL: expectedRemoteURL)
        }
        return RepositorySyncResult(commitID: commitID, pulled: update == .pulled, pushed: needsPush)
    }

    private enum RemoteUpdate { case upToDate, pulled, needsPush }

    private func fetchAndIntegrate(at localURL: URL, token: String, expectedRemoteURL: URL) throws -> RemoteUpdate {
        var repository: OpaquePointer?
        try check(git_repository_open(&repository, localURL.path), operation: "open repository")
        guard let repository else { throw EngineError.conflictsUnsupported }
        defer { git_repository_free(repository) }
        guard git_repository_state(repository) == GIT_REPOSITORY_STATE_NONE.rawValue else {
            throw EngineError.conflictsUnsupported
        }
        var remote: OpaquePointer?
        try check(git_remote_lookup(&remote, repository, "origin"), operation: "find origin")
        guard let remote else { throw EngineError.untrustedRemote }
        defer { git_remote_free(remote) }
        try validateRemotePointer(remote, expected: expectedRemoteURL)
        var options = git_fetch_options()
        try check(git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION)), operation: "prepare download")
        options.follow_redirects = GIT_REMOTE_REDIRECT_NONE
        options.download_tags = GIT_REMOTE_DOWNLOAD_TAGS_NONE
        options.prune = GIT_FETCH_PRUNE
        let budget = GitHubCredentialPayload(token: token, expectedURL: expectedRemoteURL)
        let payload = Unmanaged.passRetained(budget)
        defer { payload.release() }
        options.callbacks.payload = payload.toOpaque()
        options.callbacks.credentials = Self.githubCredentials
        options.callbacks.certificate_check = Self.githubCertificate
        options.callbacks.transfer_progress = Self.transferProgress
        // An explicit destination prevents mutable fetch configuration from writing
        // local branches. '+' only permits updates to remote-tracking references.
        guard let spec = strdup("+refs/heads/*:refs/remotes/origin/*") else { throw EngineError.resourceLimit }
        defer { free(spec) }
        var specPointer: UnsafeMutablePointer<CChar>? = spec
        let fetchResult = withUnsafeMutablePointer(to: &specPointer) { pointer in
            var specs = git_strarray(strings: pointer, count: 1)
            return git_remote_fetch(remote, &specs, &options, "GitNote: fetch before sync")
        }
        if fetchResult == GIT_EUSER.rawValue { throw EngineError.resourceLimit }
        try check(fetchResult, operation: "download changes from GitHub")

        var head: OpaquePointer?
        let headResult = git_repository_head(&head, repository)
        if headResult == GIT_EUNBORNBRANCH.rawValue { return .needsPush }
        try check(headResult, operation: "read current branch")
        guard let head else { throw EngineError.conflictsUnsupported }
        defer { git_reference_free(head) }
        guard git_reference_is_branch(head) == 1,
              let rawName = git_reference_name(head), let localOID = git_reference_target(head) else {
            throw EngineError.conflictsUnsupported
        }
        let branchName = String(cString: rawName)
        let remoteName = "refs/remotes/origin/" + branchName.dropFirst("refs/heads/".count)
        var tracking: OpaquePointer?
        let trackingResult = git_reference_lookup(&tracking, repository, remoteName)
        if trackingResult == GIT_ENOTFOUND.rawValue { return .needsPush }
        try check(trackingResult, operation: "read downloaded branch")
        guard let tracking else { throw EngineError.conflictsUnsupported }
        defer { git_reference_free(tracking) }
        guard let remoteOID = git_reference_target(tracking) else { throw EngineError.conflictsUnsupported }
        if git_oid_equal(localOID, remoteOID) == 1 { return .upToDate }
        let localAhead = git_graph_descendant_of(repository, localOID, remoteOID)
        try check(localAhead, operation: "compare local commits")
        if localAhead == 1 { return .needsPush }
        let remoteAhead = git_graph_descendant_of(repository, remoteOID, localOID)
        try check(remoteAhead, operation: "compare GitHub commits")
        guard remoteAhead == 1 else { throw EngineError.divergedHistory }

        // Lock HEAD and its branch before checking out; another Git client must
        // not switch/update the branch during the filesystem/ref update.
        var transaction: OpaquePointer?
        try check(git_transaction_new(&transaction, repository), operation: "prepare branch update")
        guard let transaction else { throw EngineError.conflictsUnsupported }
        defer { git_transaction_free(transaction) }
        try check(git_transaction_lock_ref(transaction, "HEAD"), operation: "lock HEAD")
        try check(git_transaction_lock_ref(transaction, branchName), operation: "lock current branch")
        var current: OpaquePointer?
        try check(git_repository_head(&current, repository), operation: "verify current branch")
        guard let current else { throw EngineError.conflictsUnsupported }
        defer { git_reference_free(current) }
        guard let currentName = git_reference_name(current), String(cString: currentName) == branchName,
              let currentOID = git_reference_target(current), git_oid_equal(currentOID, localOID) == 1 else {
            throw EngineError.localChangesNeedMerge
        }
        guard try Repository.open(at: localURL).status().isEmpty else { throw EngineError.localChangesNeedMerge }
        var target: OpaquePointer?
        try check(git_commit_lookup(&target, repository, remoteOID), operation: "read downloaded commit")
        guard let target else { throw EngineError.conflictsUnsupported }
        defer { git_commit_free(target) }
        try validateCheckout(repository, budget: budget, target: target)
        var checkout = git_checkout_options()
        try check(git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)), operation: "prepare local update")
        checkout.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_DONT_OVERWRITE_IGNORED.rawValue
        checkout.notify_flags = GIT_CHECKOUT_NOTIFY_ALL.rawValue
        checkout.notify_cb = Self.checkoutBudget
        checkout.notify_payload = payload.toOpaque()
        let checkoutResult = git_checkout_tree(repository, target, &checkout)
        if checkoutResult == GIT_EUSER.rawValue { throw EngineError.resourceLimit }
        try check(checkoutResult, operation: "update local notes without overwriting edits")
        try check(git_transaction_set_target(transaction, branchName, remoteOID, nil, "GitNote: fast-forward from GitHub"), operation: "prepare updated branch")
        try check(git_transaction_commit(transaction), operation: "save updated branch")
        return .pulled
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

    private func pushCurrentBranch(at localURL: URL, token: String, expectedRemoteURL: URL) throws {
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
        try validateRemotePointer(remotePointer, expected: expectedRemoteURL)

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
        options.follow_redirects = GIT_REMOTE_REDIRECT_NONE

        let tokenPayload = Unmanaged.passRetained(GitHubCredentialPayload(token: token, expectedURL: expectedRemoteURL))
        defer { tokenPayload.release() }
        options.callbacks.payload = tokenPayload.toOpaque()
        options.callbacks.credentials = Self.githubCredentials
        options.callbacks.certificate_check = Self.githubCertificate

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

    private func validateCheckout(_ repository: OpaquePointer, budget: GitHubCredentialPayload, target: OpaquePointer? = nil) throws {
        var tree: OpaquePointer?
        if let target {
            try check(git_object_peel(&tree, target, GIT_OBJECT_TREE), operation: "inspect downloaded tree")
        } else {
            var head: OpaquePointer?
            let headResult = git_repository_head(&head, repository)
            if headResult == GIT_EUNBORNBRANCH.rawValue { return }
            try check(headResult, operation: "inspect clone HEAD")
            guard let head else { throw EngineError.resourceLimit }
            defer { git_reference_free(head) }
            try check(git_reference_peel(&tree, head, GIT_OBJECT_TREE), operation: "inspect clone tree")
        }
        guard let tree else { throw EngineError.resourceLimit }
        defer { git_tree_free(tree) }
        var odb: OpaquePointer?
        try check(git_repository_odb(&odb, repository), operation: "inspect clone objects")
        guard let odb else { throw EngineError.resourceLimit }
        defer { git_odb_free(odb) }
        let payload = Unmanaged.passRetained(CheckoutValidationPayload(odb: odb, budget: budget))
        defer { payload.release() }
        let result = git_tree_walk(tree, GIT_TREEWALK_PRE, { _, entry, rawPayload in
            guard let entry, let rawPayload else { return GIT_EUSER.rawValue }
            let payload = Unmanaged<CheckoutValidationPayload>.fromOpaque(rawPayload).takeUnretainedValue()
            guard payload.budget.withinBudget() else { return GIT_EUSER.rawValue }
            guard git_tree_entry_type(entry) == GIT_OBJECT_BLOB else { return 0 }
            var size = 0
            var type = GIT_OBJECT_ANY
            let result = git_odb_read_header(&size, &type, payload.odb, git_tree_entry_id(entry))
            guard result == 0 else { return result }
            return payload.budget.withinBudget(checkoutSize: UInt64(size)) ? 0 : GIT_EUSER.rawValue
        }, payload.toOpaque())
        if result == GIT_EUSER.rawValue { throw EngineError.resourceLimit }
        try check(result, operation: "validate checkout size")
    }

    private func validateRemotePointer(_ remote: OpaquePointer, expected: URL) throws {
        guard let rawURL = git_remote_url(remote), let url = URL(string: String(cString: rawURL)) else {
            throw EngineError.untrustedRemote
        }
        try validateRemote(url, expected: expected)
        if let push = git_remote_pushurl(remote) {
            guard let url = URL(string: String(cString: push)) else { throw EngineError.untrustedRemote }
            try validateRemote(url, expected: expected)
        }
    }

    private func validateOrigin(at localURL: URL, expected: URL) throws {
        try validateRemote(expected, expected: expected)
        var repo: OpaquePointer?
        try check(git_repository_open(&repo, localURL.path), operation: "open repository")
        guard let repo else { throw EngineError.untrustedRemote }
        defer { git_repository_free(repo) }
        var remote: OpaquePointer?
        try check(git_remote_lookup(&remote, repo, "origin"), operation: "find origin")
        guard let remote else { throw EngineError.untrustedRemote }
        defer { git_remote_free(remote) }
        try validateRemotePointer(remote, expected: expected)
    }

    private static let githubCertificate: git_transport_certificate_check_cb = { _, valid, hostname, _ in
        guard valid == 1, let hostname, String(cString: hostname).lowercased() == "github.com" else {
            return GIT_ECERTIFICATE.rawValue
        }
        return 0
    }

    private static let transferProgress: git_indexer_progress_cb = { stats, payload in
        guard let stats, let payload else { return GIT_EUSER.rawValue }
        let budget = Unmanaged<GitHubCredentialPayload>.fromOpaque(payload).takeUnretainedValue()
        return budget.withinBudget(bytes: stats.pointee.received_bytes, objects: stats.pointee.total_objects)
            ? 0 : GIT_EUSER.rawValue
    }

    private static let checkoutBudget: git_checkout_notify_cb = { _, _, _, _, _, payload in
        guard let payload else { return GIT_EUSER.rawValue }
        let budget = Unmanaged<GitHubCredentialPayload>.fromOpaque(payload).takeUnretainedValue()
        return budget.withinBudget()
            ? 0 : GIT_EUSER.rawValue
    }

    private func check(_ result: Int32, operation: String) throws {
        guard result >= 0 else {
            let message: String
            if result == GIT_EAUTH.rawValue {
                message = "GitHub authentication failed. Reconnect your GitHub account and check that it has write access to this repository."
            } else if let error = git_error_last(), let rawMessage = error.pointee.message {
                message = String(cString: rawMessage)
            } else {
                message = "libgit2 error \(result)"
            }
            throw EngineError.gitOperation(operation: operation, message: message)
        }
    }

    private static let githubCredentials: git_credential_acquire_cb = {
        credential, rawURL, _, allowedTypes, payload in
        guard let payload,
              allowedTypes & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0 else {
            return GIT_PASSTHROUGH.rawValue
        }

        let credentialPayload = Unmanaged<GitHubCredentialPayload>
            .fromOpaque(payload)
            .takeUnretainedValue()
        guard let rawURL, let url = URL(string: String(cString: rawURL)),
              let token = credentialPayload.takeToken(for: url) else {
            git_error_set_str(Int32(GIT_ERROR_HTTP.rawValue), "GitHub rejected the supplied credentials")
            return GIT_EAUTH.rawValue
        }
        return token.withCString { rawToken in
            "x-access-token".withCString { username in
                git_credential_userpass_plaintext_new(credential, username, rawToken)
            }
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
