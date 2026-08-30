import XCTest
@testable import GitNote

private final class OAuthURLProtocol: URLProtocol {
    nonisolated(unsafe) static var response: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let response = Self.response else { throw URLError(.badServerResponse) }
            let (httpResponse, data) = try response(request)
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class RepositoryAddressTests: XCTestCase {
    func testParsesOwnerAndRepository() {
        let address = RepositoryAddress("henrikvindshoj/GitNote")

        XCTAssertEqual(address?.owner, "henrikvindshoj")
        XCTAssertEqual(address?.name, "GitNote")
        XCTAssertEqual(address?.cloneURL.absoluteString, "https://github.com/henrikvindshoj/GitNote.git")
    }

    func testParsesGitHubURLAndRemovesGitSuffix() {
        let address = RepositoryAddress("https://github.com/henrikvindshoj/GitNote.git")

        XCTAssertEqual(address?.fullName, "henrikvindshoj/GitNote")
    }

    func testRejectsUnsupportedAddresses() {
        XCTAssertNil(RepositoryAddress("https://example.com/owner/repo"))
        XCTAssertNil(RepositoryAddress("owner/repo/extra"))
        XCTAssertNil(RepositoryAddress("owner"))
        XCTAssertNil(RepositoryAddress(""))
    }
}

final class MarkdownRelativePathTests: XCTestCase {
    func testAddsMarkdownExtensionWhenMissing() {
        XCTAssertEqual(MarkdownRelativePath("notes/idea")?.value, "notes/idea.md")
    }

    func testPreservesSupportedExtensions() {
        XCTAssertEqual(MarkdownRelativePath("README.md")?.value, "README.md")
        XCTAssertEqual(MarkdownRelativePath("Notes/Plan.markdown")?.value, "Notes/Plan.markdown")
    }

    func testRejectsTraversalAndUnsupportedFiles() {
        XCTAssertNil(MarkdownRelativePath("../secret.md"))
        XCTAssertNil(MarkdownRelativePath("/absolute.md"))
        XCTAssertNil(MarkdownRelativePath("notes//idea.md"))
        XCTAssertNil(MarkdownRelativePath("notes/idea.txt"))
        XCTAssertNil(MarkdownRelativePath(".hidden.md"))
    }
}

final class KeychainStoreTests: XCTestCase {
    func testTokenRoundTrip() throws {
        let store = KeychainStore(
            service: "com.henrikvindshoj.GitNoteTests.\(UUID().uuidString)",
            account: "github-token"
        )
        defer { try? store.deleteToken() }

        XCTAssertNil(store.readToken())
        try store.saveToken("oauth-test-token")
        XCTAssertEqual(store.readToken(), "oauth-test-token")
        try store.deleteToken()
        XCTAssertNil(store.readToken())
    }
}

@MainActor
final class GitHubOAuthClientTests: XCTestCase {
    override func tearDown() {
        OAuthURLProtocol.response = nil
        super.tearDown()
    }

    func testDeviceFlowReturnsAuthorizedToken() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthURLProtocol.self]
        let client = GitHubOAuthClient(session: URLSession(configuration: configuration))

        OAuthURLProtocol.response = { request in
            let data: Data
            switch request.url?.path {
            case "/login/device/code":
                data = Data(#"{"device_code":"device-123","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":30,"interval":1}"#.utf8)
            case "/login/oauth/access_token":
                data = Data(#"{"access_token":"oauth-token","token_type":"bearer","scope":"public_repo"}"#.utf8)
            default:
                throw URLError(.unsupportedURL)
            }
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let authorization = try await client.begin(clientID: "client-id")
        XCTAssertEqual(authorization.userCode, "ABCD-EFGH")
        XCTAssertEqual(authorization.verificationURI.absoluteString, "https://github.com/login/device")

        let token = try await client.waitForToken(
            authorization: authorization,
            clientID: "client-id"
        )
        XCTAssertEqual(token, "oauth-token")
    }
}

@MainActor
final class GitEngineTests: XCTestCase {
    func testSyncAllPushesCommitToOrigin() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "GitNotePushTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let workingCopy = root.appending(path: "working", directoryHint: .isDirectory)
        let remote = root.appending(path: "remote.git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = GitEngine()
        try await engine.initializeRepository(at: remote, isBare: true)
        try await engine.initializeRepository(at: workingCopy)
        try await engine.addOrigin(to: workingCopy, remoteURL: remote)
        try "# Pushed note\n".write(
            to: workingCopy.appending(path: "Pushed.md"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await engine.syncAll(
            at: workingCopy,
            message: "Add pushed note",
            authorName: "GitNote Tests",
            authorEmail: "gitnote-tests@example.com",
            token: "unused-for-local-remote"
        )

        XCTAssertEqual(result.commitID?.count, 40)
        let remoteCommitID = try await engine.currentCommitID(at: remote)
        XCTAssertEqual(remoteCommitID, result.commitID)
        let remainingChanges = try await engine.changes(at: workingCopy)
        XCTAssertTrue(remainingChanges.isEmpty)

        try "# Not pushed yet\n".write(
            to: workingCopy.appending(path: "Retry.md"),
            atomically: true,
            encoding: .utf8
        )
        let unpublishedCommitID = try await engine.commitAll(
            at: workingCopy,
            message: "Create unpublished commit",
            authorName: "GitNote Tests",
            authorEmail: "gitnote-tests@example.com"
        )
        let remoteCommitBeforeRetry = try await engine.currentCommitID(at: remote)
        XCTAssertEqual(remoteCommitBeforeRetry, remoteCommitID)

        let retryResult = try await engine.syncAll(
            at: workingCopy,
            message: "Unused for a clean working tree",
            authorName: "GitNote Tests",
            authorEmail: "gitnote-tests@example.com",
            token: "unused-for-local-remote"
        )
        XCTAssertNil(retryResult.commitID)
        let remoteCommitAfterRetry = try await engine.currentCommitID(at: remote)
        XCTAssertEqual(remoteCommitAfterRetry, unpublishedCommitID)
    }

    func testCommitAllStagesAddedModifiedAndDeletedFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "GitNoteTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = GitEngine()
        do {
            try await engine.initializeRepository(at: root)
        } catch {
            XCTFail("Repository initialization failed: \(String(reflecting: error))")
            return
        }
        try "# First note\n".write(
            to: root.appending(path: "First.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Delete me\n".write(
            to: root.appending(path: "Deleted.md"),
            atomically: true,
            encoding: .utf8
        )

        _ = try await engine.commitAll(
            at: root,
            message: "Create baseline",
            authorName: "GitNote Tests",
            authorEmail: "gitnote-tests@example.com"
        )

        try "# First note, updated\n".write(
            to: root.appending(path: "First.md"),
            atomically: true,
            encoding: .utf8
        )
        try "# Added note\n".write(
            to: root.appending(path: "Added.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.removeItem(at: root.appending(path: "Deleted.md"))

        let dirtyChanges: [RepositoryChange]
        do {
            dirtyChanges = try await engine.changes(at: root)
        } catch {
            XCTFail("Dirty status failed: \(String(reflecting: error))")
            return
        }
        XCTAssertEqual(dirtyChanges.count, 3)
        XCTAssertEqual(Set(dirtyChanges.map(\.kind)), Set([.added, .modified, .deleted]))

        let commitID: String
        do {
            commitID = try await engine.commitAll(
                at: root,
                message: "Update notes",
                authorName: "GitNote Tests",
                authorEmail: "gitnote-tests@example.com"
            )
        } catch {
            XCTFail("Commit failed: \(String(reflecting: error))")
            return
        }

        XCTAssertEqual(commitID.count, 40)
        let cleanChanges: [RepositoryChange]
        do {
            cleanChanges = try await engine.changes(at: root)
        } catch {
            XCTFail("Clean status failed: \(String(reflecting: error))")
            return
        }
        XCTAssertTrue(cleanChanges.isEmpty)
    }
}
