import Foundation

public enum SupabaseConfig {
    public static let projectURL = "https://frljmdtogeyajpbwjavv.supabase.co"
    public static let anonKey = "sb_publishable_3t59NeLaq2EwQ8u7Cvh0EQ_wasKx280"

    public static var isConfigured: Bool {
        projectURL.hasPrefix("https://") &&
        !projectURL.contains("YOUR_PROJECT_REF") &&
        !anonKey.contains("YOUR_SUPABASE_ANON_KEY")
    }
}
