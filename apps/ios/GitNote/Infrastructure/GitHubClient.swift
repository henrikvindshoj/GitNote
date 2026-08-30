import Foundation

actor GitHubClient {
    enum ClientError: LocalizedError {
        case invalidResponse
        case api(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                "GitHub returned an invalid response."
            case .api(let status, let message):
                "GitHub request failed (\(status)): \(message)"
            }
        }
    }

    private struct APIError: Decodable {
        let message: String
    }

    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func currentUser(token: String) async throws -> GitHubUser {
        try await request(path: "/user", token: token)
    }

    func repositories(token: String) async throws -> [GitHubRepository] {
        try await request(
            path: "/user/repos?affiliation=owner,collaborator,organization_member&per_page=100&sort=pushed",
            token: token
        )
    }

    func repository(address: RepositoryAddress, token: String?) async throws -> GitHubRepository {
        try await request(path: "/repos/\(address.fullName)", token: token)
    }

    private func request<T: Decodable>(path: String, token: String?) async throws -> T {
        guard let url = URL(string: "https://api.github.com\(path)") else {
            throw ClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GitNote-iOS-MVP", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(APIError.self, from: data).message) ?? "Unknown error"
            throw ClientError.api(status: http.statusCode, message: message)
        }
        return try decoder.decode(T.self, from: data)
    }
}
