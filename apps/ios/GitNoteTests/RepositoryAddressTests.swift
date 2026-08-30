import XCTest
@testable import GitNote

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
