import SwiftUI
import Combine
import AVFoundation
import MediaPlayer
#if canImport(Translation)
import Translation
#endif

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
    let feedURL: URL
    let websiteURL: URL
    let learningScore: Int
    let transcriptQuality: String
    let rightsRisk: String
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

struct PodcastSavedWord: Identifiable, Codable, Hashable {
    let id: String
    let word: String
    let meaning: String
    let sentence: String
    let episodeID: String
    let episodeTitle: String
    let podcastTitle: String
    let audioURL: String
    let time: TimeInterval
    let savedAt: Date
}

// MARK: - Supabase content library

@MainActor
final class PodcastLibraryStore: ObservableObject {
    @Published private(set) var episodes: [PodcastEpisode] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?
    private let cacheKey = "tinghui.podcast.episode-cache.v5"
    private let freshCacheLifetime: TimeInterval = 6 * 60 * 60

    init() {
        restoreCache()
    }

    func loadIfNeeded(force: Bool = false) async {
        guard !isLoading, !isRefreshing else { return }
        if !force, isCacheFresh { return }

        isLoading = episodes.isEmpty
        isRefreshing = !episodes.isEmpty
        errorMessage = nil
        do {
            episodes = normalized(try await SupabaseClient.shared.fetchPodcastEpisodes(limit: 20))
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
    private let storageKey: String

    init(userKey: String) {
        storageKey = "tinghui.podcastWords.\(userKey.lowercased())"
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([PodcastSavedWord].self, from: data) { words = saved }
    }

    func contains(word: String, episodeID: String) -> Bool {
        words.contains { $0.word.caseInsensitiveCompare(word) == .orderedSame && $0.episodeID == episodeID }
    }

    func toggle(word: String, meaning: String, sentence: String, episode: PodcastEpisode, time: TimeInterval) {
        if let index = words.firstIndex(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame && $0.episodeID == episode.id }) {
            words.remove(at: index)
        } else {
            words.insert(.init(id: UUID().uuidString, word: word.lowercased(), meaning: meaning, sentence: sentence,
                               episodeID: episode.id, episodeTitle: episode.title, podcastTitle: episode.podcast.title,
                               audioURL: episode.audioURL.absoluteString, time: time, savedAt: Date()), at: 0)
        }
        if let data = try? JSONEncoder().encode(words) { UserDefaults.standard.set(data, forKey: storageKey) }
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
    let player = AVPlayer()
    private var observer: Any?
    private var statusCancellable: AnyCancellable?
    private var controlCancellable: AnyCancellable?
    private var hasTriedDownloadFallback = false
    private var preparationFallbackTask: Task<Void, Never>?

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                let total = self?.player.currentItem?.duration.seconds ?? 0
                self?.duration = total.isFinite ? max(0, total) : 0
            }
        }
    }

    func load(_ episode: PodcastEpisode) async {
        errorMessage = nil
        isPreparing = true
        isPrepared = false
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
                }
            }
        controlCancellable = player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.isBuffering = status == .waitingToPlayAtSpecifiedRate
                if status == .playing { self?.isPlaying = true }
                if status == .paused { self?.isPlaying = false }
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
        player.playImmediately(atRate: 1)
        isPlaying = true
    }
    func pause() { player.pause(); isPlaying = false }
    func seek(_ seconds: TimeInterval) { player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600)) }
    func skip(_ delta: TimeInterval) { seek(currentTime + delta) }

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
        if let values = try? destination.resourceValues(forKeys: [.fileSizeKey]),
           (values.fileSize ?? 0) > 32_000 {
            return destination
        }

        var request = URLRequest(url: episode.audioURL)
        request.timeoutInterval = 90
        request.setValue("TingHuier/1.0 PodcastLearning", forHTTPHeaderField: "User-Agent")
        request.setValue("audio/mpeg,audio/*;q=0.9,*/*;q=0.1", forHTTPHeaderField: "Accept")
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw SupabaseClientError.message("音频服务器返回异常状态")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.removeTarget(nil); commands.pauseCommand.removeTarget(nil)
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
    }
}

// MARK: - Views

struct PodcastLearningRootView: View {
    let userKey: String
    let onClose: () -> Void
    @StateObject private var library = PodcastLibraryStore()
    @StateObject private var wordStore: PodcastWordStore
    @State private var tab = 0
    @State private var selectedEpisode: PodcastEpisode?

    init(userKey: String, onClose: @escaping () -> Void) {
        self.userKey = userKey; self.onClose = onClose
        _wordStore = StateObject(wrappedValue: PodcastWordStore(userKey: userKey))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $tab) {
                PodcastTodayView(episodes: library.episodes, words: wordStore.words, isLoading: library.isLoading, error: library.errorMessage, open: { selectedEpisode = $0 }, close: onClose, retry: { Task { await library.reload() } })
                    .tabItem { Label("今日", systemImage: "house") }.tag(0)
                PodcastCuratedView(episodes: library.episodes, open: { selectedEpisode = $0 })
                    .tabItem { Label("精选", systemImage: "headphones") }.tag(1)
                PodcastWordsView(store: wordStore)
                    .tabItem { Label("单词", systemImage: "rectangle.stack") }.tag(2)
                PodcastAboutView()
                    .tabItem { Label("内容说明", systemImage: "info.circle") }.tag(3)
            }
            .tint(.white)
        }
        .task { await library.loadIfNeeded() }
        .fullScreenCover(item: $selectedEpisode) { episode in
            PodcastEpisodePlayerView(episode: episode, wordStore: wordStore)
        }
    }
}

private struct PodcastTodayView: View {
    let episodes: [PodcastEpisode]; let words: [PodcastSavedWord]; let isLoading: Bool; let error: String?
    let open: (PodcastEpisode) -> Void; let close: () -> Void; let retry: () -> Void

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("今天听 10 分钟").font(.system(size: 34, weight: .bold)).foregroundColor(.white)
                    Text("听见真实英语，把没听懂的词留到明天再见。")
                        .font(.headline).foregroundColor(.gray)
                    if let episode = episodes.first {
                        Button { open(episode) } label: { HeroEpisodeCard(episode: episode) }.buttonStyle(.plain)
                    } else if isLoading {
                        ProgressView("正在读取官方节目…").tint(.white).foregroundColor(.gray).frame(maxWidth: .infinity).padding(.vertical, 80)
                    } else if let error {
                        VStack(spacing: 14) { Text(error).foregroundColor(.gray); Button("重试", action: retry).buttonStyle(.borderedProminent) }
                            .frame(maxWidth: .infinity).padding(.vertical, 60)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("昨天遇到的词").font(.title2.bold()).foregroundColor(.white)
                        Text(words.isEmpty ? "听到陌生词时点一下，原句和声音会一起保存。" : "已有 \(words.count) 个真实语境词，可以在“单词”里回听。")
                            .foregroundColor(.gray)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 18))
                }.padding(20)
            }
            .background(Color.black)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("‹ 单词学习", action: close).foregroundColor(.gray) } }
        }.navigationViewStyle(.stack)
    }
}

private struct HeroEpisodeCard: View {
    let episode: PodcastEpisode
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("今日精选").font(.caption.bold()).foregroundColor(.mint)
            Text(episode.title).font(.title2.bold()).foregroundColor(.white).lineLimit(3)
            Text("\(episode.podcast.title) · \(episode.podcast.level) · \(episode.durationLabel)").font(.subheadline).foregroundColor(.gray)
            Label("开始听", systemImage: "play.fill").font(.headline).foregroundColor(.black).padding(.horizontal, 18).frame(height: 48).background(Color.white).clipShape(Capsule())
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(LinearGradient(colors: [.blue.opacity(0.45), .purple.opacity(0.28)], startPoint: .topLeading, endPoint: .bottomTrailing)).clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

private struct PodcastCuratedView: View {
    let episodes: [PodcastEpisode]; let open: (PodcastEpisode) -> Void
    @State private var shelf: PodcastShelf?
    var filtered: [PodcastEpisode] { shelf.map { selected in episodes.filter { $0.podcast.shelf == selected } } ?? episodes }
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { FilterChip(title: "全部", selected: shelf == nil) { shelf = nil }; ForEach(PodcastShelf.allCases) { item in FilterChip(title: item.rawValue, selected: shelf == item) { shelf = item } } }.padding(.horizontal, 16)
                }.padding(.vertical, 12)
                List(filtered) { episode in Button { open(episode) } label: { EpisodeRow(episode: episode) }.listRowBackground(Color.black).listRowSeparatorTint(Color.white.opacity(0.1)) }.listStyle(.plain).background(Color.black)
            }.background(Color.black).navigationTitle("适合你现在听的")
        }.navigationViewStyle(.stack)
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
    let episode: PodcastEpisode
    @ObservedObject var wordStore: PodcastWordStore
    @StateObject private var player = PodcastPlayerStore()
    @Environment(\.dismiss) private var dismiss
    @State private var selectedWord: String?
    @State private var showTranslation = true
    @State private var sentences: [PodcastSentence] = []
    @State private var isLoadingSentences = false
    @State private var sentenceError: String?

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
                VStack(spacing: 12) {
                    Text(episode.title).font(.title3.bold()).foregroundColor(.white).multilineTextAlignment(.center).lineLimit(2)
                    Text("\(episode.podcast.title) · \(episode.podcast.level)").font(.subheadline).foregroundColor(.gray)
                    Slider(value: Binding(get: { player.currentTime }, set: { player.seek($0) }), in: 0...max(1, player.duration)).tint(.white)
                    HStack(spacing: 44) {
                        Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                        Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 58)) }
                            .disabled(!player.isPrepared)
                        Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                    }.font(.title).foregroundColor(.white)
                    if player.isPreparing {
                        ProgressView("正在准备音频，首次播放可能需要下载…").tint(.white).foregroundColor(.gray)
                    } else if player.isBuffering {
                        ProgressView("正在缓冲音频…").tint(.white).foregroundColor(.gray)
                    }
                    if let error = player.errorMessage {
                        VStack(spacing: 8) {
                            Text(error).font(.caption).foregroundColor(.red).multilineTextAlignment(.center)
                            Button("重试音频") { Task { await player.load(episode) } }
                                .buttonStyle(.bordered)
                        }
                    }
                }.padding(20)

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("学习文本").font(.headline).foregroundColor(.white)
                        Text(sentences.isEmpty ? "该单集尚未生成逐句字幕" : "同步学习文本 · 点击句子可跳转")
                            .font(.caption).foregroundColor(.orange)
                    }
                    Spacer()
                    Toggle("中译", isOn: $showTranslation)
                        .labelsHidden()
                }.padding(.horizontal, 20).padding(.vertical, 10)

                ScrollViewReader { proxy in
                    Group {
                        if isLoadingSentences {
                            ProgressView("正在读取学习文本…")
                                .tint(.white).foregroundColor(.gray).frame(maxHeight: .infinity)
                        } else if sentences.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "text.badge.xmark").font(.system(size: 36))
                                Text(sentenceError ?? "这集尚未生成同步字幕")
                                Text("音频仍可正常播放；字幕生成后会自动显示。")
                                    .font(.caption)
                            }
                            .foregroundColor(.gray).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 16) {
                                    ForEach(sentences) { sentence in
                                        TappableSentenceView(sentence: sentence, isCurrent: sentence.id == currentSentence?.id, showTranslation: showTranslation) { word in
                                            player.pause(); selectedWord = word
                                        }.id(sentence.id).onTapGesture { player.seek(max(0, sentence.start - 0.3)) }
                                    }
                                }.padding(20)
                            }
                        }
                    }.onChange(of: currentSentence?.id) { id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
                }
            }.background(Color.black.ignoresSafeArea()).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("关闭") { player.pause(); dismiss() }.foregroundColor(.white) } }
        }.navigationViewStyle(.stack)
            .task { await player.load(episode) }
            .task { await loadSentences() }
            .sheet(item: Binding(get: { selectedWord.map(SelectedWord.init) }, set: { selectedWord = $0?.value })) { selection in
                PodcastWordSheet(word: selection.value, sentence: currentSentence?.english ?? "", episode: episode, time: currentSentence?.start ?? player.currentTime, store: wordStore) { player.play() }
            }
    }

    private struct SelectedWord: Identifiable { let value: String; var id: String { value } }

    private func loadSentences() async {
        isLoadingSentences = true
        sentenceError = nil
        do {
            sentences = try await SupabaseClient.shared.fetchPodcastSentences(episodeId: episode.id)
        } catch {
            sentenceError = "同步字幕读取失败：\(error.localizedDescription)"
        }
        isLoadingSentences = false
    }
}

private struct TappableSentenceView: View {
    let sentence: PodcastSentence
    let isCurrent: Bool
    let showTranslation: Bool
    let select: (String) -> Void
    var tokens: [String] { sentence.english.components(separatedBy: .whitespaces).filter { !$0.isEmpty } }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            WordFlowView(tokens: tokens, action: select)
            if showTranslation {
                if let chinese = sentence.chinese, !chinese.isEmpty {
                    Text(chinese).font(.subheadline).foregroundColor(.gray)
                } else {
                    PodcastSystemTranslationText(source: sentence.english)
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
    let action: (String) -> Void

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                PodcastWordFlowLayout(horizontalSpacing: 5, verticalSpacing: 8) {
                    wordButtons
                }
            } else {
                Text(tokens.joined(separator: " "))
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var wordButtons: some View {
        ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
            Button {
                action(token.trimmingCharacters(in: .punctuationCharacters))
            } label: {
                Text(token)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
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
    func value(for source: String) -> String? {
        values.object(forKey: source as NSString).map { $0 as String }
    }
    func store(_ translation: String, for source: String) {
        values.setObject(translation as NSString, forKey: source as NSString)
    }
}

private struct PodcastSystemTranslationText: View {
    let source: String
    var onTranslation: ((String) -> Void)? = nil

    @ViewBuilder
    var body: some View {
#if canImport(Translation)
        if #available(iOS 18.0, *) {
            PodcastAvailableTranslationText(source: source, onTranslation: onTranslation)
        } else {
            Text("系统升级到 iOS 18 后可使用中文翻译")
                .font(.caption).foregroundColor(.gray)
        }
#else
        Text("当前系统暂不支持翻译")
            .font(.caption).foregroundColor(.gray)
#endif
    }
}

#if canImport(Translation)
@available(iOS 18.0, *)
private struct PodcastAvailableTranslationText: View {
    let source: String
    var onTranslation: ((String) -> Void)?
    @State private var translated = ""
    @State private var failed = false

    var body: some View {
        Group {
            if !translated.isEmpty {
                Text(translated).font(.subheadline).foregroundColor(.gray)
            } else if failed {
                Text("翻译暂时不可用").font(.caption).foregroundColor(.gray)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在翻译…").font(.caption)
                }.foregroundColor(.gray)
            }
        }
        .task {
            if let cached = PodcastTranslationMemory.shared.value(for: source) {
                translated = cached
                onTranslation?(cached)
            }
        }
        .translationTask(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: "zh-Hans")
        ) { session in
            guard translated.isEmpty else { return }
            do {
                let response = try await session.translate(source)
                translated = response.targetText
                PodcastTranslationMemory.shared.store(response.targetText, for: source)
                onTranslation?(response.targetText)
            } catch {
                failed = true
            }
        }
    }
}
#endif

private struct PodcastWordSheet: View {
    let word: String; let sentence: String; let episode: PodcastEpisode; let time: TimeInterval
    @ObservedObject var store: PodcastWordStore; let resume: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var translatedMeaning: String?
    var saved: Bool { store.contains(word: word, episodeID: episode.id) }
    var meaning: String { translatedMeaning ?? "正在获取中文释义…" }
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 18) {
                Text(word).font(.system(size: 34, weight: .bold))
                PodcastSystemTranslationText(source: word) { translatedMeaning = $0 }
                Divider(); Text("原句").font(.headline); Text(sentence).font(.title3)
                Text("来源：\(episode.podcast.title) · \(episode.title)").font(.caption).foregroundColor(.secondary)
                Button { store.toggle(word: word, meaning: meaning, sentence: sentence, episode: episode, time: time) } label: { Label(saved ? "已收藏" : "收藏到我的单词", systemImage: saved ? "checkmark.circle.fill" : "star").frame(maxWidth: .infinity).frame(height: 52) }.buttonStyle(.borderedProminent)
                    .disabled(translatedMeaning == nil && !saved)
                Button("继续播放") { dismiss(); resume() }.frame(maxWidth: .infinity)
                Spacer()
            }.padding(22).navigationTitle("语境词卡").navigationBarTitleDisplayMode(.inline)
        }.navigationViewStyle(.stack)
    }
}

private struct PodcastWordsView: View {
    @ObservedObject var store: PodcastWordStore
    var body: some View {
        NavigationView {
            Group {
                if store.words.isEmpty { VStack(spacing: 12) { Image(systemName: "waveform.and.magnifyingglass").font(.system(size: 42)); Text("还没有语境词").font(.title2.bold()); Text("播放时点一下英文词，原句和来源会保存在这里。") }.foregroundColor(.gray).multilineTextAlignment(.center).padding(30) }
                else { List(store.words) { word in VStack(alignment: .leading, spacing: 7) { Text(word.word).font(.title3.bold()).foregroundColor(.white); Text(word.meaning).foregroundColor(.mint); Text(word.sentence).foregroundColor(.gray).lineLimit(2); Text("来自 \(word.podcastTitle) · \(word.savedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundColor(.secondary) }.padding(.vertical, 8).listRowBackground(Color.black) }.listStyle(.plain) }
            }.background(Color.black).navigationTitle("我的语境单词")
        }.navigationViewStyle(.stack)
    }
}

private struct PodcastAboutView: View {
    var body: some View {
        NavigationView {
            List {
                Section("首批内容") { Text("首批提供 BBC 6 Minute English 与 Overthink 精选单集，内容来自发布方公开 RSS。") }
                Section("版权与字幕") { Text("音频从发布方地址在线播放，不在 App 内重新分发。仅在完成转录和内容审核后显示同步字幕；商业上线前需逐一确认嵌入、转录、翻译和缓存授权。") }
                Section("质量原则") { Text("先保证内容清晰、时长适中、主题明确；正式字幕与中文翻译必须经过人工审核后才能发布。") }
            }.navigationTitle("内容说明")
        }.navigationViewStyle(.stack)
    }
}
