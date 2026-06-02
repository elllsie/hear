import Foundation

public struct SupabaseSession: Codable {
    public let accessToken: String
    public let refreshToken: String?
    public let user: SupabaseUser
}

public struct SupabaseUser: Codable {
    public let id: String
    public let email: String
    public let displayName: String?
}

private struct AuthResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let user: AuthUser?
}

private struct AuthUser: Decodable {
    let id: String
    let email: String?
    let userMetadata: AuthUserMetadata?
}

private struct AuthUserMetadata: Decodable {
    let displayName: String?
}

private struct SupabaseErrorResponse: Decodable {
    let msg: String?
    let message: String?
    let errorDescription: String?
}

public final class SupabaseClient {
    public static let shared = SupabaseClient()

    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private init() {
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
    }

    public func signUp(email: String, password: String) async throws -> SupabaseSession {
        let body: [String: Any] = [
            "email": email,
            "password": password,
            "data": ["display_name": displayName(from: email)]
        ]
        let data = try await request(path: "/auth/v1/signup", method: "POST", body: body)
        return try session(from: data)
    }

    public func signIn(email: String, password: String) async throws -> SupabaseSession {
        let body: [String: Any] = [
            "email": email,
            "password": password
        ]
        let data = try await request(path: "/auth/v1/token?grant_type=password", method: "POST", body: body)
        return try session(from: data)
    }

    public func refreshSession(refreshToken: String) async throws -> SupabaseSession {
        let body: [String: Any] = [
            "refresh_token": refreshToken
        ]
        let data = try await request(path: "/auth/v1/token?grant_type=refresh_token", method: "POST", body: body)
        return try session(from: data)
    }

    public func fetchProgress(accessToken: String, userId: String, bookId: String) async throws -> LearningProgress? {
        let filter = "/rest/v1/learning_progress?user_id=eq.\(userId)&book_id=eq.\(bookId)&select=book_id,last_index,updated_at&limit=1"
        let data = try await request(path: filter, method: "GET", accessToken: accessToken, bodyData: nil)
        let rows = try decoder.decode([RemoteProgress].self, from: data)
        guard let row = rows.first else { return nil }
        return LearningProgress(bookId: row.bookId, lastIndex: row.lastIndex, updatedAt: row.updatedAt)
    }

    public func upsertProgress(accessToken: String, userId: String, progress: LearningProgress) async throws {
        let row = RemoteProgressUpsert(
            userId: userId,
            bookId: progress.bookId,
            lastIndex: progress.lastIndex,
            updatedAt: progress.updatedAt
        )
        _ = try await request(
            path: "/rest/v1/learning_progress",
            method: "POST",
            accessToken: accessToken,
            headers: ["Prefer": "resolution=merge-duplicates"],
            encodableBody: [row]
        )
    }

    func fetchFavorites(accessToken: String, userId: String) async throws -> [FavoriteWordReference] {
        let filter = "/rest/v1/favorite_words?user_id=eq.\(userId)&select=book_id,word_id"
        let data = try await request(path: filter, method: "GET", accessToken: accessToken, bodyData: nil)
        let rows = try decoder.decode([RemoteFavoriteWord].self, from: data)
        return rows.map { FavoriteWordReference(bookId: $0.bookId, wordId: $0.wordId) }
    }

    func upsertFavorite(accessToken: String, userId: String, reference: FavoriteWordReference) async throws {
        let row = RemoteFavoriteWordUpsert(
            userId: userId,
            bookId: reference.bookId,
            wordId: reference.wordId,
            updatedAt: Date()
        )
        _ = try await request(
            path: "/rest/v1/favorite_words",
            method: "POST",
            accessToken: accessToken,
            headers: ["Prefer": "resolution=merge-duplicates"],
            encodableBody: [row]
        )
    }

    func deleteFavorite(accessToken: String, userId: String, reference: FavoriteWordReference) async throws {
        let path = "/rest/v1/favorite_words?user_id=eq.\(userId)&book_id=eq.\(reference.bookId)&word_id=eq.\(reference.wordId)"
        _ = try await request(path: path, method: "DELETE", accessToken: accessToken, bodyData: nil)
    }

    public func deleteAccount(accessToken: String) async throws {
        _ = try await request(
            path: "/functions/v1/delete-account",
            method: "POST",
            accessToken: accessToken,
            body: [:]
        )
    }

    private func session(from data: Data) throws -> SupabaseSession {
        let response = try decoder.decode(AuthResponse.self, from: data)
        guard let accessToken = response.accessToken,
              let user = response.user,
              let email = user.email else {
            throw SupabaseClientError.message("Supabase 没有返回登录凭证。请确认邮箱验证已关闭，或删除旧的未验证用户后重新注册")
        }

        return SupabaseSession(
            accessToken: accessToken,
            refreshToken: response.refreshToken,
            user: SupabaseUser(
                id: user.id,
                email: email,
                displayName: user.userMetadata?.displayName
            )
        )
    }

    private func request(
        path: String,
        method: String,
        accessToken: String? = nil,
        headers: [String: String] = [:],
        body: [String: Any]? = nil
    ) async throws -> Data {
        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        return try await request(path: path, method: method, accessToken: accessToken, headers: headers, bodyData: bodyData)
    }

    private func request<T: Encodable>(
        path: String,
        method: String,
        accessToken: String? = nil,
        headers: [String: String] = [:],
        encodableBody: T
    ) async throws -> Data {
        let bodyData = try encoder.encode(encodableBody)
        return try await request(path: path, method: method, accessToken: accessToken, headers: headers, bodyData: bodyData)
    }

    private func request(
        path: String,
        method: String,
        accessToken: String? = nil,
        headers: [String: String] = [:],
        bodyData: Data? = nil
    ) async throws -> Data {
        guard SupabaseConfig.isConfigured else {
            throw SupabaseClientError.message("请先填写 SupabaseConfig 里的 projectURL 和 anonKey")
        }
        guard let baseURL = URL(string: SupabaseConfig.projectURL),
              let url = URL(string: path, relativeTo: baseURL) else {
            throw SupabaseClientError.message("Supabase 地址配置不正确")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = bodyData
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        }
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseClientError.message("网络响应异常")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SupabaseClientError.message(errorMessage(from: data) ?? "Supabase 请求失败：\(http.statusCode)")
        }
        return data
    }

    private func errorMessage(from data: Data) -> String? {
        guard let error = try? decoder.decode(SupabaseErrorResponse.self, from: data) else {
            return nil
        }
        let message = error.errorDescription ?? error.message ?? error.msg
        if message?.localizedCaseInsensitiveContains("requested function was not found") == true {
            return "删除账号服务尚未部署。请先在 Supabase 部署 delete-account Edge Function。"
        }
        return message
    }

    private func displayName(from email: String) -> String {
        email.split(separator: "@").first.map(String.init) ?? email
    }
}

public enum SupabaseClientError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}

private struct RemoteProgress: Codable {
    let bookId: String
    let lastIndex: Int
    let updatedAt: Date
}

private struct RemoteProgressUpsert: Codable {
    let userId: String
    let bookId: String
    let lastIndex: Int
    let updatedAt: Date
}

private struct RemoteFavoriteWord: Codable {
    let bookId: String
    let wordId: String
}

private struct RemoteFavoriteWordUpsert: Codable {
    let userId: String
    let bookId: String
    let wordId: String
    let updatedAt: Date
}
