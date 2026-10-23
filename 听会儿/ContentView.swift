import SwiftUI
import AVFoundation

private func storedWordIdentity(_ word: Word) -> String {
    "\(word.id)\u{1F}\(word.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
}

private struct SyncedPreferences: Codable {
    let studyLanguage: String
    let learningLanguage: String
    let playbackSpeed: Double?
    let playbackRepeatCount: Int?
}

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
    @State private var hasSavedPlaybackPreferences = false
    @State private var currentIndex: Int = 0
    @State private var currentWord: Word?
    @State private var isPlaying: Bool = false
    @State private var didStartPlayback = false
    @State private var isLoadingBooks = true
    @State private var loadErrorMessage: String?
    @State private var playbackDelegate: PlayerScreenDelegate?
    @State private var progressRefreshSeed = 0
    @State private var studyLanguage: StudyLanguage = .english
    @State private var learningLanguage: LearningLanguage = .chinese
    @State private var hasSavedLearningPreferences = false
    @State private var favoriteRefs: [FavoriteWordReference] = []
    @State private var contextWords: [Word] = []
    @State private var wordBookLibrary: UserWordBookLibrary = .empty
    @State private var previousAuthUserID: String?
    @State private var favoriteRemovalUndo: FavoriteRemovalUndo?
    @State private var favoriteUndoTask: Task<Void, Never>?
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
                        authStore.cancelAuthentication()
                        authRoute = nil
                    }
                )
            } else {
                let currentUser = activeUser
                if !hasSavedLearningPreferences {
                    LanguageSetupView { targetLanguage, baseLanguage in
                        saveLearningPreferences(
                            studyLanguage: targetLanguage,
                            explanationLanguage: baseLanguage
                        )
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
                            studyLanguage: studyLanguage,
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
                            },
                            onStudyLanguageChange: { language in
                                saveStudyLanguage(language)
                                loadContextWords()
                                loadUserWordBooks()
                                selectedBook = nil
                                currentIndex = 0
                                currentWord = nil
                            },
                            onPodcast: {
                                stopPlayback()
                                if isGuestMode {
                                    promptForFavoriteSignIn()
                                } else {
                                    screen = .podcast
                                }
                            }
                        ) { book in
                            if book.bookId == FavoriteWordStore.favoriteBookId {
                                if isGuestMode {
                                    promptForFavoriteSignIn()
                                } else {
                                    screen = .wordBooks
                                }
                                return
                            }
                            selectedBook = book
                            screen = .bookWords
                        }
                    case .bookWords:
                        if let selectedBook {
                            ReadOnlyWordBookListView(
                                book: selectedBook,
                                destinationBooks: isGuestMode ? [] : wordBookLibrary.books,
                                requiresLoginForAdding: isGuestMode,
                                learningLanguage: learningLanguage,
                                showsPhonetic: AppPolicy.shouldShowPhonetic(for: studyLanguage),
                                onBack: {
                                    self.selectedBook = nil
                                    screen = .books
                                },
                                onPlay: { word in
                                    openBuiltInBook(selectedBook, at: word)
                                },
                                onMove: { wordIDs, destinationID in
                                    addWords(wordIDs, from: selectedBook, to: destinationID)
                                },
                                onLoginRequired: promptForFavoriteSignIn
                            )
                        }
                    case .settings:
                        if let selectedBook {
                            PlaybackSettingsView(
                                book: selectedBook,
                                learningLanguage: learningLanguage,
                                speed: $speed,
                                repeatCount: $repeatCount,
                                onStart: {
                                    savePlaybackPreferences()
                                    currentWord = selectedBook.words.indices.contains(currentIndex) ? selectedBook.words[currentIndex] : selectedBook.words.first
                                    didStartPlayback = false
                                    screen = .player
                                }
                            )
                        }
                    case .player:
                        if let selectedBook {
                            if selectedBook.words.isEmpty,
                               selectedBook.bookId == FavoriteWordStore.favoriteBookId {
                                EmptyFavoritePlayerView(
                                    isEnglish: learningLanguage == .english,
                                    onBack: { screen = .books }
                                )
                            } else {
                                PlayerView(
                                    book: selectedBook,
                                    speed: speed,
                                    repeatCount: Int(repeatCount.rounded()),
                                    currentIndex: currentIndex,
                                    currentWord: currentWord ?? selectedBook.words.first,
                                    isPlaying: isPlaying,
                                    learningLanguage: learningLanguage,
                                    showsPhonetic: AppPolicy.shouldShowPhonetic(for: studyLanguage),
                                    isCurrentFavorite: isWordInDefaultBook(currentWord ?? selectedBook.words.first),
                                    requiresLoginForFavorite: isGuestMode,
                                    onBack: {
                                        saveProgress(book: selectedBook, index: currentIndex)
                                        stopPlayback()
                                        screen = books.contains(where: { $0.bookId == selectedBook.bookId })
                                            ? .bookWords
                                            : .books
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
                                            if isGuestMode {
                                                promptForFavoriteSignIn()
                                            } else {
                                                toggleWord(word, in: UserWordBookStore.defaultBookID)
                                            }
                                        }
                                    },
                                    onSavePlaybackSettings: { newSpeed, newRepeatCount in
                                        speed = newSpeed
                                        repeatCount = newRepeatCount
                                        savePlaybackPreferences()
                                        startPlayback(book: selectedBook, from: currentIndex)
                                    }
                                )
                                .onAppear {
                                    guard !didStartPlayback else { return }
                                    didStartPlayback = true
                                    startPlayback(book: selectedBook, from: currentIndex)
                                }
                            }
                        }
                    case .wordBooks:
                        UserWordBooksView(
                            library: wordBookLibrary,
                            learningLanguage: learningLanguage,
                            studyLanguage: studyLanguage,
                            onBack: { screen = .books },
                            onCreate: createUserWordBook,
                            onRename: renameUserWordBook,
                            onDelete: deleteUserWordBook,
                            onDeleteWords: deleteWords,
                            onMoveWords: moveWords,
                            onSelect: { openUserWordBook($0) },
                            onSelectWord: openUserWordBook
                        )
                    case .profile:
                        ProfileSettingsView(
                            currentUser: currentUser,
                            isGuestMode: isGuestMode,
                            studyLanguage: studyLanguage,
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
                            onStudyLanguageChange: { language in
                                saveStudyLanguage(language)
                                loadContextWords()
                                loadUserWordBooks()
                                screen = .books
                            },
                            onLogin: {
                                authRoute = .login
                            },
                            onRegister: {
                                authRoute = .register
                            },
                            onDeleteAccount: deleteAccount
                        )
                    case .podcast:
                        PodcastLearningRootView(
                            userKey: currentUser.storageKey,
                            cloudUserID: authStore.currentUser?.id,
                            studyLanguage: studyLanguage,
                            learningLanguage: AppPolicy.podcastExplanationLanguage,
                            accessTokenProvider: {
                                try? await authStore.validAccessToken()
                            }
                        ) {
                            screen = .books
                        }
                    }
                }
            }

            if let undo = favoriteRemovalUndo {
                VStack {
                    Spacer()
                    FavoriteUndoBanner(
                        word: undo.word.word,
                        isEnglish: learningLanguage == .english,
                        undo: restoreLastRemovedFavorite
                    )
                    .padding(.horizontal, 18)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .zIndex(10)
            }
        }
        // Disable keyboard avoidance before the player receives its proposed
        // size; doing this only inside PlayerView still allows one resize.
        .ignoresSafeArea(.keyboard, edges: screen == .player ? .bottom : [])
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: favoriteRemovalUndo?.id)
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
            loadPlaybackPreferences()
            loadFavorites()
            loadContextWords()
            loadUserWordBooks()
        }
        .onChange(of: authStore.currentUser?.id) { newValue in
            let oldValue = previousAuthUserID
            previousAuthUserID = newValue
            favoriteUndoTask?.cancel()
            favoriteRemovalUndo = nil
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
            loadPlaybackPreferences()
            loadFavorites()
            loadContextWords()
            loadUserWordBooks()
        }
        .onReceive(NotificationCenter.default.publisher(for: ContextWordBookStore.didChange)) { notification in
            guard notification.object as? String == ContextWordBookStore.changeKey(
                for: activeUser.storageKey,
                language: studyLanguage
            ) else { return }
            loadContextWords()
            uploadContextWords()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserWordBookStore.didChange)) { notification in
            guard notification.object as? String == UserWordBookStore.changeKey(
                for: activeUser.storageKey,
                language: studyLanguage
            ) else { return }
            wordBookLibrary = UserWordBookStore.load(for: activeUser.storageKey, language: studyLanguage)
            uploadUserWordBooks()
        }
        .task(id: "\(authStore.currentUser?.id ?? "guest")-\(books.count)") {
            await syncRemoteProgress()
            await syncUserAppState()
        }
        .onDisappear(perform: stopPlayback)
    }

    private func loadBooks() {
        guard books.isEmpty else { return }
        isLoadingBooks = true
        loadErrorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let loadedBooks = DataLoader.loadBooks(named: ["A1", "A2", "B1", "KaoYan_2", "IELTS_9400"])

            DispatchQueue.main.async {
                self.books = loadedBooks
                self.loadUserWordBooks()
                self.isLoadingBooks = false
                if loadedBooks.isEmpty {
                    self.loadErrorMessage = "没有加载到词书"
                }

                Task {
                    let mergedBooks = await RemoteWordBookRepository.mergedBooks(bundled: loadedBooks)
                    await MainActor.run {
                        guard !mergedBooks.isEmpty else { return }
                        self.books = mergedBooks
                        self.loadUserWordBooks()
                    }
                }
            }
        }
    }

    private var favoriteSignInTitle: String {
        learningLanguage == .english ? "Sign in to continue" : "登录后继续"
    }

    private var favoriteSignInMessage: String {
        learningLanguage == .english
            ? "My Word Books and Podcasts are available after you sign in. Guest users can study the built-in word books."
            : "登录后可使用我的词书和播客功能；游客可继续学习系统默认词书。"
    }

    private func displayBooks() -> [WordBook] {
        return [favoriteBook()] + books.filter(isBookForSelectedLanguage)
    }

    private func favoriteBook() -> WordBook {
        let count = wordBookLibrary.books.reduce(0) { $0 + $1.words.count }
        return WordBook(bookId: FavoriteWordStore.favoriteBookId, title: FavoriteWordStore.favoriteBookTitle, words: Array(repeating: placeholderWord, count: count))
    }

    private var placeholderWord: Word {
        Word(id: "wordbook-placeholder", word: "", translation: "")
    }

    private func loadContextWords() {
        contextWords = ContextWordBookStore.load(for: activeUser.storageKey, language: studyLanguage)
    }

    private func loadUserWordBooks() {
        var library = UserWordBookStore.load(for: activeUser.storageKey, language: studyLanguage)
        if library.books.first(where: { $0.id == UserWordBookStore.defaultBookID })?.words.isEmpty == true {
            let allowedBookIDs = Set(books.filter(isBookForSelectedLanguage).map(\.bookId))
            let legacyWords = contextWords + favoriteRefs
                .filter { allowedBookIDs.contains($0.bookId) }
                .compactMap { word(for: $0) }
            var known = Set<String>()
            let unique = legacyWords.filter { known.insert($0.word.lowercased()).inserted }
            if !unique.isEmpty, let index = library.books.firstIndex(where: { $0.id == UserWordBookStore.defaultBookID }) {
                library.books[index].words = unique
                UserWordBookStore.save(library, for: activeUser.storageKey, language: studyLanguage)
            }
        }
        wordBookLibrary = library
    }

    private func isBookForSelectedLanguage(_ book: WordBook) -> Bool {
        if let language = book.language {
            return language == studyLanguage
        }
        switch studyLanguage {
        case .english:
            return ["KaoYan_2", "IELTS_9400"].contains(book.bookId)
        case .german:
            return ["A1", "A2", "B1"].contains(book.bookId)
        }
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
        if book.bookId == FavoriteWordStore.favoriteBookId {
            AudioPlayerManager.shared.audioFolderName = studyLanguage == .english ? "KaoYan_2" : "A1"
            AudioPlayerManager.shared.wordAudioPathPrefix = nil
            AudioPlayerManager.shared.wordAudioLanguage = studyLanguage
        } else {
            AudioPlayerManager.shared.audioFolderName = book.bookId
            AudioPlayerManager.shared.wordAudioPathPrefix = book.audioPathPrefix
            AudioPlayerManager.shared.wordAudioLanguage = book.language ?? studyLanguage
        }
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
        guard let word,
              let destination = wordBookLibrary.books.first(where: { $0.id == wordBookLibrary.selectedBookID }) else { return false }
        return destination.words.contains { $0.word.caseInsensitiveCompare(word.word) == .orderedSame }
    }

    private func userWordBookIDs(containing word: Word?) -> Set<String> {
        guard let word else { return [] }
        return Set(wordBookLibrary.books.compactMap { book in
            book.words.contains { $0.word.caseInsensitiveCompare(word.word) == .orderedSame }
                ? book.id : nil
        })
    }

    private func isWordInDefaultBook(_ word: Word?) -> Bool {
        guard let word,
              let book = wordBookLibrary.books.first(where: { $0.id == UserWordBookStore.defaultBookID }) else { return false }
        return book.words.contains { $0.word.caseInsensitiveCompare(word.word) == .orderedSame }
    }

    private func toggleFavorite(word: Word, in book: WordBook) {
        toggleWord(word, in: wordBookLibrary.selectedBookID)
    }

    private func toggleWord(_ word: Word, in destinationID: String) {
        guard let index = wordBookLibrary.books.firstIndex(where: { $0.id == destinationID }) else { return }
        if let wordIndex = wordBookLibrary.books[index].words.firstIndex(where: {
            $0.word.caseInsensitiveCompare(word.word) == .orderedSame
        }) {
            wordBookLibrary.books[index].words.remove(at: wordIndex)
        } else {
            wordBookLibrary.books[index].words.append(word)
            wordBookLibrary.books[index].words.sort { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }
        }
        wordBookLibrary.selectedBookID = destinationID
        saveUserWordBooks()
    }

    private func selectUserWordBook(_ id: String) {
        guard wordBookLibrary.books.contains(where: { $0.id == id }) else { return }
        wordBookLibrary.selectedBookID = id
        saveUserWordBooks()
    }

    private func createUserWordBook(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        wordBookLibrary.books.append(UserWordBook(id: UUID().uuidString, name: trimmed, words: [], createdAt: Date()))
        saveUserWordBooks()
    }

    private func renameUserWordBook(_ id: String, _ name: String) {
        guard id != UserWordBookStore.defaultBookID,
              let index = wordBookLibrary.books.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        wordBookLibrary.books[index].name = trimmed
        saveUserWordBooks()
    }

    private func deleteUserWordBook(_ id: String) {
        guard id != UserWordBookStore.defaultBookID else { return }
        wordBookLibrary.books.removeAll { $0.id == id }
        wordBookLibrary.normalize()
        saveUserWordBooks()
    }

    private func deleteWords(_ wordIDs: Set<String>, from bookID: String) {
        guard let index = wordBookLibrary.books.firstIndex(where: { $0.id == bookID }) else { return }
        wordBookLibrary.books[index].words.removeAll { wordIDs.contains(storedWordIdentity($0)) }
        saveUserWordBooks()
    }

    private func moveWords(_ wordIDs: Set<String>, from sourceID: String, to destinationID: String) {
        guard sourceID != destinationID,
              let sourceIndex = wordBookLibrary.books.firstIndex(where: { $0.id == sourceID }),
              let destinationIndex = wordBookLibrary.books.firstIndex(where: { $0.id == destinationID }) else { return }
        let moving = wordBookLibrary.books[sourceIndex].words.filter { wordIDs.contains(storedWordIdentity($0)) }
        var known = Set(wordBookLibrary.books[destinationIndex].words.map { $0.word.lowercased() })
        wordBookLibrary.books[destinationIndex].words.append(contentsOf: moving.filter { known.insert($0.word.lowercased()).inserted })
        wordBookLibrary.books[destinationIndex].words.sort { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }
        wordBookLibrary.books[sourceIndex].words.removeAll { wordIDs.contains(storedWordIdentity($0)) }
        wordBookLibrary.selectedBookID = destinationID
        saveUserWordBooks()
    }

    @discardableResult
    private func addWords(_ wordIDs: Set<String>, from source: WordBook, to destinationID: String) -> Int {
        guard let destinationIndex = wordBookLibrary.books.firstIndex(where: { $0.id == destinationID }) else { return 0 }
        let moving = source.words.filter { wordIDs.contains(storedWordIdentity($0)) }
        var known = Set(wordBookLibrary.books[destinationIndex].words.map { $0.word.lowercased() })
        let addedWords = moving.filter {
            known.insert($0.word.lowercased()).inserted
        }
        wordBookLibrary.books[destinationIndex].words.append(contentsOf: addedWords)
        wordBookLibrary.books[destinationIndex].words.sort {
            $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending
        }
        wordBookLibrary.selectedBookID = destinationID
        saveUserWordBooks()
        return addedWords.count
    }

    private func openBuiltInBook(_ book: WordBook, at word: Word) {
        selectedBook = book
        currentIndex = book.words.firstIndex {
            storedWordIdentity($0) == storedWordIdentity(word)
        } ?? 0
        currentWord = book.words.indices.contains(currentIndex) ? book.words[currentIndex] : book.words.first
        didStartPlayback = false
        screen = hasSavedPlaybackPreferences ? .player : .settings
    }

    private func openUserWordBook(_ userBook: UserWordBook, word: Word? = nil) {
        let book = WordBook(bookId: "user-\(userBook.id)", title: userBook.name, words: userBook.words)
        selectedBook = book
        currentIndex = word.flatMap { selectedWord in
            book.words.firstIndex { storedWordIdentity($0) == storedWordIdentity(selectedWord) }
        } ?? progressStore.lastIndex(for: activeUser.storageKey, bookId: book.bookId, wordCount: book.words.count)
        currentWord = book.words.indices.contains(currentIndex) ? book.words[currentIndex] : book.words.first
        screen = book.words.isEmpty ? .wordBooks : (hasSavedPlaybackPreferences ? .player : .settings)
    }

    private func saveUserWordBooks() {
        UserWordBookStore.save(wordBookLibrary, for: activeUser.storageKey, language: studyLanguage)
    }

    private func removeFromFavoriteBook(_ word: Word) {
        let removedIndex = currentIndex
        let isContextWord = contextWords.contains {
            $0.word.caseInsensitiveCompare(word.word) == .orderedSame
        }
        let reference = favoriteRefs.first { reference in
            self.word(for: reference)?.word.caseInsensitiveCompare(word.word) == .orderedSame
        }
        let removedContextWord = isContextWord && ContextWordBookStore.remove(
            word,
            for: activeUser.storageKey,
            language: studyLanguage
        )
        if removedContextWord {
            loadContextWords()
        }
        var removedFavoriteReference = false
        if let reference, let existingIndex = favoriteRefs.firstIndex(of: reference) {
            favoriteRefs.remove(at: existingIndex)
            saveFavorites()
            syncFavoriteChange(reference: reference, isFavorite: false)
            removedFavoriteReference = true
        }
        guard removedContextWord || removedFavoriteReference else {
            return
        }

        let refreshedBook = favoriteBook()
        stopPlayback()
        selectedBook = refreshedBook
        showFavoriteUndo(.init(
            word: word,
            reference: reference,
            wasContextWord: removedContextWord,
            originalIndex: removedIndex
        ))
        guard !refreshedBook.words.isEmpty else {
            currentIndex = 0
            currentWord = nil
            return
        }

        let nextIndex = min(currentIndex, refreshedBook.words.count - 1)
        currentIndex = nextIndex
        currentWord = refreshedBook.words[nextIndex]
        startPlayback(book: refreshedBook, from: nextIndex)
    }

    private func showFavoriteUndo(_ removal: FavoriteRemovalUndo) {
        favoriteUndoTask?.cancel()
        favoriteRemovalUndo = removal
        favoriteUndoTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, favoriteRemovalUndo?.id == removal.id else { return }
            favoriteRemovalUndo = nil
        }
    }

    private func restoreLastRemovedFavorite() {
        guard let removal = favoriteRemovalUndo else { return }
        favoriteUndoTask?.cancel()
        favoriteRemovalUndo = nil

        if removal.wasContextWord {
            ContextWordBookStore.add([removal.word], for: activeUser.storageKey, language: studyLanguage)
            loadContextWords()
        }
        if let reference = removal.reference, !favoriteRefs.contains(reference) {
            favoriteRefs.append(reference)
            saveFavorites()
            syncFavoriteChange(reference: reference, isFavorite: true)
        }

        let refreshedBook = favoriteBook()
        guard screen == .player,
              selectedBook?.bookId == FavoriteWordStore.favoriteBookId,
              !refreshedBook.words.isEmpty else { return }

        let playingWordID = currentWord?.id
        let restoredIndex = refreshedBook.words.firstIndex { $0.id == playingWordID }
            ?? min(removal.originalIndex, refreshedBook.words.count - 1)
        stopPlayback()
        selectedBook = refreshedBook
        currentIndex = restoredIndex
        currentWord = refreshedBook.words[restoredIndex]
        startPlayback(book: refreshedBook, from: restoredIndex)
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
        progressStore.save(username: user.storageKey, bookId: book.bookId, index: index, wordCount: book.words.count)
        guard !isGuestMode,
              let progress = progressStore.progress(for: user.storageKey, bookId: book.bookId) else { return }
        Task {
            guard let token = try? await authStore.validAccessToken() else { return }
            try? await SupabaseClient.shared.upsertProgress(
                accessToken: token,
                userId: user.id,
                progress: progress
            )
        }
    }

    private func progressText(for book: WordBook) -> String? {
        _ = progressRefreshSeed
        guard let progress = progressStore.progress(for: activeUser.storageKey, bookId: book.bookId),
              book.words.indices.contains(progress.lastIndex) else {
            return nil
        }
        let percent = Int((Double(progress.lastIndex + 1) / Double(book.words.count) * 100).rounded())
        if learningLanguage == .english {
            return "Last: \(book.words[progress.lastIndex].word) · \(percent)%"
        }
        return "已学到 \(book.words[progress.lastIndex].word) · \(percent)%"
    }

    private func syncRemoteProgress() async {
        guard let user = authStore.currentUser, !books.isEmpty,
              let accessToken = try? await authStore.validAccessToken() else {
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
            let local = progressStore.progress(for: user.storageKey, bookId: book.bookId)
            if local == nil || remote.updatedAt > (local?.updatedAt ?? .distantPast) {
                progressStore.save(username: user.storageKey, progress: remote)
            } else if let local, local.updatedAt > remote.updatedAt {
                try? await SupabaseClient.shared.upsertProgress(
                    accessToken: accessToken,
                    userId: user.id,
                    progress: local
                )
            }
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
        hasSavedLearningPreferences = false
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

        guard let explanationRawValue = UserDefaults.standard.string(forKey: learningLanguageKey(for: user)),
              let explanationLanguage = LearningLanguage(rawValue: explanationRawValue),
              let studyRawValue = UserDefaults.standard.string(forKey: studyLanguageKey(for: user)),
              let savedStudyLanguage = StudyLanguage(rawValue: studyRawValue) else {
            studyLanguage = .english
            learningLanguage = .chinese
            hasSavedLearningPreferences = false
            return
        }

        studyLanguage = savedStudyLanguage
        learningLanguage = explanationLanguage
        hasSavedLearningPreferences = true
    }

    private func saveLearningLanguage(_ language: LearningLanguage) {
        let user = activeUser
        learningLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: learningLanguageKey(for: user))
        uploadPreferences()
    }

    private func saveStudyLanguage(_ language: StudyLanguage) {
        let user = activeUser
        studyLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: studyLanguageKey(for: user))
        if language == .english, learningLanguage != .chinese {
            learningLanguage = .chinese
            UserDefaults.standard.set(LearningLanguage.chinese.rawValue, forKey: learningLanguageKey(for: user))
        }
        uploadPreferences()
    }

    private func saveLearningPreferences(
        studyLanguage: StudyLanguage,
        explanationLanguage: LearningLanguage
    ) {
        saveStudyLanguage(studyLanguage)
        saveLearningLanguage(explanationLanguage)
        hasSavedLearningPreferences = true
    }

    private func learningLanguageKey(for user: AppUser) -> String {
        "tinghui.learningLanguage.\(user.storageKey)"
    }

    private func studyLanguageKey(for user: AppUser) -> String {
        "tinghui.studyLanguage.\(user.storageKey)"
    }

    private func loadPlaybackPreferences() {
        let defaults = UserDefaults.standard
        let speedKey = playbackSpeedKey(for: activeUser)
        let repeatKey = playbackRepeatKey(for: activeUser)

        guard defaults.object(forKey: speedKey) != nil,
              defaults.object(forKey: repeatKey) != nil else {
            speed = 1.0
            repeatCount = 2.0
            hasSavedPlaybackPreferences = false
            return
        }

        speed = AppPolicy.clampedPlaybackSpeed(defaults.double(forKey: speedKey))
        repeatCount = min(max(Double(defaults.integer(forKey: repeatKey)), 1), 5)
        hasSavedPlaybackPreferences = true
    }

    private func savePlaybackPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(speed, forKey: playbackSpeedKey(for: activeUser))
        defaults.set(Int(repeatCount.rounded()), forKey: playbackRepeatKey(for: activeUser))
        hasSavedPlaybackPreferences = true
        uploadPreferences()
    }

    private func syncUserAppState() async {
        guard let user = authStore.currentUser,
              let accessToken = try? await authStore.validAccessToken() else { return }

        for language in StudyLanguage.allCases {
            let libraryKey = UserWordBookStore.cloudKey(for: language)
            let localLibrary = UserWordBookStore.load(for: user.storageKey, language: language)
            do {
                if let remote: UserWordBookLibrary = try await SupabaseClient.shared.fetchUserState(
                    accessToken: accessToken, userId: user.id, key: libraryKey
                ) {
                    UserWordBookStore.save(remote, for: user.storageKey, language: language)
                } else if localLibrary.books.contains(where: { !$0.words.isEmpty }) || localLibrary.books.count > 1 {
                    try await SupabaseClient.shared.upsertUserState(
                        accessToken: accessToken, userId: user.id, key: libraryKey, value: localLibrary
                    )
                }
            } catch { }

            let key = "context_words_\(language.rawValue)"
            let local = ContextWordBookStore.load(for: user.storageKey, language: language)
            do {
                if let remote: [Word] = try await SupabaseClient.shared.fetchUserState(
                    accessToken: accessToken,
                    userId: user.id,
                    key: key
                ) {
                    ContextWordBookStore.replace(remote, for: user.storageKey, language: language)
                } else if !local.isEmpty {
                    try await SupabaseClient.shared.upsertUserState(
                        accessToken: accessToken,
                        userId: user.id,
                        key: key,
                        value: local
                    )
                }
            } catch {
                // Local data remains available and will be retried next launch.
            }

            let podcastKey = "podcast_words_\(language.rawValue)"
            let localPodcastWords = PodcastWordStore.localWords(userKey: user.storageKey, language: language)
            do {
                if let remotePodcastWords: [PodcastSavedWord] = try await SupabaseClient.shared.fetchUserState(
                    accessToken: accessToken,
                    userId: user.id,
                    key: podcastKey
                ) {
                    PodcastWordStore.replaceLocal(
                        remotePodcastWords.sorted { $0.savedAt > $1.savedAt },
                        userKey: user.storageKey,
                        language: language
                    )
                } else if !localPodcastWords.isEmpty {
                    try await SupabaseClient.shared.upsertUserState(
                        accessToken: accessToken,
                        userId: user.id,
                        key: podcastKey,
                        value: localPodcastWords
                    )
                }
            } catch {
                // The Podcast screen also retries this sync when it opens.
            }
        }

        do {
            if let remote: SyncedPreferences = try await SupabaseClient.shared.fetchUserState(
                accessToken: accessToken,
                userId: user.id,
                key: "preferences"
            ) {
                apply(remote, for: user)
            } else if let local = currentPreferences(for: user) {
                try await SupabaseClient.shared.upsertUserState(
                    accessToken: accessToken,
                    userId: user.id,
                    key: "preferences",
                    value: local
                )
            }
        } catch {
            // Keep local preferences when the cloud is temporarily unavailable.
        }
    }

    private func uploadContextWords() {
        guard let user = authStore.currentUser else { return }
        let language = studyLanguage
        let snapshot = ContextWordBookStore.load(for: user.storageKey, language: language)
        Task {
            guard let accessToken = try? await authStore.validAccessToken() else { return }
            try? await SupabaseClient.shared.upsertUserState(
                accessToken: accessToken,
                userId: user.id,
                key: "context_words_\(language.rawValue)",
                value: snapshot
            )
        }
    }

    private func uploadUserWordBooks() {
        guard let user = authStore.currentUser else { return }
        let language = studyLanguage
        let snapshot = UserWordBookStore.load(for: user.storageKey, language: language)
        Task {
            guard let accessToken = try? await authStore.validAccessToken() else { return }
            try? await SupabaseClient.shared.upsertUserState(
                accessToken: accessToken,
                userId: user.id,
                key: UserWordBookStore.cloudKey(for: language),
                value: snapshot
            )
        }
    }

    private func uploadPreferences() {
        guard let user = authStore.currentUser,
              let preferences = currentPreferences(for: user) else { return }
        Task {
            guard let accessToken = try? await authStore.validAccessToken() else { return }
            try? await SupabaseClient.shared.upsertUserState(
                accessToken: accessToken,
                userId: user.id,
                key: "preferences",
                value: preferences
            )
        }
    }

    private func currentPreferences(for user: AppUser) -> SyncedPreferences? {
        let defaults = UserDefaults.standard
        guard let studyRaw = defaults.string(forKey: studyLanguageKey(for: user)),
              let explanationRaw = defaults.string(forKey: learningLanguageKey(for: user)) else { return nil }
        return SyncedPreferences(
            studyLanguage: studyRaw,
            learningLanguage: explanationRaw,
            playbackSpeed: defaults.object(forKey: playbackSpeedKey(for: user)) == nil ? nil : defaults.double(forKey: playbackSpeedKey(for: user)),
            playbackRepeatCount: defaults.object(forKey: playbackRepeatKey(for: user)) == nil ? nil : defaults.integer(forKey: playbackRepeatKey(for: user))
        )
    }

    private func apply(_ preferences: SyncedPreferences, for user: AppUser) {
        let defaults = UserDefaults.standard
        defaults.set(preferences.studyLanguage, forKey: studyLanguageKey(for: user))
        defaults.set(preferences.learningLanguage, forKey: learningLanguageKey(for: user))
        if let playbackSpeed = preferences.playbackSpeed {
            defaults.set(playbackSpeed, forKey: playbackSpeedKey(for: user))
        }
        if let playbackRepeatCount = preferences.playbackRepeatCount {
            defaults.set(playbackRepeatCount, forKey: playbackRepeatKey(for: user))
        }
        loadLearningLanguage()
        loadPlaybackPreferences()
        loadContextWords()
    }

    private func playbackSpeedKey(for user: AppUser) -> String {
        "tinghui.playbackSpeed.\(user.storageKey)"
    }

    private func playbackRepeatKey(for user: AppUser) -> String {
        "tinghui.playbackRepeatCount.\(user.storageKey)"
    }

    private func syncFavoriteChange(reference: FavoriteWordReference, isFavorite: Bool) {
        guard !isGuestMode,
              let user = authStore.currentUser else {
            return
        }

        Task {
            guard let accessToken = try? await authStore.validAccessToken() else { return }
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

        favoriteRefs = remoteRefs
        FavoriteWordStore.save(remoteRefs, for: user)
    }

    private func migrateGuestData(to user: AppUser) {
        let guestRefs = FavoriteWordStore.load(for: .guest)
        if !guestRefs.isEmpty {
            let userRefs = FavoriteWordStore.load(for: user)
            FavoriteWordStore.save(Array(Set(userRefs).union(guestRefs)), for: user)
        }

        for language in StudyLanguage.allCases {
            let guestContextWords = ContextWordBookStore.load(for: AppUser.guest.storageKey, language: language)
            if !guestContextWords.isEmpty {
                ContextWordBookStore.add(guestContextWords, for: user.storageKey, language: language)
            }
            let guestLibrary = UserWordBookStore.load(for: AppUser.guest.storageKey, language: language)
            if guestLibrary.books.count > 1 || guestLibrary.books.contains(where: { !$0.words.isEmpty }) {
                UserWordBookStore.save(guestLibrary, for: user.storageKey, language: language)
            }
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
            hasSavedLearningPreferences = false
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
    case bookWords
    case wordBooks
    case settings
    case player
    case profile
    case podcast
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

private struct FavoriteRemovalUndo: Identifiable {
    let id = UUID()
    let word: Word
    let reference: FavoriteWordReference?
    let wasContextWord: Bool
    let originalIndex: Int
}

private struct FavoriteUndoBanner: View {
    let word: String
    let isEnglish: Bool
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "star.slash.fill")
                .foregroundColor(.yellow)
            Text(isEnglish ? "Removed \(word) from My Word Book" : "已从我的词书移除「\(word)」")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button(isEnglish ? "Undo" : "撤销", action: undo)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.mint)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 58)
        .background(Color(red: 0.10, green: 0.13, blue: 0.18))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.14)))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }
}

struct FavoriteWordReference: Codable, Hashable {
    let bookId: String
    let wordId: String
}

private enum FavoriteWordStore {
    static let favoriteBookId = "favorites"
    static let favoriteBookTitle = "我的词书"

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
        UserDefaults.standard.set(true, forKey: snapshotKey(for: user.storageKey))
    }

    static func hasSnapshot(for user: AppUser) -> Bool {
        UserDefaults.standard.bool(forKey: snapshotKey(for: user.storageKey)) ||
            UserDefaults.standard.data(forKey: key(for: user.storageKey)) != nil
    }

    private static func key(for storageKey: String) -> String {
        "tinghui.favoriteWords.\(storageKey)"
    }

    private static func snapshotKey(for storageKey: String) -> String {
        "tinghui.favoriteWords.hasSnapshot.\(storageKey)"
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
    let onSelect: (StudyLanguage, LearningLanguage) -> Void
    @State private var studyLanguage: StudyLanguage = .english
    @State private var explanationLanguage: LearningLanguage = .chinese

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Set up your learning")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)
                    Text("先选择学习目标，再选择你更容易理解的解释语言。")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(AppColors.muted)
                }

                LanguagePreferenceSection(
                    eyebrow: "TARGET LANGUAGE",
                    title: "学习什么？",
                    subtitle: "决定你会看到哪些内容",
                    choices: [
                        .init(id: StudyLanguage.english.rawValue, title: "English", subtitle: "Podcast + Words", icon: "headphones"),
                        .init(id: StudyLanguage.german.rawValue, title: "Deutsch", subtitle: "Podcast + Words", icon: "headphones")
                    ],
                    selectedID: studyLanguage.rawValue,
                    onSelect: { studyLanguage = StudyLanguage(rawValue: $0) ?? .english }
                )

                LanguagePreferenceSection(
                    eyebrow: "BASE LANGUAGE",
                    title: "用什么解释？",
                    subtitle: "决定释义与主要界面语言",
                    choices: [
                        .init(id: LearningLanguage.chinese.rawValue, title: "中文", subtitle: "中文释义", icon: "character.book.closed"),
                        .init(id: LearningLanguage.english.rawValue, title: "English", subtitle: "English meanings", icon: "textformat")
                    ],
                    selectedID: explanationLanguage.rawValue,
                    onSelect: { explanationLanguage = LearningLanguage(rawValue: $0) ?? .chinese }
                )

                HStack(spacing: 14) {
                    Image(systemName: studyLanguage == .english ? "headphones.circle.fill" : "book.circle.fill")
                        .font(.system(size: 34))
                        .foregroundColor(.mint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("你的学习空间")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(AppColors.muted)
                        Text(studyLanguage == .english ? "English · Podcast + Words" : "Deutsch · Podcast + Words")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Spacer()
                    Text(explanationLanguage == .chinese ? "中文解释" : "English")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white)
                        .clipShape(Capsule())
                }
                .padding(18)
                .background(AppColors.panel)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                Button {
                    onSelect(studyLanguage, explanationLanguage)
                } label: {
                    HStack {
                        Text("Continue")
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 22)
                    .frame(height: 58)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 54)
            .padding(.bottom, 44)
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }
}

private struct LanguagePreferenceChoice: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
}

private struct LanguagePreferenceSection: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let choices: [LanguagePreferenceChoice]
    let selectedID: String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(eyebrow)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.2)
                    .foregroundColor(.mint)
                Text(title).font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                Text(subtitle).font(.system(size: 15, weight: .semibold)).foregroundColor(AppColors.muted)
            }

            HStack(spacing: 12) {
                ForEach(choices) { choice in
                    let isSelected = choice.id == selectedID
                    Button { onSelect(choice.id) } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: choice.icon)
                                    .font(.system(size: 22, weight: .semibold))
                                Spacer()
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            }
                            Text(choice.title).font(.system(size: 21, weight: .bold))
                            Text(choice.subtitle)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(isSelected ? .white.opacity(0.78) : AppColors.muted)
                                .lineLimit(2)
                        }
                        .foregroundColor(.white)
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
                        .background(isSelected ? Color.blue.opacity(0.32) : AppColors.panel)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(isSelected ? Color.white : AppColors.stroke, lineWidth: isSelected ? 2 : 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct BookSelectionView: View {
    let books: [WordBook]
    let isLoading: Bool
    let errorMessage: String?
    let currentUser: AppUser
    let isGuestMode: Bool
    let studyLanguage: StudyLanguage
    let learningLanguage: LearningLanguage
    let progressText: (WordBook) -> String?
    let onProfile: () -> Void
    let onLogin: () -> Void
    let onLogout: () -> Void
    let onStudyLanguageChange: (StudyLanguage) -> Void
    let onPodcast: () -> Void
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
                    VStack(spacing: 18) {
                        Menu {
                            Button {
                                onStudyLanguageChange(.english)
                            } label: {
                                Label(
                                    isEnglish ? "English Learning" : "英语学习",
                                    systemImage: studyLanguage == .english ? "checkmark" : "character.book.closed"
                                )
                            }

                            Button {
                                onStudyLanguageChange(.german)
                            } label: {
                                Label(
                                    isEnglish ? "German Learning" : "德语学习",
                                    systemImage: studyLanguage == .german ? "checkmark" : "character.book.closed"
                                )
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Text(
                                    studyLanguage == .english
                                        ? (isEnglish ? "English Learning" : "英语学习")
                                        : (isEnglish ? "German Learning" : "德语学习")
                                )
                                    .font(.system(size: 44, weight: .bold))
                                    .minimumScaleFactor(0.75)

                                Image(systemName: "chevron.down.circle.fill")
                                    .font(.system(size: 25, weight: .semibold))
                                    .foregroundColor(AppColors.muted)
                            }
                            .foregroundColor(.white)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Text(isEnglish ? "Choose how you want to learn" : "选择今天的学习方式")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(AppColors.muted)
                    }
                    .padding(.top, 58)
                    .padding(.bottom, 52)

                    Button(action: onPodcast) {
                            HStack(spacing: 28) {
                                Image(systemName: "headphones")
                                    .font(.system(size: 28, weight: .semibold))
                                    .frame(width: 42)
                                    .foregroundColor(AppColors.muted)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(isEnglish
                                         ? "Podcast"
                                         : (studyLanguage == .german ? "德语播客" : "英语播客"))
                                        .font(.system(size: 28, weight: .bold))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.5)
                                        .allowsTightening(true)
                                    Text(isEnglish
                                         ? (studyLanguage == .german ? "Listen to German · save context words" : "Listen to English · save context words")
                                         : (studyLanguage == .german ? "听真实德语 · 收藏语境词" : "听真实英语 · 收藏语境词"))
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(AppColors.muted)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.35)
                                        .allowsTightening(true)
                                }
                                .layoutPriority(1)
                                Spacer()
                                Image(systemName: isGuestMode ? "lock.fill" : "chevron.right")
                                    .font(.system(size: 30, weight: .semibold))
                                    .frame(width: 30, height: 30)
                                    .foregroundColor(Color(red: 0.34, green: 0.40, blue: 0.50))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 34)
                            .padding(.vertical, 24)
                            .frame(minHeight: 154)
                            .background(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.42), Color.purple.opacity(0.28)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .grayscale(isGuestMode ? 1 : 0)
                            .opacity(isGuestMode ? 0.48 : 1)
                    }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)

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
                            isGuestMode: isGuestMode,
                            progressText: progressText,
                            onSelect: onSelect
                        )
                    }
                }
                .padding(.bottom, 96)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .visibleScrollIndicatorsIfAvailable()
        }
    }
}

private struct BookListView: View {
    let books: [WordBook]
    let isEnglish: Bool
    let isGuestMode: Bool
    let progressText: (WordBook) -> String?
    let onSelect: (WordBook) -> Void

    var body: some View {
        VStack(spacing: 16) {
            ForEach(books, id: \.bookId) { book in
                let isFavoriteBook = book.bookId == FavoriteWordStore.favoriteBookId
                let isDisabled = isFavoriteBook && book.words.isEmpty
                let requiresLogin = isFavoriteBook && isGuestMode
                let shouldShowDisabled = isDisabled || requiresLogin

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
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .allowsTightening(true)

                            if isFavoriteBook {
                                Text(isEnglish ? "\(book.words.count) saved words" : "已收藏 \(book.words.count) 个单词")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(AppColors.muted)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                                    .allowsTightening(true)
                            } else if let progressText = progressText(book) {
                                Text(progressText)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(AppColors.muted)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.35)
                                    .allowsTightening(true)
                            }
                        }
                        .layoutPriority(1)

                        Spacer()

                        Image(systemName: requiresLogin ? "lock.fill" : "chevron.right")
                            .font(.system(size: 30, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .foregroundColor(Color(red: 0.34, green: 0.40, blue: 0.50))
                    }
                    .padding(.horizontal, 34)
                    .padding(.vertical, 24)
                    .frame(minHeight: 154)
                    .background(AppColors.background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(AppColors.stroke, lineWidth: 2)
                    )
                    .opacity(shouldShowDisabled ? 0.55 : 1)
                    .grayscale(requiresLogin ? 1 : 0)
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

        if book.bookId == "KaoYan_2" {
            return isEnglish ? "Postgraduate English" : "考研英语"
        }

        if book.bookId == "IELTS_9400" {
            return isEnglish ? "IELTS 9400 Words" : "雅思9400词"
        }

        if book.language == .english {
            return book.title
        }
        return isEnglish ? "German \(book.title)" : "德语 \(book.title)"
    }
}

private struct ProfileSettingsView: View {
    let currentUser: AppUser
    let isGuestMode: Bool
    let studyLanguage: StudyLanguage
    let learningLanguage: LearningLanguage
    let deleteErrorMessage: String?
    let deleteSuccessMessage: String?
    let isDeletingAccount: Bool
    let onBack: () -> Void
    let onLanguageChange: (LearningLanguage) -> Void
    let onStudyLanguageChange: (StudyLanguage) -> Void
    let onLogin: () -> Void
    let onRegister: () -> Void
    let onDeleteAccount: () -> Void

    @State private var isShowingDeleteWarning = false
    @State private var isShowingFinalDeleteWarning = false

    var body: some View {
        let isEnglish = learningLanguage == .english

        ScrollView {
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

                Text(isEnglish ? "Target language" : "学习目标")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(AppColors.muted)
                    .padding(.horizontal, 6)

                VStack(spacing: 0) {
                    SettingsLanguageButton(
                        title: "English",
                        subtitle: isEnglish ? "Podcasts and English words" : "Podcast 与英语单词",
                        isSelected: studyLanguage == .english,
                        action: { onStudyLanguageChange(.english) }
                    )

                    Divider().background(AppColors.stroke).padding(.leading, 24)

                    SettingsLanguageButton(
                        title: "Deutsch",
                        subtitle: isEnglish ? "German word learning" : "德语单词学习",
                        isSelected: studyLanguage == .german,
                        action: { onStudyLanguageChange(.german) }
                    )
                }
                .background(AppColors.panel)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppColors.stroke, lineWidth: 1.5))

                Text(isEnglish ? "Explanation language" : "解释语言")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(AppColors.muted)
                    .padding(.horizontal, 6)

                VStack(spacing: 0) {
                    SettingsLanguageButton(
                        title: "English",
                        subtitle: isEnglish ? "English meanings and interface" : "英文释义和英文界面",
                        isSelected: learningLanguage == .english,
                        action: {
                            onLanguageChange(.english)
                        }
                    )

                    Divider()
                        .background(AppColors.stroke)
                        .padding(.leading, 24)

                    SettingsLanguageButton(
                        title: "中文",
                        subtitle: isEnglish ? "Chinese meanings and interface" : "中文释义和中文界面",
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
        }
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
                    range: 0.5...2.0,
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

private func normalizedWordSearchText(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
}

/// Prefer matches in the word spelling. Meaning matches are useful for reverse
/// lookup, but mixing them into a successful spelling search makes unrelated
/// initial letters appear before the word the user typed.
private func prioritizedWordSearch(in words: [Word], query rawQuery: String) -> [Word] {
    let query = normalizedWordSearchText(rawQuery)
    guard !query.isEmpty else { return words }

    let spellingMatches = words.filter {
        normalizedWordSearchText($0.word).contains(query)
    }
    if !spellingMatches.isEmpty {
        return spellingMatches.sorted { lhs, rhs in
            let left = normalizedWordSearchText(lhs.word)
            let right = normalizedWordSearchText(rhs.word)
            let leftExact = left == query
            let rightExact = right == query
            if leftExact != rightExact { return leftExact }
            let leftPrefix = left.hasPrefix(query)
            let rightPrefix = right.hasPrefix(query)
            if leftPrefix != rightPrefix { return leftPrefix }
            return lhs.word.localizedCaseInsensitiveCompare(rhs.word) == .orderedAscending
        }
    }

    return words.filter { word in
        [word.translation, word.meaningZh ?? "", word.meaningEn ?? ""]
            .contains { normalizedWordSearchText($0).contains(query) }
    }
}

private struct ReadOnlyWordBookListView: View {
    let book: WordBook
    let destinationBooks: [UserWordBook]
    let requiresLoginForAdding: Bool
    let learningLanguage: LearningLanguage
    let showsPhonetic: Bool
    let onBack: () -> Void
    let onPlay: (Word) -> Void
    let onMove: (Set<String>, String) -> Int
    let onLoginRequired: () -> Void
    @State private var selectedIDs = Set<String>()
    @State private var isSelecting = false
    @State private var isShowingMoveTargets = false
    @State private var addResultMessage: String?
    @State private var searchText = ""

    private var visibleWords: [Word] {
        prioritizedWordSearch(in: book.words, query: searchText)
    }

    private var visibleWordIDs: Set<String> {
        Set(visibleWords.map(storedWordIdentity))
    }

    private var allVisibleWordsSelected: Bool {
        !visibleWordIDs.isEmpty && visibleWordIDs.isSubset(of: selectedIDs)
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(visibleWords.map { (id: storedWordIdentity($0), word: $0) }, id: \.id) { row in
                    let word = row.word
                    Button {
                        let identity = storedWordIdentity(word)
                        if isSelecting {
                            if selectedIDs.contains(identity) { selectedIDs.remove(identity) }
                            else { selectedIDs.insert(identity) }
                        } else {
                            onPlay(word)
                        }
                    } label: {
                        UserWordSelectionRow(
                            word: word,
                            learningLanguage: learningLanguage,
                            showsPhonetic: showsPhonetic,
                            isSelecting: isSelecting,
                            isSelected: selectedIDs.contains(storedWordIdentity(word))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(book.title)
            .searchable(text: $searchText, prompt: learningLanguage == .english ? "Search words" : "搜索单词")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(learningLanguage == .english ? "Back" : "返回", action: onBack)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isSelecting ? (learningLanguage == .english ? "Done" : "完成") : (learningLanguage == .english ? "Select" : "选择")) {
                        isSelecting.toggle()
                        if !isSelecting { selectedIDs.removeAll() }
                    }
                    .disabled(book.words.isEmpty)
                }
            }
            .overlay(alignment: .bottom) {
                if isSelecting {
                    WordSelectionActionBar(
                        allSelected: allVisibleWordsSelected,
                        canMove: !selectedIDs.isEmpty && (requiresLoginForAdding || !destinationBooks.isEmpty),
                        canDelete: false,
                        showsDelete: false,
                        isMoveRestricted: requiresLoginForAdding,
                        moveTitle: learningLanguage == .english ? "Add to Word Book" : "加入词书",
                        onSelectAll: {
                            if allVisibleWordsSelected {
                                selectedIDs.subtract(visibleWordIDs)
                            } else {
                                selectedIDs.formUnion(visibleWordIDs)
                            }
                        },
                        onMove: {
                            if requiresLoginForAdding {
                                onLoginRequired()
                            } else {
                                isShowingMoveTargets = true
                            }
                        },
                        onDelete: {}
                    )
                }
            }
            .confirmationDialog(
                learningLanguage == .english ? "Add to a word book" : "加入词书",
                isPresented: $isShowingMoveTargets
            ) {
                ForEach(destinationBooks) { destination in
                    Button(destination.name) {
                        let selectedCount = selectedIDs.count
                        let addedCount = onMove(selectedIDs, destination.id)
                        let skippedCount = max(0, selectedCount - addedCount)
                        if learningLanguage == .english {
                            addResultMessage = skippedCount == 0
                                ? "Added \(addedCount) words to \(destination.name)."
                                : "Added \(addedCount) words to \(destination.name); \(skippedCount) already existed."
                        } else {
                            addResultMessage = skippedCount == 0
                                ? "已将 \(addedCount) 个单词加入“\(destination.name)”。"
                                : "已加入 \(addedCount) 个，跳过 \(skippedCount) 个已存在的单词。"
                        }
                        selectedIDs.removeAll()
                        isSelecting = false
                    }
                }
                Button(learningLanguage == .english ? "Cancel" : "取消", role: .cancel) {}
            } message: {
                Text(learningLanguage == .english
                     ? "System word books are read-only. Selected words will be added to your word book."
                     : "系统词书为只读，所选单词会加入目标个人词书。")
            }
            .alert(learningLanguage == .english ? "Add Complete" : "加入完成", isPresented: Binding(
                get: { addResultMessage != nil },
                set: { if !$0 { addResultMessage = nil } }
            )) {
                Button(learningLanguage == .english ? "OK" : "好") { addResultMessage = nil }
            } message: {
                Text(addResultMessage ?? "")
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct UserWordBooksView: View {
    let library: UserWordBookLibrary
    let learningLanguage: LearningLanguage
    let studyLanguage: StudyLanguage
    let onBack: () -> Void
    let onCreate: (String) -> Void
    let onRename: (String, String) -> Void
    let onDelete: (String) -> Void
    let onDeleteWords: (Set<String>, String) -> Void
    let onMoveWords: (Set<String>, String, String) -> Void
    let onSelect: (UserWordBook) -> Void
    let onSelectWord: (UserWordBook, Word?) -> Void
    @State private var editingBook: UserWordBook?
    @State private var draftName = ""
    @State private var isCreating = false
    @State private var searchText = ""

    private var searchResults: [(book: UserWordBook, word: Word)] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return library.books.flatMap { book in
            book.words.filter {
                [$0.word, $0.translation, $0.meaningZh ?? "", $0.meaningEn ?? ""]
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }.map { (book, $0) }
        }
    }

    var body: some View {
        NavigationView {
            List {
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section(learningLanguage == .english ? "Search Results" : "搜索结果") {
                        if searchResults.isEmpty {
                            Text(learningLanguage == .english ? "No matching words" : "没有找到匹配单词")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(Array(searchResults.enumerated()), id: \.offset) { _, result in
                                Button { onSelectWord(result.book, result.word) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(result.word.word).font(.headline).foregroundColor(.primary)
                                            Text(result.word.meaning(for: learningLanguage))
                                                .font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        Text(result.book.name).font(.caption.bold()).foregroundColor(.mint)
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    ForEach(library.books) { book in
                        NavigationLink {
                            UserWordBookDetailView(
                                book: book,
                                allBooks: library.books,
                                learningLanguage: learningLanguage,
                                showsPhonetic: AppPolicy.shouldShowPhonetic(for: studyLanguage),
                                onPlay: { onSelectWord(book, $0) },
                                onDelete: { onDeleteWords($0, book.id) },
                                onMove: { ids, destinationID in onMoveWords(ids, book.id, destinationID) }
                            )
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: book.id == UserWordBookStore.defaultBookID ? "book.closed.fill" : "book.closed")
                                    .foregroundColor(.mint)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(book.name).font(.headline).foregroundColor(.primary)
                                    Text("\(book.words.count) \(learningLanguage == .english ? "words" : "个单词")")
                                        .font(.subheadline).foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if book.id != UserWordBookStore.defaultBookID {
                                Button(role: .destructive) { onDelete(book.id) } label: { Label("删除", systemImage: "trash") }
                                Button {
                                    draftName = book.name
                                    editingBook = book
                                } label: { Label("重命名", systemImage: "pencil") }
                                    .tint(.blue)
                            }
                        }
                        .contextMenu {
                            if book.id != UserWordBookStore.defaultBookID {
                                Button("重命名") { draftName = book.name; editingBook = book }
                                Button("删除", role: .destructive) { onDelete(book.id) }
                            }
                        }
                    }
                } header: {
                    Text(learningLanguage == .english ? "My Word Books" : "我的词书")
                } footer: {
                    Text(learningLanguage == .english ? "The Default book cannot be renamed or deleted." : "“默认”词书不能重命名或删除。")
                }
            }
            .navigationTitle(learningLanguage == .english ? "My Word Books" : "我的词书")
            .searchable(text: $searchText, prompt: learningLanguage == .english ? "Search saved words" : "搜索词书中的单词")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button(learningLanguage == .english ? "Back" : "返回", action: onBack) }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { draftName = ""; isCreating = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .navigationViewStyle(.stack)
        .alert(learningLanguage == .english ? "New Word Book" : "新增词书", isPresented: $isCreating) {
            TextField(learningLanguage == .english ? "Name" : "词书名称", text: $draftName)
            Button(learningLanguage == .english ? "Create" : "新增") { onCreate(draftName) }
            Button(learningLanguage == .english ? "Cancel" : "取消", role: .cancel) {}
        }
        .alert(learningLanguage == .english ? "Rename Word Book" : "重命名词书", isPresented: Binding(
            get: { editingBook != nil }, set: { if !$0 { editingBook = nil } }
        )) {
            TextField(learningLanguage == .english ? "Name" : "词书名称", text: $draftName)
            Button(learningLanguage == .english ? "Save" : "保存") {
                if let book = editingBook { onRename(book.id, draftName) }
                editingBook = nil
            }
            Button(learningLanguage == .english ? "Cancel" : "取消", role: .cancel) { editingBook = nil }
        }
    }
}

private struct UserWordBookDetailView: View {
    let book: UserWordBook
    let allBooks: [UserWordBook]
    let learningLanguage: LearningLanguage
    let showsPhonetic: Bool
    let onPlay: (Word) -> Void
    let onDelete: (Set<String>) -> Void
    let onMove: (Set<String>, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs = Set<String>()
    @State private var isSelecting = false
    @State private var isShowingMoveTargets = false
    @State private var isConfirmingDelete = false
    @State private var searchText = ""

    private var visibleWords: [Word] {
        prioritizedWordSearch(in: book.words, query: searchText)
    }

    private var visibleWordIDs: Set<String> {
        Set(visibleWords.map(storedWordIdentity))
    }

    private var allVisibleWordsSelected: Bool {
        !visibleWordIDs.isEmpty && visibleWordIDs.isSubset(of: selectedIDs)
    }

    var body: some View {
        List {
            if book.words.isEmpty {
                Text(learningLanguage == .english ? "No words yet" : "这个词书还没有单词")
                    .foregroundColor(.secondary)
            } else {
                ForEach(visibleWords.map { (id: storedWordIdentity($0), word: $0) }, id: \.id) { row in
                    let word = row.word
                    Button {
                        let identity = storedWordIdentity(word)
                        if isSelecting {
                            if selectedIDs.contains(identity) { selectedIDs.remove(identity) }
                            else { selectedIDs.insert(identity) }
                        } else {
                            onPlay(word)
                        }
                    } label: {
                        UserWordSelectionRow(
                            word: word,
                            learningLanguage: learningLanguage,
                            showsPhonetic: showsPhonetic,
                            isSelecting: isSelecting,
                            isSelected: selectedIDs.contains(storedWordIdentity(word))
                        )
                    }
                }
            }
        }
        .navigationTitle(book.name)
        .searchable(text: $searchText, prompt: learningLanguage == .english ? "Search words" : "搜索单词")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isSelecting ? (learningLanguage == .english ? "Done" : "完成") : (learningLanguage == .english ? "Select" : "选择")) {
                    isSelecting.toggle()
                    if !isSelecting { selectedIDs.removeAll() }
                }
                .disabled(book.words.isEmpty)
            }
        }
        .overlay(alignment: .bottom) {
            if isSelecting {
                WordSelectionActionBar(
                    allSelected: allVisibleWordsSelected,
                    canMove: !selectedIDs.isEmpty && allBooks.count > 1,
                    canDelete: !selectedIDs.isEmpty,
                    onSelectAll: {
                        if allVisibleWordsSelected {
                            selectedIDs.subtract(visibleWordIDs)
                        } else {
                            selectedIDs.formUnion(visibleWordIDs)
                        }
                    },
                    onMove: { isShowingMoveTargets = true },
                    onDelete: { isConfirmingDelete = true }
                )
            }
        }
        .confirmationDialog("移动到其他词书", isPresented: $isShowingMoveTargets) {
            ForEach(allBooks.filter { $0.id != book.id }) { destination in
                Button(destination.name) {
                    onMove(selectedIDs, destination.id)
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("删除所选单词？", isPresented: $isConfirmingDelete) {
            Button("删除", role: .destructive) {
                onDelete(selectedIDs)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从“\(book.name)”中删除 \(selectedIDs.count) 个单词。")
        }
    }
}

private struct UserWordSelectionRow: View {
    let word: Word
    let learningLanguage: LearningLanguage
    let showsPhonetic: Bool
    let isSelecting: Bool
    let isSelected: Bool

    private var phoneticText: String? {
        guard showsPhonetic,
              let value = word.phonetic?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value.hasPrefix("/") || value.hasPrefix("[") ? value : "/\(value)/"
    }

    var body: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? .mint : .secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(word.word)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if let phoneticText {
                        Text(phoneticText)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.mint)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(word.meaning(for: learningLanguage))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if !isSelecting {
                Image(systemName: "play.circle").foregroundColor(.mint)
            }
        }
    }
}

private struct WordSelectionActionBar: View {
    let allSelected: Bool
    let canMove: Bool
    let canDelete: Bool
    var showsDelete = true
    var isMoveRestricted = false
    var moveTitle = "移动"
    let onSelectAll: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(allSelected ? "取消全选" : "全选", action: onSelectAll)
            Spacer()
            Button(action: onMove) {
                HStack(spacing: 5) {
                    if isMoveRestricted { Image(systemName: "lock.fill") }
                    Text(moveTitle)
                }
                .foregroundColor(isMoveRestricted ? .secondary : .accentColor)
            }
            .disabled(!canMove)
            if showsDelete {
                Spacer()
                Button("删除", role: .destructive, action: onDelete).disabled(!canDelete)
            }
        }
        .font(.headline)
        .padding(.horizontal, 24)
        .frame(height: 58)
        .background(.ultraThinMaterial)
    }
}

private struct EmptyFavoritePlayerView: View {
    let isEnglish: Bool
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "star.slash")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(AppColors.muted)
            Text(isEnglish ? "My Word Book is empty" : "我的词书暂时没有单词")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
            Text(isEnglish ? "Use Undo below to restore the last word." : "可以点击下方“撤销”恢复刚才的单词。")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppColors.muted)
                .multilineTextAlignment(.center)
            Button(isEnglish ? "Back to word books" : "返回词书", action: onBack)
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundColor(.black)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.background.ignoresSafeArea())
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
    let showsPhonetic: Bool
    let isCurrentFavorite: Bool
    let requiresLoginForFavorite: Bool
    let onBack: () -> Void
    let onPrevious: () -> Void
    let onTogglePlayback: () -> Void
    let onNext: () -> Void
    let onPreviewIndex: (Int) -> Void
    let onJumpToIndex: (Int) -> Void
    let onToggleFavorite: () -> Void
    let onSavePlaybackSettings: (Double, Double) -> Void

    @State private var isSearchVisible = false
    @State private var searchText = ""
    @State private var isExampleVisible = false
    @State private var isPlaybackSettingsVisible = false
    @State private var draftSpeed: Double = 1.0
    @State private var draftRepeatCount: Double = 2.0

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
        let query = normalizedSearchText(searchText)
        guard !query.isEmpty else { return [] }

        let matches = book.words.enumerated().compactMap { index, word -> (index: Int, word: Word, wordMatch: Bool, startsWithQuery: Bool)? in
            let normalizedWord = normalizedSearchText(word.word)
            let searchableText = [
                word.word,
                word.meaning(for: learningLanguage),
                word.exampleText(for: learningLanguage)
            ]
                .joined(separator: " ")

            guard normalizedSearchText(searchableText).contains(query) else { return nil }
            return (index, word, normalizedWord.contains(query), normalizedWord.hasPrefix(query))
        }
        let wordMatches = matches.filter(\.wordMatch)
        let preferredMatches = wordMatches.isEmpty ? matches : wordMatches

        return preferredMatches
        .sorted { lhs, rhs in
            if lhs.startsWithQuery != rhs.startsWithQuery { return lhs.startsWithQuery }
            return lhs.word.word.localizedCaseInsensitiveCompare(rhs.word.word) == .orderedAscending
        }
        .prefix(20)
        .map { (index: $0.index, word: $0.word) }
    }

    private func normalizedSearchText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
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
                        showsPhonetic: !["A1", "A2", "B1"].contains(book.bookId),
                        maxResultsHeight: isCompactHeight ? 170 : 280,
                        onPreview: { index in
                            onPreviewIndex(index)
                        },
                        onPlay: { index in
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
                                    .foregroundColor(requiresLoginForFavorite ? Color.gray.opacity(0.55) : (isCurrentFavorite ? .yellow : AppColors.muted))
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(requiresLoginForFavorite ? (isEnglish ? "Sign in to save words" : "登录后收藏单词") : (isEnglish ? "Save word" : "收藏单词"))

                            Spacer(minLength: 0)
                        }

                        if showsPhonetic,
                           let value = currentWord?.phonetic?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !value.isEmpty {
                            Text(value.hasPrefix("/") || value.hasPrefix("[") ? value : "/\(value)/")
                                .font(.system(size: isCompactHeight ? 15 : 17, weight: .medium, design: .rounded))
                                .foregroundColor(.mint)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }

                        ScrollView(.vertical, showsIndicators: true) {
                            Text(currentWord?.meaning(for: learningLanguage) ?? "")
                                .font(.system(size: isCompactHeight ? 26 : 32, weight: .bold))
                                .foregroundColor(AppColors.muted)
                                .lineLimit(nil)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .minimumScaleFactor(0.65)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: isExampleVisible
                            ? (isCompactHeight ? 105 : 160)
                            : (isCompactHeight ? 190 : 270))
                        .visibleScrollIndicatorsIfAvailable()

                        if isExampleVisible, let currentWord {
                            ScrollView(.vertical, showsIndicators: true) {
                                DetailExampleView(
                                    word: currentWord,
                                    learningLanguage: learningLanguage,
                                    isCompactHeight: isCompactHeight
                                )
                            }
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: isCompactHeight ? 90 : 130)
                            .visibleScrollIndicatorsIfAvailable()
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExampleVisible.toggle()
                        }
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

                    Button {
                        draftSpeed = speed
                        draftRepeatCount = Double(repeatCount)
                        isPlaybackSettingsVisible = true
                    } label: {
                        HStack(spacing: 10) {
                            Text(isEnglish ? String(format: "Speed: %.1fx · Repeats: %d", speed, repeatCount) : String(format: "语速: %.1fx · 重复: %d次", speed, repeatCount))
                            Image(systemName: "slider.horizontal.3")
                        }
                        .font(.system(size: isCompactHeight ? 22 : 26, weight: .bold))
                        .foregroundColor(AppColors.muted)
                    }
                    .buttonStyle(.plain)
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
        // Keep the player geometry stable while the search keyboard is shown.
        // Otherwise the reduced safe area switches the whole screen into its
        // compact-height layout and makes the search field jump upward.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(isPresented: $isPlaybackSettingsVisible) {
            PlaybackSettingsEditor(
                learningLanguage: learningLanguage,
                speed: $draftSpeed,
                repeatCount: $draftRepeatCount,
                onCancel: { isPlaybackSettingsVisible = false },
                onSave: {
                    onSavePlaybackSettings(draftSpeed, draftRepeatCount)
                    isPlaybackSettingsVisible = false
                }
            )
        }
    }
}

private struct PlaybackSettingsEditor: View {
    let learningLanguage: LearningLanguage
    @Binding var speed: Double
    @Binding var repeatCount: Double
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        let isEnglish = learningLanguage == .english

        NavigationView {
            VStack(spacing: 42) {
                SettingSlider(
                    title: isEnglish ? "Speed" : "语速",
                    valueText: String(format: "%.1fx", speed),
                    value: $speed,
                    range: 0.5...2.0,
                    step: 0.1
                )

                SettingSlider(
                    title: isEnglish ? "Repeats" : "重复次数",
                    valueText: isEnglish ? "\(Int(repeatCount.rounded()))x" : "\(Int(repeatCount.rounded()))次",
                    value: $repeatCount,
                    range: 1...5,
                    step: 1
                )

                Spacer()
            }
            .padding(32)
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle(isEnglish ? "Playback Settings" : "播放设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEnglish ? "Cancel" : "取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEnglish ? "Save" : "保存", action: onSave)
                        .font(.system(size: 17, weight: .bold))
                }
            }
        }
        .preferredColorScheme(.dark)
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
    let showsPhonetic: Bool
    let maxResultsHeight: CGFloat
    let onPreview: (Int) -> Void
    let onPlay: (Int) -> Void
    @FocusState private var isSearchFocused: Bool

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
                    .focused($isSearchFocused)
                    .submitLabel(.search)
                    .onSubmit {
                        if let first = results.first { onPlay(first.index) }
                    }
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(AppColors.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isEnglish ? "Clear search" : "清空搜索")
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(AppColors.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppColors.stroke, lineWidth: 1.3)
            )

            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Group {
                    if results.isEmpty {
                        Text(isEnglish ? "No matching words" : "没有找到匹配的单词")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(AppColors.muted)
                            .frame(maxWidth: .infinity)
                            .frame(height: 68)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(results, id: \.index) { result in
                                    SearchResultRow(
                                        index: result.index,
                                        word: result.word,
                                        learningLanguage: learningLanguage,
                                        showsPhonetic: showsPhonetic,
                                        onPreview: { onPreview(result.index) },
                                        onPlay: { onPlay(result.index) }
                                    )

                                    if result.index != (results.last?.index ?? -1) {
                                        Divider()
                                            .background(AppColors.stroke)
                                            .padding(.leading, 18)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: maxResultsHeight)
                    }
                }
                .background(AppColors.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(AppColors.stroke, lineWidth: 1.3)
                )
            }
        }
        .onAppear { isSearchFocused = true }
    }
}

private struct SearchResultRow: View {
    let index: Int
    let word: Word
    let learningLanguage: LearningLanguage
    let showsPhonetic: Bool
    let onPreview: () -> Void
    let onPlay: () -> Void

    private var phoneticText: String? {
        guard showsPhonetic,
              let value = word.phonetic?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value.hasPrefix("/") || value.hasPrefix("[") ? value : "/\(value)/"
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(word.word)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if let phoneticText {
                        Text(phoneticText)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(.mint)
                            .lineLimit(2)
                    }
                }

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

private extension View {
    @ViewBuilder
    func visibleScrollIndicatorsIfAvailable() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollIndicators(.visible)
        } else {
            self
        }
    }
}

#Preview {
    ContentView()
}
