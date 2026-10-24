import SwiftUI
import Combine
import AVFoundation
import MediaPlayer
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

private struct PodcastInterfaceLanguageKey: EnvironmentKey {
    static let defaultValue: LearningLanguage = .chinese
}

private extension EnvironmentValues {
    var podcastInterfaceLanguage: LearningLanguage {
        get { self[PodcastInterfaceLanguageKey.self] }
        set { self[PodcastInterfaceLanguageKey.self] = newValue }
    }
}

private func podcastContainsChinese(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (0x3400...0x9FFF).contains(Int(scalar.value))
    }
}

// MARK: - Content models

enum PodcastShelf: String, CaseIterable, Identifiable, Codable, Sendable {
    case easy = "Easy Start"
    case thinking = "Deep Thinking"
    case world = "Real World English"
    case future = "Future & Technology"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .easy: return "leaf"
        case .thinking: return "brain.head.profile"
        case .world: return "globe.asia.australia"
        case .future: return "sparkles"
        }
    }
}

struct CuratedPodcast: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let host: String
    let region: String
    let level: String
    let shelf: PodcastShelf
    let language: StudyLanguage
    let feedURL: URL
    let websiteURL: URL
    let artworkURL: URL?
    let learningScore: Int
    let transcriptQuality: String
    let rightsRisk: String
}

@MainActor
final class PodcastCatalogStore: ObservableObject {
    @Published private(set) var podcasts: [CuratedPodcast] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    private let language: StudyLanguage

    init(language: StudyLanguage) {
        self.language = language
    }

    func loadIfNeeded(force: Bool = false) async {
        guard !isLoading, force || podcasts.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            podcasts = try await SupabaseClient.shared.fetchPodcasts(language: language)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

@MainActor
final class PodcastCollectionStore: ObservableObject {
    @Published private(set) var episodes: [PodcastEpisode] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    @Published var errorMessage: String?
    private let podcastID: String
    private let pageSize = 20
    private var nextOffset = 0

    init(podcastID: String) {
        self.podcastID = podcastID
    }

    func loadNextPage() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        errorMessage = nil
        do {
            let page = try await SupabaseClient.shared.fetchPodcastEpisodes(
                podcastID: podcastID,
                limit: pageSize,
                offset: nextOffset
            )
            nextOffset += page.count
            var known = Set(episodes.map(\.id))
            episodes.append(contentsOf: page.filter { known.insert($0.id).inserted })
            hasMore = page.count == pageSize
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func reload() async {
        episodes = []
        nextOffset = 0
        hasMore = true
        await loadNextPage()
    }
}

struct PodcastEpisode: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let podcast: CuratedPodcast
    let title: String
    let summary: String
    let audioURL: URL
    let sourceURL: URL?
    let artworkURL: URL?
    let publishedAt: Date?
    let duration: TimeInterval?

    var durationLabel: String {
        guard let duration, duration > 0 else { return "时长见节目" }
        return "\(max(1, Int(duration / 60))) 分钟"
    }
}

struct PodcastSentence: Identifiable, Codable, Hashable {
    let id: String
    let start: TimeInterval
    let end: TimeInterval
    let english: String
    let chinese: String?
}

struct PodcastAIInsights: Codable, Hashable {
    let summaryZh: String
    let summaryEn: String
    let keyPoints: [String]
    let difficultWords: [PodcastDifficultWord]
}

struct PodcastDifficultWord: Identifiable, Codable, Hashable {
    let id: String
    let word: String
    let lemma: String
    let meaning: String
    let meaningZh: String?
    let meaningEn: String?
    let cefrLevel: String?
    let sentence: String
    let start: TimeInterval
    let reason: String

    func meaning(for language: LearningLanguage) -> String {
        let localized = language == .english ? meaningEn : meaningZh
        if let localized,
           !localized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           language != .english || !podcastContainsChinese(localized) {
            return localized
        }
        return language == .chinese ? meaning : ""
    }
}

struct PodcastSavedWord: Identifiable, Codable, Hashable {
    let id: String
    let word: String
    let meaning: String
    let meaningLanguage: LearningLanguage?
    let sourceLanguage: StudyLanguage?
    let sentence: String
    let episodeID: String
    let episodeTitle: String
    let podcastTitle: String
    let audioURL: String
    let time: TimeInterval
    let savedAt: Date

    var effectiveMeaningLanguage: LearningLanguage {
        if podcastContainsChinese(meaning) { return .chinese }
        if let meaningLanguage { return meaningLanguage }
        return .english
    }

    var effectiveSourceLanguage: StudyLanguage {
        sourceLanguage ?? (podcastTitle.localizedCaseInsensitiveContains("German") ? .german : .english)
    }
}

extension PodcastSavedWord {
    private struct FlexibleKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleKey.self)

        func decode<T: Decodable>(_ type: T.Type, _ keys: String...) throws -> T {
            for key in keys {
                if let value = try container.decodeIfPresent(type, forKey: FlexibleKey(key)) {
                    return value
                }
            }
            throw DecodingError.keyNotFound(
                FlexibleKey(keys[0]),
                .init(codingPath: decoder.codingPath, debugDescription: "Missing \(keys.joined(separator: " or "))")
            )
        }

        func decodeOptional<T: Decodable>(_ type: T.Type, _ keys: String...) throws -> T? {
            for key in keys {
                if let value = try container.decodeIfPresent(type, forKey: FlexibleKey(key)) {
                    return value
                }
            }
            return nil
        }

        id = try decode(String.self, "id")
        word = try decode(String.self, "word")
        meaning = try decode(String.self, "meaning")
        meaningLanguage = try decodeOptional(LearningLanguage.self, "meaningLanguage")
        sourceLanguage = try decodeOptional(StudyLanguage.self, "sourceLanguage")
        sentence = try decode(String.self, "sentence")
        episodeID = try decode(String.self, "episodeID", "episodeId")
        episodeTitle = try decode(String.self, "episodeTitle")
        podcastTitle = try decode(String.self, "podcastTitle")
        audioURL = try decode(String.self, "audioURL", "audioUrl")
        time = try decode(TimeInterval.self, "time")
        savedAt = try decode(Date.self, "savedAt")
    }
}

private func concisePodcastExample(_ text: String, containing word: String) -> String {
    let compact = text
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    guard !compact.isEmpty else { return compact }

    var sentences: [String] = []
    compact.enumerateSubstrings(in: compact.startIndex..<compact.endIndex, options: .bySentences) { value, _, _, _ in
        if let value {
            let sentence = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
        }
    }

    let selected = sentences.first {
        $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    } ?? sentences.first ?? compact
    guard selected.count > 180 else { return selected }

    let parts = selected.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard parts.count > 24 else { return String(selected.prefix(177)) + "…" }
    let target = word.lowercased()
    let targetIndex = parts.firstIndex { part in
        part.lowercased().range(of: target) != nil
    } ?? 0
    let start = max(0, min(targetIndex - 8, parts.count - 24))
    let end = min(parts.count, start + 24)
    return (start > 0 ? "…" : "")
        + parts[start..<end].joined(separator: " ")
        + (end < parts.count ? "…" : "")
}

private struct HighlightedPodcastExample: View {
    let sentence: String
    let word: String
    var baseColor: Color = .primary

    var body: some View {
        highlightedText
    }

    private var highlightedText: Text {
        let source = concisePodcastExample(sentence, containing: word)
        let sourceNSString = source as NSString
        var searchRange = NSRange(location: 0, length: sourceNSString.length)
        var cursor = 0
        var result = Text("")

        while searchRange.length > 0 {
            let match = sourceNSString.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
            guard match.location != NSNotFound, match.length > 0 else { break }

            if match.location > cursor {
                result = result + Text(sourceNSString.substring(with: NSRange(location: cursor, length: match.location - cursor)))
                    .foregroundColor(baseColor)
            }
            result = result + Text(sourceNSString.substring(with: match))
                .foregroundColor(.mint)
                .bold()
            cursor = match.location + match.length
            searchRange = NSRange(location: cursor, length: sourceNSString.length - cursor)
        }

        if cursor < sourceNSString.length {
            result = result + Text(sourceNSString.substring(from: cursor)).foregroundColor(baseColor)
        }
        return result
    }
}

// MARK: - Supabase content library

@MainActor
final class PodcastLibraryStore: ObservableObject {
    @Published private(set) var episodes: [PodcastEpisode] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?
    private let cacheKey: String
    private let language: StudyLanguage
    private let freshCacheLifetime: TimeInterval = 6 * 60 * 60

    init(language: StudyLanguage) {
        self.language = language
        // v7 invalidates publisher-hosted Acast URLs after moving published
        // episodes to stable Supabase Storage audio.
        cacheKey = "tinghui.podcast.episode-cache.v7.\(language.rawValue)"
        restoreCache()
    }

    func loadIfNeeded(force: Bool = false) async {
        guard !isLoading, !isRefreshing else { return }
        if !force, isCacheFresh { return }

        isLoading = episodes.isEmpty
        isRefreshing = !episodes.isEmpty
        errorMessage = nil
        do {
            episodes = normalized(try await SupabaseClient.shared.fetchPodcastEpisodes(language: language, limit: 20))
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
        isRefreshing = false
        if !episodes.isEmpty { saveCache() }
        if episodes.isEmpty, errorMessage == nil {
            errorMessage = "暂时没有已发布的 Podcast 内容。"
        }
    }

    func reload() async {
        await loadIfNeeded(force: true)
    }

    private var isCacheFresh: Bool {
        guard let cache = cachedEnvelope else { return false }
        return Date().timeIntervalSince(cache.updatedAt) < freshCacheLifetime
    }

    private var cachedEnvelope: PodcastEpisodeCache? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(PodcastEpisodeCache.self, from: data)
    }

    private func restoreCache() {
        episodes = cachedEnvelope?.episodes ?? []
    }

    private func saveCache() {
        let cache = PodcastEpisodeCache(episodes: episodes, updatedAt: Date())
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    private func normalized(_ values: [PodcastEpisode]) -> [PodcastEpisode] {
        var unique: [String: PodcastEpisode] = [:]
        values.forEach { unique[$0.id] = $0 }
        return unique.values
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            .prefix(20).map { $0 }
    }
}

private struct PodcastEpisodeCache: Codable {
    let episodes: [PodcastEpisode]
    let updatedAt: Date
}

// MARK: - Saved context words

@MainActor
final class PodcastWordStore: ObservableObject {
    @Published private(set) var words: [PodcastSavedWord] = []
    @Published private(set) var wordBookLibrary: UserWordBookLibrary
    @Published private(set) var isSyncing = false
    @Published private(set) var syncErrorMessage: String?
    private let storageKey: String
    private let userKey: String
    private let language: StudyLanguage
    private let cloudUserID: String?
    private let accessTokenProvider: (() async -> String?)?
    private var hasLoadedCloud = false

    init(
        userKey: String,
        language: StudyLanguage = .english,
        cloudUserID: String? = nil,
        accessTokenProvider: (() async -> String?)? = nil
    ) {
        self.userKey = userKey
        self.language = language
        self.cloudUserID = cloudUserID
        self.accessTokenProvider = accessTokenProvider
        storageKey = Self.localStorageKey(userKey: userKey, language: language)
        wordBookLibrary = UserWordBookStore.load(for: userKey, language: language)
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([PodcastSavedWord].self, from: data) { words = saved }
    }

    static func localWords(userKey: String, language: StudyLanguage) -> [PodcastSavedWord] {
        guard let data = UserDefaults.standard.data(forKey: localStorageKey(userKey: userKey, language: language)),
              let words = try? JSONDecoder().decode([PodcastSavedWord].self, from: data) else { return [] }
        return words
    }

    static func replaceLocal(_ words: [PodcastSavedWord], userKey: String, language: StudyLanguage) {
        guard let data = try? JSONEncoder().encode(words) else { return }
        UserDefaults.standard.set(data, forKey: localStorageKey(userKey: userKey, language: language))
    }

    private static func localStorageKey(userKey: String, language: StudyLanguage) -> String {
        language == .english
            ? "tinghui.podcastWords.\(userKey.lowercased())"
            : "tinghui.podcastWords.\(userKey.lowercased()).\(language.rawValue)"
    }

    func contains(word: String, episodeID: String) -> Bool {
        words.contains { $0.word.caseInsensitiveCompare(word) == .orderedSame && $0.episodeID == episodeID }
    }

    func toggle(word: String, meaning: String, meaningLanguage: LearningLanguage, sentence: String, episode: PodcastEpisode, time: TimeInterval) {
        if let index = words.firstIndex(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame && $0.episodeID == episode.id }) {
            words.remove(at: index)
        } else {
            words.insert(.init(id: UUID().uuidString, word: word.lowercased(), meaning: meaning,
                               meaningLanguage: meaningLanguage, sourceLanguage: episode.podcast.language,
                               sentence: concisePodcastExample(sentence, containing: word),
                               episodeID: episode.id, episodeTitle: episode.title, podcastTitle: episode.podcast.title,
                               audioURL: episode.audioURL.absoluteString, time: time, savedAt: Date()), at: 0)
        }
        save()
    }

    @discardableResult
    func add(word: String, meaning: String, meaningLanguage: LearningLanguage, sentence: String, episode: PodcastEpisode, time: TimeInterval) -> Bool {
        guard !contains(word: word, episodeID: episode.id) else { return false }
        words.insert(.init(
            id: UUID().uuidString,
            word: word.lowercased(),
            meaning: meaning,
            meaningLanguage: meaningLanguage,
            sourceLanguage: episode.podcast.language,
            sentence: concisePodcastExample(sentence, containing: word),
            episodeID: episode.id,
            episodeTitle: episode.title,
            podcastTitle: episode.podcast.title,
            audioURL: episode.audioURL.absoluteString,
            time: time,
            savedAt: Date()
        ), at: 0)
        save()
        return true
    }

    @discardableResult
    func add(_ candidates: [PodcastDifficultWord], episode: PodcastEpisode, learningLanguage: LearningLanguage) -> Int {
        var added = 0
        for candidate in candidates where !contains(word: candidate.lemma, episodeID: episode.id) {
            words.append(.init(
                id: UUID().uuidString,
                word: candidate.lemma,
                meaning: candidate.meaning(for: learningLanguage),
                meaningLanguage: learningLanguage,
                sourceLanguage: episode.podcast.language,
                sentence: concisePodcastExample(candidate.sentence, containing: candidate.lemma),
                episodeID: episode.id,
                episodeTitle: episode.title,
                podcastTitle: episode.podcast.title,
                audioURL: episode.audioURL.absoluteString,
                time: candidate.start,
                savedAt: Date()
            ))
            added += 1
        }
        if added > 0 {
            words.sort { $0.savedAt > $1.savedAt }
            save()
        }
        return added
    }

    private func homeWords(ids: Set<String>) -> [Word] {
        words.filter { ids.contains($0.id) }.map { saved in
            Word(
                id: "podcast-context-\(saved.id)",
                word: saved.word,
                translation: saved.effectiveMeaningLanguage == .chinese ? saved.meaning : "",
                example: concisePodcastExample(saved.sentence, containing: saved.word),
                meaningZh: saved.effectiveMeaningLanguage == .chinese ? saved.meaning : nil,
                meaningEn: saved.effectiveMeaningLanguage == .english ? saved.meaning : nil,
                source: "\(saved.podcastTitle) · \(saved.episodeTitle)"
            )
        }
    }

    func createHomeWordBook(name: String, ids: Set<String>) -> UserWordBook? {
        let selected = homeWords(ids: ids)
        guard !selected.isEmpty else { return nil }
        var updated = wordBookLibrary
        guard let created = updated.createWordBook(named: name, words: selected),
              UserWordBookStore.save(updated, for: userKey, language: language) else { return nil }
        wordBookLibrary = updated
        uploadWordBooksToCloud()
        return created
    }

    @discardableResult
    func addToHomeWordBook(ids: Set<String>, destinationID: String) -> Int {
        let selectedWords = homeWords(ids: ids)
        guard let index = wordBookLibrary.books.firstIndex(where: { $0.id == destinationID }) else { return 0 }
        var known = Set(wordBookLibrary.books[index].words.map { $0.word.lowercased() })
        let unique = selectedWords.filter { known.insert($0.word.lowercased()).inserted }
        wordBookLibrary.books[index].words.append(contentsOf: unique)
        wordBookLibrary.books[index].words.sort { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }
        wordBookLibrary.selectedBookID = destinationID
        UserWordBookStore.save(wordBookLibrary, for: userKey, language: language)
        uploadWordBooksToCloud()
        return unique.count
    }

    @discardableResult
    func addToSelectedWordBook(
        word: String,
        meaning: String,
        meaningLanguage: LearningLanguage,
        sentence: String,
        episode: PodcastEpisode,
        time: TimeInterval
    ) -> Bool {
        _ = add(
            word: word,
            meaning: meaning,
            meaningLanguage: meaningLanguage,
            sentence: sentence,
            episode: episode,
            time: time
        )
        guard let savedWord = words.first(where: {
            $0.word.caseInsensitiveCompare(word) == .orderedSame && $0.episodeID == episode.id
        }) else { return false }
        return addToHomeWordBook(ids: [savedWord.id], destinationID: wordBookLibrary.selectedBookID) > 0
    }

    func selectWordBook(_ id: String) {
        guard wordBookLibrary.books.contains(where: { $0.id == id }) else { return }
        wordBookLibrary.selectedBookID = id
        UserWordBookStore.save(wordBookLibrary, for: userKey, language: language)
        uploadWordBooksToCloud()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(words) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        uploadToCloud()
    }

    func syncWithCloud(force: Bool = false) async {
        guard force || !hasLoadedCloud else { return }
        guard let cloudUserID else {
            syncErrorMessage = "请先登录账号后同步语境单词"
            return
        }

        isSyncing = true
        syncErrorMessage = nil
        defer { isSyncing = false }

        for attempt in 0..<3 {
            do {
                guard let accessToken = await accessTokenProvider?() else {
                    throw SupabaseClientError.message("登录凭证暂时不可用")
                }
                let key = "podcast_words_\(language.rawValue)"
                if let remote: [PodcastSavedWord] = try await SupabaseClient.shared.fetchUserState(
                    accessToken: accessToken,
                    userId: cloudUserID,
                    key: key
                ) {
                    words = remote.sorted { $0.savedAt > $1.savedAt }
                    Self.replaceLocal(words, userKey: userKey, language: language)
                } else if !words.isEmpty {
                    try await SupabaseClient.shared.upsertUserState(
                        accessToken: accessToken,
                        userId: cloudUserID,
                        key: key,
                        value: words
                    )
                }
                if let remoteLibrary = try await SupabaseClient.shared.fetchUserWordBookLibrary(
                    accessToken: accessToken,
                    userId: cloudUserID,
                    language: language,
                    includeLegacy: !UserWordBookStore.hasIndexedStorage(for: userKey, language: language)
                ) {
                    wordBookLibrary = UserWordBookStore.resolve(remoteLibrary)
                    wordBookLibrary.normalize()
                    UserWordBookStore.save(wordBookLibrary, for: userKey, language: language)
                }
                hasLoadedCloud = true
                syncErrorMessage = nil
                return
            } catch {
                syncErrorMessage = "语境单词同步失败：\(error.localizedDescription)"
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 700_000_000)
                }
            }
        }
    }

    private func uploadToCloud() {
        guard let cloudUserID else { return }
        let snapshot = words
        let key = "podcast_words_\(language.rawValue)"
        Task {
            guard let accessToken = await accessTokenProvider?() else { return }
            try? await SupabaseClient.shared.upsertUserState(
                accessToken: accessToken,
                userId: cloudUserID,
                key: key,
                value: snapshot
            )
        }
    }

    private func uploadWordBooksToCloud() {
        guard let cloudUserID else { return }
        let snapshot = wordBookLibrary
        Task {
            guard let accessToken = await accessTokenProvider?() else { return }
            try? await SupabaseClient.shared.upsertUserState(
                accessToken: accessToken,
                userId: cloudUserID,
                key: UserWordBookStore.cloudKey(for: language),
                value: snapshot
            )
        }
    }
}

// MARK: - Player

@MainActor
final class PodcastPlayerStore: ObservableObject, @unchecked Sendable {
    @Published var isPlaying = false
    @Published var isBuffering = false
    @Published var isPreparing = false
    @Published var isPrepared = false
    @Published var errorMessage: String?
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackRate: Float = 1.0
    @Published private(set) var isDownloadingAudio = false
    @Published private(set) var audioDownloadProgress: Double = 0
    @Published private(set) var audioDownloadedBytes: Int64 = 0
    @Published private(set) var audioExpectedBytes: Int64 = 0
    @Published private(set) var playbackCompletionCount = 0
    let player = AVPlayer()
    private var observer: Any?
    private var statusCancellable: AnyCancellable?
    private var controlCancellable: AnyCancellable?
    private var completionCancellable: AnyCancellable?
    private var hasTriedDownloadFallback = false
    private var preparationFallbackTask: Task<Void, Never>?
    private var shouldAutoPlayWhenPrepared = false

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                let total = self?.player.currentItem?.duration.seconds ?? 0
                self?.duration = total.isFinite ? max(0, total) : 0
            }
        }
    }

    func load(_ episode: PodcastEpisode, autoplay: Bool = false) async {
        errorMessage = nil
        isPreparing = true
        isPrepared = false
        currentTime = 0
        duration = 0
        shouldAutoPlayWhenPrepared = autoplay
        hasTriedDownloadFallback = false
        preparationFallbackTask?.cancel()
        player.automaticallyWaitsToMinimizeStalling = true
        // Every episode streams first. A failed or slow stream falls back to the
        // local cache path below, avoiding a mandatory full download for short shows.
        replaceCurrentItem(with: episode.audioURL, episode: episode)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            errorMessage = "音频设备启动失败：\(error.localizedDescription)"
        }
        configureRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: episode.podcast.title
        ]
    }

    private func replaceCurrentItem(with playableURL: URL, episode: PodcastEpisode) {
        preparationFallbackTask?.cancel()
        let asset = AVURLAsset(
            url: playableURL,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": [
                    "User-Agent": "TingHuier/1.0 PodcastLearning",
                    "Accept": "audio/mpeg,audio/*;q=0.9,*/*;q=0.1"
                ]
            ]
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 8
        statusCancellable = item.publisher(for: \.status)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak item] status in
                guard let self else { return }
                if status == .failed {
                    if !playableURL.isFileURL, !self.hasTriedDownloadFallback {
                        self.hasTriedDownloadFallback = true
                        self.preparationFallbackTask?.cancel()
                        self.isPreparing = true
                        self.errorMessage = nil
                        Task { await self.retryFromDownloadedAudio(episode) }
                        return
                    }
                    self.errorMessage = item?.error?.localizedDescription ?? "音频加载失败，请稍后重试。"
                    self.isPlaying = false
                    self.isBuffering = false
                    self.isPreparing = false
                    self.isPrepared = false
                } else if status == .readyToPlay {
                    self.preparationFallbackTask?.cancel()
                    self.isPreparing = false
                    self.isPrepared = true
                    if self.shouldAutoPlayWhenPrepared {
                        self.shouldAutoPlayWhenPrepared = false
                        self.play()
                    }
                }
            }
        controlCancellable = player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.isBuffering = status == .waitingToPlayAtSpecifiedRate
                if status == .playing { self?.isPlaying = true }
                if status == .paused { self?.isPlaying = false }
            }
        completionCancellable = NotificationCenter.default.publisher(
            for: AVPlayerItem.didPlayToEndTimeNotification,
            object: item
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            guard let self else { return }
            self.isPlaying = false
            self.isBuffering = false
            self.playbackCompletionCount += 1
        }
        player.replaceCurrentItem(with: item)
        if !playableURL.isFileURL {
            preparationFallbackTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled, let self,
                      !self.isPrepared, !self.hasTriedDownloadFallback else { return }
                self.hasTriedDownloadFallback = true
                await self.retryFromDownloadedAudio(episode)
            }
        }
    }

    private func retryFromDownloadedAudio(_ episode: PodcastEpisode) async {
        isDownloadingAudio = true
        audioDownloadProgress = 0
        audioDownloadedBytes = 0
        audioExpectedBytes = 0
        defer { isDownloadingAudio = false }
        do {
            let localURL = try await cachedAudioURL(for: episode)
            replaceCurrentItem(with: localURL, episode: episode)
        } catch {
            isPreparing = false
            isPrepared = false
            errorMessage = "在线播放失败，备用下载也失败：\(error.localizedDescription)"
        }
    }

    func toggle() { isPlaying ? pause() : play() }
    func play() {
        guard isPrepared else { return }
        errorMessage = nil
        player.playImmediately(atRate: playbackRate)
        isPlaying = true
    }
    func pause() { player.pause(); isPlaying = false }
    func seek(_ seconds: TimeInterval) { player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600)) }
    func skip(_ delta: TimeInterval) { seek(currentTime + delta) }
    func setPlaybackRate(_ rate: Float) {
        playbackRate = Float(AppPolicy.clampedPlaybackSpeed(Double(rate)))
        if isPlaying {
            player.rate = playbackRate
        }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func cachedAudioURL(for episode: PodcastEpisode) async throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = caches.appendingPathComponent("PodcastAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeID = episode.id.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "_",
            options: .regularExpression
        )
        let sourceExtension = episode.audioURL.pathExtension.isEmpty ? "mp3" : episode.audioURL.pathExtension
        let destination = directory.appendingPathComponent("\(safeID).\(sourceExtension)")
        pruneAudioCache(in: directory, keeping: destination, maximumBytes: 500 * 1_024 * 1_024)
        if let values = try? destination.resourceValues(forKeys: [.fileSizeKey]),
           (values.fileSize ?? 0) > 32_000 {
            return destination
        }

        var request = URLRequest(url: episode.audioURL)
        request.timeoutInterval = 45
        request.setValue("TingHuier/1.0 PodcastLearning", forHTTPHeaderField: "User-Agent")
        request.setValue("audio/mpeg,audio/*;q=0.9,*/*;q=0.1", forHTTPHeaderField: "Accept")
        return try await PodcastAudioDownloader().download(
            request: request,
            destination: destination
        ) { [weak self] downloaded, expected in
            Task { @MainActor in
                guard let self else { return }
                self.audioDownloadedBytes = downloaded
                self.audioExpectedBytes = max(0, expected)
                if expected > 0 {
                    self.audioDownloadProgress = min(1, max(0, Double(downloaded) / Double(expected)))
                }
            }
        }
    }

    private func pruneAudioCache(in directory: URL, keeping protectedURL: URL, maximumBytes: Int) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return }
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard url != protectedURL, let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where total > maximumBytes {
            if (try? FileManager.default.removeItem(at: entry.0)) != nil { total -= entry.1 }
        }
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.removeTarget(nil); commands.pauseCommand.removeTarget(nil)
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
    }
}

private final class PodcastAudioDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL?
    private var progress: ((Int64, Int64) -> Void)?
    private var session: URLSession?

    func download(
        request: URLRequest,
        destination: URL,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws -> URL {
        self.destination = destination
        self.progress = progress
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.default
            // Surface an actionable error instead of leaving the player on
            // "Connecting" while a publisher host repeatedly resets TCP/QUIC.
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 3 * 60
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let http = downloadTask.response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            finish(.failure(SupabaseClientError.message("音频服务器返回异常状态")))
            return
        }
        guard let destination else {
            finish(.failure(SupabaseClientError.message("音频缓存路径无效")))
            return
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        self.progress = nil
        session?.finishTasksAndInvalidate()
        session = nil
        continuation.resume(with: result)
    }
}

// MARK: - Views

private struct PodcastPlaybackSelection: Identifiable {
    let episode: PodcastEpisode
    let queue: [PodcastEpisode]

    var id: String { episode.id }
}

private enum PodcastPlayerSheet: Identifiable {
    case word(value: String, sentence: String, time: TimeInterval, preferredMeaning: String?)
    case aiInsights

    var id: String {
        switch self {
        case let .word(value, _, time, _): return "word-\(value)-\(time)"
        case .aiInsights: return "ai-insights"
        }
    }
}

private enum PodcastWordsSheet: Identifiable {
    case word(PodcastSavedWord)
    case addToWordBook

    var id: String {
        switch self {
        case let .word(word): return "word-\(word.id)"
        case .addToWordBook: return "add-to-word-book"
        }
    }
}

struct PodcastLearningRootView: View {
    let userKey: String
    let studyLanguage: StudyLanguage
    let learningLanguage: LearningLanguage
    let onClose: () -> Void
    @StateObject private var library: PodcastLibraryStore
    @StateObject private var catalog: PodcastCatalogStore
    @StateObject private var wordStore: PodcastWordStore
    @State private var tab = 0
    @State private var playbackSelection: PodcastPlaybackSelection?
    @State private var isShowingWordGestureGuide: Bool

    init(
        userKey: String,
        cloudUserID: String? = nil,
        studyLanguage: StudyLanguage,
        learningLanguage: LearningLanguage,
        accessTokenProvider: (() async -> String?)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.userKey = userKey
        self.studyLanguage = studyLanguage
        self.learningLanguage = learningLanguage
        self.onClose = onClose
        _library = StateObject(wrappedValue: PodcastLibraryStore(language: studyLanguage))
        _catalog = StateObject(wrappedValue: PodcastCatalogStore(language: studyLanguage))
        _wordStore = StateObject(wrappedValue: PodcastWordStore(
            userKey: userKey,
            language: studyLanguage,
            cloudUserID: cloudUserID,
            accessTokenProvider: accessTokenProvider
        ))
        _isShowingWordGestureGuide = State(
            initialValue: !UserDefaults.standard.bool(forKey: Self.gestureGuideKey(userKey: userKey))
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $tab) {
                PodcastTodayView(episodes: library.episodes, words: wordStore.words, studyLanguage: studyLanguage, isLoading: library.isLoading, error: library.errorMessage, open: { playbackSelection = PodcastPlaybackSelection(episode: $0, queue: library.episodes) }, openWords: { tab = 2 }, close: onClose, retry: { Task { await library.reload() } })
                    .tabItem { Label(learningLanguage == .english ? "Today" : "今日", systemImage: "house") }.tag(0)
                PodcastCuratedView(store: catalog, open: { episode, queue in
                    playbackSelection = PodcastPlaybackSelection(episode: episode, queue: queue)
                }, close: onClose)
                    .tabItem { Label(learningLanguage == .english ? "Featured" : "精选", systemImage: "headphones") }.tag(1)
                PodcastWordsView(store: wordStore, close: onClose)
                    .tabItem { Label(learningLanguage == .english ? "Words" : "单词", systemImage: "rectangle.stack") }.tag(2)
            }
            .tint(.white)

            if isShowingWordGestureGuide {
                PodcastWordGestureGuide {
                    UserDefaults.standard.set(true, forKey: Self.gestureGuideKey(userKey: userKey))
                    withAnimation { isShowingWordGestureGuide = false }
                }
                .transition(.opacity)
                .zIndex(20)
            }
        }
        .environment(\.podcastInterfaceLanguage, learningLanguage)
        .task {
            async let loadLibrary: Void = library.loadIfNeeded()
            async let loadCatalog: Void = catalog.loadIfNeeded()
            async let syncWords: Void = wordStore.syncWithCloud()
            _ = await (loadLibrary, loadCatalog, syncWords)
        }
        .fullScreenCover(item: $playbackSelection) { selection in
            PodcastEpisodePlayerView(
                episode: selection.episode,
                queue: selection.queue,
                wordStore: wordStore,
                learningLanguage: learningLanguage
            )
        }
    }

    private static func gestureGuideKey(userKey: String) -> String {
        "tinghui.podcast.word-gesture-guide.v1.\(userKey.lowercased())"
    }
}

private struct PodcastWordGestureGuide: View {
    let dismiss: () -> Void
    @Environment(\.podcastInterfaceLanguage) private var learningLanguage

    var body: some View {
        ZStack {
            Color.black.opacity(0.78).ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 54))
                    .foregroundColor(.mint)
                Text(learningLanguage == .english ? "Save words while listening" : "听播客时收集单词")
                    .font(.title2.bold())
                VStack(alignment: .leading, spacing: 14) {
                    Label(
                        learningLanguage == .english ? "Hold a word to view its pronunciation and meaning, then drag it down to add it" : "长按单词查看音标和释义，再向下拖动加入当前词书",
                        systemImage: "arrow.down.circle.fill"
                    )
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(learningLanguage == .english ? "Got it" : "知道了", action: dismiss)
                    .font(.headline)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.mint)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .foregroundColor(.white)
            .padding(26)
            .background(Color(red: 0.10, green: 0.11, blue: 0.13))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 28)
        }
    }
}

private struct PodcastTodayView: View {
    let episodes: [PodcastEpisode]; let words: [PodcastSavedWord]; let studyLanguage: StudyLanguage; let isLoading: Bool; let error: String?
    let open: (PodcastEpisode) -> Void; let openWords: () -> Void; let close: () -> Void; let retry: () -> Void
    @Environment(\.podcastInterfaceLanguage) private var interfaceLanguage

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(interfaceLanguage == .english ? "Listen for 10 minutes" : "今天听 10 分钟").font(.system(size: 34, weight: .bold)).foregroundColor(.white)
                    Text(interfaceLanguage == .english ? (studyLanguage == .german ? "Hear real German and save words in context." : "Hear real English and save words in context.") : (studyLanguage == .german ? "听见真实德语，把没听懂的词留到明天再见。" : "听见真实英语，把没听懂的词留到明天再见。"))
                        .font(.headline).foregroundColor(.gray)
                    if let episode = episodes.first {
                        Button { open(episode) } label: { HeroEpisodeCard(episode: episode) }.buttonStyle(.plain)
                    } else if isLoading {
                        ProgressView("正在读取官方节目…").tint(.white).foregroundColor(.gray).frame(maxWidth: .infinity).padding(.vertical, 80)
                    } else if let error {
                        VStack(spacing: 14) {
                            Text(error).foregroundColor(.gray)
                            Button(interfaceLanguage == .english ? "Retry" : "重试", action: retry)
                                .buttonStyle(.borderedProminent)
                                .tint(.white)
                                .foregroundColor(.black)
                        }
                            .frame(maxWidth: .infinity).padding(.vertical, 60)
                    }
                    Button(action: openWords) {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(interfaceLanguage == .english ? "Words you met" : "昨天遇到的词").font(.title2.bold()).foregroundColor(.white)
                                Text(interfaceLanguage == .english ? (words.isEmpty ? "Tap an unfamiliar word to save its sentence and audio position." : "You have \(words.count) words saved in context.") : (words.isEmpty ? "听到陌生词时点一下，原句和声音会一起保存。" : "已有 \(words.count) 个真实语境词，可以在“单词”里回听。"))
                                    .foregroundColor(.gray)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.mint)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                }.padding(20)
            }
            .background(Color.black)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("首页", action: close).foregroundColor(.gray) } }
        }.navigationViewStyle(.stack)
    }
}

private struct HeroEpisodeCard: View {
    let episode: PodcastEpisode
    @Environment(\.podcastInterfaceLanguage) private var interfaceLanguage
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(interfaceLanguage == .english ? "Featured today" : "今日精选").font(.caption.bold()).foregroundColor(.mint)
            Text(episode.title).font(.title2.bold()).foregroundColor(.white).lineLimit(3)
            Text("\(episode.podcast.title) · \(episode.podcast.level) · \(episode.durationLabel)").font(.subheadline).foregroundColor(.gray)
            Label(interfaceLanguage == .english ? "Listen" : "开始听", systemImage: "play.fill").font(.headline).foregroundColor(.black).padding(.horizontal, 18).frame(height: 48).background(Color.white).clipShape(Capsule())
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(LinearGradient(colors: [.blue.opacity(0.45), .purple.opacity(0.28)], startPoint: .topLeading, endPoint: .bottomTrailing)).clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

private struct PodcastCuratedView: View {
    @ObservedObject var store: PodcastCatalogStore
    let open: (PodcastEpisode, [PodcastEpisode]) -> Void
    let close: () -> Void
    @State private var shelf: PodcastShelf?
    @Environment(\.podcastInterfaceLanguage) private var interfaceLanguage
    var filtered: [CuratedPodcast] { shelf.map { selected in store.podcasts.filter { $0.shelf == selected } } ?? store.podcasts }
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { FilterChip(title: interfaceLanguage == .english ? "All" : "全部", selected: shelf == nil) { shelf = nil }; ForEach(PodcastShelf.allCases) { item in FilterChip(title: item.rawValue, selected: shelf == item) { shelf = item } } }.padding(.horizontal, 16)
                }.padding(.vertical, 12)
                if store.isLoading && store.podcasts.isEmpty {
                    ProgressView(interfaceLanguage == .english ? "Loading podcasts…" : "正在读取播客合集…").tint(.white).foregroundColor(.gray).frame(maxHeight: .infinity)
                } else if let error = store.errorMessage, store.podcasts.isEmpty {
                    VStack(spacing: 14) {
                        Text(error).foregroundColor(.gray)
                        Button(interfaceLanguage == .english ? "Retry" : "重试") { Task { await store.loadIfNeeded(force: true) } }
                            .buttonStyle(.borderedProminent)
                            .tint(.white)
                            .foregroundColor(.black)
                    }.frame(maxHeight: .infinity)
                } else {
                    List(filtered) { podcast in
                        NavigationLink {
                            PodcastCollectionView(podcast: podcast, open: open)
                        } label: {
                            PodcastCollectionRow(podcast: podcast)
                        }
                        .listRowBackground(Color.black)
                        .listRowSeparatorTint(Color.white.opacity(0.1))
                    }.listStyle(.plain).background(Color.black)
                }
            }.background(Color.black).navigationTitle(interfaceLanguage == .english ? "Podcasts" : "播客合集")
                .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("首页", action: close).foregroundColor(.gray) } }
        }.navigationViewStyle(.stack)
    }
}

private struct PodcastCollectionRow: View {
    let podcast: CuratedPodcast
    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: podcast.artworkURL) { image in image.resizable().scaledToFill() } placeholder: {
                ZStack { Color.blue.opacity(0.25); Image(systemName: podcast.shelf.icon).foregroundColor(.white) }
            }.frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(podcast.title).font(.headline).foregroundColor(.white)
                Text(podcast.host.isEmpty ? podcast.region : "\(podcast.host) · \(podcast.region)")
                    .font(.subheadline).foregroundColor(.gray).lineLimit(1)
                Text("\(podcast.level) · \(podcast.shelf.rawValue)").font(.caption).foregroundColor(.mint)
            }
        }.padding(.vertical, 8)
    }
}

private struct PodcastCollectionView: View {
    let podcast: CuratedPodcast
    let open: (PodcastEpisode, [PodcastEpisode]) -> Void
    @StateObject private var store: PodcastCollectionStore

    init(podcast: CuratedPodcast, open: @escaping (PodcastEpisode, [PodcastEpisode]) -> Void) {
        self.podcast = podcast
        self.open = open
        _store = StateObject(wrappedValue: PodcastCollectionStore(podcastID: podcast.id))
    }

    var body: some View {
        List {
            ForEach(store.episodes) { episode in
                Button { open(episode, store.episodes) } label: { EpisodeRow(episode: episode) }
                    .listRowBackground(Color.black)
                    .listRowSeparatorTint(Color.white.opacity(0.1))
                    .onAppear {
                        if episode.id == store.episodes.last?.id { Task { await store.loadNextPage() } }
                    }
            }
            if store.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.black)
            } else if store.errorMessage != nil {
                Button("加载失败，点击重试") { Task { await store.loadNextPage() } }
                    .foregroundColor(.orange).listRowBackground(Color.black)
            } else if store.episodes.isEmpty {
                Text("暂时没有已发布的节目").foregroundColor(.gray).listRowBackground(Color.black)
            }
        }
        .listStyle(.plain)
        .background(Color.black)
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.episodes.isEmpty { await store.loadNextPage() } }
        .refreshable { await store.reload() }
    }
}

private struct FilterChip: View {
    let title: String; let selected: Bool; let action: () -> Void
    var body: some View { Button(action: action) { Text(title).font(.subheadline.bold()).foregroundColor(selected ? .black : .white).padding(.horizontal, 14).frame(height: 36).background(selected ? Color.white : Color.white.opacity(0.1)).clipShape(Capsule()) }.buttonStyle(.plain) }
}

private struct EpisodeRow: View {
    let episode: PodcastEpisode
    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: episode.artworkURL) { image in image.resizable().scaledToFill() } placeholder: { ZStack { Color.blue.opacity(0.25); Image(systemName: "waveform").foregroundColor(.white) } }.frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(episode.title).font(.headline).foregroundColor(.white).lineLimit(2)
                Text("\(episode.podcast.title) · \(episode.podcast.level)").font(.subheadline).foregroundColor(.gray).lineLimit(1)
                Text("\(episode.durationLabel) · \(episode.podcast.learningScore) 分").font(.caption).foregroundColor(.mint)
            }
            Spacer(); Image(systemName: "chevron.right").foregroundColor(.gray)
        }.padding(.vertical, 8)
    }
}

private struct PodcastEpisodePlayerView: View {
    @State private var episode: PodcastEpisode
    let queue: [PodcastEpisode]
    @ObservedObject var wordStore: PodcastWordStore
    let learningLanguage: LearningLanguage
    @StateObject private var player = PodcastPlayerStore()
    @Environment(\.dismiss) private var dismiss
    @State private var activeSheet: PodcastPlayerSheet?
    @State private var showTranslation = true
    @State private var sentences: [PodcastSentence] = []
    @State private var isLoadingSentences = false
    @State private var sentenceError: String?
    @State private var aiInsights: PodcastAIInsights?
    @State private var isLoadingAIInsights = false
    @State private var aiInsightsError: String?
    @State private var draggedWord: DraggedPodcastWord?
    @State private var draggedWordMeaning: String?
    @State private var draggedWordPhonetic: String?
    @State private var draggedWordLocation: CGPoint = .zero
    @State private var isWordOverGarden = false
    @State private var gardenMessage: String?
    @State private var shouldAutoplayEpisode = false
    @State private var isPlayerHeaderCollapsed = false

    init(
        episode: PodcastEpisode,
        queue: [PodcastEpisode],
        wordStore: PodcastWordStore,
        learningLanguage: LearningLanguage
    ) {
        _episode = State(initialValue: episode)
        self.queue = queue
        self.wordStore = wordStore
        self.learningLanguage = learningLanguage
    }

    var currentSentence: PodcastSentence? {
        guard !sentences.isEmpty else { return nil }
        let time = player.currentTime + 0.15
        var lower = 0
        var upper = sentences.count - 1
        var candidate: PodcastSentence?
        while lower <= upper {
            let middle = (lower + upper) / 2
            let sentence = sentences[middle]
            if sentence.start <= time {
                candidate = sentence
                lower = middle + 1
            } else {
                upper = middle - 1
            }
        }
        guard let candidate else { return sentences.first }
        return time <= candidate.end + 0.25 ? candidate : nil
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                playbackHeader

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(learningLanguage == .english ? "Learning text" : "学习文本").font(.headline).foregroundColor(.white)
                        if sentences.isEmpty {
                            Text(learningLanguage == .english ? "Sentence transcript is not ready" : "该单集尚未生成逐句字幕")
                                .font(.caption).foregroundColor(.orange)
                        }
                    }
                    Spacer()
                    Button {
                        activeSheet = .aiInsights
                    } label: {
                        Label(learningLanguage == .english ? "AI Summary" : "AI 总结", systemImage: "sparkles")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                    .disabled(aiInsights == nil)
                    Toggle("中译", isOn: $showTranslation)
                        .labelsHidden()
                }.padding(.horizontal, 20).padding(.vertical, 10)

                ScrollViewReader { proxy in
                    Group {
                        if isLoadingSentences {
                            ProgressView(learningLanguage == .english ? "Loading learning text…" : "正在读取学习文本…")
                                .tint(.white).foregroundColor(.gray).frame(maxHeight: .infinity)
                        } else if sentences.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "text.badge.xmark").font(.system(size: 36))
                                Text(sentenceError ?? (learningLanguage == .english ? "Synced transcript is not ready" : "这集尚未生成同步字幕"))
                                Text(learningLanguage == .english ? "Audio remains available and the transcript will appear when ready." : "音频仍可正常播放；字幕生成后会自动显示。")
                                    .font(.caption)
                                if sentenceError != nil {
                                    Button(learningLanguage == .english ? "Retry transcript" : "重试读取字幕") {
                                        Task { await loadSentences() }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.white)
                                    .foregroundColor(.black)
                                }
                            }
                            .foregroundColor(.gray).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 16) {
                                    ForEach(sentences) { sentence in
                                        TappableSentenceView(
                                            sentence: sentence,
                                            isCurrent: sentence.id == currentSentence?.id,
                                            showTranslation: showTranslation,
                                            sourceLanguage: episode.podcast.language,
                                            learningLanguage: learningLanguage,
                                            beginDrag: { word, location in
                                                beginWordDrag(word: word, sentence: sentence, location: location)
                                            },
                                            updateDrag: updateWordDrag,
                                            endDrag: finishWordDrag
                                        )
                                        .id(sentence.id)
                                    }
                                }.padding(20)
                            }
                        }
                    }.onChange(of: currentSentence?.id) { id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
                }
            }.background(Color.black.ignoresSafeArea()).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button(learningLanguage == .english ? "Close" : "关闭") { player.pause(); dismiss() }.foregroundColor(.white) } }
        }.navigationViewStyle(.stack)
            .task(id: episode.id) {
                let autoplay = shouldAutoplayEpisode
                shouldAutoplayEpisode = false
                await player.load(episode, autoplay: autoplay)
            }
            .task(id: episode.id) { await loadSentences() }
            .task(id: episode.id) { await loadAIInsights() }
            .task(id: episode.podcast.language) {
                PodcastWordLookup.shared.prepare(for: episode.podcast.language)
            }
            .onChange(of: player.playbackCompletionCount) { _ in playNextEpisodeIfAvailable() }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case let .word(value, sentence, time, preferredMeaning):
                    PodcastWordSheet(
                        word: value,
                        sentence: sentence,
                        episode: episode,
                        time: time,
                        preferredMeaning: preferredMeaning,
                        store: wordStore,
                        learningLanguage: learningLanguage
                    ) { player.play() }
                case .aiInsights:
                    if let aiInsights {
                        PodcastAIInsightsView(insights: aiInsights, episode: episode, store: wordStore) { time in
                            activeSheet = nil
                            player.seek(time)
                        }
                    }
                }
            }
            .overlay {
                GeometryReader { proxy in
                    if let draggedWord {
                        Text(draggedWord.word)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(isWordOverGarden ? .black : .white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(isWordOverGarden ? Color.mint : Color.blue)
                            .clipShape(Capsule())
                            .shadow(color: (isWordOverGarden ? Color.mint : Color.blue).opacity(0.55), radius: 14)
                            .scaleEffect(isWordOverGarden ? 1.12 : 1)
                            .position(
                                x: draggedWordLocation.x - proxy.frame(in: .global).minX,
                                y: draggedWordLocation.y - proxy.frame(in: .global).minY - 34
                            )
                            .animation(.easeOut(duration: 0.16), value: isWordOverGarden)
                    }
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if draggedWord != nil || gardenMessage != nil {
                    PodcastWordGarden(
                        isTargeted: isWordOverGarden,
                        message: gardenMessage,
                        word: draggedWord?.word,
                        phonetic: draggedWordPhonetic,
                        meaning: draggedWordMeaning,
                        learningLanguage: learningLanguage
                    )
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.82), value: draggedWord != nil)
    }

    @ViewBuilder
    private var playbackHeader: some View {
        VStack(spacing: isPlayerHeaderCollapsed ? 8 : 12) {
            if isPlayerHeaderCollapsed {
                HStack(spacing: 12) {
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 34))
                    }
                    .disabled(!player.isPrepared)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(episode.title).font(.subheadline.bold()).lineLimit(1)
                        Text(episode.podcast.title).font(.caption).foregroundColor(.gray).lineLimit(1)
                    }

                    Spacer(minLength: 4)
                    playbackRateMenu
                    Button { withAnimation(.easeInOut(duration: 0.22)) { isPlayerHeaderCollapsed = false } } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: 30, height: 30)
                    }
                    .accessibilityLabel(learningLanguage == .english ? "Expand player" : "展开播放器")
                }
                .foregroundColor(.white)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Spacer().frame(width: 30)
                    Text(episode.title)
                        .font(.title3.bold())
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity)
                    Button { withAnimation(.easeInOut(duration: 0.22)) { isPlayerHeaderCollapsed = true } } label: {
                        Image(systemName: "chevron.up")
                            .frame(width: 30, height: 30)
                    }
                    .foregroundColor(.white)
                    .accessibilityLabel(learningLanguage == .english ? "Collapse player" : "收起播放器")
                }
                Text("\(episode.podcast.title) · \(episode.podcast.level)").font(.subheadline).foregroundColor(.gray)
                Slider(value: Binding(get: { player.currentTime }, set: { player.seek($0) }), in: 0...max(1, player.duration)).tint(.white)
                HStack(spacing: 44) {
                    Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 58)) }
                        .disabled(!player.isPrepared)
                    Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                }.font(.title).foregroundColor(.white)
                playbackRateButtons
            }

            playbackStatus
        }
        .padding(.horizontal, 20)
        .padding(.vertical, isPlayerHeaderCollapsed ? 8 : 16)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                if value.translation.height < -24, !isPlayerHeaderCollapsed {
                    withAnimation(.easeInOut(duration: 0.22)) { isPlayerHeaderCollapsed = true }
                } else if value.translation.height > 24, isPlayerHeaderCollapsed {
                    withAnimation(.easeInOut(duration: 0.22)) { isPlayerHeaderCollapsed = false }
                }
            }
        )
    }

    private var playbackRateButtons: some View {
        HStack(spacing: 8) {
            ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { rate in
                Button { player.setPlaybackRate(Float(rate)) } label: {
                    Text(String(format: "%gx", rate))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(abs(Double(player.playbackRate) - rate) < 0.01 ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(abs(Double(player.playbackRate) - rate) < 0.01 ? Color.white : Color.white.opacity(0.10))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel(learningLanguage == .english ? "Playback speed" : "播放速度")
    }

    private var playbackRateMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                Button {
                    player.setPlaybackRate(Float(rate))
                } label: {
                    if abs(Double(player.playbackRate) - rate) < 0.01 {
                        Label(String(format: "%gx", rate), systemImage: "checkmark")
                    } else {
                        Text(String(format: "%gx", rate))
                    }
                }
            }
        } label: {
            Text(String(format: "%gx", player.playbackRate))
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
        }
        .accessibilityLabel(learningLanguage == .english ? "Playback speed" : "播放速度")
    }

    @ViewBuilder
    private var playbackStatus: some View {
        if player.isDownloadingAudio {
            VStack(spacing: 6) {
                if player.audioExpectedBytes > 0 {
                    ProgressView(value: player.audioDownloadProgress).tint(.white)
                    HStack {
                        Text(learningLanguage == .english ? "Downloading audio \(Int(player.audioDownloadProgress * 100))%" : "正在下载音频 \(Int(player.audioDownloadProgress * 100))%")
                        Spacer()
                        Text("\(formattedBytes(player.audioDownloadedBytes)) / \(formattedBytes(player.audioExpectedBytes))")
                    }.font(.caption).foregroundColor(.gray)
                } else {
                    ProgressView(learningLanguage == .english ? "Connecting to audio server…" : "正在连接音频服务器…")
                        .tint(.white).foregroundColor(.gray)
                }
            }
        } else if player.isPreparing {
            ProgressView(learningLanguage == .english ? "Preparing audio…" : "正在准备音频，首次播放可能需要下载…").tint(.white).foregroundColor(.gray)
        } else if player.isBuffering {
            ProgressView(learningLanguage == .english ? "Buffering audio…" : "正在缓冲音频…").tint(.white).foregroundColor(.gray)
        }
        if let error = player.errorMessage {
            VStack(spacing: 8) {
                Text(error).font(.caption).foregroundColor(.red).multilineTextAlignment(.center)
                Button(learningLanguage == .english ? "Retry audio" : "重试音频") { Task { await player.load(episode) } }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func loadSentences() async {
        let episodeID = episode.id
        isLoadingSentences = true
        sentenceError = nil
        sentences = []
        do {
            let loadedSentences = try await SupabaseClient.shared.fetchPodcastSentences(episodeId: episodeID)
            guard episode.id == episodeID else { return }
            sentences = loadedSentences
        } catch {
            guard episode.id == episodeID else { return }
            sentenceError = "同步字幕读取失败：\(error.localizedDescription)"
        }
        isLoadingSentences = false
    }

    private func loadAIInsights() async {
        let episodeID = episode.id
        isLoadingAIInsights = true
        aiInsightsError = nil
        aiInsights = nil
        do {
            let loadedInsights = try await SupabaseClient.shared.fetchPodcastAIInsights(episodeId: episodeID)
            guard episode.id == episodeID else { return }
            aiInsights = loadedInsights
        } catch {
            guard episode.id == episodeID else { return }
            aiInsightsError = error.localizedDescription
        }
        isLoadingAIInsights = false
    }

    private func playNextEpisodeIfAvailable() {
        guard let currentIndex = queue.firstIndex(where: { $0.id == episode.id }) else { return }
        let nextIndex = queue.index(after: currentIndex)
        guard queue.indices.contains(nextIndex) else { return }
        shouldAutoplayEpisode = true
        episode = queue[nextIndex]
    }

    private func beginWordDrag(word: String, sentence: PodcastSentence, location: CGPoint) {
        guard draggedWord == nil else { return }
        let cleaned = word.trimmingCharacters(in: .punctuationCharacters)
        guard !cleaned.isEmpty else { return }
        draggedWord = DraggedPodcastWord(word: cleaned, sentence: sentence.english, time: sentence.start)
        draggedWordMeaning = contextualMeaning(for: cleaned, sentence: sentence)
        draggedWordPhonetic = PodcastWordPronunciationPlayer.phonetic(
            for: cleaned,
            language: episode.podcast.language
        )
        draggedWordLocation = location
        gardenMessage = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard draggedWordMeaning == nil else { return }
        Task {
            let meaning = PodcastWordLookup.shared.meaning(
                for: cleaned,
                sourceLanguage: episode.podcast.language,
                targetLanguage: learningLanguage
            )
            guard draggedWord?.word.caseInsensitiveCompare(cleaned) == .orderedSame else { return }
            // Empty means the lookup completed without a trustworthy result.
            // Keep it distinct from nil (still loading) so it can never be saved.
            draggedWordMeaning = meaning ?? ""
        }
    }

    private func updateWordDrag(_ location: CGPoint) {
        draggedWordLocation = location
        let isNowTargeted = location.y > UIScreen.main.bounds.height - 190
        if isNowTargeted != isWordOverGarden {
            isWordOverGarden = isNowTargeted
            UIImpactFeedbackGenerator(style: isNowTargeted ? .medium : .light).impactOccurred()
        }
    }

    private func finishWordDrag(_ location: CGPoint) {
        updateWordDrag(location)
        guard let draggedWord else { return }
        if isWordOverGarden {
            if let meaning = draggedWordMeaning?.trimmingCharacters(in: .whitespacesAndNewlines), !meaning.isEmpty {
                let added = wordStore.addToSelectedWordBook(
                    word: draggedWord.word,
                    meaning: meaning,
                    meaningLanguage: learningLanguage,
                    sentence: draggedWord.sentence,
                    episode: episode,
                    time: draggedWord.time
                )
                let bookName = wordStore.wordBookLibrary.books.first(where: {
                    $0.id == wordStore.wordBookLibrary.selectedBookID
                })?.name ?? "我的词书"
                gardenMessage = added ? "\(draggedWord.word) 已加入“\(bookName)”" : "\(draggedWord.word) 已在“\(bookName)”中"
                UINotificationFeedbackGenerator().notificationOccurred(added ? .success : .warning)
            } else {
                gardenMessage = learningLanguage == .english ? "Meaning is still loading. Please try again." : "释义仍在查询，请稍后重试"
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
                withAnimation { gardenMessage = nil }
            }
        }
        self.draggedWord = nil
        draggedWordMeaning = nil
        draggedWordPhonetic = nil
        isWordOverGarden = false
    }

    private func contextualMeaning(for word: String, sentence: PodcastSentence) -> String? {
        let normalized = word.trimmingCharacters(in: .punctuationCharacters)
        guard let candidate = aiInsights?.difficultWords.first(where: {
            ($0.word.caseInsensitiveCompare(normalized) == .orderedSame ||
             $0.lemma.caseInsensitiveCompare(normalized) == .orderedSame) &&
            ($0.sentence.caseInsensitiveCompare(sentence.english) == .orderedSame ||
             abs($0.start - sentence.start) < 0.5)
        }) else { return nil }
        let meaning = candidate.meaning(for: learningLanguage).trimmingCharacters(in: .whitespacesAndNewlines)
        return meaning.isEmpty ? nil : meaning
    }
}

private struct DraggedPodcastWord {
    let word: String
    let sentence: String
    let time: TimeInterval
}

private struct PodcastWordGarden: View {
    let isTargeted: Bool
    let message: String?
    let word: String?
    let phonetic: String?
    let meaning: String?
    let learningLanguage: LearningLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.mint)
                    Text(message)
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .center)
            } else {
                HStack(alignment: .center, spacing: 12) {
                    Text(word ?? "")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .allowsTightening(true)
                        .layoutPriority(1)
                    Spacer()
                    Image(systemName: isTargeted ? "plus.circle.fill" : "text.book.closed.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(isTargeted ? .mint : .white.opacity(0.55))
                        .fixedSize()
                }

                if let phonetic, !phonetic.isEmpty {
                    Text(phonetic)
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(meaning.map {
                    $0.isEmpty
                        ? (learningLanguage == .english ? "Meaning unavailable" : "暂未查到可靠释义")
                        : $0
                } ?? (learningLanguage == .english ? "Looking up meaning…" : "正在查询释义…"))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(meaning?.isEmpty == false ? .mint : .white.opacity(0.68))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .background(Color(red: 0.10, green: 0.11, blue: 0.13))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(isTargeted ? Color.mint : Color.white.opacity(0.18), lineWidth: isTargeted ? 3 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .scaleEffect(isTargeted ? 1.02 : 1)
        .animation(.easeOut(duration: 0.16), value: isTargeted)
    }
}

private struct PodcastAIInsightsView: View {
    let insights: PodcastAIInsights
    let episode: PodcastEpisode
    @ObservedObject var store: PodcastWordStore
    let seek: (TimeInterval) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.podcastInterfaceLanguage) private var learningLanguage
    @State private var addedMessage: String?
    @State private var selectedWordIDs: Set<String>

    init(
        insights: PodcastAIInsights,
        episode: PodcastEpisode,
        store: PodcastWordStore,
        seek: @escaping (TimeInterval) -> Void
    ) {
        self.insights = insights
        self.episode = episode
        self.store = store
        self.seek = seek
        _selectedWordIDs = State(initialValue: Set(insights.difficultWords.map(\.id)))
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(learningLanguage == .english ? "AI Summary" : "AI 内容总结", systemImage: "sparkles")
                            .font(.headline).foregroundColor(.mint)
                        if learningLanguage == .english,
                           !insights.summaryEn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           !podcastContainsChinese(insights.summaryEn) {
                            Text(insights.summaryEn).font(.body)
                        } else {
                            PodcastLocalizedInsightText(text: insights.summaryZh, targetLanguage: learningLanguage)
                                .font(.body)
                        }
                    }

                    if !insights.keyPoints.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(learningLanguage == .english ? "Key points" : "关键观点").font(.headline)
                            ForEach(Array(insights.keyPoints.enumerated()), id: \.offset) { _, point in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•")
                                    PodcastLocalizedInsightText(text: point, targetLanguage: learningLanguage)
                                }
                            }
                        }
                    }

                    HStack {
                        Text(learningLanguage == .english ? "Difficult words · \(insights.difficultWords.count)" : "可能的难词 · \(insights.difficultWords.count)").font(.headline)
                        Spacer()
                        Button(learningLanguage == .english ? "Add selected \(selectedWordIDs.count)" : "加入已选 \(selectedWordIDs.count)") {
                            let selectedWords = insights.difficultWords.filter { selectedWordIDs.contains($0.id) }
                            let added = store.add(selectedWords, episode: episode, learningLanguage: learningLanguage)
                            addedMessage = added == 0
                                ? (learningLanguage == .english ? "The selected words are already saved." : "已选单词都在语境单词中")
                                : (learningLanguage == .english ? "Added \(added) context words." : "已加入 \(added) 个语境单词")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedWordIDs.isEmpty)
                    }

                    HStack(spacing: 16) {
                        Button(learningLanguage == .english ? "Select all" : "全选") {
                            selectedWordIDs = Set(insights.difficultWords.map(\.id))
                        }
                        Button(learningLanguage == .english ? "Clear" : "取消全选") {
                            selectedWordIDs.removeAll()
                        }
                    }
                    .font(.caption.bold())

                    if let addedMessage {
                        Text(addedMessage).font(.caption).foregroundColor(.mint)
                    }

                    ForEach(insights.difficultWords) { word in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(word.lemma).font(.title3.bold())
                                if let level = word.cefrLevel, !level.isEmpty {
                                    Text(level).font(.caption.bold()).foregroundColor(.mint)
                                }
                                Spacer()
                                Button {
                                    if selectedWordIDs.contains(word.id) {
                                        selectedWordIDs.remove(word.id)
                                    } else {
                                        selectedWordIDs.insert(word.id)
                                    }
                                } label: {
                                    Image(systemName: selectedWordIDs.contains(word.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 24, weight: .semibold))
                                        .foregroundColor(selectedWordIDs.contains(word.id) ? .mint : .secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(selectedWordIDs.contains(word.id) ? "取消选择 \(word.lemma)" : "选择 \(word.lemma)")
                            }
                            if !word.meaning(for: learningLanguage).isEmpty {
                                Text(word.meaning(for: learningLanguage)).foregroundColor(.mint)
                            } else {
                                PodcastSystemTranslationText(
                                    source: word.meaning,
                                    sourceExplanationLanguage: .chinese,
                                    targetLanguage: learningLanguage
                                )
                            }
                            Button { seek(word.start) } label: {
                                HighlightedPodcastExample(
                                    sentence: word.sentence,
                                    word: word.word,
                                    baseColor: .secondary
                                )
                                    .multilineTextAlignment(.leading)
                            }
                            .buttonStyle(.plain)
                            if !word.reason.isEmpty {
                                PodcastLocalizedInsightText(text: word.reason, targetLanguage: learningLanguage)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(16)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(20)
            }
            .navigationTitle(learningLanguage == .english ? "Episode Summary" : "本集学习摘要")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(learningLanguage == .english ? "Done" : "完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct PodcastLocalizedInsightText: View {
    let text: String
    let targetLanguage: LearningLanguage

    private var containsChinese: Bool {
        text.unicodeScalars.contains { scalar in
            (0x3400...0x9FFF).contains(Int(scalar.value))
        }
    }

    @ViewBuilder
    var body: some View {
        if targetLanguage == .english, containsChinese {
            PodcastSystemTranslationText(
                source: text,
                sourceExplanationLanguage: .chinese,
                targetLanguage: .english
            )
        } else {
            Text(text)
        }
    }
}

private struct TappableSentenceView: View {
    let sentence: PodcastSentence
    let isCurrent: Bool
    let showTranslation: Bool
    let sourceLanguage: StudyLanguage
    let learningLanguage: LearningLanguage
    let beginDrag: (String, CGPoint) -> Void
    let updateDrag: (CGPoint) -> Void
    let endDrag: (CGPoint) -> Void
    var tokens: [String] { sentence.english.components(separatedBy: .whitespaces).filter { !$0.isEmpty } }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            WordFlowView(
                tokens: tokens,
                beginDrag: beginDrag,
                updateDrag: updateDrag,
                endDrag: endDrag
            )
            if showTranslation {
                if learningLanguage == .chinese,
                   let chinese = sentence.chinese,
                   !chinese.isEmpty {
                    Text(chinese).font(.subheadline).foregroundColor(.gray)
                } else if sourceLanguage.translationLanguageCode != learningLanguage.translationLanguageCode {
                    PodcastSystemTranslationText(
                        source: sentence.english,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: learningLanguage
                    )
                }
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(isCurrent ? Color.mint.opacity(0.13) : Color.white.opacity(0.04))
            .overlay(alignment: .leading) { if isCurrent { Rectangle().fill(Color.mint).frame(width: 3) } }
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct WordFlowView: View {
    let tokens: [String]
    let beginDrag: (String, CGPoint) -> Void
    let updateDrag: (CGPoint) -> Void
    let endDrag: (CGPoint) -> Void

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                PodcastWordFlowLayout(horizontalSpacing: 5, verticalSpacing: 8) {
                    wordButtons
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 42), spacing: 5, alignment: .leading)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    wordButtons
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var wordButtons: some View {
        ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
            Text(token)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white)
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.35)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                        .onChanged { value in
                            switch value {
                            case .second(true, let drag?):
                                beginDrag(token, drag.location)
                                updateDrag(drag.location)
                            default:
                                break
                            }
                        }
                        .onEnded { value in
                            if case .second(true, let drag?) = value {
                                endDrag(drag.location)
                            }
                        }
                )
        }
    }
}

@available(iOS 16.0, *)
private struct PodcastWordFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            x += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : x, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private final class PodcastTranslationMemory {
    static let shared = PodcastTranslationMemory()
    private let values = NSCache<NSString, NSString>()
    private let defaultsKey = "tinghui.podcast.translation-cache.v2"
    private let lock = NSLock()
    private var persistedValues: [String: String]

    private init() {
        persistedValues = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    func value(for source: String, sourceCode: String, targetCode: String) -> String? {
        let cacheKey = key(source, sourceCode, targetCode)
        if let memoryValue = values.object(forKey: cacheKey as NSString) { return memoryValue as String }
        lock.lock()
        let persistedValue = persistedValues[cacheKey]
        lock.unlock()
        if let persistedValue {
            values.setObject(persistedValue as NSString, forKey: cacheKey as NSString)
        }
        return persistedValue
    }

    func store(_ translation: String, for source: String, sourceCode: String, targetCode: String) {
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let cacheKey = key(source, sourceCode, targetCode)
        values.setObject(trimmed as NSString, forKey: cacheKey as NSString)
        lock.lock()
        persistedValues[cacheKey] = trimmed
        if persistedValues.count > 2_000 {
            let staleKeys = Array(persistedValues.keys.prefix(persistedValues.count - 2_000))
            for staleKey in staleKeys {
                persistedValues.removeValue(forKey: staleKey)
            }
        }
        let snapshot = persistedValues
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: defaultsKey)
    }

    private func key(_ source: String, _ sourceCode: String, _ targetCode: String) -> String {
        "v2|\(sourceCode)>\(targetCode)|\(source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }
}

private struct PodcastSystemTranslationText: View {
    let source: String
    let sourceLanguageCode: String
    let targetLanguage: LearningLanguage
    var onTranslation: ((String) -> Void)? = nil

    init(source: String, sourceLanguage: StudyLanguage, targetLanguage: LearningLanguage, onTranslation: ((String) -> Void)? = nil) {
        self.source = source
        sourceLanguageCode = sourceLanguage.translationLanguageCode
        self.targetLanguage = targetLanguage
        self.onTranslation = onTranslation
    }

    init(source: String, sourceExplanationLanguage: LearningLanguage, targetLanguage: LearningLanguage, onTranslation: ((String) -> Void)? = nil) {
        self.source = source
        sourceLanguageCode = sourceExplanationLanguage.translationLanguageCode
        self.targetLanguage = targetLanguage
        self.onTranslation = onTranslation
    }

    @ViewBuilder
    var body: some View {
#if canImport(Translation)
        if #available(iOS 18.0, *) {
            PodcastAvailableTranslationText(
                source: source,
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguage.translationLanguageCode,
                learningLanguage: targetLanguage,
                onTranslation: onTranslation
            )
        } else {
            Text(targetLanguage == .english ? "Update to iOS 18 to use translation" : "系统升级到 iOS 18 后可使用翻译")
                .font(.caption).foregroundColor(.gray)
        }
#else
        Text(targetLanguage == .english ? "Translation is unavailable" : "当前系统暂不支持翻译")
            .font(.caption).foregroundColor(.gray)
#endif
    }
}

#if canImport(Translation)
@available(iOS 18.0, *)
private struct PodcastAvailableTranslationText: View {
    let source: String
    let sourceLanguageCode: String
    let targetLanguageCode: String
    let learningLanguage: LearningLanguage
    var onTranslation: ((String) -> Void)?
    @State private var translated = ""
    @State private var checkedAvailability = false
    @State private var isLanguagePairInstalled = false

    var body: some View {
        Group {
            if !translated.isEmpty {
                Text(translated).font(.subheadline).foregroundColor(.gray)
            } else if isLanguagePairInstalled {
                PodcastInstalledTranslationText(
                    source: source,
                    sourceLanguageCode: sourceLanguageCode,
                    targetLanguageCode: targetLanguageCode,
                    learningLanguage: learningLanguage
                ) { result in
                    translated = result
                    PodcastTranslationMemory.shared.store(
                        result,
                        for: source,
                        sourceCode: sourceLanguageCode,
                        targetCode: targetLanguageCode
                    )
                    onTranslation?(result)
                }
            } else if checkedAvailability {
                Text(learningLanguage == .english ? "Translation language is not downloaded" : "翻译语言包未下载")
                    .font(.caption)
                    .foregroundColor(.gray)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(learningLanguage == .english ? "Checking translation…" : "正在检查翻译…").font(.caption)
                }.foregroundColor(.gray)
            }
        }
        .task(id: "\(sourceLanguageCode)>\(targetLanguageCode)|\(source)") {
            if sourceLanguageCode == targetLanguageCode {
                translated = source
                onTranslation?(source)
            } else if let cached = PodcastTranslationMemory.shared.value(
                for: source,
                sourceCode: sourceLanguageCode,
                targetCode: targetLanguageCode
            ) {
                translated = cached
                onTranslation?(cached)
            } else {
                let availability = LanguageAvailability()
                let status = await availability.status(
                    from: Locale.Language(identifier: sourceLanguageCode),
                    to: Locale.Language(identifier: targetLanguageCode)
                )
                // `.supported` lets Translation download/enable the language
                // assets instead of falling back to the original Chinese text.
                isLanguagePairInstalled = status == .installed || status == .supported
                checkedAvailability = true
            }
        }
    }
}

@available(iOS 18.0, *)
private struct PodcastInstalledTranslationText: View {
    let source: String
    let sourceLanguageCode: String
    let targetLanguageCode: String
    let learningLanguage: LearningLanguage
    let completion: (String) -> Void
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                Text(learningLanguage == .english ? "Translation is temporarily unavailable" : "翻译暂时不可用")
                    .font(.caption)
                    .foregroundColor(.gray)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(learningLanguage == .english ? "Translating…" : "正在翻译…").font(.caption)
                }
                .foregroundColor(.gray)
            }
        }
        .translationTask(
            source: Locale.Language(identifier: sourceLanguageCode),
            target: Locale.Language(identifier: targetLanguageCode)
        ) { session in
            do {
                let response = try await session.translate(source)
                completion(response.targetText)
            } catch {
                failed = true
            }
        }
    }
}
#endif

@MainActor
private final class PodcastWordLookup {
    static let shared = PodcastWordLookup()
    private var cache: [StudyLanguage: [String: Word]] = [:]

    func prepare(for sourceLanguage: StudyLanguage) {
        guard cache[sourceLanguage] == nil else { return }
        let bookNames = sourceLanguage == .german ? ["A1", "A2", "B1"] : ["IELTS_9400", "KaoYan_2"]
        var words: [String: Word] = [:]
        for book in DataLoader.loadBooks(named: bookNames) {
            for word in book.words where words[word.word.lowercased()] == nil {
                words[word.word.lowercased()] = word
            }
        }
        cache[sourceLanguage] = words
    }

    func meaning(
        for token: String,
        sourceLanguage: StudyLanguage,
        targetLanguage: LearningLanguage
    ) -> String? {
        prepare(for: sourceLanguage)

        guard let dictionary = cache[sourceLanguage] else { return nil }
        for candidate in Self.lookupCandidates(for: token, language: sourceLanguage) {
            guard let word = dictionary[candidate] else { continue }
            let meaning: String
            switch targetLanguage {
            case .chinese:
                meaning = word.meaningZh ?? word.translation
            case .english:
                meaning = word.meaningEn ?? (sourceLanguage == .english ? "" : word.translation)
            }
            let trimmed = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               targetLanguage != .english || !podcastContainsChinese(trimmed) {
                return trimmed
            }
        }
        return nil
    }

    private static func lookupCandidates(for token: String, language: StudyLanguage) -> [String] {
        let normalized = token
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            .lowercased()
        guard !normalized.isEmpty else { return [] }

        var candidates = [normalized]
        if let lemma = linguisticLemma(for: normalized, language: language), lemma != normalized {
            candidates.append(lemma)
        }
        if normalized.hasSuffix("’s") || normalized.hasSuffix("'s") {
            candidates.append(String(normalized.dropLast(2)))
        }
        guard language == .english else { return candidates }

        let irregularForms = [
            "am": "be", "is": "be", "are": "be", "was": "be", "were": "be", "been": "be",
            "went": "go", "gone": "go", "did": "do", "done": "do", "had": "have",
            "made": "make", "took": "take", "taken": "take", "came": "come",
            "saw": "see", "seen": "see", "said": "say", "children": "child",
            "men": "man", "women": "woman", "people": "person", "mice": "mouse",
            "better": "good", "best": "good", "worse": "bad", "worst": "bad"
        ]
        if let base = irregularForms[normalized] { candidates.append(base) }

        if normalized.hasSuffix("ies"), normalized.count > 3 {
            candidates.append(String(normalized.dropLast(3)) + "y")
        }
        if normalized.hasSuffix("ing"), normalized.count > 4 {
            let stem = String(normalized.dropLast(3))
            candidates.append(stem)
            candidates.append(stem + "e")
            if stem.count > 2, stem.last == stem.dropLast().last { candidates.append(String(stem.dropLast())) }
        }
        if normalized.hasSuffix("ed"), normalized.count > 3 {
            let stem = String(normalized.dropLast(2))
            candidates.append(stem)
            candidates.append(stem + "e")
            if stem.count > 2, stem.last == stem.dropLast().last { candidates.append(String(stem.dropLast())) }
        }
        if normalized.hasSuffix("es"), normalized.count > 3 {
            candidates.append(String(normalized.dropLast(2)))
        }
        if normalized.hasSuffix("s"), normalized.count > 2 {
            candidates.append(String(normalized.dropLast()))
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func linguisticLemma(for token: String, language: StudyLanguage) -> String? {
        guard let firstLetter = token.firstIndex(where: { $0.isLetter }) else { return nil }
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = token
        tagger.setLanguage(
            language == .german ? .german : .english,
            range: token.startIndex..<token.endIndex
        )
        return tagger.tag(at: firstLetter, unit: .word, scheme: .lemma).0?.rawValue.lowercased()
    }
}

private struct PodcastWordSheet: View {
    let word: String; let sentence: String; let episode: PodcastEpisode; let time: TimeInterval
    let preferredMeaning: String?
    @ObservedObject var store: PodcastWordStore
    let learningLanguage: LearningLanguage
    let resume: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var translatedMeaning: String?
    @State private var dictionaryMeaning: String?
    @State private var didFinishDictionaryLookup = false
    @State private var addResultMessage: String?
    var saved: Bool { store.contains(word: word, episodeID: episode.id) }
    var resolvedMeaning: String? { dictionaryMeaning ?? translatedMeaning }
    var meaning: String {
        resolvedMeaning ?? (learningLanguage == .english ? "Getting meaning…" : "正在获取中文释义…")
    }
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 18) {
                Text(word).font(.system(size: 34, weight: .bold))
                if let dictionaryMeaning {
                    Text(dictionaryMeaning)
                        .font(.title3)
                        .foregroundColor(.mint)
                } else if didFinishDictionaryLookup {
                    PodcastSystemTranslationText(
                        source: word,
                        sourceLanguage: episode.podcast.language,
                        targetLanguage: learningLanguage
                    ) { translatedMeaning = $0 }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(learningLanguage == .english ? "Looking up meaning…" : "正在查询释义…")
                    }
                    .foregroundColor(.secondary)
                }
                Divider(); Text(learningLanguage == .english ? "Original sentence" : "原句").font(.headline)
                HighlightedPodcastExample(sentence: sentence, word: word).font(.title3)
                Text(learningLanguage == .english ? "Source: \(episode.podcast.title) · \(episode.title)" : "来源：\(episode.podcast.title) · \(episode.title)").font(.caption).foregroundColor(.secondary)
                Button {
                    let added = store.addToSelectedWordBook(
                        word: word,
                        meaning: meaning,
                        meaningLanguage: learningLanguage,
                        sentence: sentence,
                        episode: episode,
                        time: time
                    )
                    let bookName = store.wordBookLibrary.books.first(where: {
                        $0.id == store.wordBookLibrary.selectedBookID
                    })?.name ?? (learningLanguage == .english ? "My Word Book" : "我的词书")
                    addResultMessage = added
                        ? (learningLanguage == .english ? "Added to \(bookName)." : "已加入“\(bookName)”")
                        : (learningLanguage == .english ? "Already in \(bookName)." : "该单词已在“\(bookName)”中")
                } label: {
                    Label(
                        learningLanguage == .english ? "Add to Word Book" : "加入词书",
                        systemImage: "text.badge.plus"
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                }
                .buttonStyle(.borderedProminent)
                    .disabled(resolvedMeaning == nil && !saved)
                if let addResultMessage {
                    Text(addResultMessage)
                        .font(.caption)
                        .foregroundColor(.mint)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                Button(learningLanguage == .english ? "Resume" : "继续播放") { dismiss(); resume() }.frame(maxWidth: .infinity)
                Spacer()
            }.padding(22).navigationTitle("语境词卡").navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .task(id: "\(episode.podcast.language.rawValue)|\(learningLanguage.rawValue)|\(word.lowercased())") {
            dictionaryMeaning = nil
            translatedMeaning = nil
            didFinishDictionaryLookup = false
            if let preferredMeaning = preferredMeaning?.trimmingCharacters(in: .whitespacesAndNewlines),
               !preferredMeaning.isEmpty,
               learningLanguage != .english || !podcastContainsChinese(preferredMeaning) {
                dictionaryMeaning = preferredMeaning
                didFinishDictionaryLookup = true
                return
            }
            dictionaryMeaning = PodcastWordLookup.shared.meaning(
                for: word,
                sourceLanguage: episode.podcast.language,
                targetLanguage: learningLanguage
            )
            didFinishDictionaryLookup = true
        }
    }
}

private struct PodcastSavedWordMeaningText: View {
    let word: PodcastSavedWord
    let targetLanguage: LearningLanguage
    var font: Font = .subheadline

    var body: some View {
        Group {
            if word.effectiveMeaningLanguage == targetLanguage {
                Text(word.meaning)
                    .font(font)
                    .foregroundColor(.mint)
            } else {
                PodcastSystemTranslationText(
                    source: word.meaning,
                    sourceExplanationLanguage: word.effectiveMeaningLanguage,
                    targetLanguage: targetLanguage
                )
            }
        }
    }
}

private struct PodcastWordsView: View {
    @ObservedObject var store: PodcastWordStore
    let close: () -> Void
    @AppStorage("podcastWordsDisplayMode") private var displayMode = "groups"
    @State private var activeSheet: PodcastWordsSheet?
    @State private var selectedWordIDs = Set<String>()
    @State private var importMessage: String?
    @State private var pendingImportMessage: String?
    @State private var searchText = ""
    @Environment(\.podcastInterfaceLanguage) private var learningLanguage

    private var sortedWords: [PodcastSavedWord] {
        filteredWords.sorted { lhs, rhs in
            lhs.word.localizedCaseInsensitiveCompare(rhs.word) == .orderedAscending
        }
    }

    private var filteredWords: [PodcastSavedWord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.words }
        return store.words.filter { word in
            [word.word, word.meaning, word.sentence, word.podcastTitle, word.episodeTitle]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var groups: [(letter: String, words: [PodcastSavedWord])] {
        Dictionary(grouping: filteredWords, by: { initialLetter(for: $0.word) })
            .map { letter, words in
                (letter, words.sorted { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending })
            }
            .sorted { lhs, rhs in
                if lhs.letter == "#" { return false }
                if rhs.letter == "#" { return true }
                return lhs.letter < rhs.letter
            }
    }

    var body: some View {
        NavigationView {
            Group {
                if store.words.isEmpty {
                    VStack(spacing: 12) {
                        if store.isSyncing {
                            ProgressView().tint(.white)
                            Text("正在同步语境单词…")
                        } else {
                            Image(systemName: "waveform.and.magnifyingglass").font(.system(size: 42))
                            Text("还没有语境词").font(.title2.bold())
                            Text(store.syncErrorMessage ?? "播放时点一下英文词，原句和来源会保存在这里。")
                            Button("重新同步") {
                                Task { await store.syncWithCloud(force: true) }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.mint)
                            .foregroundColor(.black)
                        }
                    }
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(30)
                }
                else {
                    VStack(spacing: 0) {
                        Picker("展示方式", selection: $displayMode) {
                            Label("字母分块", systemImage: "square.grid.2x2")
                                .tag("groups")
                            Label("单词列表", systemImage: "list.bullet")
                                .tag("list")
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                        Button {
                            selectedWordIDs = Set(filteredWords.map(\.id))
                            activeSheet = .addToWordBook
                        } label: {
                            Label("加入首页我的词书", systemImage: "text.badge.plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.mint)
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)

                        ScrollView {
                            if filteredWords.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 36))
                                    Text("没有找到匹配的语境单词")
                                        .font(.headline)
                                    Text("请尝试其他关键词")
                                        .font(.subheadline)
                                }
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 60)
                            }
                            if displayMode == "list" {
                                LazyVStack(spacing: 10) {
                                    ForEach(sortedWords) { word in
                                        Button { activeSheet = .word(word) } label: {
                                            HStack(spacing: 14) {
                                                VStack(alignment: .leading, spacing: 5) {
                                                    Text(word.word)
                                                        .font(.system(size: 19, weight: .bold))
                                                        .foregroundColor(.white)
                                                        .lineLimit(1)
                                                    PodcastSavedWordMeaningText(word: word, targetLanguage: learningLanguage)
                                                        .lineLimit(2)
                                                }
                                                Spacer(minLength: 8)
                                                Image(systemName: "chevron.right")
                                                    .font(.caption.bold())
                                                    .foregroundColor(.secondary)
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 13)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.white.opacity(0.07))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 14)
                                                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 14))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(16)
                            } else {
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 12)],
                                    spacing: 12
                                ) {
                                    ForEach(groups, id: \.letter) { group in
                                        NavigationLink {
                                            PodcastWordLetterView(letter: group.letter, words: group.words)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 8) {
                                                HStack(alignment: .firstTextBaseline) {
                                                    Text(group.letter)
                                                        .font(.system(size: 36, weight: .bold))
                                                        .foregroundColor(.white)
                                                    Spacer()
                                                    Text("\(group.words.count)")
                                                        .font(.caption.bold())
                                                        .foregroundColor(.black)
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 4)
                                                        .background(Color.mint)
                                                        .clipShape(Capsule())
                                                }

                                                Text(group.words.prefix(2).map(\.word).joined(separator: " · "))
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(2)
                                            }
                                            .padding(14)
                                            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                                            .background(Color.white.opacity(0.07))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 16)
                                                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 16))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(16)
                            }
                        }
                    }
                }
            }.background(Color.black).navigationTitle(learningLanguage == .english ? "My Context Words" : "我的语境单词")
                .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("首页", action: close).foregroundColor(.gray) } }
                .searchable(text: $searchText, prompt: "搜索单词、释义或原句")
                .sheet(item: $activeSheet, onDismiss: {
                    if let pendingImportMessage {
                        importMessage = pendingImportMessage
                        self.pendingImportMessage = nil
                    }
                }) { sheet in
                    switch sheet {
                    case let .word(word):
                        PodcastSavedWordDetailView(word: word)
                    case .addToWordBook:
                        PodcastWordBookSelectionView(
                            words: sortedWords,
                            selectedWordIDs: $selectedWordIDs,
                            wordBooks: store.wordBookLibrary.books,
                            selectedBookID: store.wordBookLibrary.selectedBookID,
                            onSelectBook: store.selectWordBook,
                            onCreateBook: { name in store.createHomeWordBook(name: name, ids: selectedWordIDs) },
                            onCreatedBook: { created in
                                let skipped = max(0, selectedWordIDs.count - created.entryCount)
                                pendingImportMessage = "已将 \(created.entryCount) 个单词加入“\(created.name)”，跳过 \(skipped) 个重复词。"
                                activeSheet = nil
                            }
                        ) {
                            let destinationID = store.wordBookLibrary.selectedBookID
                            let destinationName = store.wordBookLibrary.books.first(where: { $0.id == destinationID })?.name ?? "默认"
                            let added = store.addToHomeWordBook(ids: selectedWordIDs, destinationID: destinationID)
                            pendingImportMessage = added == 0
                                ? "所选单词已在“\(destinationName)”中"
                                : "已将 \(added) 个单词加入“\(destinationName)”"
                            activeSheet = nil
                        }
                    }
                }
                .alert("加入词书", isPresented: Binding(
                    get: { importMessage != nil },
                    set: { if !$0 { importMessage = nil } }
                )) {
                    Button("好") { importMessage = nil }
                } message: {
                    Text(importMessage ?? "")
                }
        }
        .navigationViewStyle(.stack)
    }

    private func initialLetter(for word: String) -> String {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "#" }
        let letter = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).uppercased()
        return letter.range(of: "^[A-Z]$", options: .regularExpression) == nil ? "#" : letter
    }
}

private struct PodcastWordBookSelectionView: View {
    let words: [PodcastSavedWord]
    @Binding var selectedWordIDs: Set<String>
    let wordBooks: [UserWordBook]
    let selectedBookID: String
    let onSelectBook: (String) -> Void
    let onCreateBook: (String) -> UserWordBook?
    let onCreatedBook: (UserWordBook) -> Void
    let onAdd: () -> Void
    @State private var isCreatingBook = false
    @State private var createdBook: UserWordBook?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.podcastInterfaceLanguage) private var learningLanguage

    private var allSelected: Bool {
        !words.isEmpty && selectedWordIDs.count == words.count
    }

    var body: some View {
        NavigationView {
            List {
                Section("加入到列表") {
                    Button { isCreatingBook = true } label: {
                        Label("新建词书…", systemImage: "plus.circle")
                    }
                    .disabled(selectedWordIDs.isEmpty)
                    ForEach(wordBooks) { book in
                        Button { onSelectBook(book.id) } label: {
                            HStack {
                                Image(systemName: book.id == selectedBookID ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(book.id == selectedBookID ? .mint : .secondary)
                                Text(book.name).foregroundColor(.primary)
                                Spacer()
                                Text("\(book.entryCount)").foregroundColor(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Button {
                        selectedWordIDs = allSelected ? [] : Set(words.map(\.id))
                    } label: {
                        HStack {
                            Text(allSelected ? "取消全选" : "全选")
                            Spacer()
                            Text("已选 \(selectedWordIDs.count)/\(words.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("选择要加入的单词") {
                    ForEach(words) { word in
                        Button {
                            if selectedWordIDs.contains(word.id) {
                                selectedWordIDs.remove(word.id)
                            } else {
                                selectedWordIDs.insert(word.id)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedWordIDs.contains(word.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundColor(selectedWordIDs.contains(word.id) ? .mint : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(word.word).font(.headline).foregroundColor(.primary)
                                    PodcastSavedWordMeaningText(word: word, targetLanguage: learningLanguage)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("加入我的词书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("加入（\(selectedWordIDs.count)）", action: onAdd)
                        .disabled(selectedWordIDs.isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $isCreatingBook, onDismiss: {
            if let created = createdBook {
                createdBook = nil
                onCreatedBook(created)
            }
        }) {
            CreateWordBookSheet(selectedWordCount: selectedWordIDs.count, isEnglish: learningLanguage == .english) { name in
                guard let created = onCreateBook(name) else { return "创建或保存失败，所选单词已保留，请重试。" }
                createdBook = created
                return nil
            }
        }
    }
}

private struct PodcastWordLetterView: View {
    let letter: String
    let words: [PodcastSavedWord]
    @State private var selectedWord: PodcastSavedWord?
    @Environment(\.podcastInterfaceLanguage) private var learningLanguage

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 148, maximum: 240), spacing: 12)],
                spacing: 12
            ) {
                ForEach(words) { word in
                    Button { selectedWord = word } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(word.word)
                                .font(.system(size: 19, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                            PodcastSavedWordMeaningText(word: word, targetLanguage: learningLanguage)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
                        .padding(14)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("\(letter) · \(words.count) 个单词")
        .sheet(item: $selectedWord) { word in
            PodcastSavedWordDetailView(word: word)
        }
    }
}

private struct PodcastSavedWordDetailView: View {
    let word: PodcastSavedWord
    @StateObject private var pronunciation = PodcastWordPronunciationPlayer()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.podcastInterfaceLanguage) private var learningLanguage

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(word.word).font(.system(size: 36, weight: .bold))
                            if let phonetic = PodcastWordPronunciationPlayer.phonetic(
                                for: word.word,
                                language: word.effectiveSourceLanguage
                            ) {
                                Text(phonetic)
                                    .font(.system(size: 18, weight: .medium, design: .rounded))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            pronunciation.speak(word.word, language: word.effectiveSourceLanguage)
                        } label: {
                            Image(systemName: pronunciation.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundColor(.black)
                                .frame(width: 52, height: 52)
                                .background(Color.mint)
                                .clipShape(Circle())
                        }
                        .accessibilityLabel("播放单词发音")
                    }
                    PodcastSavedWordMeaningText(word: word, targetLanguage: learningLanguage, font: .title3)
                    Divider()
                    Text("播客例句").font(.headline)
                    HighlightedPodcastExample(sentence: word.sentence, word: word.word)
                        .font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("来源：\(word.podcastTitle) · \(word.episodeTitle)")
                        .font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .navigationTitle("语境词卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

@MainActor
private final class PodcastWordPronunciationPlayer: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private static var phoneticsByLanguage: [StudyLanguage: [String: String]] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, language: StudyLanguage) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language == .german ? "de-DE" : "en-US")
        utterance.rate = 0.42
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    static func phonetic(for text: String, language: StudyLanguage) -> String? {
        guard language == .english else { return nil }
        if phoneticsByLanguage[language] == nil {
            let names = language == .german ? ["A1", "A2", "B1"] : ["KaoYan_2", "IELTS_9400"]
            var values: [String: String] = [:]
            for book in DataLoader.loadBooks(named: names) {
                for word in book.words {
                    guard let phonetic = word.phonetic?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !phonetic.isEmpty else { continue }
                    values[word.word.lowercased()] = phonetic
                }
            }
            phoneticsByLanguage[language] = values
        }
        guard let value = phoneticsByLanguage[language]?[text.lowercased()] else { return nil }
        return value.hasPrefix("/") || value.hasPrefix("[") ? value : "/\(value)/"
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
    }
}
