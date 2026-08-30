import Foundation

struct GitHubUser: Decodable, Equatable, Sendable {
    let id: Int64
    let login: String
    let avatarURL: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case login
        case avatarURL = "avatar_url"
    }
}

struct GitHubDeviceAuthorization: Decodable, Equatable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

struct GitHubRepository: Decodable, Identifiable, Hashable, Sendable {
    struct Owner: Decodable, Hashable, Sendable {
        let login: String
    }

    let id: Int64
    let name: String
    let fullName: String
    let owner: Owner
    let cloneURL: URL
    let defaultBranch: String
    let isPrivate: Bool
    let isFork: Bool
    let summary: String?
    let pushedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case fullName = "full_name"
        case owner
        case cloneURL = "clone_url"
        case defaultBranch = "default_branch"
        case isPrivate = "private"
        case isFork = "fork"
        case summary = "description"
        case pushedAt = "pushed_at"
    }
}

struct RepositoryAddress: Equatable, Sendable {
    let owner: String
    let name: String

    var fullName: String { "\(owner)/\(name)" }
    var cloneURL: URL { URL(string: "https://github.com/\(fullName).git")! }

    init?(_ input: String) {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("https://github.com/") {
            value.removeFirst("https://github.com/".count)
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if value.hasSuffix(".git") {
            value.removeLast(4)
        }

        let components = value.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 2 else { return nil }

        let owner = String(components[0])
        let name = String(components[1])
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard owner.unicodeScalars.allSatisfy(allowed.contains),
              name.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }

        self.owner = owner
        self.name = name
    }
}

struct Workspace: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let repositoryID: Int64
    let fullName: String
    let cloneURL: URL
    let defaultBranch: String
    let localFolderName: String
    let createdAt: Date

    init(repository: GitHubRepository, localFolderName: String) {
        id = UUID()
        repositoryID = repository.id
        fullName = repository.fullName
        cloneURL = repository.cloneURL
        defaultBranch = repository.defaultBranch
        self.localFolderName = localFolderName
        createdAt = Date()
    }

    var displayName: String {
        fullName.split(separator: "/").last.map(String.init) ?? fullName
    }

    var ownerName: String {
        fullName.split(separator: "/").first.map(String.init) ?? ""
    }
}

struct MarkdownFile: Identifiable, Hashable, Sendable {
    let url: URL
    let relativePath: String

    var id: String { relativePath }
    var name: String { url.lastPathComponent }

    var folder: String? {
        let folder = (relativePath as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder
    }
}

struct MarkdownRelativePath: Equatable, Sendable {
    let value: String

    init?(_ input: String) {
        var path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("\\") else {
            return nil
        }

        var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let invalidCharacters = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "<>:\"|?*"))
        guard !components.isEmpty,
              components.allSatisfy({ component in
                  !component.isEmpty
                      && component != "."
                      && component != ".."
                      && !component.hasPrefix(".")
                      && component.rangeOfCharacter(from: invalidCharacters) == nil
              }) else {
            return nil
        }

        let filename = components.removeLast()
        let fileExtension = (filename as NSString).pathExtension.lowercased()
        if fileExtension.isEmpty {
            components.append(filename + ".md")
        } else if fileExtension == "md" || fileExtension == "markdown" {
            components.append(filename)
        } else {
            return nil
        }

        path = components.joined(separator: "/")
        guard path.count <= 512 else { return nil }
        value = path
    }
}

struct RepositoryChange: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case added
        case modified
        case deleted
        case renamed
        case conflicted
        case typeChanged
        case unreadable
        case unknown

        var label: String {
            switch self {
            case .added: "Added"
            case .modified: "Modified"
            case .deleted: "Deleted"
            case .renamed: "Renamed"
            case .conflicted: "Conflicted"
            case .typeChanged: "Type changed"
            case .unreadable: "Unreadable"
            case .unknown: "Changed"
            }
        }

        var symbol: String {
            switch self {
            case .added: "plus.circle.fill"
            case .modified: "pencil.circle.fill"
            case .deleted: "minus.circle.fill"
            case .renamed: "arrow.right.circle.fill"
            case .conflicted: "exclamationmark.triangle.fill"
            case .typeChanged: "arrow.triangle.2.circlepath.circle.fill"
            case .unreadable: "lock.circle.fill"
            case .unknown: "circle.fill"
            }
        }
    }

    let path: String
    let kind: Kind
    let isStaged: Bool

    var id: String { "\(path)-\(kind.rawValue)-\(isStaged)" }
}

struct RepositorySyncResult: Sendable {
    let commitID: String?
}
