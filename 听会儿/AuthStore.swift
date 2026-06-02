import Foundation
import Combine

public struct AppUser: Codable, Equatable {
    public let id: String
    public let username: String
    public let displayName: String

    public static let guest = AppUser(
        id: "local-guest",
        username: "guest",
        displayName: "Guest"
    )

    public var isGuest: Bool {
        id == Self.guest.id
    }

    public var storageKey: String {
        isGuest ? "guest" : username
    }
}

@MainActor
public final class AuthStore: ObservableObject {
    @Published public private(set) var currentUser: AppUser?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isWorking = false

    private let defaults: UserDefaults
    private let currentUserKey = "tinghui.supabase.currentUser"
    private let keychainService = "tinghui.supabase.auth"
    private let accessTokenAccount = "accessToken"
    private let refreshTokenAccount = "refreshToken"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: currentUserKey),
           let user = try? JSONDecoder().decode(AppUser.self, from: data),
           accessToken != nil {
            currentUser = user
        }
    }

    public var accessToken: String? {
        KeychainStore.read(service: keychainService, account: accessTokenAccount)
    }

    private var refreshToken: String? {
        KeychainStore.read(service: keychainService, account: refreshTokenAccount)
    }

    public func register(email: String, password: String) {
        runAuth(email: email, password: password, action: SupabaseClient.shared.signUp)
    }

    public func login(email: String, password: String) {
        runAuth(email: email, password: password, action: SupabaseClient.shared.signIn)
    }

    public func logout() {
        KeychainStore.delete(service: keychainService, account: accessTokenAccount)
        KeychainStore.delete(service: keychainService, account: refreshTokenAccount)
        defaults.removeObject(forKey: currentUserKey)
        currentUser = nil
        errorMessage = nil
    }

    public func deleteAccount() async -> Bool {
        errorMessage = nil
        guard accessToken != nil else {
            errorMessage = "登录已过期，请重新登录后再删除账号"
            return false
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let validAccessToken = try await refreshedAccessToken()
            try await SupabaseClient.shared.deleteAccount(accessToken: validAccessToken)
            logout()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func refreshedAccessToken() async throws -> String {
        guard let refreshToken else {
            guard let accessToken else {
                throw SupabaseClientError.message("登录已过期，请重新登录后再删除账号")
            }
            return accessToken
        }

        do {
            let session = try await SupabaseClient.shared.refreshSession(refreshToken: refreshToken)
            KeychainStore.save(session.accessToken, service: keychainService, account: accessTokenAccount)
            if let refreshToken = session.refreshToken {
                KeychainStore.save(refreshToken, service: keychainService, account: refreshTokenAccount)
            }
            return session.accessToken
        } catch {
            logout()
            throw SupabaseClientError.message("登录已过期，请重新登录后再删除账号")
        }
    }

    private func runAuth(
        email: String,
        password: String,
        action: @escaping (String, String) async throws -> SupabaseSession
    ) {
        errorMessage = nil
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanEmail.contains("@") else {
            errorMessage = "请输入邮箱"
            return
        }
        guard cleanPassword.count >= 6 else {
            errorMessage = "密码至少需要6个字符"
            return
        }

        isWorking = true
        Task {
            do {
                let session = try await action(cleanEmail, cleanPassword)
                signIn(session)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func signIn(_ session: SupabaseSession) {
        KeychainStore.save(session.accessToken, service: keychainService, account: accessTokenAccount)
        if let refreshToken = session.refreshToken {
            KeychainStore.save(refreshToken, service: keychainService, account: refreshTokenAccount)
        }

        let displayName = session.user.displayName ?? session.user.email.split(separator: "@").first.map(String.init) ?? session.user.email
        let user = AppUser(id: session.user.id, username: session.user.email, displayName: displayName)
        if let data = try? JSONEncoder().encode(user) {
            defaults.set(data, forKey: currentUserKey)
        }
        currentUser = user
    }
}
