import Foundation

/// A disposable private cache. The canonical ledger is still reconciled on
/// every import; a cache miss/corrupt entry simply invokes the reader again.
struct PDFReadingCache {
    let directory: URL

    static var local: PDFReadingCache? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first.map {
            PDFReadingCache(directory: $0.appendingPathComponent("MarcelitoReader", isDirectory: true))
        }
    }

    private func file(_ key: String) -> URL? {
        guard key.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return nil }
        return directory.appendingPathComponent(key + ".json")
    }

    func load<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        guard let url = file(key), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func store<Value: Encodable>(_ value: Value, key: String) {
        guard let url = file(key), let data = try? JSONEncoder().encode(value) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            // Cache eviction affects performance only. Bound disk usage by
            // retaining the newest 128 successful extractions.
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "json" }
            if files.count > 128 {
                let oldest = files.sorted {
                    let left = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    let right = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    return (left ?? .distantPast) < (right ?? .distantPast)
                }
                for stale in oldest.prefix(files.count - 128) { try? FileManager.default.removeItem(at: stale) }
            }
        } catch {
            // Failure to cache must never prevent importing a valid PDF.
        }
    }
}

/// Serializes expensive PDFKit/Vision work across imports, inspection and
/// diagnostics. A synchronous actor operation cannot overlap another reader
/// pass, which bounds peak image memory when the UI starts a second task.
/// Callers still check cancellation inside page and region loops so a canceled
/// operation releases the actor promptly instead of finishing an entire file.
actor PDFExtractionCoordinator {
    static let shared = PDFExtractionCoordinator()

    func perform<Value: Sendable>(
        _ operation: @Sendable () throws -> Value
    ) throws -> Value {
        try Task.checkCancellation()
        let value = try operation()
        try Task.checkCancellation()
        return value
    }
}
