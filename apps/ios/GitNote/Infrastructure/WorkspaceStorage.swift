import Foundation
import Darwin

enum WorkspacePaths {
    static var repositoriesRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Repositories", directoryHint: .isDirectory)
    }

    static var metadataURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "GitNote", directoryHint: .isDirectory)
            .appending(path: "workspaces.json", directoryHint: .notDirectory)
    }

    static func repositoryURL(for workspace: Workspace) -> URL {
        repositoriesRoot.appending(path: workspace.localFolderName, directoryHint: .isDirectory)
    }
}

struct WorkspaceMetadataStore: Sendable {
    func load() -> [Workspace] {
        guard let data = try? Data(contentsOf: WorkspacePaths.metadataURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([Workspace].self, from: data)) ?? []).filter {
            SecureWorkspaceIO.validFolderName($0.localFolderName)
        }
    }

    func save(_ workspaces: [Workspace]) throws {
        let target = WorkspacePaths.metadataURL
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(workspaces)
        try data.write(to: target, options: .atomic)
    }
}

actor WorkspaceFileService {
    enum FileError: LocalizedError {
        case fileOutsideWorkspace
        case fileAlreadyExists
        case directoryAlreadyExists
        case invalidTextEncoding
        case resourceLimit

        var errorDescription: String? {
            switch self {
            case .fileOutsideWorkspace: "The selected file is outside its repository."
            case .fileAlreadyExists: "A file already exists at that path."
            case .directoryAlreadyExists: "A file or directory already exists at that path."
            case .invalidTextEncoding: "The file is not valid UTF-8 text."
            case .resourceLimit: "This file or repository exceeds GitNote’s safety limits (2 MB per note, 10,000 visible entries)."
            }
        }
    }

    func prepareRoot() throws {
        try FileManager.default.createDirectory(
            at: WorkspacePaths.repositoriesRoot,
            withIntermediateDirectories: true
        )
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                             ofItemAtPath: WorkspacePaths.repositoriesRoot.path)
        #endif
    }

    func contents(in workspace: Workspace) throws -> WorkspaceContents {
        let root = try checkedRoot(workspace).standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isHiddenKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return WorkspaceContents(markdownFiles: [], directories: []) }

        let rootFD = try SecureWorkspaceIO.openRoot(root)
        close(rootFD)
        var visited = 0
        var files: [MarkdownFile] = []
        var directories: [RepositoryDirectory] = []
        for case let fileURL as URL in enumerator {
            visited += 1
            guard visited <= 10_000 else { throw FileError.resourceLimit }
            let values = try fileURL.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isHiddenKey, .isSymbolicLinkKey]
            )
            guard values.isHidden != true, values.isSymbolicLink != true,
                  let relativePath = relativePath(of: fileURL, beneath: root) else {
                continue
            }

            if values.isDirectory == true {
                directories.append(RepositoryDirectory(url: fileURL, relativePath: relativePath))
                continue
            }

            guard values.isRegularFile == true else { continue }
            let fileExtension = fileURL.pathExtension.lowercased()
            guard fileExtension == "md" || fileExtension == "markdown" else { continue }
            files.append(MarkdownFile(url: fileURL, relativePath: relativePath))
        }
        return WorkspaceContents(
            markdownFiles: files.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            },
            directories: directories.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
        )
    }

    func read(_ file: MarkdownFile, in workspace: Workspace) throws -> String {
        let root = try checkedRoot(workspace)
        let path = try validatedPath(file.url, root: root)
        let data = try SecureWorkspaceIO.read(root: root, path: path, limit: SecureWorkspaceIO.noteLimit)
        guard let text = String(data: data, encoding: .utf8) else { throw FileError.invalidTextEncoding }
        return text
    }

    func write(_ text: String, to file: MarkdownFile, in workspace: Workspace) throws {
        let root = try checkedRoot(workspace)
        try SecureWorkspaceIO.write(text, root: root, path: validatedPath(file.url, root: root), create: false)
    }

    func createMarkdownFile(
        at relativePath: MarkdownRelativePath,
        contents: String,
        in workspace: Workspace
    ) throws -> MarkdownFile {
        let root = try checkedRoot(workspace)
        try SecureWorkspaceIO.write(contents, root: root, path: relativePath.value, create: true)
        return MarkdownFile(url: root.appending(path: relativePath.value), relativePath: relativePath.value)
    }

    func createDirectory(
        at relativePath: DirectoryRelativePath,
        in workspace: Workspace
    ) throws -> RepositoryDirectory {
        let root = try checkedRoot(workspace)
        let (parent, name) = try SecureWorkspaceIO.parent(root: root, path: relativePath.value, create: true)
        defer { close(parent) }
        guard mkdirat(parent, name, 0o700) == 0 else {
            if errno == EEXIST { throw FileError.directoryAlreadyExists }
            throw SecureWorkspaceIO.posixError()
        }
        return RepositoryDirectory(url: root.appending(path: relativePath.value), relativePath: relativePath.value)
    }

    func remove(_ workspace: Workspace) throws {
        let root = try checkedRoot(workspace).standardizedFileURL
        guard root.deletingLastPathComponent() == WorkspacePaths.repositoriesRoot.standardizedFileURL else {
            throw FileError.fileOutsideWorkspace
        }
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func checkedRoot(_ workspace: Workspace) throws -> URL {
        guard SecureWorkspaceIO.validFolderName(workspace.localFolderName) else {
            throw FileError.fileOutsideWorkspace
        }
        return WorkspacePaths.repositoryURL(for: workspace)
    }

    private func validatedPath(_ fileURL: URL, root: URL) throws -> String {
        guard fileURL.isFileURL,
              let path = relativePath(of: fileURL.standardizedFileURL, beneath: root.standardizedFileURL),
              let safe = MarkdownRelativePath(path), safe.value == path else {
            throw FileError.fileOutsideWorkspace
        }
        return path
    }

    private func relativePath(of file: URL, beneath root: URL) -> String? {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(rootPath) else { return nil }
        return String(file.path.dropFirst(rootPath.count))
    }
}

// Traverse with directory descriptors so a symlink swap cannot redirect the next
// component. Never reopen a validated path using Foundation's path-based writes.
enum SecureWorkspaceIO {
    static let noteLimit = 2_000_000

    static func validFolderName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    static func openRoot(_ root: URL) throws -> Int32 {
        guard root.isFileURL, validFolderName(root.lastPathComponent) else {
            throw WorkspaceFileService.FileError.fileOutsideWorkspace
        }
        // The Documents container is OS-owned. Refuse a replaced Repositories
        // directory or workspace root; neither may be a symbolic link.
        let container = Darwin.open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard container >= 0 else { throw posixError() }
        defer { close(container) }
        let fd = openat(container, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        return fd
    }

    static func parent(root: URL, path: String, create: Bool) throws -> (Int32, String) {
        guard let safe = DirectoryRelativePath(path), safe.value == path else {
            throw WorkspaceFileService.FileError.fileOutsideWorkspace
        }
        let components = path.split(separator: "/").map(String.init)
        var fd = try openRoot(root)
        do {
            for component in components.dropLast() {
                if create && mkdirat(fd, component, 0o700) != 0 && errno != EEXIST { throw posixError() }
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw posixError() }
                close(fd)
                fd = next
            }
            return (fd, components.last!)
        } catch {
            close(fd)
            throw error
        }
    }

    static func read(root: URL, path: String, limit: Int) throws -> Data {
        let (parent, name) = try parent(root: root, path: path, create: false)
        defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw WorkspaceFileService.FileError.fileOutsideWorkspace
        }
        guard info.st_size <= limit else { throw WorkspaceFileService.FileError.resourceLimit }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - result.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= limit else { throw WorkspaceFileService.FileError.resourceLimit }
        }
    }

    static func write(_ text: String, root: URL, path: String, create: Bool) throws {
        guard text.utf8.count <= noteLimit else { throw WorkspaceFileService.FileError.resourceLimit }
        guard let safe = MarkdownRelativePath(path), safe.value == path else {
            throw WorkspaceFileService.FileError.fileOutsideWorkspace
        }
        let (parent, name) = try parent(root: root, path: path, create: create)
        defer { close(parent) }
        var info = stat()
        let exists = fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0
        if exists && create { throw WorkspaceFileService.FileError.fileAlreadyExists }
        if exists && (info.st_mode & S_IFMT != S_IFREG || info.st_nlink != 1) {
            throw WorkspaceFileService.FileError.fileOutsideWorkspace
        }
        if !exists && errno != ENOENT { throw posixError() }
        if !exists && !create { throw WorkspaceFileService.FileError.fileOutsideWorkspace }
        let temporary = ".gitnote-save-" + UUID().uuidString
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd); unlinkat(parent, temporary, 0) }
        if exists {
            guard fchmod(fd, info.st_mode & 0o777) == 0 else { throw posixError() }
        }
        try Data(text.utf8).withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw posixError() }
        if create {
            // linkat publishes without overwriting a concurrently created file.
            guard linkat(parent, temporary, parent, name, 0) == 0 else {
                if errno == EEXIST { throw WorkspaceFileService.FileError.fileAlreadyExists }
                throw posixError()
            }
        } else {
            guard renameat(parent, temporary, parent, name) == 0 else { throw posixError() }
        }
    }
}
