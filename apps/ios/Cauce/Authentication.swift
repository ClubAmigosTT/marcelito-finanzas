import CryptoKit
import Foundation
import LocalAuthentication
import Observation
import Security

/// Keychain-backed credentials for this device only. No username, password or
/// biometric data is sent to a server.
private enum SecureAccountStore {
    private static let service = "mx.marcelito.personal.account"

    static func string(for account: String) -> String? {
        guard let data = data(for: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func data(for account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        save(Data(value.utf8), account: account)
    }

    @discardableResult
    static func save(_ value: Data, account: String) -> Bool {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecValueData as String] = value
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func deleteAll() {
        [
            "username",
            "passwordHash",
            "fallbackHash",
            "fallbackSalt",
            "failedAttempts",
            "lockoutUntil",
            "biometricFailures"
        ].forEach { SecItemDelete(baseQuery(account: $0) as CFDictionary) }
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

@Observable
final class AuthenticationModel {
    var isAuthenticated = false
    var message: String?
    var requiresFallback = false
    private(set) var isBiometricAvailable = false

    private let fallbackHashAccount = "fallbackHash"
    private let fallbackSaltAccount = "fallbackSalt"
    private let failedAttemptsAccount = "failedAttempts"
    private let lockoutUntilAccount = "lockoutUntil"
    private let biometricFailuresAccount = "biometricFailures"
    private let maxFallbackAttempts = 5
    private let maxBiometricFailures = 3
    private let defaultFallback = "homero10"

    init() {
        if SecureAccountStore.string(for: fallbackHashAccount) == nil,
           SecureAccountStore.string(for: "passwordHash") == nil {
            // The personal app keeps a local bootstrap fallback so a device
            // without Face ID can still be opened. It is stored only as a
            // salted hash and can be replaced by a future security settings UI.
            configureFallback(defaultFallback)
        }
        isBiometricAvailable = canEvaluateBiometrics()
    }

    /// Called by the sign-in view when it first appears or after the app
    /// returns from the background.
    func unlockAutomatically() async {
        guard !isAuthenticated, !isAuthenticating else { return }
        if isLockedOut() {
            requiresFallback = true
            message = lockoutMessage()
            return
        }
        await unlockWithFaceID()
    }

    func unlockWithFaceID() async {
        guard !isAuthenticated, !isAuthenticating else { return }
        if isLockedOut() {
            await MainActor.run {
                requiresFallback = true
                message = lockoutMessage()
            }
            return
        }

        let context = LAContext()
        context.localizedCancelTitle = "Usar clave de respaldo"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            await MainActor.run {
                isBiometricAvailable = false
                requiresFallback = true
                message = "Face ID no está disponible. Usa tu clave de respaldo."
            }
            return
        }

        await MainActor.run {
            isBiometricAvailable = true
            isAuthenticating = true
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Desbloquea tu panorama financiero"
            )
            await MainActor.run {
                isAuthenticating = false
                if success {
                    isAuthenticated = true
                    requiresFallback = false
                    message = nil
                    resetFailures()
                    SecureAccountStore.delete(account: "username")
                    SecureAccountStore.delete(account: "passwordHash")
                } else {
                    registerBiometricFailure()
                }
            }
        } catch {
            await MainActor.run {
                isAuthenticating = false
                registerBiometricFailure()
                if !requiresFallback {
                    message = "Face ID no pudo confirmar tu identidad. Puedes intentarlo de nuevo."
                }
            }
        }
    }

    func showFallback() {
        requiresFallback = true
        message = nil
    }

    func unlockWithFallback(_ password: String) {
        guard !isAuthenticated else { return }
        guard !isLockedOut() else {
            requiresFallback = true
            message = lockoutMessage()
            return
        }

        let candidate = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            requiresFallback = true
            message = "Escribe tu clave de respaldo."
            return
        }

        if verifyFallback(candidate) {
            isAuthenticated = true
            requiresFallback = false
            message = nil
            resetFailures()
        } else {
            registerFallbackFailure()
        }
    }

    func lock() {
        isAuthenticated = false
        requiresFallback = false
        message = nil
    }

    func deleteAccount() {
        SecureAccountStore.deleteAll()
        isAuthenticated = false
        requiresFallback = false
        message = nil
    }

    private var isAuthenticating = false

    private func canEvaluateBiometrics() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    private func configureFallback(_ password: String) {
        let salt = Data(UUID().uuidString.utf8)
        _ = SecureAccountStore.save(salt.base64EncodedString(), account: fallbackSaltAccount)
        _ = SecureAccountStore.save(Self.passwordHash(password: password, salt: salt), account: fallbackHashAccount)
    }

    private func verifyFallback(_ password: String) -> Bool {
        if let saltString = SecureAccountStore.string(for: fallbackSaltAccount),
           let salt = Data(base64Encoded: saltString),
           let savedHash = SecureAccountStore.string(for: fallbackHashAccount) {
            return Self.passwordHash(password: password, salt: salt) == savedHash
        }

        // Migrate an existing installation to the requested personal
        // fallback without keeping the old username/password UI alive.
        if password == defaultFallback,
           SecureAccountStore.string(for: "passwordHash") != nil {
            configureFallback(defaultFallback)
            SecureAccountStore.delete(account: "username")
            SecureAccountStore.delete(account: "passwordHash")
            return true
        }

        // One-time migration path for installations that used the old
        // username/password screen. A successful unlock upgrades the
        // credential to the salted device-only format.
        if let username = SecureAccountStore.string(for: "username"),
           let savedHash = SecureAccountStore.string(for: "passwordHash") {
            let digest = SHA256.hash(data: Data("\(username):\(password)".utf8))
            let legacyHash = digest.map { String(format: "%02x", $0) }.joined()
            guard legacyHash == savedHash else { return false }
            configureFallback(password)
            SecureAccountStore.delete(account: "username")
            SecureAccountStore.delete(account: "passwordHash")
            return true
        }
        return false
    }

    private static func passwordHash(password: String, salt: Data) -> String {
        var input = Data()
        input.append(salt)
        input.append(Data(password.utf8))
        let digest = SHA256.hash(data: input)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func registerBiometricFailure() {
        let failures = (Int(SecureAccountStore.string(for: biometricFailuresAccount) ?? "0") ?? 0) + 1
        _ = SecureAccountStore.save(String(failures), account: biometricFailuresAccount)
        if failures >= maxBiometricFailures {
            requiresFallback = true
            message = "Face ID falló varias veces. Usa tu clave de respaldo."
        } else {
            message = "Face ID no pudo confirmar tu identidad. Intento \(failures) de \(maxBiometricFailures)."
        }
    }

    private func registerFallbackFailure() {
        let failures = (Int(SecureAccountStore.string(for: failedAttemptsAccount) ?? "0") ?? 0) + 1
        _ = SecureAccountStore.save(String(failures), account: failedAttemptsAccount)
        requiresFallback = true
        if failures >= maxFallbackAttempts {
            let exponent = min(failures - maxFallbackAttempts, 3)
            let seconds = [60, 300, 900, 3600][exponent]
            _ = SecureAccountStore.save(String(Date().addingTimeInterval(TimeInterval(seconds)).timeIntervalSince1970), account: lockoutUntilAccount)
            message = "Demasiados intentos. Inténtalo de nuevo en \(lockoutLabel(seconds))."
        } else {
            let remaining = maxFallbackAttempts - failures
            message = "Clave incorrecta. Intentos restantes: \(remaining)."
        }
    }

    private func resetFailures() {
        _ = SecureAccountStore.save("0", account: failedAttemptsAccount)
        _ = SecureAccountStore.save("0", account: biometricFailuresAccount)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "mx.marcelito.personal.account",
            kSecAttrAccount as String: lockoutUntilAccount
        ] as CFDictionary)
    }

    private func isLockedOut() -> Bool {
        guard let value = SecureAccountStore.string(for: lockoutUntilAccount),
              let timestamp = Double(value) else { return false }
        if Date().timeIntervalSince1970 < timestamp { return true }
        resetFailures()
        return false
    }

    private func lockoutMessage() -> String {
        guard let value = SecureAccountStore.string(for: lockoutUntilAccount),
              let timestamp = Double(value) else {
            return "Usa tu clave de respaldo."
        }
        let remaining = max(1, Int(ceil(timestamp - Date().timeIntervalSince1970)))
        return "Demasiados intentos. Inténtalo de nuevo en \(lockoutLabel(remaining))."
    }

    private func lockoutLabel(_ seconds: Int) -> String {
        if seconds >= 3600 { return "una hora" }
        if seconds >= 60 { return "\(max(1, seconds / 60)) minutos" }
        return "\(seconds) segundos"
    }

}
