import Foundation
import AVFoundation

public protocol AudioPlayerManagerDelegate: AnyObject {
    func audioPlayerManager(didStartPlaying itemDescription: String)
    func audioPlayerManager(didFinishPlaying itemDescription: String)
    func audioPlayerManager(didUpdateState isPlaying: Bool)
    func audioPlayerManager(didEncounter error: Error)
    func audioPlayerManager(didUpdateCurrentWord word: Word, index: Int, total: Int)
    func audioPlayerManagerDidCompleteQueue()
}

public extension AudioPlayerManagerDelegate {
    func audioPlayerManager(didUpdateCurrentWord word: Word, index: Int, total: Int) {}
    func audioPlayerManagerDidCompleteQueue() {}
}

public final class AudioPlayerManager: NSObject {
    public static let shared = AudioPlayerManager()

    public weak var delegate: AudioPlayerManagerDelegate?

    private var audioPlayer: AVAudioPlayer?
    private var audioDownloadTask: URLSessionDataTask?
    private var audioPrefetchTasks: [String: URLSessionDataTask] = [:]
    private let tts = AVSpeechSynthesizer()
    private var queue: [PlayItem] = []
    private var currentIndex: Int = 0
    private var currentWordProgressIndex: Int = -1
    private var playbackGeneration: Int = 0
    private var activeAudioGeneration: Int = -1
    private var activeSpeechGeneration: Int = -1
    private weak var activeSpeechUtterance: AVSpeechUtterance?
    private weak var suppressedSpeechCancelUtterance: AVSpeechUtterance?
    private var remoteRefreshAttempts: [String: Date] = [:]
    private let remoteRefreshInterval: TimeInterval = 60 * 60
    /// Rotates even while the app remains open, so a backend in-place audio
    /// refresh cannot remain pinned behind a launch-scoped CDN cache key.
    private var remoteRefreshToken: String {
        let hourlyToken = String(Int(Date().timeIntervalSince1970 / remoteRefreshInterval))
        return "\(SupabaseConfig.learningAudioContentRevision)-\(hourlyToken)"
    }
    public var repeatTimes: Int = 2 // default repeat times per word
    public var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    public var playbackRate: Float = 1.0
    public var volume: Float = 1.0
    public var audioFolderName: String?
    public var learningLanguage: LearningLanguage = .chinese
    public var chineseMeaningFileRateMultiplier: Float = 1.5
    public var chineseMeaningFallbackSpeechRateMultiplier: Float = 1.5

    private(set) public var isPlaying: Bool = false {
        didSet { delegate?.audioPlayerManager(didUpdateState: isPlaying) }
    }

    private override init() {
        super.init()
        tts.delegate = self
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
    }

    // Play a single word (uses local file if provided, otherwise TTS)
    public func play(word: Word) {
        beginNewPlayback()
        queue = []
        currentIndex = 0
        currentWordProgressIndex = -1
        enqueue(word: word, wordIndex: 0, totalWords: 1)
        startQueue()
    }

    // Play a list of words sequentially
    public func play(words: [Word]) {
        play(words: words, startIndex: 0)
    }

    public func play(words: [Word], startIndex: Int) {
        beginNewPlayback()
        queue = []
        currentIndex = 0
        currentWordProgressIndex = -1
        let safeStartIndex = min(max(0, startIndex), max(0, words.count - 1))
        guard !words.isEmpty else {
            finishQueue()
            return
        }

        words.enumerated().dropFirst(safeStartIndex).forEach { index, word in
            enqueue(word: word, wordIndex: index, totalWords: words.count)
        }
        startQueue()
    }

    private func beginNewPlayback() {
        playbackGeneration += 1
        resetCurrentPlayback()
    }

    private func resetCurrentPlayback() {
        audioDownloadTask?.cancel()
        audioDownloadTask = nil
        stopAudioPlayer()
        if tts.isSpeaking || tts.isPaused {
            suppressedSpeechCancelUtterance = activeSpeechUtterance
            tts.stopSpeaking(at: .immediate)
        }
        activeSpeechUtterance = nil
        activeSpeechGeneration = -1
    }

    // Enqueue word repeated `repeatTimes`
    private func enqueue(word: Word, wordIndex: Int, totalWords: Int) {
        let wordLanguage = wordSpeechLanguageCode()
        for repeatIndex in 0..<max(1, repeatTimes) {
            if let file = preferredAudioFileName(for: word) {
                queue.append(.file(name: file, description: "file:\(file)", fallbackText: word.word, fallbackLanguage: wordLanguage, word: word, wordIndex: wordIndex, totalWords: totalWords))
            } else {
                queue.append(.text(text: word.word, language: wordLanguage, description: "word:\(word.word)", word: word, wordIndex: wordIndex, totalWords: totalWords))
            }

            let isLastRepeat = repeatIndex == max(1, repeatTimes) - 1
            if isLastRepeat {
                let meaning = word.spokenMeaning(for: learningLanguage)
                let meaningAudioLookupText = word.meaningAudioLookupText(for: learningLanguage)
                if let file = preferredMeaningAudioFileName(for: meaningAudioLookupText, language: learningLanguage) {
                    queue.append(.file(name: file, subdirectory: learningLanguage.meaningAudioSubdirectory, description: "meaning:\(meaning)", fallbackText: meaning, fallbackLanguage: learningLanguage.speechLanguageCode, word: word, wordIndex: wordIndex, totalWords: totalWords))
                } else {
                    queue.append(.text(text: meaning, language: learningLanguage.speechLanguageCode, description: "meaning:\(meaning)", word: word, wordIndex: wordIndex, totalWords: totalWords))
                }
            }
        }
    }

    private func wordSpeechLanguageCode() -> String {
        ["KaoYan_2", "IELTS_9400"].contains(audioFolderName ?? "") ? "en-US" : "de-DE"
    }

    private var activeNaturalWordAudioVersion: String? {
        guard let audioFolderName else { return nil }
        if audioFolderName == "KaoYan_2" {
            return SupabaseConfig.kaoYanEnglishWordAudioVersion
        }
        if audioFolderName == "IELTS_9400" {
            return SupabaseConfig.ieltsEnglishWordAudioVersion
        }
        if ["12yue", "A1", "A2", "B1"].contains(audioFolderName) {
            return SupabaseConfig.germanWordAudioVersion
        }
        return nil
    }

    private func preferredAudioFileName(for word: Word) -> String? {
        if activeNaturalWordAudioVersion != nil {
            return "\(safeAudioFileName(for: word.word))_\(safeAudioFileName(for: word.id)).mp3"
        }
        if let fileName = word.audioFileName, !fileName.isEmpty {
            return fileName
        }

        return "\(safeAudioFileName(for: word.word)).mp3"
    }

    private func preferredMeaningAudioFileName(for meaning: String, language: LearningLanguage) -> String? {
        let fileName = safeMeaningAudioFileName(for: meaning)
        return fileName
    }

    private func safeMeaningAudioFileName(for text: String) -> String {
        let base = String(safeAudioFileName(for: text).prefix(160))
        return "\(base)_\(hashSuffix(for: text)).mp3"
    }

    private func hashSuffix(for text: String) -> String {
        let normalized = text
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        var value: UInt32 = 2166136261
        for byte in normalized.utf8 {
            value ^= UInt32(byte)
            value = value &* 16777619
        }
        return String(format: "%08x", value)
    }

    private func safeAudioFileName(for text: String) -> String {
        let normalized = text
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        var result = ""
        var previousWasUnderscore = false

        for scalar in normalized.unicodeScalars {
            let isAllowed = CharacterSet.alphanumerics.contains(scalar) ||
                scalar == "_" ||
                scalar == "-" ||
                scalar == "ä" ||
                scalar == "ö" ||
                scalar == "ü" ||
                scalar == "ß"

            if isAllowed {
                result.unicodeScalars.append(scalar)
                previousWasUnderscore = false
            } else if !previousWasUnderscore {
                result.append("_")
                previousWasUnderscore = true
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "word" : trimmed
    }

    // Start processing queue
    private func startQueue() {
        guard !queue.isEmpty else { return }
        playCurrent()
    }

    private func playCurrent() {
        guard currentIndex < queue.count else {
            finishQueue()
            return
        }
        let item = queue[currentIndex]
        notifyProgressIfNeeded(for: item)
        switch item {
        case .file(let name, let subdirectory, let desc, let fallbackText, let fallbackLanguage, _, _, _):
            playAudioFile(named: name, preferredSubdirectory: subdirectory, description: desc, fallbackText: fallbackText, fallbackLanguage: fallbackLanguage)
        case .text(let text, let language, let desc, _, _, _):
            speakText(text: text, language: language, description: desc)
        }
    }

    private func notifyProgressIfNeeded(for item: PlayItem) {
        guard currentWordProgressIndex != item.wordIndex else { return }
        currentWordProgressIndex = item.wordIndex
        delegate?.audioPlayerManager(didUpdateCurrentWord: item.word, index: item.wordIndex, total: item.totalWords)
    }

    // MARK: - File play
    private func playAudioFile(named name: String, preferredSubdirectory: String?, description: String, fallbackText: String?, fallbackLanguage: String?) {
        stopAudioPlayer()
        let cachedURL = cachedAudioURL(named: name, preferredSubdirectory: preferredSubdirectory)
        let availableCachedURL = cachedURL.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
        let remoteURLs = remoteAudioURLs(named: name, preferredSubdirectory: preferredSubdirectory)
        let refreshKey = remotePath(named: name, preferredSubdirectory: preferredSubdirectory)
        if let remoteURL = remoteURLs.first,
           shouldRefreshRemoteAudio(for: refreshKey) {
            remoteRefreshAttempts[refreshKey] = Date()
            audioDiagnostic("download \(description) url=\(remoteURL.absoluteString)")
            downloadAndPlay(
                remoteURL,
                remainingRemoteURLs: Array(remoteURLs.dropFirst()),
                cachedFallbackURL: availableCachedURL,
                named: name,
                preferredSubdirectory: preferredSubdirectory,
                description: description,
                fallbackText: fallbackText,
                fallbackLanguage: fallbackLanguage
            )
            return
        }

        if let availableCachedURL {
            audioDiagnostic("cache hit \(description) path=\(availableCachedURL.path)")
            playFile(at: availableCachedURL, preferredSubdirectory: preferredSubdirectory, description: description, fallbackText: fallbackText, fallbackLanguage: fallbackLanguage)
            return
        }

        playFallbackOrAdvance(text: fallbackText, language: fallbackLanguage, description: description)
    }

    private func shouldRefreshRemoteAudio(for key: String) -> Bool {
        guard let lastAttempt = remoteRefreshAttempts[key] else { return true }
        return Date().timeIntervalSince(lastAttempt) >= remoteRefreshInterval
    }

    private func downloadAndPlay(
        _ remoteURL: URL,
        remainingRemoteURLs: [URL] = [],
        retryCount: Int = 1,
        cachedFallbackURL: URL?,
        named name: String,
        preferredSubdirectory: String?,
        description: String,
        fallbackText: String?,
        fallbackLanguage: String?
    ) {
        let generation = playbackGeneration
        let expectedIndex = currentIndex
        audioDownloadTask?.cancel()
        var request = URLRequest(url: remoteURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        audioDownloadTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self,
                      generation == self.playbackGeneration,
                      expectedIndex == self.currentIndex else { return }
                self.audioDownloadTask = nil
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let errorDescription = error?.localizedDescription ?? "none"
                self.audioDiagnostic(
                    "response \(description) status=\(statusCode) " +
                    "bytes=\((response as? HTTPURLResponse)?.expectedContentLength ?? -1) " +
                    "error=\(errorDescription) url=\(remoteURL.absoluteString)"
                )
                guard error == nil,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let data,
                      data.count >= 512,
                      self.isPlayableAudioData(data),
                      let destination = self.cachedAudioURL(named: name, preferredSubdirectory: preferredSubdirectory, createDirectory: true) else {
                    if retryCount > 0 {
                        self.audioDiagnostic("retrying remote audio \(description)")
                        self.downloadAndPlay(
                            remoteURL,
                            remainingRemoteURLs: remainingRemoteURLs,
                            retryCount: retryCount - 1,
                            cachedFallbackURL: cachedFallbackURL,
                            named: name,
                            preferredSubdirectory: preferredSubdirectory,
                            description: description,
                            fallbackText: fallbackText,
                            fallbackLanguage: fallbackLanguage
                        )
                        return
                    }
                    if error == nil,
                       response is HTTPURLResponse,
                       let nextURL = remainingRemoteURLs.first {
                        self.audioDiagnostic("trying alternate url=\(nextURL.absoluteString)")
                        self.downloadAndPlay(
                            nextURL,
                            remainingRemoteURLs: Array(remainingRemoteURLs.dropFirst()),
                            cachedFallbackURL: cachedFallbackURL,
                            named: name,
                            preferredSubdirectory: preferredSubdirectory,
                            description: description,
                            fallbackText: fallbackText,
                            fallbackLanguage: fallbackLanguage
                        )
                        return
                    }
                    if let cachedFallbackURL,
                       FileManager.default.fileExists(atPath: cachedFallbackURL.path) {
                        self.audioDiagnostic("network unavailable; using cache \(description)")
                        self.playFile(
                            at: cachedFallbackURL,
                            preferredSubdirectory: preferredSubdirectory,
                            description: description,
                            fallbackText: fallbackText,
                            fallbackLanguage: fallbackLanguage
                        )
                        return
                    }
                    self.playFallbackOrAdvance(text: fallbackText, language: fallbackLanguage, description: description)
                    return
                }
                do {
                    try data.write(to: destination, options: .atomic)
                    self.trimDownloadedAudioCache()
                    self.playFile(at: destination, preferredSubdirectory: preferredSubdirectory, description: description, fallbackText: fallbackText, fallbackLanguage: fallbackLanguage)
                } catch {
                    self.audioDiagnostic("cache write failed \(description): \(error.localizedDescription)")
                    if let cachedFallbackURL,
                       FileManager.default.fileExists(atPath: cachedFallbackURL.path) {
                        self.playFile(
                            at: cachedFallbackURL,
                            preferredSubdirectory: preferredSubdirectory,
                            description: description,
                            fallbackText: fallbackText,
                            fallbackLanguage: fallbackLanguage
                        )
                        return
                    }
                    self.playFallbackOrAdvance(text: fallbackText, language: fallbackLanguage, description: description)
                }
            }
        }
        audioDownloadTask?.resume()
    }

    private func isPlayableAudioData(_ data: Data) -> Bool {
        guard let player = try? AVAudioPlayer(data: data) else { return false }
        return player.duration > 0
    }

    private func prefetchUpcomingAudio() {
        guard currentIndex + 1 < queue.count else { return }

        for item in queue.dropFirst(currentIndex + 1) {
            guard case .file(let name, let subdirectory, _, _, _, _, _, _) = item else {
                continue
            }

            let refreshKey = remotePath(named: name, preferredSubdirectory: subdirectory)
            guard shouldRefreshRemoteAudio(for: refreshKey),
                  audioPrefetchTasks[refreshKey] == nil,
                  let remoteURL = remoteAudioURLs(named: name, preferredSubdirectory: subdirectory).first,
                  let destination = cachedAudioURL(named: name, preferredSubdirectory: subdirectory, createDirectory: true) else {
                continue
            }

            remoteRefreshAttempts[refreshKey] = Date()
            var request = URLRequest(url: remoteURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 8
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

            let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    defer { self.audioPrefetchTasks[refreshKey] = nil }
                    guard error == nil,
                          let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode),
                          let data,
                          data.count >= 512,
                          self.isPlayableAudioData(data) else {
                        self.audioDiagnostic("prefetch unavailable path=\(refreshKey)")
                        return
                    }

                    do {
                        try data.write(to: destination, options: .atomic)
                        self.trimDownloadedAudioCache()
                        self.audioDiagnostic("prefetch ready path=\(refreshKey)")
                    } catch {
                        self.audioDiagnostic("prefetch write failed path=\(refreshKey): \(error.localizedDescription)")
                    }
                }
            }
            audioPrefetchTasks[refreshKey] = task
            task.resume()
            return
        }
    }

    private func playFile(at url: URL, preferredSubdirectory: String?, description: String, fallbackText: String?, fallbackLanguage: String?) {
        // Audio-session activation can transiently fail during route changes,
        // interruptions, or when speech synthesis has just stopped. That must
        // not discard a valid downloaded MP3 and switch the whole library to
        // the system voice; AVAudioPlayer can still start once the route is
        // available.
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            audioDiagnostic("audio session activation warning \(description): \(error.localizedDescription)")
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            audioPlayer = player
            activeAudioGeneration = playbackGeneration
            player.delegate = self
            player.volume = volume
            player.enableRate = true
            player.rate = adjustedPlaybackRate(for: preferredSubdirectory)
            let prepared = player.prepareToPlay()
            delegate?.audioPlayerManager(didStartPlaying: description)
            let started = player.play()
            audioDiagnostic(
                "player \(description) prepared=\(prepared) started=\(started) " +
                "duration=\(player.duration) path=\(url.path)"
            )
            guard started else {
                playFallbackOrAdvance(text: fallbackText, language: fallbackLanguage, description: description)
                return
            }
            isPlaying = true
            prefetchUpcomingAudio()
        } catch {
            audioDiagnostic("player error \(description): \(error.localizedDescription)")
            delegate?.audioPlayerManager(didEncounter: error)
            playFallbackOrAdvance(text: fallbackText, language: fallbackLanguage, description: description)
        }
    }

    private func audioDiagnostic(_ message: String) {
#if DEBUG
        print("[WordAudio] \(message)")
#endif
    }

    private func stopAudioPlayer() {
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        activeAudioGeneration = -1
    }

    private func remotePath(named name: String, preferredSubdirectory: String?) -> String {
        let remoteName = storageSafeAudioFileName(name)
        if let preferredSubdirectory, !preferredSubdirectory.isEmpty {
            var path = preferredSubdirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path.hasPrefix("audio/") { path.removeFirst("audio/".count) }
            return "\(path)/\(remoteName)"
        }
        if let audioFolderName,
           ["KaoYan_2", "IELTS_9400"].contains(audioFolderName) {
            if let version = activeNaturalWordAudioVersion {
                return "\(version)/words/en-us/\(audioFolderName.lowercased())/\(remoteName)"
            }
            return "words/\(audioFolderName)/\(remoteName)"
        }
        if let version = SupabaseConfig.germanWordAudioVersion,
           let audioFolderName,
           ["12yue", "A1", "A2", "B1"].contains(audioFolderName) {
            return "\(version)/words/de-de/\(audioFolderName.lowercased())/\(remoteName)"
        }
        return "words/\(remoteName)"
    }

    /// Supabase Storage rejects some Unicode object keys. Keep bundled file
    /// names unchanged, but use a stable ASCII representation for remote keys.
    private func storageSafeAudioFileName(_ name: String) -> String {
        let replacements: [UnicodeScalar: String] = [
            "ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss"
        ]
        let normalized = name
            .precomposedStringWithCanonicalMapping
            .lowercased()
        var result = ""
        var previousWasUnderscore = false

        for scalar in normalized.unicodeScalars {
            if let replacement = replacements[scalar] {
                result.append(replacement)
                previousWasUnderscore = false
            } else if scalar.isASCII,
                      (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == ".") {
                if scalar == "_" {
                    if !previousWasUnderscore {
                        result.unicodeScalars.append(scalar)
                    }
                    previousWasUnderscore = true
                } else {
                    result.unicodeScalars.append(scalar)
                    previousWasUnderscore = false
                }
            } else if !previousWasUnderscore {
                result.append("_")
                previousWasUnderscore = true
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "_."))
        return trimmed.isEmpty ? "audio" : trimmed
    }

    private func remoteAudioURLs(named name: String, preferredSubdirectory: String?) -> [URL] {
        let primaryPath = remotePath(named: name, preferredSubdirectory: preferredSubdirectory)
        var paths = [primaryPath]
        if preferredSubdirectory == nil,
           SupabaseConfig.germanWordAudioVersion != nil,
           let currentBook = audioFolderName,
           ["12yue", "A1", "A2", "B1"].contains(currentBook) {
            let remoteName = storageSafeAudioFileName(name)
            let version = SupabaseConfig.germanWordAudioVersion ?? "v2"
            for book in ["12yue", "A1", "A2", "B1"] where book != currentBook {
                paths.append("\(version)/words/de-de/\(book.lowercased())/\(remoteName)")
            }
        }
        return paths.compactMap(remoteAudioURL(forPath:))
    }

    private func remoteAudioURL(forPath path: String) -> URL? {
        guard var url = SupabaseConfig.learningAudioBaseURL else { return nil }
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.queryItems = [URLQueryItem(name: "audioVersion", value: remoteRefreshToken)]
        return components.url
    }

    private func cachedAudioURL(named name: String, preferredSubdirectory: String?, createDirectory: Bool = false) -> URL? {
        guard let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        var url = cacheRoot.appendingPathComponent("TingHuiErAudioV4", isDirectory: true)
        let components = remotePath(named: name, preferredSubdirectory: preferredSubdirectory).split(separator: "/")
        for component in components.dropLast() { url.appendPathComponent(String(component), isDirectory: true) }
        if createDirectory {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url.appendingPathComponent(name)
    }

    private func trimDownloadedAudioCache(maximumBytes: Int64 = 300 * 1_024 * 1_024) {
        guard let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let root = cacheRoot.appendingPathComponent("TingHuiErAudioV4", isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentAccessDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int64, date: Date)] = []
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, Int64(values.fileSize ?? 0), values.contentAccessDate ?? .distantPast))
        }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > maximumBytes else { return }
        for file in files.sorted(by: { $0.date < $1.date }) where total > maximumBytes {
            if (try? FileManager.default.removeItem(at: file.url)) != nil { total -= file.size }
        }
    }

    private func playFallbackOrAdvance(text: String?, language: String?, description: String) {
        if let text, let language, !text.isEmpty {
            audioDiagnostic("using system speech fallback \(description) language=\(language)")
            speakText(text: text, language: language, description: description)
        } else {
            advanceQueue()
        }
    }

    // MARK: - TTS
    private func speakText(text: String, language: String, description: String) {
        if tts.isSpeaking {
            suppressedSpeechCancelUtterance = activeSpeechUtterance
            tts.stopSpeaking(at: .immediate)
        }
        let utter = AVSpeechUtterance(string: text)
        utter.voice = preferredSpeechVoice(for: language)
        utter.rate = adjustedSpeechRate(for: language)
        utter.volume = volume
        activeSpeechUtterance = utter
        activeSpeechGeneration = playbackGeneration
        delegate?.audioPlayerManager(didStartPlaying: description)
        isPlaying = true
        tts.speak(utter)
        prefetchUpcomingAudio()
    }

    private func adjustedPlaybackRate(for preferredSubdirectory: String?) -> Float {
        let multiplier = preferredSubdirectory == LearningLanguage.chinese.meaningAudioSubdirectory ? chineseMeaningFileRateMultiplier : 1.0
        return min(max(playbackRate * multiplier, 0.5), 2.0)
    }

    private func adjustedSpeechRate(for language: String) -> Float {
        let multiplier = language.lowercased().hasPrefix("zh") ? chineseMeaningFallbackSpeechRateMultiplier : 1.0
        return min(max(rate * multiplier, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    private func preferredSpeechVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let prefix = language.lowercased().hasPrefix("zh") ? "zh" :
            (language.lowercased().hasPrefix("de") ? "de" : "en")
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix(prefix)
        }
        if #available(iOS 16.0, *) {
            if let premium = candidates.first(where: { $0.quality == .premium }) {
                return premium
            }
        }
        if let enhanced = candidates.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        let preferredLocale = prefix == "zh" ? "zh-CN" : (prefix == "de" ? "de-DE" : "en-US")
        return candidates.first(where: { $0.language == preferredLocale })
            ?? AVSpeechSynthesisVoice(language: preferredLocale)
    }

    // MARK: - Controls
    public func pause() {
        if let player = audioPlayer, player.isPlaying {
            player.pause()
            isPlaying = false
        } else if tts.isSpeaking {
            tts.pauseSpeaking(at: .immediate)
            isPlaying = false
        }
    }

    public func resume() {
        if let player = audioPlayer {
            player.play()
            isPlaying = true
        } else if tts.isPaused {
            tts.continueSpeaking()
            isPlaying = true
        } else {
            playCurrent()
        }
    }

    public func stop() {
        playbackGeneration += 1
        audioDownloadTask?.cancel()
        audioDownloadTask = nil
        stopAudioPlayer()
        if tts.isSpeaking || tts.isPaused {
            suppressedSpeechCancelUtterance = activeSpeechUtterance
            tts.stopSpeaking(at: .immediate)
        }
        isPlaying = false
        queue = []
        currentIndex = 0
        currentWordProgressIndex = -1
        activeSpeechUtterance = nil
        activeSpeechGeneration = -1
    }

    public func next() {
        stopAudioPlayer()
        if tts.isSpeaking {
            suppressedSpeechCancelUtterance = activeSpeechUtterance
            tts.stopSpeaking(at: .immediate)
        }
        activeSpeechUtterance = nil
        activeSpeechGeneration = -1
        advanceQueue()
    }

    public func previous() {
        guard currentIndex > 0 else { return }
        currentIndex = max(0, currentIndex - 1)
        stopAudioPlayer()
        if tts.isSpeaking {
            suppressedSpeechCancelUtterance = activeSpeechUtterance
            tts.stopSpeaking(at: .immediate)
        }
        activeSpeechUtterance = nil
        activeSpeechGeneration = -1
        playCurrent()
    }

    private func advanceQueue() {
        let lastDescription = queue.indices.contains(currentIndex) ? queue[currentIndex].description : ""
        delegate?.audioPlayerManager(didFinishPlaying: lastDescription)
        currentIndex += 1
        if currentIndex < queue.count {
            playCurrent()
        } else {
            finishQueue()
        }
    }

    private func finishQueue() {
        stopAudioPlayer()
        if tts.isSpeaking || tts.isPaused {
            suppressedSpeechCancelUtterance = activeSpeechUtterance
            tts.stopSpeaking(at: .immediate)
        }
        queue = []
        currentIndex = 0
        currentWordProgressIndex = -1
        activeSpeechUtterance = nil
        activeSpeechGeneration = -1
        isPlaying = false
        delegate?.audioPlayerManagerDidCompleteQueue()
    }
}

// Helper enum representing an item to play
private enum PlayItem {
    case file(name: String, subdirectory: String? = nil, description: String, fallbackText: String?, fallbackLanguage: String?, word: Word, wordIndex: Int, totalWords: Int)
    case text(text: String, language: String, description: String, word: Word, wordIndex: Int, totalWords: Int)

    var description: String {
        switch self {
        case .file(_, _, let d, _, _, _, _, _): return d
        case .text(_, _, let d, _, _, _): return d
        }
    }

    var word: Word {
        switch self {
        case .file(_, _, _, _, _, let word, _, _): return word
        case .text(_, _, _, let word, _, _): return word
        }
    }

    var wordIndex: Int {
        switch self {
        case .file(_, _, _, _, _, _, let index, _): return index
        case .text(_, _, _, _, let index, _): return index
        }
    }

    var totalWords: Int {
        switch self {
        case .file(_, _, _, _, _, _, _, let total): return total
        case .text(_, _, _, _, _, let total): return total
        }
    }
}

// MARK: AVAudioPlayerDelegate
extension AudioPlayerManager: AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === audioPlayer, activeAudioGeneration == playbackGeneration else { return }
        advanceQueue()
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === audioPlayer, activeAudioGeneration == playbackGeneration else { return }
        if let e = error { delegate?.audioPlayerManager(didEncounter: e) }
        advanceQueue()
    }
}

// MARK: AVSpeechSynthesizerDelegate
extension AudioPlayerManager: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === activeSpeechUtterance, activeSpeechGeneration == playbackGeneration else { return }
        activeSpeechUtterance = nil
        activeSpeechGeneration = -1
        advanceQueue()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if utterance === suppressedSpeechCancelUtterance {
            suppressedSpeechCancelUtterance = nil
            return
        }
        guard utterance === activeSpeechUtterance, activeSpeechGeneration == playbackGeneration else { return }
        activeSpeechUtterance = nil
        activeSpeechGeneration = -1
        advanceQueue()
    }
}
