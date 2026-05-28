import Foundation

// Model representing a single word entry
public struct Word: Codable, Equatable {
    public let id: String
    public let word: String
    public let translation: String
    public let phonetic: String?
    public let example: String?
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
        case audioFileName
        case article
        case meaningZh
        case meaningEn
        case source
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
