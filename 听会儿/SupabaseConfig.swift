import Foundation

public enum SupabaseConfig {
    /// Versions are enabled independently so languages can be migrated without
    /// temporarily storing two complete word-audio libraries.
    /// English word-audio rollout is controlled per book so either library can
    /// be refreshed without changing the other book's routing.
    public static let kaoYanEnglishWordAudioVersion: String? = "v2"
    public static let ieltsEnglishWordAudioVersion: String? = "v2"
    public static let germanWordAudioVersion: String? = "v2"
    /// Bump when existing Storage objects are intentionally replaced. This
    /// changes only the request URL, so the stable object paths and V4 cache
    /// fallback remain intact while a new app build cannot inherit a stale CDN
    /// response from the previous audio release.
    public static let learningAudioContentRevision = "20261021-tackle-1"
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
