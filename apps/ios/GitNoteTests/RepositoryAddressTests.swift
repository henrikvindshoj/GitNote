import XCTest
import SwiftUI
import UIKit
import Network
@testable import GitNote

@MainActor
private final class MarkdownEditorHarnessModel: ObservableObject {
    @Published var markdown = "Select this text"
    @Published var command: MarkdownEditorCommand?
}

private struct MarkdownEditorHarness: View {
    @ObservedObject var model: MarkdownEditorHarnessModel

    var body: some View {
        RichMarkdownDocumentView(
            markdown: $model.markdown,
            command: $model.command
        )
    }
}

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

final class DirectoryRelativePathTests: XCTestCase {
    func testAcceptsNestedDirectoryPath() {
        XCTAssertEqual(DirectoryRelativePath("Notes/Research")?.value, "Notes/Research")
    }

    func testRejectsUnsafeDirectoryPaths() {
        XCTAssertNil(DirectoryRelativePath("../Secrets"))
        XCTAssertNil(DirectoryRelativePath("/Absolute"))
        XCTAssertNil(DirectoryRelativePath("Notes//Research"))
        XCTAssertNil(DirectoryRelativePath(".git"))
        XCTAssertNil(DirectoryRelativePath("Notes/"))
    }
}

final class WorkspaceDirectoryTests: XCTestCase {
    func testCreatesAndDiscoversNestedAndEmptyDirectories() async throws {
        let repository = GitHubRepository(
            id: Int64.random(in: 1...Int64.max),
            name: "directory-test",
            fullName: "tests/directory-test",
            owner: GitHubRepository.Owner(login: "tests"),
            cloneURL: URL(string: "https://github.com/tests/directory-test.git")!,
            defaultBranch: "main",
            isPrivate: true,
            isFork: false,
            summary: nil,
            pushedAt: nil
        )
        let workspace = Workspace(
            repository: repository,
            localFolderName: "GitNoteDirectoryTests-\(UUID().uuidString)"
        )
        let root = WorkspacePaths.repositoryURL(for: workspace)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = WorkspaceFileService()
        let directoryPath = try XCTUnwrap(DirectoryRelativePath("Notes/Empty"))
        _ = try await service.createDirectory(at: directoryPath, in: workspace)
        let filePath = try XCTUnwrap(MarkdownRelativePath("Notes/Idea.md"))
        _ = try await service.createMarkdownFile(
            at: filePath,
            contents: "# Idea\n",
            in: workspace
        )

        let contents = try await service.contents(in: workspace)
        XCTAssertEqual(contents.directories.map(\.relativePath), ["Notes", "Notes/Empty"])
        XCTAssertEqual(contents.directories.map(\.parentPath), ["", "Notes"])
        XCTAssertEqual(contents.markdownFiles.map(\.relativePath), ["Notes/Idea.md"])
    }
}

@MainActor
final class MarkdownRichCodecTests: XCTestCase {
    func testToolbarCommandFormatsSelectionThroughSwiftUIBridge() throws {
        let model = MarkdownEditorHarnessModel()
        let host = UIHostingController(rootView: MarkdownEditorHarness(model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()

        let textView = try XCTUnwrap(findTextView(in: host.view))
        textView.becomeFirstResponder()
        textView.selectedRange = NSRange(location: 7, length: 4)
        model.command = MarkdownEditorCommand(action: .bold)
        waitForViewUpdate()

        XCTAssertEqual(model.markdown, "Select **this** text")
        let font = try XCTUnwrap(
            textView.textStorage.attribute(.font, at: 7, effectiveRange: nil) as? UIFont
        )
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))

        model.command = MarkdownEditorCommand(action: .italic)
        waitForViewUpdate()
        XCTAssertEqual(model.markdown, "Select ***this*** text")
    }

    func testToolbarRestoresSelectionAfterEditorLosesFocus() throws {
        let model = MarkdownEditorHarnessModel()
        let host = UIHostingController(rootView: MarkdownEditorHarness(model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()

        let textView = try XCTUnwrap(findTextView(in: host.view))
        textView.becomeFirstResponder()
        textView.selectedRange = NSRange(location: 7, length: 4)
        textView.delegate?.textViewDidChangeSelection?(textView)
        textView.resignFirstResponder()
        textView.selectedRange = NSRange(location: 11, length: 0)

        model.command = MarkdownEditorCommand(action: .bold)
        waitForViewUpdate()

        XCTAssertEqual(model.markdown, "Select **this** text")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 7, length: 4))
    }

    func testBasicMarkdownRoundTripUsesVisibleRichContent() throws {
        let markdown = "# Project\n\nThis is **important**.\n\n- First\n- Second\n\n> A quote"

        let richDocument = MarkdownRichCodec.decode(markdown)

        XCTAssertFalse(richDocument.string.contains("#"))
        XCTAssertFalse(richDocument.string.contains("**"))
        XCTAssertTrue(richDocument.string.contains("Project"))
        XCTAssertTrue(richDocument.string.contains("• First"))
        XCTAssertEqual(MarkdownRichCodec.encode(richDocument), markdown)
    }

    func testHeadingFormattingCreatesMarkdownWithoutVisibleSyntax() {
        let textView = UITextView()
        textView.attributedText = MarkdownRichCodec.decode("Project")
        textView.selectedRange = NSRange(location: 0, length: 7)

        MarkdownRichCommandApplier.apply(.heading(2), to: textView)

        XCTAssertEqual(textView.text, "Project")
        XCTAssertEqual(MarkdownRichCodec.encode(textView.attributedText), "## Project")
    }

    func testParagraphFormattingRemovesStructuralHeadingBold() {
        let textView = UITextView()
        textView.attributedText = MarkdownRichCodec.decode("## Project")
        textView.selectedRange = NSRange(location: 0, length: 7)

        MarkdownRichCommandApplier.apply(.paragraph, to: textView)

        XCTAssertEqual(MarkdownRichCodec.encode(textView.attributedText), "Project")
    }

    func testOrderedListAndMultilineCodeRoundTrip() {
        let markdown = "3. Third\n4. Fourth\n\n```\nlet first = 1\nlet second = 2\n```"

        XCTAssertEqual(
            MarkdownRichCodec.encode(MarkdownRichCodec.decode(markdown)),
            markdown
        )
    }

    func testReturnContinuesAListWithAVisibleBullet() {
        let textView = UITextView()
        textView.attributedText = MarkdownRichCodec.decode("- First")
        textView.selectedRange = NSRange(location: textView.textStorage.length, length: 0)

        let handled = MarkdownRichCommandApplier.handleReturn(
            in: textView,
            replacing: textView.selectedRange
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(textView.text, "• First\n• ")
        XCTAssertEqual(MarkdownRichCodec.encode(textView.attributedText), "- First\n- ")
    }

    func testReturnOnEmptyListItemExitsTheList() {
        let textView = UITextView()
        textView.attributedText = MarkdownRichCodec.decode("- First\n- ")
        textView.selectedRange = NSRange(location: textView.textStorage.length, length: 0)

        let handled = MarkdownRichCommandApplier.handleReturn(
            in: textView,
            replacing: textView.selectedRange
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(textView.text, "• First\n")
        XCTAssertEqual(MarkdownRichCodec.encode(textView.attributedText), "- First")
    }

    func testLinkCommandUsesProvidedDestination() {
        let textView = UITextView()
        textView.attributedText = MarkdownRichCodec.decode("OpenAI")
        textView.selectedRange = NSRange(location: 0, length: 6)

        MarkdownRichCommandApplier.apply(
            MarkdownEditorCommand(
                action: .link,
                destination: "https://openai.com"
            ),
            to: textView
        )

        XCTAssertEqual(
            MarkdownRichCodec.encode(textView.attributedText),
            "[OpenAI](https://openai.com)"
        )
    }

    private func findTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) { return textView }
        }
        return nil
    }

    private func waitForViewUpdate() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
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
        XCTAssertEqual(GitHubOAuthClient.requestedScope, "public_repo")

        OAuthURLProtocol.response = { request in
            let data: Data
            switch request.url?.path {
            case "/login/device/code":
                data = Data(#"{"device_code":"device-123","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":30,"interval":1}"#.utf8)
            case "/login/oauth/access_token":
                data = Data(#"{"access_token":"oauth-token","token_type":"bearer","scope":"repo"}"#.utf8)
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
    func testSyncRejectsUntrustedRemoteBeforeSendingCredentialsOrCommitting() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "HTTP server ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        let connectionAttempt = expectation(description: "No connection to untrusted remote")
        connectionAttempt.isInverted = true
        listener.newConnectionHandler = { connection in
            connectionAttempt.fulfill()
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let response = Data((
                    "HTTP/1.1 401 Unauthorized\r\n"
                    + "WWW-Authenticate: Basic realm=\"GitNote test\"\r\n"
                    + "Content-Length: 0\r\nConnection: close\r\n\r\n"
                ).utf8)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let remote = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port.rawValue)/repo.git"))
        let root = FileManager.default.temporaryDirectory
            .appending(path: "GitNoteAuthTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = GitEngine()
        try await engine.initializeRepository(at: root)
        try await engine.addOrigin(to: root, remoteURL: remote)
        try "# Keep this note\n".write(
            to: root.appending(path: "Note.md"), atomically: true, encoding: .utf8
        )
        do {
            _ = try await engine.syncAll(
                at: root, message: "Save note", authorName: "Tests",
                authorEmail: "tests@example.com", token: "rejected-test-token",
                expectedRemoteURL: URL(string: "https://github.com/tests/notes.git")!
            )
            XCTFail("Expected authentication to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does not match"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("followRedirects"))
        }
        let changes = try await engine.changes(at: root)
        XCTAssertFalse(changes.isEmpty)
        await fulfillment(of: [connectionAttempt], timeout: 0.3)
    }

    func testCloneCreatesWorkingCopyWithCredentialCapablePath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "GitNoteCloneTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        let clone = root.appending(path: "clone", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = GitEngine(allowLocalTestRemotes: true)
        try await engine.initializeRepository(at: source)
        try "# Private note\n".write(
            to: source.appending(path: "Private.md"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await engine.commitAll(
            at: source,
            message: "Create private note",
            authorName: "GitNote Tests",
            authorEmail: "gitnote-tests@example.com"
        )

        try await engine.clone(from: source, to: clone, token: "credential-is-not-needed-locally")

        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.appending(path: "Private.md").path))
        let clonedChanges = try await engine.changes(at: clone)
        XCTAssertTrue(clonedChanges.isEmpty)
    }

    func testSyncAllPushesCommitToOrigin() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "GitNotePushTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let workingCopy = root.appending(path: "working", directoryHint: .isDirectory)
        let remote = root.appending(path: "remote.git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = GitEngine(allowLocalTestRemotes: true)
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
            token: "unused-for-local-remote",
            expectedRemoteURL: remote
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
            token: "unused-for-local-remote",
            expectedRemoteURL: remote
        )
        XCTAssertNil(retryResult.commitID)
        let remoteCommitAfterRetry = try await engine.currentCommitID(at: remote)
        XCTAssertEqual(remoteCommitAfterRetry, unpublishedCommitID)
    }

    func testOversizedCloneIsRejectedAndPartialDirectoryRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CloneBudget-" + UUID().uuidString)
        let source = root.appending(path: "source")
        let destination = root.appending(path: "clone")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = GitEngine(allowLocalTestRemotes: true)
        try await engine.initializeRepository(at: source)
        try Data(repeating: 65, count: 20_000_001).write(to: source.appending(path: "large.md"))
        _ = try await engine.commitAll(at: source, message: "Large fixture", authorName: "Tests", authorEmail: "tests@example.com")
        do {
            try await engine.clone(from: source, to: destination)
            XCTFail("Expected clone size limit")
        } catch GitEngine.EngineError.resourceLimit { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPushURLAndURLRewriteAreRejectedBeforeCommit() async throws {
        let expected = URL(string: "https://github.com/tests/notes.git")!
        for extraConfig in [
            "\n[remote \"origin\"]\n pushurl = https://attacker.invalid/notes.git\n",
            "\n[url \"https://attacker.invalid/\"]\n insteadOf = https://github.com/\n"
        ] {
            let root = FileManager.default.temporaryDirectory.appending(path: "RemotePolicy-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let engine = GitEngine()
            try await engine.initializeRepository(at: root)
            try await engine.addOrigin(to: root, remoteURL: expected)
            let config = root.appending(path: ".git/config")
            let original = try String(contentsOf: config, encoding: .utf8)
            try (original + extraConfig).write(to: config, atomically: true, encoding: .utf8)
            try "unchanged".write(to: root.appending(path: "note.md"), atomically: true, encoding: .utf8)
            do {
                _ = try await engine.syncAll(at: root, message: "Do not publish", authorName: "Tests", authorEmail: "tests@example.com", token: "dummy", expectedRemoteURL: expected)
                XCTFail("Accepted untrusted transport configuration")
            } catch GitEngine.EngineError.untrustedRemote { }
            let changes = try await engine.changes(at: root)
            XCTAssertFalse(changes.isEmpty)
        }
    }

    private func syncFixture() async throws -> (GitEngine, URL, URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "SyncFixture-" + UUID().uuidString)
        let writer = root.appending(path: "writer")
        let reader = root.appending(path: "reader")
        let remote = root.appending(path: "remote.git")
        let engine = GitEngine(allowLocalTestRemotes: true)
        try await engine.initializeRepository(at: remote, isBare: true)
        try await engine.initializeRepository(at: writer)
        try await engine.addOrigin(to: writer, remoteURL: remote)
        try "original".write(to: writer.appending(path: "note.md"), atomically: true, encoding: .utf8)
        _ = try await engine.syncAll(at: writer, message: "Initial", authorName: "Tests", authorEmail: "tests@example.com", token: "fixture", expectedRemoteURL: remote)
        try await engine.clone(from: remote, to: reader)
        return (engine, root, writer, reader, remote)
    }

    func testCleanSyncDownloadsNewCommitsWithoutCreatingOrPushingACommit() async throws {
        let (engine, root, writer, reader, remote) = try await syncFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: writer.appending(path: "note.md"))
        try "new note".write(to: writer.appending(path: "new.md"), atomically: true, encoding: .utf8)
        let published = try await engine.syncAll(at: writer, message: "Remote update", authorName: "Tests", authorEmail: "tests@example.com", token: "fixture", expectedRemoteURL: remote)
        let result = try await engine.syncAll(at: reader, message: "", authorName: "", authorEmail: "", token: "fixture", expectedRemoteURL: remote)
        XCTAssertTrue(result.pulled)
        XCTAssertFalse(result.pushed)
        XCTAssertNil(result.commitID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reader.appending(path: "note.md").path))
        XCTAssertEqual(try String(contentsOf: reader.appending(path: "new.md"), encoding: .utf8), "new note")
        let head = try await engine.currentCommitID(at: reader)
        XCTAssertEqual(head, published.commitID)
        let changes = try await engine.changes(at: reader)
        XCTAssertTrue(changes.isEmpty)
        let again = try await engine.syncAll(at: reader, message: "", authorName: "", authorEmail: "", token: "fixture", expectedRemoteURL: remote)
        XCTAssertFalse(again.pulled)
        XCTAssertFalse(again.pushed)
    }

    func testSyncPreservesUncommittedEditsWhenGitHubIsAhead() async throws {
        let (engine, root, writer, reader, remote) = try await syncFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldHead = try await engine.currentCommitID(at: reader)
        try "phone edit".write(to: reader.appending(path: "note.md"), atomically: true, encoding: .utf8)
        try "GitHub edit".write(to: writer.appending(path: "note.md"), atomically: true, encoding: .utf8)
        _ = try await engine.syncAll(at: writer, message: "Remote update", authorName: "Tests", authorEmail: "tests@example.com", token: "fixture", expectedRemoteURL: remote)
        do {
            _ = try await engine.syncAll(at: reader, message: "Local", authorName: "Tests", authorEmail: "tests@example.com", token: "fixture", expectedRemoteURL: remote)
            XCTFail("Must not overwrite or commit local edits")
        } catch GitEngine.EngineError.localChangesNeedMerge { }
        XCTAssertEqual(try String(contentsOf: reader.appending(path: "note.md"), encoding: .utf8), "phone edit")
        let head = try await engine.currentCommitID(at: reader)
        XCTAssertEqual(head, oldHead)
    }

    func testSyncPreservesDivergedLocalCommits() async throws {
        let (engine, root, writer, reader, remote) = try await syncFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "phone commit".write(to: reader.appending(path: "local.md"), atomically: true, encoding: .utf8)
        let localHead = try await engine.commitAll(at: reader, message: "Local", authorName: "Tests", authorEmail: "tests@example.com")
        try "remote commit".write(to: writer.appending(path: "remote.md"), atomically: true, encoding: .utf8)
        _ = try await engine.syncAll(at: writer, message: "Remote update", authorName: "Tests", authorEmail: "tests@example.com", token: "fixture", expectedRemoteURL: remote)
        do {
            _ = try await engine.syncAll(at: reader, message: "", authorName: "", authorEmail: "", token: "fixture", expectedRemoteURL: remote)
            XCTFail("Must not overwrite diverged history")
        } catch GitEngine.EngineError.divergedHistory { }
        let head = try await engine.currentCommitID(at: reader)
        XCTAssertEqual(head, localHead)
        XCTAssertEqual(try String(contentsOf: reader.appending(path: "local.md"), encoding: .utf8), "phone commit")
    }

    func testFastForwardDoesNotOverwriteIgnoredFiles() async throws {
        let (engine, root, writer, reader, remote) = try await syncFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "ignored.md\n".write(to: reader.appending(path: ".git/info/exclude"), atomically: true, encoding: .utf8)
        try "private local file".write(to: reader.appending(path: "ignored.md"), atomically: true, encoding: .utf8)
        try "remote file".write(to: writer.appending(path: "ignored.md"), atomically: true, encoding: .utf8)
        _ = try await engine.syncAll(at: writer, message: "Remote update", authorName: "Tests", authorEmail: "tests@example.com", token: "fixture", expectedRemoteURL: remote)
        let original = try await engine.currentCommitID(at: reader)
        do {
            _ = try await engine.syncAll(at: reader, message: "", authorName: "", authorEmail: "", token: "fixture", expectedRemoteURL: remote)
            XCTFail("Must preserve ignored files")
        } catch { }
        XCTAssertEqual(try String(contentsOf: reader.appending(path: "ignored.md"), encoding: .utf8), "private local file")
        let head = try await engine.currentCommitID(at: reader)
        XCTAssertEqual(head, original)
    }

    func testFastForwardAppliesCheckoutSizeLimitsBeforeChangingFiles() async throws {
        let (engine, root, writer, reader, remote) = try await syncFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 65, count: 20_000_001).write(to: writer.appending(path: "large.md"))
        _ = try await engine.syncAll(at: writer, message: "Large remote file", authorName: "Tests", authorEmail: "tests@example.com", token: "fixture", expectedRemoteURL: remote)
        let original = try await engine.currentCommitID(at: reader)
        do {
            _ = try await engine.syncAll(at: reader, message: "", authorName: "", authorEmail: "", token: "fixture", expectedRemoteURL: remote)
            XCTFail("Must enforce checkout budget")
        } catch GitEngine.EngineError.resourceLimit { }
        let head = try await engine.currentCommitID(at: reader)
        XCTAssertEqual(head, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reader.appending(path: "large.md").path))
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

final class SecurityBoundaryTests: XCTestCase {
    func testRemotePolicyRejectsHostConfusionAndOtherRepositories() throws {
        let expected = URL(string: "https://github.com/tests/notes.git")!
        for raw in ["http://github.com/tests/notes.git", "https://github.com.attacker.invalid/tests/notes.git",
                    "https://github.com@attacker.invalid/tests/notes.git", "https://user@github.com/tests/notes.git",
                    "https://github.com:444/tests/notes.git", "https://github.com/tests/other.git",
                    "https://github.com/tests/notes.git?query", "https://github.com/tests/notes.git#fragment",
                    "https://github.com/tests/%6eotes.git", "file:///tmp/notes", "https://github.com/../notes.git"] {
            XCTAssertFalse(GitRemotePolicy.matches(try XCTUnwrap(URL(string: raw)), expected: expected), raw)
        }
        XCTAssertTrue(GitRemotePolicy.matches(URL(string: "https://github.com:443/TESTS/notes")!, expected: expected))
        let credentials = GitHubCredentialPayload(token: "dummy-token", expectedURL: expected)
        XCTAssertNil(credentials.takeToken(for: URL(string: "https://attacker.invalid/tests/notes.git")!))
        XCTAssertEqual(credentials.takeToken(for: expected), "dummy-token")
        XCTAssertNil(credentials.takeToken(for: expected))
    }

    func testCloneBudgetAndCancellation() {
        let expected = URL(string: "https://github.com/tests/notes.git")!
        let budget = GitHubCredentialPayload(token: nil, expectedURL: expected)
        XCTAssertTrue(budget.withinBudget(bytes: 100, objects: 10, checkoutSize: 100))
        XCTAssertFalse(budget.withinBudget(bytes: 100_000_001))
        XCTAssertFalse(budget.withinBudget(objects: 20_001))
        XCTAssertFalse(budget.withinBudget(checkoutSize: 20_000_001))
        let cancelled = GitHubCredentialPayload(token: nil, expectedURL: expected)
        cancelled.cancel()
        XCTAssertFalse(cancelled.withinBudget())
    }

    func testFileServiceRejectsSymlinksStaleReferencesAndOversizedNotes() async throws {
        let repository = GitHubRepository(id: 1, name: "security", fullName: "tests/security",
            owner: .init(login: "tests"), cloneURL: URL(string: "https://github.com/tests/security.git")!,
            defaultBranch: "main", isPrivate: true, isFork: false, summary: nil, pushedAt: nil)
        let workspace = Workspace(repository: repository, localFolderName: "Security-" + UUID().uuidString)
        let root = WorkspacePaths.repositoryURL(for: workspace)
        let outside = root.deletingLastPathComponent().appending(path: "Outside-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }
        try "secret".write(to: outside.appending(path: "secret.md"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: root.appending(path: "linked"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appending(path: "broken"), withDestinationURL: outside.appending(path: "missing"))
        try fm.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appending(path: "internal"), withDestinationURL: root.appending(path: ".git"))
        let service = WorkspaceFileService()
        for path in ["linked/injected.md", "broken/injected.md", "internal/injected.md"] {
            do {
                _ = try await service.createMarkdownFile(at: MarkdownRelativePath(path)!, contents: "injected", in: workspace)
                XCTFail("Accepted symlink: " + path)
            } catch { }
        }
        XCTAssertFalse(fm.fileExists(atPath: outside.appending(path: "injected.md").path))
        let linked = MarkdownFile(url: root.appending(path: "linked/secret.md"), relativePath: "linked/secret.md")
        do { _ = try await service.read(linked, in: workspace); XCTFail("Read outside workspace") } catch { }
        do { try await service.write("changed", to: linked, in: workspace); XCTFail("Wrote outside workspace") } catch { }
        XCTAssertEqual(try String(contentsOf: outside.appending(path: "secret.md"), encoding: .utf8), "secret")
        let normal = try await service.createMarkdownFile(at: MarkdownRelativePath("normal/note.md")!, contents: "safe", in: workspace)
        try await service.write("saved", to: normal, in: workspace)
        let saved = try await service.read(normal, in: workspace)
        XCTAssertEqual(saved, "saved")
        try fm.removeItem(at: normal.url.deletingLastPathComponent())
        try fm.createSymbolicLink(at: normal.url.deletingLastPathComponent(), withDestinationURL: outside)
        do { try await service.write("changed", to: normal, in: workspace); XCTFail("Accepted stale path") } catch { }
        do {
            _ = try await service.createMarkdownFile(at: MarkdownRelativePath("huge.md")!, contents: String(repeating: "x", count: SecureWorkspaceIO.noteLimit + 1), in: workspace)
            XCTFail("Accepted oversized note")
        } catch { }
        try Data(repeating: 65, count: SecureWorkspaceIO.noteLimit + 1).write(to: root.appending(path: "huge.md"))
        do {
            _ = try await service.read(MarkdownFile(url: root.appending(path: "huge.md"), relativePath: "huge.md"), in: workspace)
            XCTFail("Read oversized note")
        } catch { }
    }
}

@MainActor
final class SecureImageTests: XCTestCase {
    func testLocalThumbnailAndRejectedExternalHiddenAndOversizedImages() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "Images-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData())
        try png.write(to: root.appending(path: "image.png"))
        let context = MarkdownImageContext(repositoryRoot: root, documentURL: root.appending(path: "note.md"))
        XCTAssertNotNil(context.thumbnail(for: "image.png"))
        XCTAssertNil(context.thumbnail(for: "https://attacker.invalid/image.png"))
        XCTAssertNil(context.thumbnail(for: "../image.png"))
        try fm.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        try png.write(to: root.appending(path: ".git/image.png"))
        XCTAssertNil(context.thumbnail(for: ".git/image.png"))
        try Data(repeating: 65, count: 8_000_001).write(to: root.appending(path: "huge.png"))
        XCTAssertNil(context.thumbnail(for: "huge.png"))
    }
}
