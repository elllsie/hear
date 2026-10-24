import XCTest
import AVFoundation
@testable import 听会儿

final class AppPolicyTests: XCTestCase {
    func testPlaybackSpeedIsClampedToSupportedRange() {
        XCTAssertEqual(AppPolicy.clampedPlaybackSpeed(0.1), 0.5)
        XCTAssertEqual(AppPolicy.clampedPlaybackSpeed(1.25), 1.25)
        XCTAssertEqual(AppPolicy.clampedPlaybackSpeed(3.0), 2.0)
    }

    func testOnlyEnglishStudyShowsPhonetics() {
        XCTAssertTrue(AppPolicy.shouldShowPhonetic(for: .english))
        XCTAssertFalse(AppPolicy.shouldShowPhonetic(for: .german))
    }

    func testPodcastExplanationAlwaysDefaultsToChinese() {
        XCTAssertEqual(AppPolicy.podcastExplanationLanguage, .chinese)
    }

    func testRemoteWordBookRejectsEmptyAndDuplicateWordIDs() {
        XCTAssertFalse(RemoteWordBookRepository.isValid(words: []))
        let duplicate = [
            Word(id: "1", word: "hello", translation: "你好"),
            Word(id: "1", word: "world", translation: "世界")
        ]
        XCTAssertFalse(RemoteWordBookRepository.isValid(words: duplicate))
    }

    func testRemoteWordBookAcceptsValidWords() {
        let words = [
            Word(id: "1", word: "hello", translation: "你好"),
            Word(id: "2", word: "world", translation: "世界")
        ]
        XCTAssertTrue(RemoteWordBookRepository.isValid(words: words))
    }
}


final class DifficultySelectionTests: XCTestCase {
    private let ids = (0..<101).map(String.init)

    func testFiveTiersFilterAtLeastSpecifiedRatioAndNest() {
        var previous = Set(ids)
        XCTAssertEqual(WordBookRecommendation.percentages, [70, 60, 50, 40, 30])
        for percentage in WordBookRecommendation.percentages {
            var state = WordRecommendationSelection()
            state.apply(percentage, rankedIDs: ids)
            XCTAssertEqual(state.selected.count, ids.count * percentage / 100)
            XCTAssertTrue(state.selected.isSubset(of: previous))
            XCTAssertGreaterThanOrEqual(Double(ids.count - state.selected.count) / Double(ids.count), Double(100 - percentage) / 100)
            previous = state.selected
        }
    }

    func testManualAdditionsAndRemovalsSurviveTierChanges() {
        var state = WordRecommendationSelection()
        state.apply(70, rankedIDs: ids)
        state.set(["100"], selected: true)
        state.set(["0"], selected: false)
        state.apply(30, rankedIDs: ids)
        XCTAssertTrue(state.selected.contains("100"))
        XCTAssertFalse(state.selected.contains("0"))
        XCTAssertEqual(state.recommendationCount, 29)
        XCTAssertEqual(state.additionCount, 1)
        state.apply(30, rankedIDs: ids, reset: true)
        XCTAssertEqual(state.selected, Set(ids.prefix(30)))
    }

    func testSupplementalRowsRemainAfterSelectionAndUndoIncludingRemovedRecommendations() {
        var state = WordRecommendationSelection()
        state.apply(70, rankedIDs: ids)
        let initial = state.supplemental
        state.set(["100"], selected: true)
        XCTAssertEqual(state.supplemental, initial)
        state.set(["100"], selected: false)
        XCTAssertEqual(state.supplemental, initial)
        state.set(["0"], selected: false)
        XCTAssertTrue(state.supplemental.contains("0"))
        let withRemovedRecommendation = state.supplemental
        state.set(["0"], selected: true)
        XCTAssertEqual(state.supplemental, withRemovedRecommendation)
    }

    func testClearAndSearchSubsetPreserveOtherSelections() {
        var state = WordRecommendationSelection()
        state.apply(70, rankedIDs: ids)
        let searchMatches: Set<String> = ["90", "100"]
        state.set(searchMatches, selected: true)
        XCTAssertEqual(state.selected.count, 72)
        state.set(searchMatches, selected: false)
        XCTAssertEqual(state.selected, Set(ids.prefix(70)))
        state.clear()
        XCTAssertTrue(state.selected.isEmpty)
        state.set(["100"], selected: true)
        XCTAssertEqual(state.selected, ["100"])
    }

    func testFrequencyReferenceCoversBothBooksAndPrioritizesRareWords() throws {
        for name in ["KaoYan_2", "IELTS_9400"] {
            let book = try DataLoader.loadBook(named: name)
            let ranked = try XCTUnwrap(WordBookRecommendation.rankedWords(in: book))
            XCTAssertEqual(ranked.count, book.words.count)
            XCTAssertEqual(Set(ranked.map(\.id)), Set(book.words.map(\.id)))
        }
        let book = try DataLoader.loadBook(named: "KaoYan_2")
        let ranked = try XCTUnwrap(WordBookRecommendation.rankedWords(in: book))
        let rare = try XCTUnwrap(ranked.firstIndex { $0.word == "ambiguous" })
        let common = try XCTUnwrap(ranked.firstIndex { $0.word == "apple" })
        XCTAssertLessThan(rare, common)
        XCTAssertNil(WordBookRecommendation.rankedWords(in: try DataLoader.loadBook(named: "A1")))
    }
}

final class LinkedWordBookRegressionTests: XCTestCase {
    private func source(meaning: String = "原释义", prefix: String = "v2/source") -> WordBook {
        WordBook(bookId: "original", title: "Original", words: [Word(id: "1", word: "example", translation: meaning)],
                 language: .english, audioPathPrefix: prefix)
    }
    private func library() -> UserWordBookLibrary {
        UserWordBookLibrary(books: [UserWordBook(id: "personal", name: "Personal", words: [], createdAt: .distantPast)], selectedBookID: "personal")
    }

    func testAdditionSkipsDuplicatesAndEncodesOnlyReferences() throws {
        let book = source()
        var saved = library()
        XCTAssertEqual(saved.addLinkedWords(book.words + book.words, from: book, to: "personal"), 1)
        XCTAssertEqual(saved.addLinkedWords(book.words, from: book, to: "personal"), 0)
        let data = try JSONEncoder().encode(saved)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let books = try XCTUnwrap(json["books"] as? [[String: Any]])
        XCTAssertEqual((books[0]["words"] as? [Any])?.count, 0)
        XCTAssertEqual((books[0]["sourceReferences"] as? [Any])?.count, 1)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("原释义"))
        XCTAssertNil(book.words[0].sourceReference)
    }

    func testSourceUpdatesMissingReferencesAndDeletionAreSafe() throws {
        let book = source()
        var saved = library()
        saved.addLinkedWords(book.words, from: book, to: "personal")
        let encoded = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(UserWordBookLibrary.self, from: encoded)
        let missing = decoded.resolving(in: [])
        XCTAssertEqual(missing.books[0].entryCount, 1)
        XCTAssertTrue(missing.books[0].words.isEmpty)
        var restored = missing.resolving(in: [source(meaning: "更新释义", prefix: "v3/source")])
        XCTAssertEqual(restored.books[0].words[0].translation, "更新释义")
        XCTAssertEqual(restored.books[0].words[0].indexedAudioSource?.pathPrefix, "v3/source")
        restored.books[0].words.removeAll()
        XCTAssertTrue(restored.books[0].references.isEmpty)
        XCTAssertEqual(book.words.count, 1)
    }

    func testCloudCodecPreservesIndexAndSelectedBook() throws {
        let book = source()
        var saved = library()
        saved.addLinkedWords(book.words, from: book, to: "personal")
        let independent = Word(id: "custom", word: "independent", translation: "独立词")
        saved.books[0].words.append(independent)
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase; encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase; decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(UserWordBookLibrary.self, from: encoder.encode(saved)).resolving(in: [book])
        XCTAssertEqual(decoded.selectedBookID, saved.selectedBookID)
        XCTAssertEqual(decoded.books[0].references, saved.books[0].references)
        XCTAssertEqual(decoded.books[0].words.first { $0.id == "custom" }, independent)
        XCTAssertNotEqual(UserWordBookStore.cloudKey(for: .english), UserWordBookStore.legacyCloudKey(for: .english))
    }

    func testLargeSelectedBookPersistsAsCompactIndexAndRetainsLegacyBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "difficulty-regression-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
            UserWordBookStore.updateSources([])
        }
        let book = try DataLoader.loadBook(named: "IELTS_9400")
        let ranked = try XCTUnwrap(WordBookRecommendation.rankedWords(in: book))
        let selected = Array(ranked.prefix(book.words.count * 70 / 100))
        var saved = library()
        saved.addLinkedWords(selected, from: book, to: "personal")
        let legacy = Data("old snapshot".utf8)
        let legacyKey = "tinghui.userWordBooks.test.english"
        defaults.set(legacy, forKey: legacyKey)
        UserWordBookStore.updateSources([book])
        XCTAssertTrue(UserWordBookStore.save(saved, for: "test", language: .english, directory: directory))
        let data = try Data(contentsOf: UserWordBookStore.storageURL(for: "test", language: .english, directory: directory))
        XCTAssertLessThan(data.count, 1024 * 1024)
        let loaded = UserWordBookStore.load(for: "test", language: .english, directory: directory, defaults: defaults)
        XCTAssertEqual(loaded.books.last?.references.count, selected.count)
        XCTAssertEqual(loaded.books.last?.words.count, selected.count)
        XCTAssertEqual(defaults.data(forKey: legacyKey), legacy)
        XCTAssertEqual(UserWordBookStore.load(for: "other", language: .english, directory: directory, defaults: defaults), .empty)
    }

    func testLegacyIndependentWordsRemainUnlinkedAndLargeDataUsesFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "legacy-regression-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let word = Word(id: "custom", word: "independent", translation: String(repeating: "x", count: 5 * 1024 * 1024))
        var saved = library(); saved.books[0].words = [word]
        XCTAssertTrue(UserWordBookStore.save(saved, for: "large", language: .english, directory: directory))
        let loaded = UserWordBookStore.load(for: "large", language: .english, directory: directory, defaults: defaults)
        XCTAssertEqual(loaded.books.last?.words, [word])
        XCTAssertTrue(loaded.books.last?.references.isEmpty == true)
        XCTAssertNil(defaults.object(forKey: "tinghui.userWordBooks.large.english"))
    }

    func testMixedWordBooksRetainOriginalAudioURLsLanguagesAndFileNames() throws {
        let player = AudioPlayerManager.shared
        let folder = player.audioFolderName, prefix = player.wordAudioPathPrefix
        let language = player.wordAudioLanguage
        defer { player.audioFolderName = folder; player.wordAudioPathPrefix = prefix; player.wordAudioLanguage = language }
        for name in ["KaoYan_2", "IELTS_9400", "A1"] {
            let book = try DataLoader.loadBook(named: name)
            let word = try XCTUnwrap(book.words.first)
            player.audioFolderName = book.bookId; player.wordAudioPathPrefix = book.audioPathPrefix; player.wordAudioLanguage = book.language
            let original = player.wordAudioURLs(for: word).map(\.path)
            let location = player.wordAudioLocation(for: word)
            XCTAssertFalse(original.isEmpty)
            player.audioFolderName = "user-mixed"; player.wordAudioPathPrefix = nil; player.wordAudioLanguage = .german
            let linked = word.indexed(in: book)
            XCTAssertEqual(player.wordAudioURLs(for: linked).map(\.path), original)
            XCTAssertEqual(player.wordAudioLocation(for: linked).name, location.name)
            XCTAssertEqual(player.wordAudioLocation(for: linked).language, location.language)
        }
    }

    func testOnlyChineseSystemSpeechIgnoresSpeed() {
        let player = AudioPlayerManager.shared
        let rate = player.rate, playback = player.playbackRate, fileMultiplier = player.chineseMeaningFileRateMultiplier
        defer { player.rate = rate; player.playbackRate = playback }
        for speed: Float in [0.25, 0.5, 0.75] {
            player.rate = speed; player.playbackRate = 1.75
            XCTAssertEqual(player.adjustedSpeechRate(for: "zh-CN"), AVSpeechUtteranceDefaultSpeechRate)
            XCTAssertEqual(player.adjustedSpeechRate(for: "en-US"), speed)
            XCTAssertEqual(player.playbackRate, 1.75)
            XCTAssertEqual(player.chineseMeaningFileRateMultiplier, fileMultiplier)
        }
    }
}

final class LegacyFavoriteAudioTests: XCTestCase {
    func testOldDefaultAbandonUsesItsDeclaredOriginalAudioWithoutChangingContent() throws {
        let player = AudioPlayerManager.shared
        let folder = player.audioFolderName, prefix = player.wordAudioPathPrefix, language = player.wordAudioLanguage
        defer {
            player.audioFolderName = folder; player.wordAudioPathPrefix = prefix; player.wordAudioLanguage = language
            UserWordBookStore.updateSources([])
        }
        for name in ["KaoYan_2", "IELTS_9400"] {
            let book = try DataLoader.loadBook(named: name)
            let word = try XCTUnwrap(book.words.first { $0.word == "abandon" })
            var library = UserWordBookLibrary.empty
            library.books[0].words = [word]
            XCTAssertNil(word.sourceReference)
            let oldPayload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(word)) as? NSDictionary
            UserWordBookStore.updateSources([book])
            let restored = try XCTUnwrap(UserWordBookStore.resolve(library).books[0].words.first)
            XCTAssertNil(restored.sourceReference)
            XCTAssertEqual(restored.translation, word.translation)
            let newPayload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? NSDictionary
            XCTAssertEqual(oldPayload, newPayload)
            player.audioFolderName = book.bookId; player.wordAudioPathPrefix = book.audioPathPrefix; player.wordAudioLanguage = book.language
            let originalURLs = player.wordAudioURLs(for: word).map(\.path)
            player.audioFolderName = "user-default"; player.wordAudioPathPrefix = nil; player.wordAudioLanguage = .english
            XCTAssertEqual(player.wordAudioURLs(for: restored).map(\.path), originalURLs)
            XCTAssertEqual(player.wordAudioLocation(for: restored).language, "en-US")
        }
    }

    func testMissingOrConflictingLegacyProvenanceIsNeverGuessed() throws {
        let book = try DataLoader.loadBook(named: "IELTS_9400")
        let words = [
            Word(id: "3", word: "abandon", translation: "Custom"),
            Word(id: "wrong-id", word: "abandon", translation: "Custom", source: "IELTS_9400"),
            Word(id: "3", word: "different", translation: "Custom", source: "IELTS_9400"),
            Word(id: "3", word: "abandon", translation: "Custom", source: "missing-source")
        ]
        var library = UserWordBookLibrary.empty
        library.books[0].words = words
        let restored = library.resolving(in: [book])
        XCTAssertEqual(Set(restored.books[0].words.map(\.word)), Set(words.map(\.word)))
        XCTAssertEqual(restored.books[0].words.count, words.count)
        XCTAssertTrue(restored.books[0].words.allSatisfy { $0.indexedAudioSource == nil && $0.sourceReference == nil })
    }
}


final class ChineseMeaningPlaybackTests: XCTestCase {
    func testActualSystemUtteranceUsesNormalRateRegardlessOfSpeedOrLegacyMultiplier() {
        let player = AudioPlayerManager.shared
        let savedRate = player.rate, savedPlayback = player.playbackRate
        let savedMultiplier = player.chineseMeaningFallbackSpeechRateMultiplier
        defer {
            player.rate = savedRate; player.playbackRate = savedPlayback
            player.chineseMeaningFallbackSpeechRateMultiplier = savedMultiplier
        }
        player.chineseMeaningFallbackSpeechRateMultiplier = 1.5
        for speed: Float in [0.25, 0.5, 0.75] {
            player.rate = speed; player.playbackRate = 2.0
            for language in ["zh-CN", "zh-TW", "zh-HK"] {
                let utterance = player.makeSpeechUtterance(text: "放弃，抛弃", language: language)
                XCTAssertEqual(utterance.rate, AVSpeechUtteranceDefaultSpeechRate)
            }
        }
    }

    func testRecordedChineseMeaningStillUsesOnePointFiveMultiplier() {
        let player = AudioPlayerManager.shared
        let savedRate = player.playbackRate, savedMultiplier = player.chineseMeaningFileRateMultiplier
        defer { player.playbackRate = savedRate; player.chineseMeaningFileRateMultiplier = savedMultiplier }
        player.playbackRate = 1.0; player.chineseMeaningFileRateMultiplier = 1.5
        XCTAssertEqual(player.adjustedPlaybackRate(for: LearningLanguage.chinese.meaningAudioSubdirectory), 1.5)
        XCTAssertEqual(player.adjustedPlaybackRate(for: nil), 1.0)
    }
}

final class CreateWordBookDuringSelectionTests: XCTestCase {
    func testCreateWithSelectionTrimsNameDeduplicatesAndKeepsOriginalIndex() throws {
        let source = try DataLoader.loadBook(named: "IELTS_9400")
        let word = try XCTUnwrap(source.words.first).indexed(in: source)
        var library = UserWordBookLibrary.empty
        let original = library.books[0]
        let created = try XCTUnwrap(library.createWordBook(named: "  我的雅思难词\n", words: [word, word]))
        XCTAssertEqual(created.name, "我的雅思难词")
        XCTAssertEqual(created.entryCount, 1)
        XCTAssertEqual(created.references, [word.sourceReference!])
        XCTAssertEqual(library.selectedBookID, created.id)
        XCTAssertEqual(library.books[0], original)
        XCTAssertNil(source.words[0].sourceReference)
        let data = try JSONEncoder().encode(library)
        let decoded = try JSONDecoder().decode(UserWordBookLibrary.self, from: data).resolving(in: [source])
        XCTAssertEqual(decoded.books.last?.references, created.references)
        XCTAssertEqual(decoded.books.last?.words[0].indexedAudioSource, word.indexedAudioSource)
    }

    func testBlankNameDoesNotCreateOrChangeSelection() {
        var library = UserWordBookLibrary.empty
        let before = library
        XCTAssertNil(library.createWordBook(named: " \n\t ", words: []))
        XCTAssertEqual(library, before)
    }

    func testCreatesOnlySelectedIndependentPodcastWords() throws {
        let word = Word(id: "podcast-context-1", word: "Example", translation: "例子", source: "节目 · 单集")
        let duplicate = Word(id: "podcast-context-2", word: "example", translation: "例子")
        var library = UserWordBookLibrary.empty
        let first = try XCTUnwrap(library.createWordBook(named: "播客词汇", words: [word, duplicate]))
        XCTAssertEqual(first.words, [word])
        XCTAssertTrue(first.references.isEmpty)
        let second = try XCTUnwrap(library.createWordBook(named: "播客词汇", words: [word]))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(library.books.first?.entryCount, 0)
    }

    func testCreateAndSelectionSaveInOneSnapshotWhileFailureLeavesOriginalUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "create-book-selection-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let original = UserWordBookLibrary.empty
        var candidate = original
        let word = Word(id: "custom", word: "custom", translation: "自定义")
        let created = try XCTUnwrap(candidate.createWordBook(named: "刚创建的词书", words: [word]))
        // Deliberately block directory creation: a failed save must not mutate the original.
        try Data("blocking file".utf8).write(to: directory)
        XCTAssertFalse(UserWordBookStore.save(candidate, for: "test", language: .english, directory: directory))
        XCTAssertEqual(original, .empty)
        try FileManager.default.removeItem(at: directory)
        XCTAssertTrue(UserWordBookStore.save(candidate, for: "test", language: .english, directory: directory))
        let loaded = UserWordBookStore.load(for: "test", language: .english, directory: directory, defaults: defaults)
        XCTAssertEqual(loaded.selectedBookID, created.id)
        XCTAssertEqual(loaded.books.last?.words, [word])
    }
}
