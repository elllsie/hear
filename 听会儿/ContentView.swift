import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var authStore = AuthStore()
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
    @State private var progressRefreshSeed = 0
    @State private var learningLanguage: LearningLanguage = .chinese
    @State private var hasSavedLearningLanguage = false
    private let progressStore = LearningProgressStore.shared

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            if let currentUser = authStore.currentUser {
                if !hasSavedLearningLanguage {
                    LanguageSetupView { language in
                        saveLearningLanguage(language)
                        screen = .books
                    }
                } else {
                    switch screen {
                    case .books:
                        BookSelectionView(
                            books: books,
                            isLoading: isLoadingBooks,
                            errorMessage: loadErrorMessage,
                            currentUser: currentUser,
                            learningLanguage: learningLanguage,
                            progressText: progressText(for:),
                            onProfile: {
                                screen = .profile
                            },
                            onLogout: logout
                        ) { book in
                            let savedIndex = progressStore.lastIndex(
                                for: currentUser.username,
                                bookId: book.bookId,
                                wordCount: book.words.count
                            )
                            selectedBook = book
                            currentIndex = savedIndex
                            currentWord = book.words.indices.contains(savedIndex) ? book.words[savedIndex] : book.words.first
                            screen = .settings
                        }
                    case .settings:
                        if let selectedBook {
                            PlaybackSettingsView(
                                book: selectedBook,
                                learningLanguage: learningLanguage,
                                speed: $speed,
                                repeatCount: $repeatCount,
                                onStart: {
                                    currentWord = selectedBook.words.indices.contains(currentIndex) ? selectedBook.words[currentIndex] : selectedBook.words.first
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
                                learningLanguage: learningLanguage,
                                onBack: {
                                    saveProgress(book: selectedBook, index: currentIndex)
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
                    case .profile:
                        ProfileSettingsView(
                            currentUser: currentUser,
                            learningLanguage: learningLanguage,
                            onBack: {
                                screen = .books
                            },
                            onLanguageChange: { language in
                                saveLearningLanguage(language)
                            },
                            onLogout: logout
                        )
                    }
                }
            } else {
                AuthView(
                    errorMessage: authStore.errorMessage,
                    isWorking: authStore.isWorking,
                    onLogin: { email, password in
                        authStore.login(email: email, password: password)
                    },
                    onRegister: { email, password in
                        authStore.register(email: email, password: password)
                    }
                )
            }
        }
        .onAppear {
            loadBooks()
            loadLearningLanguage()
        }
        .onChange(of: authStore.currentUser?.id) { _, _ in
            stopPlayback()
            selectedBook = nil
            currentIndex = 0
            currentWord = nil
            screen = .books
            loadLearningLanguage()
        }
        .task(id: "\(authStore.currentUser?.id ?? "guest")-\(books.count)") {
            await syncRemoteProgress()
        }
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
        saveProgress(book: book, index: safeIndex)

        let delegate = PlayerScreenDelegate(
            onCurrentWord: { word, index, _ in
                currentWord = word
                currentIndex = index
                saveProgress(book: book, index: index)
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
        AudioPlayerManager.shared.learningLanguage = learningLanguage
        AudioPlayerManager.shared.play(words: book.words, startIndex: safeIndex)
    }

    private func saveProgress(book: WordBook, index: Int) {
        guard let user = authStore.currentUser else { return }
        progressStore.saveAndSync(
            username: user.username,
            userId: user.id,
            accessToken: authStore.accessToken,
            bookId: book.bookId,
            index: index,
            wordCount: book.words.count
        )
    }

    private func progressText(for book: WordBook) -> String? {
        _ = progressRefreshSeed
        guard let username = authStore.currentUser?.username,
              let progress = progressStore.progress(for: username, bookId: book.bookId),
              book.words.indices.contains(progress.lastIndex) else {
            return nil
        }
        let percent = Int((Double(progress.lastIndex + 1) / Double(book.words.count) * 100).rounded())
        if learningLanguage == .english {
            return "Last studied: \(book.words[progress.lastIndex].word) · \(percent)%"
        }
        return "已学到 \(book.words[progress.lastIndex].word) · \(percent)%"
    }

    private func syncRemoteProgress() async {
        guard let user = authStore.currentUser,
              let accessToken = authStore.accessToken,
              !books.isEmpty else {
            return
        }

        for book in books {
            guard let remote = try? await SupabaseClient.shared.fetchProgress(
                accessToken: accessToken,
                userId: user.id,
                bookId: book.bookId
            ) else {
                continue
            }
            progressStore.save(username: user.username, progress: remote)
            progressRefreshSeed += 1
        }
    }

    private func logout() {
        stopPlayback()
        selectedBook = nil
        currentIndex = 0
        currentWord = nil
        screen = .books
        hasSavedLearningLanguage = false
        authStore.logout()
    }

    private func loadLearningLanguage() {
        guard let user = authStore.currentUser else {
            learningLanguage = .chinese
            hasSavedLearningLanguage = false
            return
        }

        guard let rawValue = UserDefaults.standard.string(forKey: learningLanguageKey(for: user)),
              let language = LearningLanguage(rawValue: rawValue) else {
            learningLanguage = .chinese
            hasSavedLearningLanguage = false
            return
        }

        learningLanguage = language
        hasSavedLearningLanguage = true
    }

    private func saveLearningLanguage(_ language: LearningLanguage) {
        guard let user = authStore.currentUser else { return }
        learningLanguage = language
        hasSavedLearningLanguage = true
        UserDefaults.standard.set(language.rawValue, forKey: learningLanguageKey(for: user))
    }

    private func learningLanguageKey(for user: AppUser) -> String {
        "tinghui.learningLanguage.\(user.id)"
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
    case profile
}

private enum AppColors {
    static let background = Color.black
    static let panel = Color(red: 0.07, green: 0.10, blue: 0.17)
    static let stroke = Color(red: 0.17, green: 0.24, blue: 0.36)
    static let muted = Color(red: 0.60, green: 0.65, blue: 0.73)
    static let track = Color(red: 0.12, green: 0.18, blue: 0.27)
}

private struct AuthView: View {
    let errorMessage: String?
    let isWorking: Bool
    let onLogin: (String, String) -> Void
    let onRegister: (String, String) -> Void

    @State private var isRegistering = false
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 84)

            VStack(spacing: 16) {
                Text("听会儿")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundColor(.white)

                Text(isRegistering ? "注册账号后开始学习" : "登录后继续学习")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(AppColors.muted)
            }

            VStack(spacing: 18) {
                TextField("邮箱", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 64)
                    .background(AppColors.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(AppColors.stroke, lineWidth: 1.5)
                    )

                SecureField("密码", text: $password)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 64)
                    .background(AppColors.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(AppColors.stroke, lineWidth: 1.5)
                    )

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.red.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    if isRegistering {
                        onRegister(email, password)
                    } else {
                        onLogin(email, password)
                    }
                } label: {
                    Text(isWorking ? "处理中..." : (isRegistering ? "注册并登录" : "登录"))
                        .font(.system(size: 23, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 68)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .opacity(isWorking ? 0.65 : 1)
                .padding(.top, 10)

                Button {
                    isRegistering.toggle()
                } label: {
                    Text(isRegistering ? "已有账号，去登录" : "没有账号，注册一个")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(AppColors.muted)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 34)
            .padding(.top, 72)

            Spacer(minLength: 56)
        }
    }
}

private struct LanguageSetupView: View {
    let onSelect: (LearningLanguage) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 96)

            VStack(spacing: 16) {
                Text("Choose Study Language")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text("选择学习语言")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(AppColors.muted)
            }
            .padding(.horizontal, 28)

            VStack(spacing: 18) {
                LanguageChoiceButton(
                    title: "English Learning",
                    subtitle: "Use English meanings and English interface",
                    iconName: "textformat.abc",
                    action: {
                        onSelect(.english)
                    }
                )

                LanguageChoiceButton(
                    title: "中文学习",
                    subtitle: "使用中文释义和中文界面",
                    iconName: "character.book.closed",
                    action: {
                        onSelect(.chinese)
                    }
                )
            }
            .padding(.horizontal, 24)
            .padding(.top, 78)

            Spacer(minLength: 64)
        }
    }
}

private struct LanguageChoiceButton: View {
    let title: String
    let subtitle: String
    let iconName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 22) {
                Image(systemName: iconName)
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 42)
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 27, weight: .bold))
                        .foregroundColor(.white)

                    Text(subtitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(AppColors.muted)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(Color(red: 0.34, green: 0.40, blue: 0.50))
            }
            .padding(.horizontal, 28)
            .frame(height: 132)
            .background(AppColors.background)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(AppColors.stroke, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct BookSelectionView: View {
    let books: [WordBook]
    let isLoading: Bool
    let errorMessage: String?
    let currentUser: AppUser
    let learningLanguage: LearningLanguage
    let progressText: (WordBook) -> String?
    let onProfile: () -> Void
    let onLogout: () -> Void
    let onSelect: (WordBook) -> Void

    var body: some View {
        let isEnglish = learningLanguage == .english

        VStack(spacing: 0) {
            HStack {
                Button(action: onProfile) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 20, weight: .semibold))

                        Text(currentUser.displayName)
                            .font(.system(size: 18, weight: .bold))
                    }
                    .foregroundColor(AppColors.muted)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onLogout) {
                    Text(isEnglish ? "Log Out" : "退出")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(AppColors.muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)

            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 16) {
                        Text(isEnglish ? "Word Player" : "单词播放器")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundColor(.white)
                            .minimumScaleFactor(0.75)

                        Text(isEnglish ? "Choose a word book to start" : "选择一个单词书开始学习")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(AppColors.muted)
                    }
                    .padding(.top, 58)
                    .padding(.bottom, 52)

                    if isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(1.4)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if let errorMessage {
                        Text(isEnglish && errorMessage == "没有加载到词书" ? "No word books loaded" : errorMessage)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(AppColors.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        BookListView(
                            books: books,
                            isEnglish: isEnglish,
                            progressText: progressText,
                            onSelect: onSelect
                        )
                    }
                }
                .padding(.bottom, 96)
            }
            .scrollIndicators(.visible)
        }
    }
}

private struct BookListView: View {
    let books: [WordBook]
    let isEnglish: Bool
    let progressText: (WordBook) -> String?
    let onSelect: (WordBook) -> Void

    var body: some View {
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

                        VStack(alignment: .leading, spacing: 8) {
                            Text(isEnglish ? "German \(book.title)" : "德语 \(book.title)")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(.white)

                            if let progressText = progressText(book) {
                                Text(progressText)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(AppColors.muted)
                                    .lineLimit(1)
                            }
                        }

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
}

private struct ProfileSettingsView: View {
    let currentUser: AppUser
    let learningLanguage: LearningLanguage
    let onBack: () -> Void
    let onLanguageChange: (LearningLanguage) -> Void
    let onLogout: () -> Void

    var body: some View {
        let isEnglish = learningLanguage == .english

        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 12) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 24, weight: .semibold))
                        Text(isEnglish ? "Back" : "返回")
                            .font(.system(size: 22, weight: .bold))
                    }
                    .foregroundColor(AppColors.muted)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onLogout) {
                    Text(isEnglish ? "Log Out" : "退出")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(AppColors.muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)

            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 70, weight: .regular))
                    .foregroundColor(.white)

                Text(currentUser.displayName)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(currentUser.username)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(AppColors.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 28)
            .padding(.top, 58)

            VStack(alignment: .leading, spacing: 18) {
                Text(isEnglish ? "Preferences" : "偏好设置")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)

                VStack(spacing: 0) {
                    SettingsLanguageButton(
                        title: isEnglish ? "English Learning" : "英语学习",
                        subtitle: isEnglish ? "English meanings and English interface" : "英文释义和英文界面",
                        isSelected: learningLanguage == .english,
                        action: {
                            onLanguageChange(.english)
                        }
                    )

                    Divider()
                        .background(AppColors.stroke)
                        .padding(.leading, 24)

                    SettingsLanguageButton(
                        title: isEnglish ? "Chinese Learning" : "中文学习",
                        subtitle: isEnglish ? "Chinese meanings and Chinese interface" : "中文释义和中文界面",
                        isSelected: learningLanguage == .chinese,
                        action: {
                            onLanguageChange(.chinese)
                        }
                    )
                }
                .background(AppColors.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(AppColors.stroke, lineWidth: 1.5)
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text(isEnglish ? "More Settings" : "更多设置")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)

                    Text(isEnglish ? "Reserved for future options." : "后续设置预留位置。")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(AppColors.muted)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(AppColors.stroke, lineWidth: 1.5)
                )
            }
            .padding(.horizontal, 28)
            .padding(.top, 58)

            Spacer(minLength: 32)
        }
    }
}

private struct SettingsLanguageButton: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(isSelected ? .white : AppColors.muted)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)

                    Text(subtitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppColors.muted)
                        .lineLimit(2)
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(height: 94)
        }
        .buttonStyle(.plain)
    }
}

private struct PlaybackSettingsView: View {
    let book: WordBook
    let learningLanguage: LearningLanguage
    @Binding var speed: Double
    @Binding var repeatCount: Double
    let onStart: () -> Void

    var body: some View {
        let isEnglish = learningLanguage == .english

        VStack(spacing: 0) {
            Spacer(minLength: 120)

            HStack(spacing: 18) {
                Image(systemName: "gearshape")
                    .font(.system(size: 34, weight: .bold))
                Text(isEnglish ? "Playback Settings" : learningLanguage.description)
                    .font(.system(size: 40, weight: .bold))
            }
            .foregroundColor(.white)
            .padding(.bottom, 92)

            VStack(spacing: 64) {
                SettingSlider(
                    title: isEnglish ? "Speed" : "语速",
                    valueText: String(format: "%.1fx", speed),
                    value: $speed,
                    range: 0.6...1.4,
                    step: 0.1
                )

                SettingSlider(
                    title: isEnglish ? "Repeats" : "重复次数",
                    valueText: isEnglish ? "\(Int(repeatCount.rounded()))x" : "\(Int(repeatCount.rounded()))次",
                    value: $repeatCount,
                    range: 1...5,
                    step: 1
                )
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 32)

            Button(action: onStart) {
                Text(isEnglish ? "Start Playing" : "开始播放")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 96)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 560)
            .padding(.horizontal, 32)
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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(AppColors.muted)
                    .lineLimit(1)

                Spacer(minLength: 18)

                Text(valueText)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 74, alignment: .trailing)
            }

            Slider(value: $value, in: range, step: step)
                .tint(AppColors.track)
                .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                ForEach(0..<tickCount, id: \.self) { index in
                    Rectangle()
                        .fill(index == selectedTick ? Color.white : AppColors.muted.opacity(0.55))
                        .frame(width: index == selectedTick ? 3 : 2, height: index == selectedTick ? 14 : 8)

                    if index < tickCount - 1 {
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 10)
        }
    }

    private var tickCount: Int {
        max(2, Int(((range.upperBound - range.lowerBound) / step).rounded()) + 1)
    }

    private var selectedTick: Int {
        Int(((value - range.lowerBound) / step).rounded())
    }
}

private struct PlayerView: View {
    let book: WordBook
    let speed: Double
    let repeatCount: Int
    let currentIndex: Int
    let currentWord: Word?
    let isPlaying: Bool
    let learningLanguage: LearningLanguage
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
            let isEnglish = learningLanguage == .english
            let isCompactHeight = proxy.size.height < 740
            let horizontalPadding: CGFloat = proxy.size.width < 390 ? 22 : 32
            let topPadding: CGFloat = isCompactHeight ? 28 : 48
            let controlSize: CGFloat = isCompactHeight ? 104 : 128

            VStack(alignment: .leading, spacing: 0) {
                Button(action: onBack) {
                    HStack(spacing: 14) {
                        Image(systemName: "house")
                            .font(.system(size: 28, weight: .semibold))
                        Text(isEnglish ? "Home" : "返回")
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

                    Text(currentWord?.meaning(for: learningLanguage) ?? "")
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

                    Text(isEnglish ? String(format: "Speed: %.1fx · Repeats: %d", speed, repeatCount) : String(format: "语速: %.1fx · 重复: %d次", speed, repeatCount))
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
