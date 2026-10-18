import Foundation

public enum SupabaseConfig {
    public static let projectURL = "https://frljmdtogeyajpbwjavv.supabase.co"
    public static let anonKey = "sb_publishable_3t59NeLaq2EwQ8u7Cvh0EQ_wasKx280"

    // Public Supabase Storage bucket for mp3 files.
    // Expected paths:
    // words/hallo.mp3
    // meanings/zh/你好_xxxxxxxx.mp3
    // meanings/en/hello_xxxxxxxx.mp3
    public static let audioStorageBucket = "audio"

    public static var isConfigured: Bool {
        projectURL.hasPrefix("https://") &&
        !projectURL.contains("YOUR_PROJECT_REF") &&
        !anonKey.contains("YOUR_SUPABASE_ANON_KEY")
    }

    public static var publicAudioStorageBaseURL: URL? {
        guard isConfigured else { return nil }
        return URL(string: "\(projectURL)/storage/v1/object/public/\(audioStorageBucket)")
    }
}
