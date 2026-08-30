import Foundation

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
        return (try? decoder.decode([Workspace].self, from: data)) ?? []
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
        case invalidTextEncoding

        var errorDescription: String? {
            switch self {
            case .fileOutsideWorkspace: "The selected file is outside its repository."
            case .fileAlreadyExists: "A file already exists at that path."
            case .invalidTextEncoding: "The file is not valid UTF-8 text."
            }
        }
    }

    func prepareRoot() throws {
        try FileManager.default.createDirectory(
            at: WorkspacePaths.repositoriesRoot,
            withIntermediateDirectories: true
        )
    }

    func markdownFiles(in workspace: Workspace) throws -> [MarkdownFile] {
        let root = WorkspacePaths.repositoryURL(for: workspace).standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [MarkdownFile] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey])
            guard values.isRegularFile == true, values.isHidden != true else { continue }
            let fileExtension = fileURL.pathExtension.lowercased()
            guard fileExtension == "md" || fileExtension == "markdown" else { continue }
            guard let relativePath = relativePath(of: fileURL, beneath: root) else { continue }
            files.append(MarkdownFile(url: fileURL, relativePath: relativePath))
        }
        return files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    func read(_ file: MarkdownFile, in workspace: Workspace) throws -> String {
        try validate(file.url, in: workspace)
        do {
            return try String(contentsOf: file.url, encoding: .utf8)
        } catch CocoaError.fileReadInapplicableStringEncoding {
            throw FileError.invalidTextEncoding
        }
    }

    func write(_ text: String, to file: MarkdownFile, in workspace: Workspace) throws {
        try validate(file.url, in: workspace)
        try text.write(to: file.url, atomically: true, encoding: .utf8)
    }

    func createMarkdownFile(
        at relativePath: MarkdownRelativePath,
        contents: String,
        in workspace: Workspace
    ) throws -> MarkdownFile {
        let root = WorkspacePaths.repositoryURL(for: workspace).standardizedFileURL
        let target = root.appending(path: relativePath.value, directoryHint: .notDirectory).standardizedFileURL
        guard self.relativePath(of: target, beneath: root) == relativePath.value else {
            throw FileError.fileOutsideWorkspace
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw FileError.fileAlreadyExists
        }

        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: target, atomically: true, encoding: .utf8)
        return MarkdownFile(url: target, relativePath: relativePath.value)
    }

    func remove(_ workspace: Workspace) throws {
        let root = WorkspacePaths.repositoryURL(for: workspace).standardizedFileURL
        guard root.deletingLastPathComponent() == WorkspacePaths.repositoriesRoot.standardizedFileURL else {
            throw FileError.fileOutsideWorkspace
        }
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func validate(_ fileURL: URL, in workspace: Workspace) throws {
        let root = WorkspacePaths.repositoryURL(for: workspace).standardizedFileURL
        guard relativePath(of: fileURL.standardizedFileURL, beneath: root) != nil else {
            throw FileError.fileOutsideWorkspace
        }
    }

    private func relativePath(of file: URL, beneath root: URL) -> String? {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(rootPath) else { return nil }
        return String(file.path.dropFirst(rootPath.count))
    }
}
