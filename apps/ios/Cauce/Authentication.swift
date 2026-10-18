import Foundation
import LocalAuthentication
import Observation
import Security

/// Credentials stored by builds that had their own fallback password. They
/// are only ever deleted now; Face ID and the iPhone passcode are verified by
/// iOS and nothing about them reaches this app.
private enum SecureAccountStore {
    private static let service = "mx.marcelito.personal.account"

    static func deleteAll() {
        [
            "username",
            "passwordHash",
            "fallbackHash",
            "fallbackSalt",
            "failedAttempts",
            "lockoutUntil",
            "biometricFailures"
        ].forEach { account in
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ] as CFDictionary)
        }
    }
}

@MainActor
@Observable
final class AuthenticationModel {
    var isAuthenticated = false
    var message: String?
    private var isAuthenticating = false

    init() {
        // Older builds kept their own fallback password (a value shipped in
        // the source). Access now relies only on Face ID and the iPhone
        // passcode, so remove every credential those builds left behind.
        SecureAccountStore.deleteAll()
    }

    /// Called by the sign-in view when it first appears or after the app
    /// returns from the background.
    func unlockAutomatically() async {
        await unlock()
    }

    /// Face ID first; iOS itself offers the device passcode when Face ID is
    /// unavailable, locked out or not recognised, and applies its own
    /// attempt limits. Marcelito never stores a password.
    func unlock() async {
        guard !isAuthenticated, !isAuthenticating else { return }
        let context = LAContext()
        context.localizedFallbackTitle = "Usar código del iPhone"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if (error as? LAError)?.code == .passcodeNotSet {
                // Without a device passcode iOS has nothing to verify. Locking
                // the owner out of their own local data would not protect it.
                isAuthenticated = true
                message = nil
            } else {
                message = "No se pudo verificar tu identidad. Revisa Face ID y el código de tu iPhone en Ajustes."
            }
            return
        }

        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Desbloquea tu panorama financiero"
            )
            isAuthenticated = success
            message = success ? nil : "No se pudo verificar tu identidad. Inténtalo de nuevo."
        } catch {
            switch (error as? LAError)?.code {
            case .userCancel?, .systemCancel?, .appCancel?:
                // Dismissing the prompt or leaving the app is not a failure.
                message = nil
            default:
                message = "No se pudo verificar tu identidad. Inténtalo de nuevo."
            }
        }
    }

    func lock() {
        isAuthenticated = false
        message = nil
    }

    func deleteAccount() {
        SecureAccountStore.deleteAll()
        lock()
    }
}
