import Foundation
import XCTest
@testable import Marcelito

final class PDFReadingCacheTests: XCTestCase {
    func testCacheRoundTripVersionIsolationAndCorruptEntry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PDFReadingCache(directory: directory)
        let first = String(repeating: "a", count: 64)
        let other = String(repeating: "b", count: 64)
        cache.store(["rows": 2], key: first)
        XCTAssertEqual(cache.load([String: Int].self, key: first), ["rows": 2])
        XCTAssertNil(cache.load([String: Int].self, key: other))
        try Data("broken".utf8).write(to: directory.appendingPathComponent(first + ".json"))
        XCTAssertNil(cache.load([String: Int].self, key: first))
        XCTAssertNil(cache.load([String: Int].self, key: "../escape"))
    }
}
