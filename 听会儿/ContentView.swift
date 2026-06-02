import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var authStore = AuthStore()
    @State private var screen: PlayerScreen = .books
    @State private var authRoute: AuthRoute?
    @State private var isShowingFavoriteSignInPrompt = false
    @State private var pendingFavorite: PendingFavorite?
    @State private var deleteSuccessMessage: String?
    @State private var isShowingDeleteSuccess = false
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
    @State private var favoriteRefs: [FavoriteWordReference] = []
    private let progressStore = LearningProgressStore.shared

    private var activeUser: AppUser {
        authStore.currentUser ?? .guest
    }

    private var isGuestMode: Bool {
        authStore.currentUser == nil
    }

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            if let route = authRoute {
                AuthView(
                    mode: route,
                    learningLanguage: learningLanguage,
                    errorMessage: authStore.errorMessage,
                    isWorking: authStore.isWorking,
                    onLogin: { email, password in
                        authStore.login(email: email, password: password)
                    },
                    onRegister: { email, password in
                        authStore.register(email: email, password: password)
                    },
                    onSwitchMode: {
                        authRoute = route == .login ? .register : .login
                    },
                    onBack: {
                        authRoute = nil
                    }
                )
            } else {
                let currentUser = activeUser
                if !hasSavedLearningLanguage {
                    LanguageSetupView { language in
                        saveLearningLanguage(language)
                        screen = .books
                    }
                } else {
                    switch screen {
                    case .books:
                        BookSelectionView(
                            books: displayBooks(),
                            isLoading: isLoadingBooks,
                            errorMessage: loadErrorMessage,
                            currentUser: currentUser,
                            isGuestMode: isGuestMode,
                            learningLanguage: learningLanguage,
                            progressText: progressText(for:),
                            onProfile: {
                                screen = .profile
                            },
                            onLogin: {
                                authRoute = .login
                            },
                            onLogout: {
                                logout()
                            }
                        ) { book in
                            if isGuestMode, book.bookId == FavoriteWordStore.favoriteBookId {
                                promptForFavoriteSignIn()
                                return
                            }
                            let savedIndex = progressStore.lastIndex(
                                for: currentUser.storageKey,
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
                                isCurrentFavorite: isFavorite(currentWord ?? selectedBook.words.first, in: selectedBook),
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
                                onPreviewIndex: { index in
                                    previewWord(book: selectedBook, at: index)
                                },
                                onJumpToIndex: { index in
                                    startPlayback(book: selectedBook, from: index)
                                },
                                onToggleFavorite: {
                                    if let word = currentWord ?? selectedBook.words.first {
                                        toggleFavorite(word: word, in: selectedBook)
                                    }
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
                            isGuestMode: isGuestMode,
                            learningLanguage: learningLanguage,
                            deleteErrorMessage: authStore.errorMessage,
                            deleteSuccessMessage: deleteSuccessMessage,
                            isDeletingAccount: authStore.isWorking,
                            onBack: {
                                screen = .books
                            },
                            onLanguageChange: { language in
                                saveLearningLanguage(language)
                            },
                            onLogin: {
                                authRoute = .login
                            },
                            onRegister: {
                                authRoute = .register
                            },
                            onDeleteAccount: deleteAccount
                        )
                    }
                }
            }
        }
        .alert(favoriteSignInTitle, isPresented: $isShowingFavoriteSignInPrompt) {
            Button(learningLanguage == .english ? "Sign In" : "登录") {
                authRoute = .login
            }
            Button(learningLanguage == .english ? "Create Account" : "创建账号") {
                authRoute = .register
            }
            Button(learningLanguage == .english ? "Cancel" : "取消", role: .cancel) {}
        } message: {
            Text(favoriteSignInMessage)
        }
        .alert("删除成功", isPresented: $isShowingDeleteSuccess) {
            Button("OK") {
                deleteSuccessMessage = nil
            }
        } message: {
            Text(deleteSuccessMessage ?? "账号和云端数据已删除")
        }
        .onAppear {
            loadBooks()
            loadLearningLanguage()
            loadFavorites()
        }
        .onChange(of: authStore.currentUser?.id) { oldValue, newValue in
            stopPlayback()
            selectedBook = nil
            currentIndex = 0
            currentWord = nil
            screen = .books
            authRoute = nil
            if oldValue == nil, newValue != nil, let user = authStore.currentUser {
                migrateGuestData(to: user)
                completePendingFavoriteIfNeeded()
            }
            loadLearningLanguage()
            loadFavorites()
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

    private var favoriteSignInTitle: String {
        learningLanguage == .english ? "Sign in to save your favorites" : "登录以保存收藏"
    }

    private var favoriteSignInMessage: String {
        learningLanguage == .english
            ? "Create an account or sign in to sync your favorite words across devices."
            : "创建账号或登录后，可以在多台设备同步收藏单词。"
    }

    private func displayBooks() -> [WordBook] {
        return [favoriteBook()] + books
    }

    private func favoriteBook() -> WordBook {
        let words = isGuestMode ? [] : favoriteRefs.compactMap { word(for: $0) }
        return WordBook(bookId: FavoriteWordStore.favoriteBookId, title: FavoriteWordStore.favoriteBookTitle, words: words)
    }

    private func word(for reference: FavoriteWordReference) -> Word? {
        books.first { $0.bookId == reference.bookId }?
            .words
            .first { $0.id == reference.wordId }
    }

    private func previewWord(book: WordBook, at index: Int) {
        guard book.words.indices.contains(index) else { return }
        stopPlayback()
        selectedBook = book
        currentIndex = index
        currentWord = book.words[index]
    }

    private func startPlayback(book: WordBook, from index: Int) {
        guard !book.words.isEmpty else { return }

        let safeIndex = min(max(0, index), book.words.count - 1)
        currentIndex = safeIndex
        currentWord = book.words[safeIndex]
        isPlaying = true
        didStartPlayback = true
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
                didStartPlayback = false
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

    private func loadFavorites() {
        favoriteRefs = isGuestMode ? [] : FavoriteWordStore.load(for: activeUser)
    }

    private func saveFavorites() {
        guard !isGuestMode else { return }
        FavoriteWordStore.save(favoriteRefs, for: activeUser)
    }

    private func favoriteReference(for word: Word, in book: WordBook) -> FavoriteWordReference? {
        if book.bookId != FavoriteWordStore.favoriteBookId {
            return FavoriteWordReference(bookId: book.bookId, wordId: word.id)
        }

        return favoriteRefs.first { reference in
            guard let storedWord = self.word(for: reference) else { return false }
            return storedWord.id == word.id && storedWord.word == word.word
        }
    }

    private func isFavorite(_ word: Word?, in book: WordBook) -> Bool {
        guard let word, let reference = favoriteReference(for: word, in: book) else { return false }
        return favoriteRefs.contains(reference)
    }

    private func toggleFavorite(word: Word, in book: WordBook) {
        guard !isGuestMode else {
            stopPlayback()
            pendingFavorite = PendingFavorite(book: book, word: word, index: currentIndex)
            isShowingFavoriteSignInPrompt = true
            return
        }
        toggleFavoriteReference(for: word, in: book)
    }

    private func toggleFavoriteReference(for word: Word, in book: WordBook) {
        guard let reference = favoriteReference(for: word, in: book) else { return }

        if let existingIndex = favoriteRefs.firstIndex(of: reference) {
            favoriteRefs.remove(at: existingIndex)
        } else {
            favoriteRefs.append(reference)
        }

        saveFavorites()
        syncFavoriteChange(reference: reference, isFavorite: favoriteRefs.contains(reference))
    }

    private func promptForFavoriteSignIn() {
        stopPlayback()
        pendingFavorite = nil
        isShowingFavoriteSignInPrompt = true
    }

    private func completePendingFavoriteIfNeeded() {
        guard let pendingFavorite else { return }
        selectedBook = pendingFavorite.book
        currentIndex = pendingFavorite.index
        currentWord = pendingFavorite.word
        favoriteRefs = FavoriteWordStore.load(for: activeUser)
        toggleFavoriteReference(for: pendingFavorite.word, in: pendingFavorite.book)
        self.pendingFavorite = nil
        screen = .player
        didStartPlayback = false
    }

    private func saveProgress(book: WordBook, index: Int) {
        let user = activeUser
        progressStore.saveAndSync(
            username: user.storageKey,
            userId: user.id,
            accessToken: isGuestMode ? nil : authStore.accessToken,
            bookId: book.bookId,
            index: index,
            wordCount: book.words.count
        )
    }

    private func progressText(for book: WordBook) -> String? {
        _ = progressRefreshSeed
        guard let progress = progressStore.progress(for: activeUser.storageKey, bookId: book.bookId),
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
            progressStore.save(username: user.storageKey, progress: remote)
            progressRefreshSeed += 1
        }

        await syncRemoteFavorites(user: user, accessToken: accessToken)
    }

    private func logout() {
        let wasGuestMode = isGuestMode
        stopPlayback()
        selectedBook = nil
        currentIndex = 0
        currentWord = nil
        screen = .books
        hasSavedLearningLanguage = false
        authRoute = nil
        deleteSuccessMessage = nil
        if !wasGuestMode {
            authStore.logout()
        }
        loadLearningLanguage()
        loadFavorites()
    }

    private func loadLearningLanguage() {
        let user = activeUser

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
        let user = activeUser
        learningLanguage = language
        hasSavedLearningLanguage = true
        UserDefaults.standard.set(language.rawValue, forKey: learningLanguageKey(for: user))
    }

    private func learningLanguageKey(for user: AppUser) -> String {
        "tinghui.learningLanguage.\(user.storageKey)"
    }

    private func syncFavoriteChange(reference: FavoriteWordReference, isFavorite: Bool) {
        guard !isGuestMode,
              let accessToken = authStore.accessToken,
              let user = authStore.currentUser else {
            return
        }

        Task {
            if isFavorite {
                try? await SupabaseClient.shared.upsertFavorite(
                    accessToken: accessToken,
                    userId: user.id,
                    reference: reference
                )
            } else {
                try? await SupabaseClient.shared.deleteFavorite(
                    accessToken: accessToken,
                    userId: user.id,
                    reference: reference
                )
            }
        }
    }

    private func syncRemoteFavorites(user: AppUser, accessToken: String) async {
        guard let remoteRefs = try? await SupabaseClient.shared.fetchFavorites(
            accessToken: accessToken,
            userId: user.id
        ) else {
            return
        }

        let merged = Array(Set(favoriteRefs).union(remoteRefs))
            .sorted { "\($0.bookId)-\($0.wordId)" < "\($1.bookId)-\($1.wordId)" }
        favoriteRefs = merged
        FavoriteWordStore.save(merged, for: user)

        for reference in merged {
            try? await SupabaseClient.shared.upsertFavorite(
                accessToken: accessToken,
                userId: user.id,
                reference: reference
            )
        }
    }

    private func migrateGuestData(to user: AppUser) {
        let guestRefs = FavoriteWordStore.load(for: .guest)
        if !guestRefs.isEmpty {
            let userRefs = FavoriteWordStore.load(for: user)
            FavoriteWordStore.save(Array(Set(userRefs).union(guestRefs)), for: user)
        }

        for book in books {
            guard let guestProgress = progressStore.progress(for: AppUser.guest.storageKey, bookId: book.bookId) else {
                continue
            }
            progressStore.save(username: user.storageKey, progress: guestProgress)
            if let accessToken = authStore.accessToken {
                progressStore.saveAndSync(
                    username: user.storageKey,
                    userId: user.id,
                    accessToken: accessToken,
                    bookId: book.bookId,
                    index: guestProgress.lastIndex,
                    wordCount: book.words.count
                )
            }
        }
    }

    private func deleteAccount() {
        Task {
            let didDelete = await authStore.deleteAccount()
            guard didDelete else { return }
            stopPlayback()
            selectedBook = nil
            currentIndex = 0
            currentWord = nil
            screen = .books
            hasSavedLearningLanguage = false
            authRoute = nil
            deleteSuccessMessage = "账号和云端数据已删除"
            isShowingDeleteSuccess = true
        }
    }

    private func togglePlayback() {
        if isPlaying {
            AudioPlayerManager.shared.pause()
        } else if let selectedBook, selectedBook.words.indices.contains(currentIndex), !didStartPlayback {
            startPlayback(book: selectedBook, from: currentIndex)
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

enum AuthRoute {
    case login
    case register
}

private struct PendingFavorite {
    let book: WordBook
    let word: Word
    let index: Int
}

struct FavoriteWordReference: Codable, Hashable {
    let bookId: String
    let wordId: String
}

private enum FavoriteWordStore {
    static let favoriteBookId = "favorites"
    static let favoriteBookTitle = "MY"

    static func load(for user: AppUser) -> [FavoriteWordReference] {
        guard let data = UserDefaults.standard.data(forKey: key(for: user.storageKey)),
              let refs = try? JSONDecoder().decode([FavoriteWordReference].self, from: data) else {
            return []
        }

        return refs
    }

    static func save(_ refs: [FavoriteWordReference], for user: AppUser) {
        guard let data = try? JSONEncoder().encode(refs) else { return }
        UserDefaults.standard.set(data, forKey: key(for: user.storageKey))
    }

    private static func key(for storageKey: String) -> String {
        "tinghui.favoriteWords.\(storageKey)"
    }
}

private enum AppColors {
    static let background = Color.black
    static let panel = Color(red: 0.07, green: 0.10, blue: 0.17)
    static let stroke = Color(red: 0.17, green: 0.24, blue: 0.36)
    static let muted = Color(red: 0.60, green: 0.65, blue: 0.73)
    static let track = Color(red: 0.12, green: 0.18, blue: 0.27)
}

private struct WelcomeView: View {
    let signedInUser: AppUser?
    let onContinueAsGuest: () -> Void
    let onContinueSignedIn: () -> Void
    let onLogin: () -> Void
    let onRegister: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 88)

            VStack(spacing: 16) {
                Text("听会儿")
                    .font(.system(size: 50, weight: .bold))
                    .foregroundColor(.white)

                Text("先听起来，账号只用于云端同步")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(AppColors.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            VStack(spacing: 16) {
                Button(action: onContinueAsGuest) {
                    Text("Continue Without Account")
                        .font(.system(size: 23, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 66)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                if let signedInUser {
                    Button(action: onContinueSignedIn) {
                        Text("Continue as \(signedInUser.displayName)")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .frame(maxWidth: .infinity)
                            .frame(height: 64)
                            .background(AppColors.panel)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(AppColors.stroke, lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onLogin) {
                    Text("Login")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 64)
                        .background(AppColors.panel)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(AppColors.stroke, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)

                Button(action: onRegister) {
                    Text("Register")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(AppColors.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 34)
            .padding(.top, 76)

            Spacer(minLength: 64)
        }
    }
}

private struct AuthView: View {
    let mode: AuthRoute
    let learningLanguage: LearningLanguage
    let errorMessage: String?
    let isWorking: Bool
    let onLogin: (String, String) -> Void
    let onRegister: (String, String) -> Void
    let onSwitchMode: () -> Void
    let onBack: () -> Void

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        let isRegistering = mode == .register
        let isEnglish = learningLanguage == .english

        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 24, weight: .semibold))
                        Text(isEnglish ? "Back" : "返回")
                            .font(.system(size: 22, weight: .bold))
                    }
                    .foregroundColor(AppColors.muted)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)

            Spacer(minLength: 52)

            VStack(spacing: 16) {
                Text("听会儿")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundColor(.white)

                Text(authSubtitle(isRegistering: isRegistering, isEnglish: isEnglish))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(AppColors.muted)
            }

            VStack(spacing: 18) {
                TextField(isEnglish ? "Email" : "邮箱", text: $email)
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

                SecureField(isEnglish ? "Password" : "密码", text: $password)
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
                    Text(localizedErrorMessage(errorMessage, isEnglish: isEnglish))
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
                    Text(authPrimaryButtonTitle(isRegistering: isRegistering, isWorking: isWorking, isEnglish: isEnglish))
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

                Button(action: onSwitchMode) {
                    Text(authSwitchTitle(isRegistering: isRegistering, isEnglish: isEnglish))
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
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private func authSubtitle(isRegistering: Bool, isEnglish: Bool) -> String {
        if isEnglish {
            return isRegistering ? "Create an account to save favorites" : "Sign in to save favorites"
        }

        return isRegistering ? "注册账号后收藏单词" : "登录后收藏单词"
    }

    private func authPrimaryButtonTitle(isRegistering: Bool, isWorking: Bool, isEnglish: Bool) -> String {
        if isWorking {
            return isEnglish ? "Processing..." : "处理中..."
        }

        if isEnglish {
            return isRegistering ? "Create Account and Sign In" : "Sign In"
        }

        return isRegistering ? "注册并登录" : "登录"
    }

    private func authSwitchTitle(isRegistering: Bool, isEnglish: Bool) -> String {
        if isEnglish {
            return isRegistering ? "Already have an account? Sign in" : "No account yet? Create one"
        }

        return isRegistering ? "已有账号，去登录" : "没有账号，注册一个"
    }

    private func localizedErrorMessage(_ message: String, isEnglish: Bool) -> String {
        guard isEnglish else { return message }

        switch message {
        case "请输入邮箱":
            return "Please enter a valid email address"
        case "密码至少需要6个字符":
            return "Password must be at least 6 characters"
        case "登录已过期，请重新登录后再删除账号":
            return "Your session has expired. Please sign in again before deleting your account."
        default:
            return message
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
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
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
    let isGuestMode: Bool
    let learningLanguage: LearningLanguage
    let progressText: (WordBook) -> String?
    let onProfile: () -> Void
    let onLogin: () -> Void
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

                        Text(isGuestMode ? (isEnglish ? "Guest" : "游客") : currentUser.displayName)
                            .font(.system(size: 18, weight: .bold))
                    }
                    .foregroundColor(AppColors.muted)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: isGuestMode ? onLogin : onLogout) {
                    Text(isGuestMode ? (isEnglish ? "Sign In" : "登录") : (isEnglish ? "Log Out" : "退出"))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(AppColors.muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)

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
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
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
                let isFavoriteBook = book.bookId == FavoriteWordStore.favoriteBookId
                let isDisabled = isFavoriteBook && book.words.isEmpty
                let shouldShowDisabled = isDisabled

                Button {
                    onSelect(book)
                } label: {
                    HStack(spacing: 28) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 28, weight: .medium))
                            .frame(width: 42)
                            .foregroundColor(AppColors.muted)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(title(for: book, isEnglish: isEnglish))
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(isDisabled ? AppColors.muted : .white)

                            if isFavoriteBook {
                                Text(isEnglish ? "\(book.words.count) saved words" : "已收藏 \(book.words.count) 个单词")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(AppColors.muted)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.72)
                            } else if let progressText = progressText(book) {
                                Text(progressText)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(AppColors.muted)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.72)
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
                    .opacity(shouldShowDisabled ? 0.55 : 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
    }

    private func title(for book: WordBook, isEnglish: Bool) -> String {
        if book.bookId == FavoriteWordStore.favoriteBookId {
            return isEnglish ? "My Word Book" : "我的词书"
        }

        return isEnglish ? "German \(book.title)" : "德语 \(book.title)"
    }
}

private struct ProfileSettingsView: View {
    let currentUser: AppUser
    let isGuestMode: Bool
    let learningLanguage: LearningLanguage
    let deleteErrorMessage: String?
    let deleteSuccessMessage: String?
    let isDeletingAccount: Bool
    let onBack: () -> Void
    let onLanguageChange: (LearningLanguage) -> Void
    let onLogin: () -> Void
    let onRegister: () -> Void
    let onDeleteAccount: () -> Void

    @State private var isShowingDeleteWarning = false
    @State private var isShowingFinalDeleteWarning = false

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
            }
            .padding(.horizontal, 28)
            .padding(.top, 58)

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
            .padding(.top, 42)

            VStack(alignment: .leading, spacing: 18) {
                Text(isEnglish ? "Settings" : "设置")
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

                if isGuestMode {
                    VStack(spacing: 0) {
                        SettingsActionButton(
                            title: isEnglish ? "Login to Sync" : "登录以同步",
                            subtitle: isEnglish ? "Sync favorites and progress across devices" : "跨设备同步收藏和学习记录",
                            iconName: "icloud.and.arrow.up",
                            tint: .white,
                            action: onLogin
                        )

                        Divider()
                            .background(AppColors.stroke)
                            .padding(.leading, 24)

                        SettingsActionButton(
                            title: isEnglish ? "Create Account" : "注册账号",
                            subtitle: isEnglish ? "Keep your learning data in the cloud" : "把学习数据保存到云端",
                            iconName: "person.badge.plus",
                            tint: .white,
                            action: onRegister
                        )
                    }
                    .background(AppColors.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(AppColors.stroke, lineWidth: 1.5)
                    )
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(isEnglish ? "Account" : "账号")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)

                        VStack(spacing: 0) {
                            SettingsActionButton(
                                title: isEnglish ? "Cloud Sync" : "云端同步",
                                subtitle: isEnglish ? "Favorites and progress are synced after login" : "登录后同步收藏和学习记录",
                                iconName: "checkmark.icloud",
                                tint: AppColors.muted,
                                isPassive: true,
                                action: {}
                            )
                            .disabled(true)

                            Divider()
                                .background(AppColors.stroke)
                                .padding(.leading, 24)

                            SettingsActionButton(
                                title: isEnglish ? "Delete Account" : "删除账号",
                                subtitle: isEnglish ? "Delete account and cloud learning data" : "删除账号和云端学习数据",
                                iconName: "trash",
                                tint: .red.opacity(0.9),
                                action: {
                                    isShowingDeleteWarning = true
                                }
                            )
                        }
                        .background(AppColors.panel)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(AppColors.stroke, lineWidth: 1.5)
                        )
                    }
                }

                if let deleteErrorMessage {
                    Text(deleteErrorMessage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.red.opacity(0.9))
                }

                if let deleteSuccessMessage {
                    Text(deleteSuccessMessage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.green.opacity(0.9))
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 58)

            Spacer(minLength: 32)
        }
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .alert(isEnglish ? "Delete Account?" : "删除账号？", isPresented: $isShowingDeleteWarning) {
            Button(isEnglish ? "Cancel" : "取消", role: .cancel) {}
            Button(isEnglish ? "Continue" : "继续", role: .destructive) {
                isShowingFinalDeleteWarning = true
            }
        } message: {
            Text(isEnglish ? "This will delete your cloud favorites, learning progress, profile, and login account." : "这会删除你的云端收藏、学习记录、个人资料和登录账号。")
        }
        .alert(isEnglish ? "Confirm Deletion" : "再次确认删除", isPresented: $isShowingFinalDeleteWarning) {
            Button(isEnglish ? "Cancel" : "取消", role: .cancel) {}
            Button(isDeletingAccount ? (isEnglish ? "Deleting..." : "删除中...") : (isEnglish ? "Delete Account" : "删除账号"), role: .destructive) {
                onDeleteAccount()
            }
        } message: {
            Text(isEnglish ? "This action cannot be undone." : "此操作无法撤销。")
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

private struct SettingsActionButton: View {
    let title: String
    let subtitle: String
    let iconName: String
    let tint: Color
    var isPassive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: iconName)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(isPassive ? AppColors.muted : .white)

                    Text(subtitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppColors.muted)
                        .lineLimit(2)
                }

                Spacer()

                if !isPassive {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(AppColors.muted)
                }
            }
            .padding(.horizontal, 24)
            .frame(height: 96)
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
                    .font(.system(size: 36, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.62)
                    .multilineTextAlignment(.leading)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 32)
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
    let isCurrentFavorite: Bool
    let onBack: () -> Void
    let onPrevious: () -> Void
    let onTogglePlayback: () -> Void
    let onNext: () -> Void
    let onPreviewIndex: (Int) -> Void
    let onJumpToIndex: (Int) -> Void
    let onToggleFavorite: () -> Void

    @State private var isSearchVisible = false
    @State private var searchText = ""
    @State private var isDetailVisible = false

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

    private var searchResults: [(index: Int, word: Word)] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }

        return book.words.enumerated().compactMap { index, word in
            let searchableText = [
                word.word,
                word.meaning(for: learningLanguage),
                word.exampleText(for: learningLanguage)
            ]
                .joined(separator: " ")
                .lowercased()

            return searchableText.contains(query) ? (index, word) : nil
        }
        .prefix(8)
        .map { $0 }
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
            let controlSize: CGFloat = isCompactHeight ? 52 : 64

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button(action: onBack) {
                        HStack(spacing: 14) {
                            Image(systemName: "house")
                                .font(.system(size: 24, weight: .semibold))
                            Text(isEnglish ? "Home" : "返回")
                                .font(.system(size: 22, weight: .bold))
                        }
                        .foregroundColor(AppColors.muted)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        isSearchVisible.toggle()
                        if !isSearchVisible {
                            searchText = ""
                        }
                    } label: {
                        Image(systemName: isSearchVisible ? "xmark.circle.fill" : "magnifyingglass")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundColor(AppColors.muted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, topPadding)

                if isSearchVisible {
                    SearchWordPanel(
                        searchText: $searchText,
                        results: searchResults,
                        learningLanguage: learningLanguage,
                        onPreview: { index in
                            isDetailVisible = true
                            onPreviewIndex(index)
                        },
                        onPlay: { index in
                            isDetailVisible = false
                            isSearchVisible = false
                            searchText = ""
                            onJumpToIndex(index)
                        }
                    )
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 18)
                }

                Spacer(minLength: isCompactHeight ? 18 : 42)

                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: proxy.size.width < 390 ? 8 : 12) {
                            ForEach(letterIndexes, id: \.letter) { item in
                                Button {
                                    onJumpToIndex(item.index)
                                } label: {
                                    Text(item.letter)
                                        .font(.system(size: isCompactHeight ? 14 : 16, weight: .bold))
                                        .foregroundColor(item.letter == currentLetter ? .black : AppColors.muted)
                                        .frame(width: isCompactHeight ? 30 : 34, height: isCompactHeight ? 30 : 34)
                                        .background(item.letter == currentLetter ? Color.white : AppColors.panel)
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, proxy.size.width < 390 ? 8 : 18)
                    }
                    .padding(.top, isCompactHeight ? 24 : 42)

                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .background(AppColors.track)
                        .frame(height: 6)
                        .padding(.horizontal, proxy.size.width < 390 ? 34 : 64)
                        .padding(.top, isCompactHeight ? 8 : 12)

                    Spacer(minLength: isCompactHeight ? 26 : 46)

                    VStack(spacing: isCompactHeight ? 14 : 20) {
                        HStack(spacing: 14) {
                            Spacer(minLength: 0)

                            Text(currentWord?.word ?? "")
                                .font(.system(size: isCompactHeight ? 54 : 68, weight: .regular))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.45)

                            Button(action: onToggleFavorite) {
                                Image(systemName: isCurrentFavorite ? "star.fill" : "star")
                                    .font(.system(size: isCompactHeight ? 26 : 30, weight: .semibold))
                                    .foregroundColor(isCurrentFavorite ? .yellow : AppColors.muted)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)

                            Spacer(minLength: 0)
                        }

                        Text(currentWord?.meaning(for: learningLanguage) ?? "")
                            .font(.system(size: isCompactHeight ? 26 : 32, weight: .bold))
                            .foregroundColor(AppColors.muted)
                            .lineLimit(isDetailVisible ? 4 : 2)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.65)

                        if isDetailVisible, let currentWord {
                            ScrollView {
                                DetailExampleView(
                                    word: currentWord,
                                    learningLanguage: learningLanguage,
                                    isCompactHeight: isCompactHeight
                                )
                            }
                            .frame(maxHeight: isCompactHeight ? 150 : 220)
                            .scrollIndicators(.visible)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isDetailVisible.toggle()
                    }
                    .frame(maxWidth: .infinity)

                    HStack(spacing: proxy.size.width < 390 ? 42 : 62) {
                        Button(action: onPrevious) {
                            Image(systemName: "backward.end")
                                .font(.system(size: 44, weight: .regular))
                                .foregroundColor(currentIndex == 0 ? Color.white.opacity(0.25) : Color.white.opacity(0.55))
                        }
                        .disabled(currentIndex == 0)

                        Button(action: onTogglePlayback) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: isCompactHeight ? 26 : 30, weight: .regular))
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

private struct DetailExampleView: View {
    let word: Word
    let learningLanguage: LearningLanguage
    let isCompactHeight: Bool

    var body: some View {
        let localizedExample = word.exampleText(for: learningLanguage)

        VStack(spacing: 10) {
            if let example = word.example, !example.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(example)
                    .font(.system(size: isCompactHeight ? 20 : 23, weight: .semibold))
                    .foregroundColor(.white.opacity(0.86))
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.62)
            }

            if !localizedExample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               localizedExample != word.example {
                Text(localizedExample)
                    .font(.system(size: isCompactHeight ? 19 : 22, weight: .semibold))
                    .foregroundColor(AppColors.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.62)
            }
        }
        .padding(.horizontal, 12)
    }
}

private struct SearchWordPanel: View {
    @Binding var searchText: String
    let results: [(index: Int, word: Word)]
    let learningLanguage: LearningLanguage
    let onPreview: (Int) -> Void
    let onPlay: (Int) -> Void

    var body: some View {
        let isEnglish = learningLanguage == .english

        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(AppColors.muted)

                TextField(isEnglish ? "Search word" : "搜索单词", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(AppColors.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppColors.stroke, lineWidth: 1.3)
            )

            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 0) {
                    ForEach(results, id: \.index) { result in
                        SearchResultRow(
                            index: result.index,
                            word: result.word,
                            learningLanguage: learningLanguage,
                            onPreview: {
                                onPreview(result.index)
                            },
                            onPlay: {
                                onPlay(result.index)
                            }
                        )

                        if result.index != (results.last?.index ?? -1) {
                            Divider()
                                .background(AppColors.stroke)
                                .padding(.leading, 18)
                        }
                    }
                }
                .background(AppColors.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(AppColors.stroke, lineWidth: 1.3)
                )
            }
        }
    }
}

private struct SearchResultRow: View {
    let index: Int
    let word: Word
    let learningLanguage: LearningLanguage
    let onPreview: () -> Void
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(word.word)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(word.meaning(for: learningLanguage))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppColors.muted)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 36, height: 36)
                    .background(Color.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .frame(height: 68)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPreview)
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
