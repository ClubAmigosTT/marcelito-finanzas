import Foundation
import Security

/// Automatic encrypted backup into a folder the user chose once in Files (for
/// example a folder in iCloud Drive). It needs no iCloud entitlement: the
/// folder is kept as a security-scoped bookmark and the backup password lives
/// in this iPhone's Keychain. Each run rewrites "Marcelito-respaldo.marcelito"
/// and keeps one copy per month, so a bad day never replaces all history.
enum AutoBackup {
    static let bookmarkKey = "marcelito.autoBackup.folder.v1"
    static let lastRunKey = "marcelito.autoBackup.lastRun.v1"
    static let lastErrorKey = "marcelito.autoBackup.lastError.v1"
    private static let service = "mx.marcelito.personal.autobackup"
    private static let account = "password"
    static let latestFileName = "Marcelito-respaldo.marcelito"

    static var isConfigured: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil && password() != nil }
    static var lastRun: Date? { UserDefaults.standard.object(forKey: lastRunKey) as? Date }
    static var lastError: String? { UserDefaults.standard.string(forKey: lastErrorKey) }

    static var folderName: String? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        return (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))?.lastPathComponent
    }

    static func configure(folder: URL, password: String) throws {
        guard password.count >= 12 else { throw LoanError.invalid("Usa una contraseña de al menos 12 caracteres.") }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        guard savePassword(password) else { throw LoanError.invalid("No se pudo guardar la contraseña en el llavero del iPhone.") }
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: lastErrorKey)
    }

    static func disable() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: lastRunKey)
        UserDefaults.standard.removeObject(forKey: lastErrorKey)
        SecItemDelete(query() as CFDictionary)
    }

    /// Writes a backup when the last one is older than `minimumInterval`
    /// (default 20 hours) or when `force` is set. Returns true on success.
    @discardableResult
    static func runIfDue(now: Date = .now, minimumInterval: TimeInterval = 20 * 3600, force: Bool = false) async -> Bool {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey), let password = password() else { return false }
        if !force, let lastRun, now.timeIntervalSince(lastRun) < minimumInterval { return false }
        do {
            let data = try await Task.detached(priority: .utility) {
                try FinanceBackup.encrypt(FinanceBackup.capture(), password: password)
            }.value
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            if stale, let refreshed = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
            }
            let monthly = "Marcelito-" + String(LoanMath.dayKey(now).prefix(7)) + ".marcelito"
            for name in [latestFileName, monthly] {
                try write(data, to: folder.appendingPathComponent(name))
            }
            UserDefaults.standard.set(now, forKey: lastRunKey)
            UserDefaults.standard.removeObject(forKey: lastErrorKey)
            DiagnosticsRecorder.record(stage: "backup.auto", message: "Respaldo automático guardado en \(folder.lastPathComponent).")
            return true
        } catch {
            UserDefaults.standard.set(error.localizedDescription, forKey: lastErrorKey)
            DiagnosticsRecorder.record(level: "error", stage: "backup.auto", message: "No se pudo guardar el respaldo automático: \(error.localizedDescription)")
            return false
        }
    }

    /// iCloud Drive folders are coordinated; write through a coordinator so
    /// the file provider never sees a half-written backup.
    private static func write(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func savePassword(_ password: String) -> Bool {
        SecItemDelete(query() as CFDictionary)
        var item = query()
        item[kSecValueData as String] = Data(password.utf8)
        // Available after the first unlock so a later launch can back up
        // without asking; never synced off this device.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func password() -> String? {
        var item = query()
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
