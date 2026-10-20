import Foundation

public enum SupabaseConfig {
    /// Versions are enabled independently so languages can be migrated without
    /// temporarily storing two complete word-audio libraries.
    public static let englishWordAudioVersion: String? = nil
    public static let germanWordAudioVersion: String? = "v2"
    public static let projectURL = "https://frljmdtogeyajpbwjavv.supabase.co"
    public static let anonKey = "sb_publishable_3t59NeLaq2EwQ8u7Cvh0EQ_wasKx280"
    public static let learningAudioBucket = "learning-audio"

    public static var learningAudioBaseURL: URL? {
        URL(string: "\(projectURL)/storage/v1/object/public/\(learningAudioBucket)/")
    }

    public static var isConfigured: Bool {
        projectURL.hasPrefix("https://") &&
        !projectURL.contains("YOUR_PROJECT_REF") &&
        !anonKey.contains("YOUR_SUPABASE_ANON_KEY")
    }
}
