import Foundation
import SwiftGitX

actor GitEngine {
    enum EngineError: LocalizedError {
        case destinationExists

        var errorDescription: String? {
            switch self {
            case .destinationExists:
                "A local folder already exists for this repository."
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
