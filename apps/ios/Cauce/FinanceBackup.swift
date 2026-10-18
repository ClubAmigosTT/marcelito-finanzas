import Foundation
import CryptoKit
import CommonCrypto
import Security

struct FinanceBackupPayload: Codable {
    let schema: Int
    let createdAt: Date
    let preferences: Data
    let files: [String: Data]
}
private struct EncryptedFinanceBackup: Codable {
    let schema: Int
    let salt: Data
    let rounds: UInt32
    let sealed: Data
}
enum FinanceBackup {
    static var fileOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtection]
        #else
        return [.atomic]
        #endif
    }
    static let folders = ["ImportedStatements", "ImportedBankScreenshots", "MarcelitoLoans"]
    static let keys: Set<String> = [
        "marcelito.ledger.active.v1", "marcelito.movements.v2", "marcelito.statements.v1", "marcelito.lastImport",
        "marcelito.categoryRules.v1", "marcelito.categoryOverrides.v1", "marcelito.manualReviews.v1", "marcelito.categoryTaxonomyVersion.v1",
        "marcelito.canonicalRebuild.v1", "marcelito.canonicalRebuild.readerVersion.v1", "marcelito.canonicalRebuild.expectedCount.v1",
        "marcelito.extractionReplayVersion.v1", "marcelito.ledger.normalizedReaderVersion.v1", "marcelito.transfer.ownerAliases.v1",
        "marcelito.transfer.matcherVersion.v1", "marcelito.bankScreenshotCaptures.v1", "marcelito.planning.v1", "marcelito.loans.v1",
        "marcelito.transfer.rejectedPairs.v1", "marcelito.accounts.closed.v1"
    ]
    static func allowed(_ key: String) -> Bool { keys.contains(key) || key.hasPrefix("marcelito.monthlyPlan.") }
    static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    static func capture(defaults: UserDefaults = .standard, directory: URL = support) throws -> FinanceBackupPayload {
        let values = defaults.dictionaryRepresentation().filter { allowed($0.key) }
        let preferences = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        var files: [String: Data] = [:]; var bytes = 0
        for folder in folders {
            let root = directory.appendingPathComponent(folder, isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true else { throw LoanError.invalid("El respaldo contiene un archivo no compatible.") }
                let data = try Data(contentsOf: url, options: .mappedIfSafe); bytes += data.count
                guard bytes <= 60_000_000 else { throw LoanError.invalid("El respaldo supera 60 MB. No se cambió tu información.") }
                files[folder + "/" + url.lastPathComponent] = data
            }
        }
        return FinanceBackupPayload(schema: 1, createdAt: .now, preferences: preferences, files: files)
    }
    static func validate(_ payload: FinanceBackupPayload) throws -> [String: Any] {
        guard payload.schema == 1, payload.files.count <= 2000, payload.files.values.reduce(0, { $0 + $1.count }) <= 60_000_000,
              let prefs = try PropertyListSerialization.propertyList(from: payload.preferences, format: nil) as? [String: Any], prefs.keys.allSatisfy(allowed) else { throw LoanError.invalid("El respaldo no es compatible.") }
        for path in payload.files.keys {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, folders.contains(String(parts[0])), !parts[1].isEmpty, parts[1] != ".", parts[1] != "..", !parts[1].contains("\\") else { throw LoanError.invalid("El respaldo contiene una ruta inválida.") }
        }
        let dataKeys: Set<String> = ["marcelito.ledger.active.v1", "marcelito.movements.v2", "marcelito.statements.v1", "marcelito.manualReviews.v1", "marcelito.planning.v1", "marcelito.loans.v1", "marcelito.bankScreenshotCaptures.v1"]
        guard prefs.allSatisfy({ !dataKeys.contains($0.key) || $0.value is Data }) else { throw LoanError.invalid("El respaldo contiene un registro financiero inválido.") }
        let decoder = JSONDecoder()
        if let data = prefs["marcelito.ledger.active.v1"] as? Data { guard try decoder.decode(LedgerEnvelope.self, from: data).schemaVersion == 1 else { throw LoanError.invalid("Actualiza la app para restaurar este libro.") } }
        if let data = prefs["marcelito.movements.v2"] as? Data { _ = try decoder.decode([Movement].self, from: data) }
        if let data = prefs["marcelito.statements.v1"] as? Data { _ = try decoder.decode([StatementRecord].self, from: data) }
        if let data = prefs["marcelito.planning.v1"] as? Data { guard try decoder.decode(PlanningState.self, from: data).schema == 1 else { throw LoanError.invalid("Versión de presupuesto no compatible.") } }
        if let data = prefs["marcelito.loans.v1"] as? Data { guard try decoder.decode(LoanState.self, from: data).schema == 1 else { throw LoanError.invalid("Versión de préstamos no compatible.") } }
        return prefs
    }
    static func key(password: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        guard password.count >= 12, salt.count == 16, rounds >= 210_000, rounds <= 1_000_000 else { throw LoanError.invalid("Usa una contraseña de al menos 12 caracteres.") }
        let passwordData = Array(password.utf8); var derived = [UInt8](repeating: 0, count: 32)
        let status = passwordData.withUnsafeBytes { passwordBytes in salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.baseAddress!.assumingMemoryBound(to: Int8.self), passwordData.count, saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &derived, 32)
        } }
        guard status == kCCSuccess else { throw LoanError.invalid("No se pudo proteger el respaldo.") }
        return SymmetricKey(data: derived)
    }
    static func encrypt(_ payload: FinanceBackupPayload, password: String) throws -> Data {
        _ = try validate(payload)
        var salt = Data(count: 16)
        let result = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard result == errSecSuccess else { throw LoanError.invalid("No se pudo proteger el respaldo.") }
        let sealed = try AES.GCM.seal(JSONEncoder().encode(payload), using: key(password: password, salt: salt, rounds: 210_000))
        return try JSONEncoder().encode(EncryptedFinanceBackup(schema: 1, salt: salt, rounds: 210_000, sealed: sealed.combined!))
    }
    static func decrypt(_ data: Data, password: String) throws -> FinanceBackupPayload {
        guard data.count <= 120_000_000 else { throw LoanError.invalid("Ese archivo es demasiado grande.") }
        do {
            let envelope = try JSONDecoder().decode(EncryptedFinanceBackup.self, from: data)
            guard envelope.schema == 1 else { throw LoanError.invalid("Versión de respaldo no compatible.") }
            let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key(password: password, salt: envelope.salt, rounds: envelope.rounds))
            let payload = try JSONDecoder().decode(FinanceBackupPayload.self, from: clear)
            _ = try validate(payload); return payload
        } catch { throw LoanError.invalid("No se pudo abrir el respaldo. Revisa la contraseña y el archivo; tus datos se conservan.") }
    }
    private static func apply(_ payload: FinanceBackupPayload, defaults: UserDefaults, directory: URL) throws {
        let prefs = try validate(payload)
        let fm = FileManager.default
        for folder in folders {
            let next = directory.appendingPathComponent("restore-next-" + UUID().uuidString)
            try fm.createDirectory(at: next, withIntermediateDirectories: true)
            for (path, data) in payload.files where path.hasPrefix(folder + "/") {
                try data.write(to: next.appendingPathComponent(String(path.split(separator: "/")[1])), options: fileOptions)
            }
            let target = directory.appendingPathComponent(folder)
            let old = directory.appendingPathComponent("restore-old-" + UUID().uuidString)
            if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: old) }
            do { try fm.moveItem(at: next, to: target); try? fm.removeItem(at: old) }
            catch { if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: target) }; throw error }
        }
        for key in defaults.dictionaryRepresentation().keys where allowed(key) { defaults.removeObject(forKey: key) }
        for (key, value) in prefs { defaults.set(value, forKey: key) }
        defaults.removeObject(forKey: "marcelito.categoryUndo.v1")
        defaults.synchronize()
    }
    static func restore(_ payload: FinanceBackupPayload, defaults: UserDefaults = .standard, directory: URL = support) throws {
        _ = try validate(payload)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rollback = directory.appendingPathComponent("marcelito-restore-rollback.json")
        let previous = try capture(defaults: defaults, directory: directory)
        try JSONEncoder().encode(previous).write(to: rollback, options: fileOptions)
        do { try apply(payload, defaults: defaults, directory: directory); try FileManager.default.removeItem(at: rollback) }
        catch { try apply(previous, defaults: defaults, directory: directory); try? FileManager.default.removeItem(at: rollback); throw error }
    }
    static func recoverInterruptedRestore(defaults: UserDefaults = .standard, directory: URL = support) throws {
        let rollback = directory.appendingPathComponent("marcelito-restore-rollback.json")
        guard FileManager.default.fileExists(atPath: rollback.path) else { return }
        let previous = try JSONDecoder().decode(FinanceBackupPayload.self, from: Data(contentsOf: rollback))
        try apply(previous, defaults: defaults, directory: directory)
        try FileManager.default.removeItem(at: rollback)
    }
}
