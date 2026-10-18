import Foundation

public enum StudyLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case english
    case german

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .english: return "English"
        case .german: return "Deutsch"
        }
    }

    public var translationLanguageCode: String {
        switch self {
        case .english: return "en"
        case .german: return "de"
        }
    }
}

// Model representing a single word entry
public struct Word: Codable, Equatable {
    public let id: String
    public let word: String
    public let translation: String
    public let phonetic: String?
    public let example: String?
    public let exampleZh: String?
    public let exampleEn: String?
    public let audioFileName: String?

    public let article: String? // Additional field
    public let meaningZh: String? // Additional field
    public let meaningEn: String? // Additional field
    public let source: String? // Additional field for some datasets

    private enum CodingKeys: String, CodingKey {
        case id
        case word = "text" // Map JSON 'text' to 'word'
        case translation = "meaning" // Map JSON 'meaning' to 'translation'
        case phonetic
        case example
        case exampleZh
        case exampleEn
        case audioFileName
        case article
        case meaningZh
        case meaningEn
        case source
    }

    public init(
        id: String,
        word: String,
        translation: String,
        phonetic: String? = nil,
        example: String? = nil,
        exampleZh: String? = nil,
        exampleEn: String? = nil,
        audioFileName: String? = nil,
        article: String? = nil,
        meaningZh: String? = nil,
        meaningEn: String? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.word = word
        self.translation = translation
        self.phonetic = phonetic
        self.example = example
        self.exampleZh = exampleZh
        self.exampleEn = exampleEn
        self.audioFileName = audioFileName
        self.article = article
        self.meaningZh = meaningZh
        self.meaningEn = meaningEn
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let id = try? container.decode(String.self, forKey: .id) {
            self.id = id
        } else if let id = try? container.decode(Int.self, forKey: .id) {
            self.id = String(id)
        } else {
            self.id = ""
        }

        self.word = try container.decode(String.self, forKey: .word)
        self.translation = try container.decode(String.self, forKey: .translation)
        self.phonetic = try container.decodeIfPresent(String.self, forKey: .phonetic)
        self.example = try container.decodeIfPresent(String.self, forKey: .example)
        self.exampleZh = try container.decodeIfPresent(String.self, forKey: .exampleZh)
        self.exampleEn = try container.decodeIfPresent(String.self, forKey: .exampleEn)
        self.audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName)
        self.article = try container.decodeIfPresent(String.self, forKey: .article)
        self.meaningZh = try container.decodeIfPresent(String.self, forKey: .meaningZh)
        self.meaningEn = try container.decodeIfPresent(String.self, forKey: .meaningEn)
        self.source = try container.decodeIfPresent(String.self, forKey: .source)
    }
}

enum ContextWordBookStore {
    static let didChange = Notification.Name("tinghui.contextWordBook.didChange")

    static func load(for userKey: String, language: StudyLanguage = .english) -> [Word] {
        let defaults = UserDefaults.standard
        let storageKey = key(for: userKey, language: language)
        let data = defaults.data(forKey: storageKey)
            ?? (language == .english ? defaults.data(forKey: legacyKey(for: userKey)) : nil)
        guard let data,
              let words = try? JSONDecoder().decode([Word].self, from: data) else {
            return []
        }
        return words
    }

    @discardableResult
    static func add(_ newWords: [Word], for userKey: String, language: StudyLanguage = .english) -> Int {
        var words = load(for: userKey, language: language)
        var known = Set(words.map { $0.word.lowercased() })
        let unique = newWords.filter { known.insert($0.word.lowercased()).inserted }
        guard !unique.isEmpty else { return 0 }
        words.append(contentsOf: unique)
        words.sort { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }
        guard let data = try? JSONEncoder().encode(words) else { return 0 }
        UserDefaults.standard.set(data, forKey: key(for: userKey, language: language))
        NotificationCenter.default.post(name: didChange, object: changeKey(for: userKey, language: language))
        return unique.count
    }

    @discardableResult
    static func remove(_ word: Word, for userKey: String, language: StudyLanguage = .english) -> Bool {
        var words = load(for: userKey, language: language)
        let originalCount = words.count
        words.removeAll {
            $0.word.caseInsensitiveCompare(word.word) == .orderedSame
        }
        guard words.count != originalCount,
              let data = try? JSONEncoder().encode(words) else { return false }
        UserDefaults.standard.set(data, forKey: key(for: userKey, language: language))
        NotificationCenter.default.post(name: didChange, object: changeKey(for: userKey, language: language))
        return true
    }

    static func replace(_ words: [Word], for userKey: String, language: StudyLanguage) {
        guard let data = try? JSONEncoder().encode(words) else { return }
        UserDefaults.standard.set(data, forKey: key(for: userKey, language: language))
        NotificationCenter.default.post(name: didChange, object: changeKey(for: userKey, language: language))
    }

    static func changeKey(for userKey: String, language: StudyLanguage) -> String {
        "\(userKey.lowercased())|\(language.rawValue)"
    }

    private static func key(for userKey: String, language: StudyLanguage) -> String {
        "tinghui.contextWordBook.\(userKey.lowercased()).\(language.rawValue)"
    }

    private static func legacyKey(for userKey: String) -> String {
        "tinghui.contextWordBook.\(userKey.lowercased())"
    }
}

struct UserWordBook: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var words: [Word]
    let createdAt: Date

    static func defaultBook(words: [Word] = []) -> UserWordBook {
        UserWordBook(id: UserWordBookStore.defaultBookID, name: "默认", words: words, createdAt: .distantPast)
    }
}

struct UserWordBookLibrary: Codable, Equatable {
    var books: [UserWordBook]
    var selectedBookID: String

    static var empty: UserWordBookLibrary {
        UserWordBookLibrary(books: [.defaultBook()], selectedBookID: UserWordBookStore.defaultBookID)
    }

    mutating func normalize() {
        if let index = books.firstIndex(where: { $0.id == UserWordBookStore.defaultBookID }) {
            books[index].name = "默认"
        } else {
            books.insert(.defaultBook(), at: 0)
        }
        if !books.contains(where: { $0.id == selectedBookID }) {
            selectedBookID = UserWordBookStore.defaultBookID
        }
    }
}

enum UserWordBookStore {
    static let defaultBookID = "default"
    static let didChange = Notification.Name("tinghui.userWordBooks.didChange")

    static func load(for userKey: String, language: StudyLanguage) -> UserWordBookLibrary {
        guard let data = UserDefaults.standard.data(forKey: key(for: userKey, language: language)),
              var library = try? JSONDecoder().decode(UserWordBookLibrary.self, from: data) else {
            return .empty
        }
        library.normalize()
        return library
    }

    static func save(_ library: UserWordBookLibrary, for userKey: String, language: StudyLanguage) {
        var normalized = library
        normalized.normalize()
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        UserDefaults.standard.set(data, forKey: key(for: userKey, language: language))
        NotificationCenter.default.post(name: didChange, object: changeKey(for: userKey, language: language))
    }

    static func changeKey(for userKey: String, language: StudyLanguage) -> String {
        "\(userKey.lowercased())|\(language.rawValue)"
    }

    static func cloudKey(for language: StudyLanguage) -> String {
        "word_book_library_\(language.rawValue)"
    }

    private static func key(for userKey: String, language: StudyLanguage) -> String {
        "tinghui.userWordBooks.\(userKey.lowercased()).\(language.rawValue)"
    }
}

public enum LearningLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case english
    case chinese

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .english: return "English Learning"
        case .chinese: return "中文"
        }
    }

    public var description: String {
        switch self {
        case .english: return "English descriptions"
        case .chinese: return "用中文描述"
        }
    }

    public func title(for interfaceLanguage: LearningLanguage) -> String {
        switch interfaceLanguage {
        case .english:
            switch self {
            case .english: return "English Learning"
            case .chinese: return "Chinese Learning"
            }
        case .chinese:
            switch self {
            case .english: return "English Learning"
            case .chinese: return "中文学习"
            }
        }
    }

    public var speechLanguageCode: String {
        switch self {
        case .english: return "en-US"
        case .chinese: return "zh-CN"
        }
    }

    public var translationLanguageCode: String {
        switch self {
        case .english: return "en"
        case .chinese: return "zh-Hans"
        }
    }

    public var meaningAudioSubdirectory: String {
        switch self {
        case .english: return "audio/meanings/en"
        case .chinese: return "audio/meanings/zh"
        }
    }
}

public extension Word {
    func meaning(for language: LearningLanguage) -> String {
        let preferred: String?
        switch language {
        case .english:
            preferred = meaningEn
        case .chinese:
            preferred = meaningZh
        }

        if let preferred, !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return preferred
        }

        switch language {
        case .chinese:
            let legacy = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            return legacy.isEmpty ? "暂无中文释义" : legacy
        case .english:
            // `translation` is the legacy Chinese field. Never leak it into the
            // English-explanation UI when an older dataset lacks `meaningEn`.
            return "English definition unavailable"
        }
    }

    func spokenMeaning(for language: LearningLanguage) -> String {
        meaning(for: language).strippingSpeechPartLabels()
    }

    func exampleText(for language: LearningLanguage) -> String {
        let preferred: String?
        switch language {
        case .english:
            preferred = exampleEn
        case .chinese:
            preferred = exampleZh
        }

        if let preferred, !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return preferred
        }

        return example ?? ""
    }
}

private extension String {
    func strippingSpeechPartLabels() -> String {
        let labelPattern = #"(?i)(^|[；;，,、\s])\s*(n|v|vt|vi|adj|adv|prep|pron|conj|num|art|aux|abbr|int|pl|sing|interj|det|modal)\.?\s+"#
        var cleaned = replacingOccurrences(
            of: labelPattern,
            with: "$1",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"([；;，,、])\s+"#,
            with: "$1",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// Model representing a wordbook (e.g., A1, A2, B1)
public struct WordBook: Codable {
    public let bookId: String
    public let title: String
    public let words: [Word]
}

public enum DataLoader {
    // Load a WordBook JSON from bundle data/<name>.json
    public static func loadBook(named name: String) throws -> WordBook {
        // First check bundle subdirectory `data/`
        let url: URL
        if let u = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "data") {
            url = u
        } else if let u = Bundle.main.url(forResource: name, withExtension: "json") {
            url = u
        } else {
            throw NSError(domain: "DataLoader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(name).json in bundle/data or bundle root"])
        }
        
        let d = try Data(contentsOf: url)
        let decodedWords = try JSONDecoder().decode([Word].self, from: d)
        let words = wordsForDisplay(decodedWords, bookId: name)
        return WordBook(bookId: name, title: title(for: name), words: words)
    }

    // Load multiple books by names
    public static func loadBooks(named names: [String]) -> [WordBook] {
        return names.compactMap { try? loadBook(named: $0) }
    }

    private static func title(for name: String) -> String {
        switch name {
        case "KaoYan_2":
            return "考研英语"
        case "IELTS_9400":
            return "雅思9400词"
        default:
            return name.uppercased()
        }
    }

    private static func wordsForDisplay(_ words: [Word], bookId: String) -> [Word] {
        guard ["KaoYan_2", "IELTS_9400"].contains(bookId) else { return words }
        return words.sorted {
            $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending
        }
    }
}
