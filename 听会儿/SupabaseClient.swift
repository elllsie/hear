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

    func fetchUserState<T: Decodable>(
        accessToken: String,
        userId: String,
        key: String,
        as type: T.Type = T.self
    ) async throws -> T? {
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        let path = "/rest/v1/user_app_state?user_id=eq.\(userId)&state_key=eq.\(encodedKey)&select=value&limit=1"
        let data = try await request(path: path, method: "GET", accessToken: accessToken, bodyData: nil)
        return try decoder.decode([RemoteUserState<T>].self, from: data).first?.value
    }

    func upsertUserState<T: Encodable>(
        accessToken: String,
        userId: String,
        key: String,
        value: T
    ) async throws {
        let row = RemoteUserStateUpsert(userId: userId, stateKey: key, value: value)
        _ = try await request(
            path: "/rest/v1/user_app_state",
            method: "POST",
            accessToken: accessToken,
            headers: ["Prefer": "resolution=merge-duplicates"],
            encodableBody: row
        )
    }

    func fetchPodcasts(language: StudyLanguage) async throws -> [CuratedPodcast] {
        let languageCode = language == .german ? "de" : "en"
        let path = "/rest/v1/podcasts?is_active=eq.true&rights_status=eq.approved&language=eq.\(languageCode)&select=id,name,host,region,level,language,category,rss_url,website_url,cover_url&order=name.asc"
        let data = try await request(path: path, method: "GET", bodyData: nil)
        return try decoder.decode([RemotePodcast].self, from: data).compactMap(\.appModel)
    }

    func fetchWordBookCatalog() async throws -> [RemoteWordBookDescriptor] {
        let selection = "book_id,title,language,content_version,data_url,audio_path_prefix,sort_order"
        let path = "/rest/v1/word_books?is_active=eq.true&select=\(selection)&order=sort_order.asc,title.asc"
        let data = try await request(path: path, method: "GET", bodyData: nil)
        return try decoder.decode([RemoteWordBookDescriptor].self, from: data)
    }

    func fetchWordBookWords(from descriptor: RemoteWordBookDescriptor) async throws -> [Word] {
        guard descriptor.dataUrl.scheme == "https" else {
            throw SupabaseClientError.message("词书数据地址必须使用 HTTPS")
        }
        var urlRequest = URLRequest(url: descriptor.dataUrl)
        urlRequest.timeoutInterval = 30
        urlRequest.cachePolicy = .reloadRevalidatingCacheData
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SupabaseClientError.message("词书数据下载失败")
        }
        guard data.count <= 25 * 1024 * 1024 else {
            throw SupabaseClientError.message("词书数据超过 25 MB 安全限制")
        }
        return try decoder.decode([Word].self, from: data)
    }

    func fetchPodcastEpisodes(language: StudyLanguage? = nil, podcastID: String? = nil, limit: Int = 20, offset: Int = 0) async throws -> [PodcastEpisode] {
        let safeLimit = min(max(limit, 1), 50)
        let safeOffset = max(offset, 0)
        let selection = [
            "id", "title", "description", "audio_url", "source_url", "cover_url",
            "duration_seconds", "publish_date",
            "podcast:podcasts!inner(id,name,host,region,level,language,category,rss_url,website_url,cover_url)"
        ].joined(separator: ",")
        let podcastFilter = podcastID.map { "&podcast_id=eq.\($0)" } ?? ""
        let languageFilter = language.map { "&podcast.language=eq.\($0 == .german ? "de" : "en")" } ?? ""
        let path = "/rest/v1/episodes?editorial_status=eq.published&transcript_status=eq.ready\(podcastFilter)\(languageFilter)&select=\(selection)&order=publish_date.desc.nullslast,id.desc&limit=\(safeLimit)&offset=\(safeOffset)"
        let data = try await request(path: path, method: "GET", bodyData: nil)
        let rows = try decoder.decode([RemotePodcastEpisode].self, from: data)
        return rows.compactMap { $0.appModel }
    }

    func fetchPodcastSentences(episodeId: String) async throws -> [PodcastSentence] {
        let encodedID = episodeId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? episodeId
        let path = "/rest/v1/episode_sentences?episode_id=eq.\(encodedID)&select=id,start_ms,end_ms,english,chinese&order=sequence.asc"
        let data = try await request(path: path, method: "GET", bodyData: nil)
        return try decoder.decode([RemotePodcastSentence].self, from: data).map(\.appModel)
    }

    func fetchPodcastAIInsights(episodeId: String) async throws -> PodcastAIInsights? {
        let encodedID = episodeId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? episodeId
        async let insightData = request(
            path: "/rest/v1/episode_ai_insights?episode_id=eq.\(encodedID)&select=summary_zh,summary_en,key_points&limit=1",
            method: "GET",
            bodyData: nil
        )
        async let wordsData = request(
            path: "/rest/v1/episode_difficult_words?episode_id=eq.\(encodedID)&select=*&order=sequence.asc",
            method: "GET",
            bodyData: nil
        )
        let (resolvedInsightData, resolvedWordsData) = try await (insightData, wordsData)
        guard let insight = try decoder.decode([RemotePodcastAIInsight].self, from: resolvedInsightData).first else {
            return nil
        }
        let words = try decoder.decode([RemotePodcastDifficultWord].self, from: resolvedWordsData)
        return PodcastAIInsights(
            summaryZh: insight.summaryZh,
            summaryEn: insight.summaryEn,
            keyPoints: insight.keyPoints,
            difficultWords: words.map(\.appModel)
        )
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

private struct RemoteUserState<Value: Decodable>: Decodable {
    let value: Value
}

private struct RemoteUserStateUpsert<Value: Encodable>: Encodable {
    let userId: String
    let stateKey: String
    let value: Value
}

private struct RemotePodcastEpisode: Decodable {
    let id: String
    let title: String
    let description: String
    let audioUrl: URL
    let sourceUrl: URL?
    let coverUrl: URL?
    let durationSeconds: Int?
    let publishDate: Date?
        let podcast: RemotePodcast

    var appModel: PodcastEpisode? {
        guard let feedURL = URL(string: podcast.rssUrl) else { return nil }
        let shelf: PodcastShelf
        switch podcast.category {
        case "easy": shelf = .easy
        case "thinking": shelf = .thinking
        case "world": shelf = .world
        case "future": shelf = .future
        default: return nil
        }
        let show = CuratedPodcast(
            id: podcast.id,
            title: podcast.name,
            host: podcast.host ?? "",
            region: podcast.region ?? "",
            level: podcast.level ?? "B1-C1",
            shelf: shelf,
            language: podcast.language == "de" ? .german : .english,
            feedURL: feedURL,
            websiteURL: URL(string: podcast.websiteUrl ?? podcast.rssUrl) ?? feedURL,
            artworkURL: podcast.coverUrl,
            learningScore: shelf == .easy ? 96 : 86,
            transcriptQuality: "待生成学习文本",
            rightsRisk: "已通过后台内容审核"
        )
        return PodcastEpisode(
            id: id,
            podcast: show,
            title: title,
            summary: description,
            audioURL: audioUrl,
            sourceURL: sourceUrl,
            artworkURL: coverUrl ?? podcast.coverUrl,
            publishedAt: publishDate,
            duration: durationSeconds.map(TimeInterval.init)
        )
    }
}

private struct RemotePodcast: Decodable {
    let id: String
    let name: String
    let host: String?
    let region: String?
    let level: String?
    let language: String
    let category: String
    let rssUrl: String
    let websiteUrl: String?
    let coverUrl: URL?

    var appModel: CuratedPodcast? {
        guard let feedURL = URL(string: rssUrl) else { return nil }
        let shelf: PodcastShelf
        switch category {
        case "easy": shelf = .easy
        case "thinking": shelf = .thinking
        case "world": shelf = .world
        case "future": shelf = .future
        default: return nil
        }
        return CuratedPodcast(
            id: id,
            title: name,
            host: host ?? "",
            region: region ?? "",
            level: level ?? "B1-C1",
            shelf: shelf,
            language: language == "de" ? .german : .english,
            feedURL: feedURL,
            websiteURL: URL(string: websiteUrl ?? rssUrl) ?? feedURL,
            artworkURL: coverUrl,
            learningScore: shelf == .easy ? 96 : 86,
            transcriptQuality: "待生成学习文本",
            rightsRisk: "已通过后台内容审核"
        )
    }
}

private struct RemotePodcastSentence: Decodable {
    let id: String
    let startMs: Int
    let endMs: Int
    let english: String
    let chinese: String?

    var appModel: PodcastSentence {
        PodcastSentence(
            id: id,
            start: TimeInterval(startMs) / 1_000,
            end: TimeInterval(endMs) / 1_000,
            english: english,
            chinese: chinese
        )
    }
}

private struct RemotePodcastAIInsight: Decodable {
    let summaryZh: String
    let summaryEn: String
    let keyPoints: [String]
}

private struct RemotePodcastDifficultWord: Decodable {
    let id: String
    let word: String
    let lemma: String
    let meaning: String
    let meaningZh: String?
    let meaningEn: String?
    let cefrLevel: String?
    let sentence: String
    let startMs: Int
    let reason: String

    var appModel: PodcastDifficultWord {
        PodcastDifficultWord(
            id: id,
            word: word,
            lemma: lemma,
            meaning: meaning,
            meaningZh: meaningZh,
            meaningEn: meaningEn,
            cefrLevel: cefrLevel,
            sentence: sentence,
            start: TimeInterval(startMs) / 1_000,
            reason: reason
        )
    }
}

extension SupabaseClient {
    func fetchUserWordBookLibrary(accessToken: String, userId: String, language: StudyLanguage, includeLegacy: Bool = true) async throws -> UserWordBookLibrary? {
        if let indexed: UserWordBookLibrary = try await fetchUserState(accessToken: accessToken,
            userId: userId, key: UserWordBookStore.cloudKey(for: language)) { return indexed }
        guard includeLegacy else { return nil }
        // Read the old snapshot without overwriting it, so the previous app remains usable.
        return try await fetchUserState(accessToken: accessToken, userId: userId,
            key: UserWordBookStore.legacyCloudKey(for: language))
    }
}

private struct RemoteFavoriteWordUpsert: Codable {
    let userId: String
    let bookId: String
    let wordId: String
    let updatedAt: Date
}
