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
    public var chineseMeaningFileRateMultiplier: Float = 1.5
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
        for repeatIndex in 0..<max(1, repeatTimes) {
            if let file = preferredAudioFileName(for: word) {
                queue.append(.file(name: file, description: "file:\(file)", word: word, wordIndex: wordIndex, totalWords: totalWords))
            } else {
                queue.append(.text(text: word.word, language: "de-DE", description: "word:\(word.word)", word: word, wordIndex: wordIndex, totalWords: totalWords))
            }

            let isLastRepeat = repeatIndex == max(1, repeatTimes) - 1
            if isLastRepeat {
                let meaning = word.meaning(for: learningLanguage)
                if let file = preferredMeaningAudioFileName(for: meaning, language: learningLanguage) {
                    queue.append(.file(name: file, subdirectory: learningLanguage.meaningAudioSubdirectory, description: "meaning:\(meaning)", word: word, wordIndex: wordIndex, totalWords: totalWords))
                } else {
                    queue.append(.text(text: meaning, language: learningLanguage.speechLanguageCode, description: "meaning:\(meaning)", word: word, wordIndex: wordIndex, totalWords: totalWords))
                }
            }
        }
    }

    private func preferredAudioFileName(for word: Word) -> String? {
        if let fileName = word.audioFileName, !fileName.isEmpty {
            return fileName
        }

        let fileName = "\(safeAudioFileName(for: word.word)).mp3"
        if audioURL(named: fileName) != nil {
            return fileName
        }

        return nil
    }

    private func preferredMeaningAudioFileName(for meaning: String, language: LearningLanguage) -> String? {
        let fileName = safeMeaningAudioFileName(for: meaning)
        if audioURL(named: fileName, preferredSubdirectory: language.meaningAudioSubdirectory) != nil {
            return fileName
        }

        return nil
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
        case .file(let name, let subdirectory, let desc, _, _, _):
            playLocalFile(named: name, preferredSubdirectory: subdirectory, description: desc)
        case .text(let text, let language, let desc, _, _, _):
            speakText(text: text, language: language, description: desc)
        }
    }

    private func notifyProgressIfNeeded(for item: PlayItem) {
        guard currentWordProgressIndex != item.wordIndex else { return }
        currentWordProgressIndex = item.wordIndex
        delegate?.audioPlayerManager(didUpdateCurrentWord: item.word, index: item.wordIndex, total: item.totalWords)
    }

    // MARK: - Local file play
    private func playLocalFile(named name: String, preferredSubdirectory: String?, description: String) {
        stopAudioPlayer()
        guard let url = audioURL(named: name, preferredSubdirectory: preferredSubdirectory) else {
            delegate?.audioPlayerManager(didEncounter: NSError(domain: "AudioPlayerManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing audio file: \(name)" ]))
            advanceQueue()
            return
        }
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
            advanceQueue()
        }
    }

    private func stopAudioPlayer() {
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        activeAudioGeneration = -1
    }

    private func audioURL(named name: String, preferredSubdirectory: String? = nil) -> URL? {
        if let preferredSubdirectory, !preferredSubdirectory.isEmpty,
           let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: preferredSubdirectory) {
            return url
        }

        if let folder = audioFolderName, !folder.isEmpty {
            return Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "audio/\(folder)") ??
            Bundle.main.url(forResource: name, withExtension: nil, subdirectory: folder) ??
            Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "audio/words") ??
            Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "audio") ??
            Bundle.main.url(forResource: name, withExtension: nil)
        }

        return Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "audio/words") ??
        Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "audio") ??
        Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "audio/12yue") ??
        Bundle.main.url(forResource: name, withExtension: nil)
    }

    // MARK: - TTS
    private func speakText(text: String, language: String, description: String) {
        if tts.isSpeaking {
            suppressedSpeechCancelUtterance = activeSpeechUtterance
            tts.stopSpeaking(at: .immediate)
        }
        let utter = AVSpeechUtterance(string: text)
        utter.voice = AVSpeechSynthesisVoice(language: language)
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
    case file(name: String, subdirectory: String? = nil, description: String, word: Word, wordIndex: Int, totalWords: Int)
    case text(text: String, language: String, description: String, word: Word, wordIndex: Int, totalWords: Int)

    var description: String {
        switch self {
        case .file(_, _, let d, _, _, _): return d
        case .text(_, _, let d, _, _, _): return d
        }
    }

    var word: Word {
        switch self {
        case .file(_, _, _, let word, _, _): return word
        case .text(_, _, _, let word, _, _): return word
        }
    }

    var wordIndex: Int {
        switch self {
        case .file(_, _, _, _, let index, _): return index
        case .text(_, _, _, _, let index, _): return index
        }
    }

    var totalWords: Int {
        switch self {
        case .file(_, _, _, _, _, let total): return total
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
