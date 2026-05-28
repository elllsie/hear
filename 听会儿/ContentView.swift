import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var screen: PlayerScreen = .books
    @State private var books: [WordBook] = []
    @State private var selectedBook: WordBook?
    @State private var speed: Double = 1.0
    @State private var repeatCount: Double = 2.0
    @State private var currentIndex: Int = 0
    @State private var currentWord: Word?
    @State private var isPlaying: Bool = false
    @State private var didStartPlayback = false
    @State private var isLoadingBooks = true
    @State private var loadErrorMessage: String?
    @State private var playbackDelegate: PlayerScreenDelegate?

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            switch screen {
            case .books:
                BookSelectionView(
                    books: books,
                    isLoading: isLoadingBooks,
                    errorMessage: loadErrorMessage
                ) { book in
                    selectedBook = book
                    currentIndex = 0
                    currentWord = book.words.first
                    screen = .settings
                }
            case .settings:
                if let selectedBook {
                    PlaybackSettingsView(
                        book: selectedBook,
                        speed: $speed,
                        repeatCount: $repeatCount,
                        onStart: {
                            currentIndex = 0
                            currentWord = selectedBook.words.first
                            didStartPlayback = false
                            screen = .player
                        }
                    )
                }
            case .player:
                if let selectedBook {
                    PlayerView(
                        book: selectedBook,
                        speed: speed,
                        repeatCount: Int(repeatCount.rounded()),
                        currentIndex: currentIndex,
                        currentWord: currentWord ?? selectedBook.words.first,
                        isPlaying: isPlaying,
                        onBack: {
                            stopPlayback()
                            screen = .books
                        },
                        onPrevious: {
                            startPlayback(book: selectedBook, from: max(0, currentIndex - 1))
                        },
                        onTogglePlayback: togglePlayback,
                        onNext: {
                            startPlayback(book: selectedBook, from: min(selectedBook.words.count - 1, currentIndex + 1))
                        },
                        onJumpToIndex: { index in
                            startPlayback(book: selectedBook, from: index)
                        }
                    )
                    .onAppear {
                        guard !didStartPlayback else { return }
                        didStartPlayback = true
                        startPlayback(book: selectedBook, from: currentIndex)
                    }
                }
            }
        }
        .onAppear(perform: loadBooks)
        .onDisappear(perform: stopPlayback)
    }

    private func loadBooks() {
        guard books.isEmpty else { return }
        isLoadingBooks = true
        loadErrorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let loadedBooks = DataLoader.loadBooks(named: ["A1", "A2", "B1"])

            DispatchQueue.main.async {
                self.books = loadedBooks
                self.isLoadingBooks = false
                if loadedBooks.isEmpty {
                    self.loadErrorMessage = "没有加载到词书"
                }
            }
        }
    }

    private func startPlayback(book: WordBook, from index: Int) {
        guard !book.words.isEmpty else { return }

        let safeIndex = min(max(0, index), book.words.count - 1)
        currentIndex = safeIndex
        currentWord = book.words[safeIndex]
        isPlaying = true

        let delegate = PlayerScreenDelegate(
            onCurrentWord: { word, index, _ in
                currentWord = word
                currentIndex = index
            },
            onStateChange: { playing in
                isPlaying = playing
            },
            onComplete: {
                isPlaying = false
            }
        )

        playbackDelegate = delegate
        AudioPlayerManager.shared.delegate = delegate
        AudioPlayerManager.shared.repeatTimes = Int(repeatCount.rounded())
        AudioPlayerManager.shared.rate = AVSpeechUtteranceDefaultSpeechRate * Float(speed)
        AudioPlayerManager.shared.playbackRate = Float(speed)
        AudioPlayerManager.shared.volume = 1.0
        AudioPlayerManager.shared.audioFolderName = book.bookId
        AudioPlayerManager.shared.play(words: book.words, startIndex: safeIndex)
    }

    private func togglePlayback() {
        if isPlaying {
            AudioPlayerManager.shared.pause()
        } else {
            AudioPlayerManager.shared.resume()
        }
    }

    private func stopPlayback() {
        AudioPlayerManager.shared.stop()
        isPlaying = false
        didStartPlayback = false
    }
}

private enum PlayerScreen {
    case books
    case settings
    case player
}

private enum AppColors {
    static let background = Color.black
    static let panel = Color(red: 0.07, green: 0.10, blue: 0.17)
    static let stroke = Color(red: 0.17, green: 0.24, blue: 0.36)
    static let muted = Color(red: 0.60, green: 0.65, blue: 0.73)
    static let track = Color(red: 0.12, green: 0.18, blue: 0.27)
}

private struct BookSelectionView: View {
    let books: [WordBook]
    let isLoading: Bool
    let errorMessage: String?
    let onSelect: (WordBook) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                Text("单词播放器")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.75)

                Text("选择一个单词书开始学习")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(AppColors.muted)
            }
            .padding(.top, 86)
            .padding(.bottom, 70)

            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.4)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(AppColors.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else {
                VStack(spacing: 16) {
                    ForEach(books, id: \.bookId) { book in
                        Button {
                            onSelect(book)
                        } label: {
                            HStack(spacing: 28) {
                                Image(systemName: "book.closed")
                                    .font(.system(size: 28, weight: .medium))
                                    .frame(width: 42)
                                    .foregroundColor(AppColors.muted)

                                Text("德语 \(book.title)")
                                    .font(.system(size: 28, weight: .bold))
                                    .foregroundColor(.white)

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 30, weight: .semibold))
                                    .foregroundColor(Color(red: 0.34, green: 0.40, blue: 0.50))
                            }
                            .padding(.horizontal, 34)
                            .frame(height: 154)
                            .background(AppColors.background)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(AppColors.stroke, lineWidth: 2)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
            }

            Spacer(minLength: 24)
        }
    }
}

private struct PlaybackSettingsView: View {
    let book: WordBook
    @Binding var speed: Double
    @Binding var repeatCount: Double
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 120)

            HStack(spacing: 18) {
                Image(systemName: "gearshape")
                    .font(.system(size: 34, weight: .bold))
                Text("播放设置")
                    .font(.system(size: 40, weight: .bold))
            }
            .foregroundColor(.white)
            .padding(.bottom, 92)

            VStack(spacing: 64) {
                SettingSlider(
                    title: "语速",
                    valueText: String(format: "%.1fx", speed),
                    value: $speed,
                    range: 0.6...1.4,
                    step: 0.1
                )

                SettingSlider(
                    title: "重复次数",
                    valueText: "\(Int(repeatCount.rounded()))次",
                    value: $repeatCount,
                    range: 1...5,
                    step: 1
                )
            }
            .padding(.horizontal, 112)

            Button(action: onStart) {
                Text("开始播放")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 96)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 112)
            .padding(.top, 108)

            Spacer(minLength: 84)
        }
    }
}

private struct SettingSlider: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(AppColors.muted)

            HStack(spacing: 66) {
                Slider(value: $value, in: range, step: step)
                    .tint(AppColors.track)

                Text(valueText)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 74, alignment: .trailing)
            }
        }
    }
}

private struct PlayerView: View {
    let book: WordBook
    let speed: Double
    let repeatCount: Int
    let currentIndex: Int
    let currentWord: Word?
    let isPlaying: Bool
    let onBack: () -> Void
    let onPrevious: () -> Void
    let onTogglePlayback: () -> Void
    let onNext: () -> Void
    let onJumpToIndex: (Int) -> Void

    private var progress: Double {
        guard !book.words.isEmpty else { return 0 }
        return Double(currentIndex + 1) / Double(book.words.count)
    }

    private var letterIndexes: [(letter: String, index: Int)] {
        var seen = Set<String>()

        return book.words.enumerated().compactMap { index, word in
            let letter = indexLetter(for: word.word)
            guard !letter.isEmpty, !seen.contains(letter) else { return nil }
            seen.insert(letter)
            return (letter, index)
        }
    }

    private var currentLetter: String {
        indexLetter(for: currentWord?.word ?? "")
    }

    private func indexLetter(for word: String) -> String {
        let articles = ["der", "die", "das", "ein", "eine", "einen", "einem", "einer"]
        let cleanedWord = word
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .drop { articles.contains($0) }
            .first ?? word.lowercased()

        guard let firstScalar = cleanedWord.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).first else {
            return ""
        }

        let letter = String(firstScalar).uppercased()
        return letter.range(of: "^[A-Z]$", options: .regularExpression) == nil ? "" : letter
    }

    var body: some View {
        GeometryReader { proxy in
            let isCompactHeight = proxy.size.height < 740
            let horizontalPadding: CGFloat = proxy.size.width < 390 ? 22 : 32
            let topPadding: CGFloat = isCompactHeight ? 28 : 48
            let controlSize: CGFloat = isCompactHeight ? 104 : 128

            VStack(alignment: .leading, spacing: 0) {
                Button(action: onBack) {
                    HStack(spacing: 14) {
                        Image(systemName: "house")
                            .font(.system(size: 28, weight: .semibold))
                        Text("返回")
                            .font(.system(size: 27, weight: .bold))
                    }
                    .foregroundColor(AppColors.muted)
                }
                .buttonStyle(.plain)
                .padding(.leading, horizontalPadding)
                .padding(.top, topPadding)

                Spacer(minLength: isCompactHeight ? 24 : 54)

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(letterIndexes, id: \.letter) { item in
                            Button {
                                onJumpToIndex(item.index)
                            } label: {
                                Text(item.letter)
                                    .font(.system(size: isCompactHeight ? 14 : 16, weight: .bold))
                                    .foregroundColor(item.letter == currentLetter ? .white : AppColors.muted)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: isCompactHeight ? 30 : 34)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, proxy.size.width < 390 ? 8 : 18)
                    .padding(.top, isCompactHeight ? 24 : 42)

                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .background(AppColors.track)
                        .frame(height: 6)
                        .padding(.horizontal, proxy.size.width < 390 ? 34 : 64)
                        .padding(.top, isCompactHeight ? 8 : 12)

                    Spacer(minLength: isCompactHeight ? 26 : 46)

                    Text(currentWord?.word ?? "")
                        .font(.system(size: isCompactHeight ? 60 : 74, weight: .regular))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                        .frame(maxWidth: .infinity)

                    Text(currentWord?.translation ?? "")
                        .font(.system(size: isCompactHeight ? 28 : 34, weight: .bold))
                        .foregroundColor(AppColors.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.65)
                        .padding(.top, isCompactHeight ? 20 : 28)

                    HStack(spacing: proxy.size.width < 390 ? 42 : 62) {
                        Button(action: onPrevious) {
                            Image(systemName: "backward.end")
                                .font(.system(size: 44, weight: .regular))
                                .foregroundColor(currentIndex == 0 ? Color.white.opacity(0.25) : Color.white.opacity(0.55))
                        }
                        .disabled(currentIndex == 0)

                        Button(action: onTogglePlayback) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: isCompactHeight ? 50 : 58, weight: .regular))
                                .foregroundColor(.black)
                                .frame(width: controlSize, height: controlSize)
                                .background(Color.white)
                                .clipShape(Circle())
                        }

                        Button(action: onNext) {
                            Image(systemName: "forward.end")
                                .font(.system(size: 44, weight: .regular))
                                .foregroundColor(currentIndex >= book.words.count - 1 ? Color.white.opacity(0.25) : .white)
                        }
                        .disabled(currentIndex >= book.words.count - 1)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, isCompactHeight ? 34 : 48)

                    Text(String(format: "语速: %.1fx · 重复: %d次", speed, repeatCount))
                        .font(.system(size: isCompactHeight ? 22 : 26, weight: .bold))
                        .foregroundColor(AppColors.muted)
                        .padding(.top, isCompactHeight ? 34 : 50)

                    Spacer(minLength: isCompactHeight ? 26 : 54)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppColors.background)
                .padding(.horizontal, horizontalPadding)

                Spacer(minLength: isCompactHeight ? 18 : 32)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(AppColors.background)
        }
        .background(AppColors.background)
    }
}

private final class PlayerScreenDelegate: AudioPlayerManagerDelegate {
    let onCurrentWord: (Word, Int, Int) -> Void
    let onStateChange: (Bool) -> Void
    let onComplete: () -> Void

    init(
        onCurrentWord: @escaping (Word, Int, Int) -> Void,
        onStateChange: @escaping (Bool) -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.onCurrentWord = onCurrentWord
        self.onStateChange = onStateChange
        self.onComplete = onComplete
    }

    func audioPlayerManager(didStartPlaying itemDescription: String) {}

    func audioPlayerManager(didFinishPlaying itemDescription: String) {}

    func audioPlayerManager(didUpdateState isPlaying: Bool) {
        DispatchQueue.main.async {
            self.onStateChange(isPlaying)
        }
    }

    func audioPlayerManager(didEncounter error: Error) {
        print("Audio playback error: \(error)")
    }

    func audioPlayerManager(didUpdateCurrentWord word: Word, index: Int, total: Int) {
        DispatchQueue.main.async {
            self.onCurrentWord(word, index, total)
        }
    }

    func audioPlayerManagerDidCompleteQueue() {
        DispatchQueue.main.async {
            self.onComplete()
        }
    }
}

#Preview {
    ContentView()
}
