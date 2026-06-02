import Foundation

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

public enum LearningLanguage: String, CaseIterable, Identifiable {
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

        return translation
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
        let words = try JSONDecoder().decode([Word].self, from: d)
        return WordBook(bookId: name, title: name.uppercased(), words: words)
    }

    // Load multiple books by names
    public static func loadBooks(named names: [String]) -> [WordBook] {
        return names.compactMap { try? loadBook(named: $0) }
    }
}
