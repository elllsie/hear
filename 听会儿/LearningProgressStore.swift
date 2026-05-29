import Foundation

public struct LearningProgress: Codable, Equatable {
    public let bookId: String
    public var lastIndex: Int
    public var updatedAt: Date
}

public final class LearningProgressStore {
    public static let shared = LearningProgressStore()

    private let defaults: UserDefaults
    private let keyPrefix = "tinghui.progress"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func progress(for username: String, bookId: String) -> LearningProgress? {
        guard let data = defaults.data(forKey: key(username: username, bookId: bookId)) else {
            return nil
        }
        return try? JSONDecoder().decode(LearningProgress.self, from: data)
    }

    public func lastIndex(for username: String, bookId: String, wordCount: Int) -> Int {
        guard wordCount > 0, let progress = progress(for: username, bookId: bookId) else {
            return 0
        }
        return min(max(0, progress.lastIndex), wordCount - 1)
    }

    public func save(username: String, bookId: String, index: Int, wordCount: Int) {
        guard wordCount > 0 else { return }
        let safeIndex = min(max(0, index), wordCount - 1)
        let progress = LearningProgress(bookId: bookId, lastIndex: safeIndex, updatedAt: Date())
        save(username: username, progress: progress)
    }

    public func save(username: String, progress: LearningProgress) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: key(username: username, bookId: progress.bookId))
    }

    public func syncFromRemoteIfNeeded(username: String, userId: String, accessToken: String, bookId: String) {
        Task {
            guard let remote = try? await SupabaseClient.shared.fetchProgress(
                accessToken: accessToken,
                userId: userId,
                bookId: bookId
            ) else {
                return
            }
            save(username: username, progress: remote)
        }
    }

    public func saveAndSync(username: String, userId: String, accessToken: String?, bookId: String, index: Int, wordCount: Int) {
        guard wordCount > 0 else { return }
        let safeIndex = min(max(0, index), wordCount - 1)
        let progress = LearningProgress(bookId: bookId, lastIndex: safeIndex, updatedAt: Date())
        save(username: username, progress: progress)

        guard let accessToken else { return }
        Task {
            try? await SupabaseClient.shared.upsertProgress(
                accessToken: accessToken,
                userId: userId,
                progress: progress
            )
        }
    }

    private func key(username: String, bookId: String) -> String {
        let userKey = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(keyPrefix).\(userKey).\(bookId)"
    }
}
