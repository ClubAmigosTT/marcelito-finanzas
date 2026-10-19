import Foundation

/// Large financial records live in files, not UserDefaults. iOS silently
/// refuses any single UserDefaults value of 4 MB or more ("Attempting to store
/// >= 4194304 bytes of data in CFPreferences/NSUserDefaults on this platform is
/// invalid"), so a ledger past that size stopped saving its newest imports and
/// they vanished on the next launch. Values written by older builds are moved
/// to a file the first time they are read.
enum LedgerStorage {
    private static let exactKeys: Set<String> = [
        "marcelito.ledger.active.v1", "marcelito.ledger.backup.v1",
        "marcelito.movements.v2", "marcelito.statements.v1",
        "marcelito.manualReviews.v1", "marcelito.bankScreenshotCaptures.v1",
    ]

    static func isFileKey(_ key: String) -> Bool {
        exactKeys.contains(key) || key.hasPrefix("marcelito.ledger.before") || key.hasPrefix("marcelito.manualReviews.before")
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarcelitoLedgerStore", isDirectory: true)
    }

    private static func url(for key: String, in directory: URL) -> URL {
        directory.appendingPathComponent(key + ".data")
    }

    static func data(forKey key: String, defaults: UserDefaults = .standard, directory: URL = defaultDirectory) -> Data? {
        if let data = try? Data(contentsOf: url(for: key, in: directory)) { return data }
        guard let legacy = defaults.data(forKey: key) else { return nil }
        if write(legacy, forKey: key, directory: directory) { defaults.removeObject(forKey: key) }
        return legacy
    }

    static func set(_ data: Data?, forKey key: String, defaults: UserDefaults = .standard, directory: URL = defaultDirectory) {
        guard let data else { remove(forKey: key, defaults: defaults, directory: directory); return }
        if write(data, forKey: key, directory: directory) { defaults.removeObject(forKey: key) }
    }

    static func remove(forKey key: String, defaults: UserDefaults = .standard, directory: URL = defaultDirectory) {
        defaults.removeObject(forKey: key)
        try? FileManager.default.removeItem(at: url(for: key, in: directory))
    }

    /// Every stored file value, for backups.
    static func allValues(directory: URL = defaultDirectory) -> [String: Data] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.reduce(into: [:]) { values, file in
            guard file.pathExtension == "data" else { return }
            let key = file.deletingPathExtension().lastPathComponent
            if isFileKey(key), let data = try? Data(contentsOf: file) { values[key] = data }
        }
    }

    @discardableResult
    private static func write(_ data: Data, forKey key: String, directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try data.write(to: url(for: key, in: directory), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url(for: key, in: directory), options: [.atomic])
            #endif
            return true
        } catch {
            DiagnosticsRecorder.record(level: "error", stage: "storage.write", message: "No se pudo guardar \(key): \(error.localizedDescription)")
            return false
        }
    }
}
