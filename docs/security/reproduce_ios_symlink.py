#!/usr/bin/env python3
"""Compile the current iOS file service with disposable storage roots; no app data is read."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="gitnote-security-") as folder:
    temp = Path(folder)
    models = (root / "apps/ios/GitNote/Domain/Models.swift").read_text()
    storage = (root / "apps/ios/GitNote/Infrastructure/WorkspaceStorage.swift").read_text()
    for name in ("documentDirectory", "applicationSupportDirectory"):
        storage = storage.replace(f"FileManager.default.urls(for: .{name}, in: .userDomainMask)[0]", f'URL(fileURLWithPath: "{folder}/data")')
    harness = r'''@main struct Probe {
        static func main() async throws {
            let fm = FileManager.default
            let repo = GitHubRepository(id: 1, name: "notes", fullName: "test/notes",
                owner: .init(login: "test"), cloneURL: URL(string: "https://github.com/test/notes.git")!,
                defaultBranch: "main", isPrivate: true, isFork: false, summary: nil, pushedAt: nil)
            let workspace = Workspace(repository: repo, localFolderName: UUID().uuidString)
            let root = WorkspacePaths.repositoryURL(for: workspace)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            try "private fixture".write(to: outside.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)
            try fm.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
            let service = WorkspaceFileService()
            var rejected = false
            do {
                _ = try await service.createMarkdownFile(at: MarkdownRelativePath("linked/injected.md")!, contents: "outside write", in: workspace)
            } catch { rejected = true }
            precondition(rejected, "SYMLINK CREATE ESCAPED")
            precondition(!fm.fileExists(atPath: outside.appendingPathComponent("injected.md").path))
            let file = MarkdownFile(url: root.appendingPathComponent("linked/secret.md"), relativePath: "linked/secret.md")
            rejected = false
            do { _ = try await service.read(file, in: workspace) } catch { rejected = true }
            precondition(rejected, "SYMLINK READ ESCAPED")
            let safe = try await service.createMarkdownFile(at: MarkdownRelativePath("safe/note.md")!, contents: "safe", in: workspace)
            try await service.write("updated", to: safe, in: workspace)
            let content = try await service.read(safe, in: workspace)
            precondition(content == "updated")
            print("PASS: symlink creation/read rejected; normal creation/read/write preserved")
        }
    }
    '''
    source = temp / "probe.swift"
    source.write_text(models + "\n" + storage + "\n" + harness)
    subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", str(temp / "cache"), str(source), "-o", str(temp / "probe")], check=True)
    subprocess.run([str(temp / "probe")], check=True)
