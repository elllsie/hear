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
    private var audioDownloadTask: URLSessionDownloadTask?
    private let tts = AVSpeechSynthesizer()
    private var queue: [PlayItem] = []
    private var currentIndex: Int = 0
    private var currentWordProgressIndex: Int = -1
    private var playbackGeneration: Int = 0
    private var activeAudioGeneration: Int = -1
    private var activeSpeechGeneration: Int = -1
    private weak var activeSpeechUtterance: AVSpeechUtterance?
    private weak var suppressedSpeechCancelUtterance: AVSpeechUtterance?
    public var repeatTimes: Int = 2 // default repeat times per word
    public var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    public var playbackRate: Float = 1.0
    public var volume: Float = 1.0
    public var audioFolderName: String?
    public var learningLanguage: LearningLanguage = .chinese
    public var chineseMeaningFileRateMultiplier: Float = 1.0
    public var chineseMeaningFallbackSpeechRateMultiplier: Float = 1.0

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
                if let file = preferredMeaningAudioFileName(for: meaning, language: learningLanguage) {
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
        if ["KaoYan_2", "IELTS_9400"].contains(audioFolderName) {
            return SupabaseConfig.englishWordAudioVersion
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
        if let cachedURL = cachedAudioURL(named: name, preferredSubdirectory: preferredSubdirectory),
           FileManager.default.fileExists(atPath: cachedURL.path) {
            playFile(at: cachedURL, preferredSubdirectory: preferredSubdirectory, description: description, fallbackText: fallbackText, fallbackLanguage: fallbackLanguage)
            return
        }

        if let remoteURL = remoteAudioURL(named: name, preferredSubdirectory: preferredSubdirectory) {
            downloadAndPlay(
                remoteURL,
                named: name,
                preferredSubdirectory: preferredSubdirectory,
                description: description,
                fallbackText: fallbackText,
                fallbackLanguage: fallbackLanguage
            )
            return
        }

        playFallbackOrAdvance(text: fallbackText, language: fallbackLanguage, description: description)
    }

    private func downloadAndPlay(
        _ remoteURL: URL,
        named name: String,
        preferredSubdirectory: String?,
        description: String,
        fallbackText: String?,
        fallbackLanguage: String?
    ) {
        let generation = playbackGeneration
        let expectedIndex = currentIndex
        audioDownloadTask?.cancel()
        audioDownloadTask = URLSession.shared.downloadTask(with: remoteURL) { [weak self] temporaryURL, response, error in
            DispatchQueue.main.async {
                guard let self,
                      generation == self.playbackGeneration,
                      expectedIndex == self.currentIndex else { return }
                self.audioDownloadTask = nil
                guard error == nil,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let temporaryURL,
                      let destination = self.cachedAudioURL(named: name, preferredSubdirectory: preferredSubdirectory, createDirectory: true) else {
                    self.playFallbackOrAdvance(text: fallbackText, language: fallbackLanguage, description: description)
                    return
                }
                do {
                    let manager = FileManager.default
                    if manager.fileExists(atPath: destination.path) {
                        try manager.removeItem(at: destination)
                    }
                    try manager.moveItem(at: temporaryURL, to: destination)
                    self.trimDownloadedAudioCache()
                    self.playFile(at: destination, preferredSubdirectory: preferredSubdirectory, description: description, fallbackText: fallbackText, fallbackLanguage: fallbackLanguage)
                } catch {
                    self.playFallbackOrAdvance(text: fallbackText, language: fallbackLanguage, description: description)
                }
            }
        }
        audioDownloadTask?.resume()
    }

    private func playFile(at url: URL, preferredSubdirectory: String?, description: String, fallbackText: String?, fallbackLanguage: String?) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            audioPlayer = player
            activeAudioGeneration = playbackGeneration
            player.delegate = self
            player.volume = volume
            player.enableRate = true
            player.rate = adjustedPlaybackRate(for: preferredSubdirectory)
            player.prepareToPlay()
            delegate?.audioPlayerManager(didStartPlaying: description)
            isPlaying = true
            player.play()
        } catch {
            delegate?.audioPlayerManager(didEncounter: error)
            playFallbackOrAdvance(text: fallbackText, language: fallbackLanguage, description: description)
        }
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
            if let version = SupabaseConfig.englishWordAudioVersion {
                return "\(version)/words/en-US/\(audioFolderName)/\(remoteName)"
            }
            return "words/\(audioFolderName)/\(remoteName)"
        }
        if let version = SupabaseConfig.germanWordAudioVersion,
           let audioFolderName,
           ["12yue", "A1", "A2", "B1"].contains(audioFolderName) {
            return "\(version)/words/de-DE/\(audioFolderName)/\(remoteName)"
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
                result.unicodeScalars.append(scalar)
                previousWasUnderscore = false
            } else if !previousWasUnderscore {
                result.append("_")
                previousWasUnderscore = true
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "_."))
        return trimmed.isEmpty ? "audio" : trimmed
    }

    private func remoteAudioURL(named name: String, preferredSubdirectory: String?) -> URL? {
        guard var url = SupabaseConfig.learningAudioBaseURL else { return nil }
        for component in remotePath(named: name, preferredSubdirectory: preferredSubdirectory).split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private func cachedAudioURL(named name: String, preferredSubdirectory: String?, createDirectory: Bool = false) -> URL? {
        guard let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        var url = cacheRoot.appendingPathComponent("TingHuiErAudioV2", isDirectory: true)
        let components = remotePath(named: name, preferredSubdirectory: preferredSubdirectory).split(separator: "/")
        for component in components.dropLast() { url.appendPathComponent(String(component), isDirectory: true) }
        if createDirectory {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url.appendingPathComponent(name)
    }

    private func trimDownloadedAudioCache(maximumBytes: Int64 = 300 * 1_024 * 1_024) {
        guard let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let root = cacheRoot.appendingPathComponent("TingHuiErAudioV2", isDirectory: true)
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
        // Once natural-word audio v2 is active, never silently substitute an
        // iOS system voice for a missing or temporarily unavailable word file.
        if activeNaturalWordAudioVersion != nil,
           description.hasPrefix("file:"),
           preferredAudioDescriptionIsWord(description) {
            delegate?.audioPlayerManager(didEncounter: NaturalWordAudioError.unavailable)
            advanceQueue()
            return
        }
        if let text, let language, !text.isEmpty {
            speakText(text: text, language: language, description: description)
        } else {
            advanceQueue()
        }
    }

    private func preferredAudioDescriptionIsWord(_ description: String) -> Bool {
        !description.hasPrefix("meaning:")
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

private enum NaturalWordAudioError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "自然发音暂时无法加载，请检查网络后重试。"
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
