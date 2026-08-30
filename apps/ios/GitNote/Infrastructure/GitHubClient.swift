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

actor GitHubOAuthClient {
    static let requestedScope = "repo"

    enum OAuthError: LocalizedError {
        case missingClientID
        case invalidResponse
        case request(status: Int, message: String)
        case expired
        case denied
        case deviceFlowDisabled
        case github(code: String, description: String)

        var errorDescription: String? {
            switch self {
            case .missingClientID:
                "GitHub login is not configured. Add the OAuth App client ID to the GITHUB_OAUTH_CLIENT_ID build setting."
            case .invalidResponse:
                "GitHub returned an invalid OAuth response."
            case .request(let status, let message):
                "GitHub login failed (\(status)): \(message)"
            case .expired:
                "The GitHub login code expired. Start the login again."
            case .denied:
                "GitHub login was cancelled or denied."
            case .deviceFlowDisabled:
                "Device Flow is not enabled for the GitNote OAuth App. Enable it in the app's GitHub settings."
            case .github(let code, let description):
                "GitHub login failed (\(code)): \(description)"
            }
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case error
            case errorDescription = "error_description"
        }
    }

    private struct OAuthAPIError: Decodable {
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func configuredClientID(bundle: Bundle = .main) -> String? {
        guard let rawValue = bundle.object(forInfoDictionaryKey: "GitHubOAuthClientID") as? String else {
            return nil
        }
        let clientID = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientID.contains("$(") else { return nil }
        return clientID
    }

    func begin(clientID: String) async throws -> GitHubDeviceAuthorization {
        let request = try formRequest(
            url: "https://github.com/login/device/code",
            fields: ["client_id": clientID, "scope": Self.requestedScope]
        )
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(GitHubDeviceAuthorization.self, from: data)
    }

    func waitForToken(
        authorization: GitHubDeviceAuthorization,
        clientID: String
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(authorization.expiresIn))
        var interval = max(authorization.interval, 1)

        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(interval))

            let request = try formRequest(
                url: "https://github.com/login/oauth/access_token",
                fields: [
                    "client_id": clientID,
                    "device_code": authorization.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                ]
            )
            let (data, response) = try await session.data(for: request)
            try validate(response: response, data: data)
            let tokenResponse = try decoder.decode(TokenResponse.self, from: data)

            if let accessToken = tokenResponse.accessToken, !accessToken.isEmpty {
                return accessToken
            }

            switch tokenResponse.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            case "expired_token":
                throw OAuthError.expired
            case "access_denied":
                throw OAuthError.denied
            case "device_flow_disabled":
                throw OAuthError.deviceFlowDisabled
            case let code?:
                throw OAuthError.github(
                    code: code,
                    description: tokenResponse.errorDescription ?? "Unknown OAuth error"
                )
            case nil:
                throw OAuthError.invalidResponse
            }
        }

        throw OAuthError.expired
    }

    private func formRequest(url rawURL: String, fields: [String: String]) throws -> URLRequest {
        guard let url = URL(string: rawURL) else { throw OAuthError.invalidResponse }
        var components = URLComponents()
        components.queryItems = fields
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else {
            throw OAuthError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("GitNote-iOS-MVP", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let apiError = try? decoder.decode(OAuthAPIError.self, from: data)
            throw OAuthError.request(
                status: http.statusCode,
                message: apiError?.errorDescription ?? apiError?.error ?? "Unknown error"
            )
        }
    }
}
