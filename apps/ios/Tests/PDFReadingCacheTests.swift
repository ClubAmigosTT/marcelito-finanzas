import Foundation
import XCTest
@testable import Marcelito

private final class PDFWorkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0

    var maximumConcurrent: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    func enter() {
        lock.lock()
        active += 1
        peak = max(peak, active)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}

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

    func testExtractionCoordinatorSerializesPDFJobs() async throws {
        let coordinator = PDFExtractionCoordinator()
        let probe = PDFWorkProbe()
        let values = try await withThrowingTaskGroup(of: Int.self) { group in
            for value in 0..<4 {
                group.addTask {
                    try await coordinator.perform {
                        probe.enter()
                        defer { probe.leave() }
                        Thread.sleep(forTimeInterval: 0.01)
                        return value
                    }
                }
            }
            var results: [Int] = []
            for try await value in group { results.append(value) }
            return results.sorted()
        }

        XCTAssertEqual(values, [0, 1, 2, 3])
        XCTAssertEqual(probe.maximumConcurrent, 1)
    }

    func testExtractionCoordinatorStopsCanceledPageWork() async throws {
        let coordinator = PDFExtractionCoordinator()
        let started = AsyncStream<Void>.makeStream(of: Void.self)
        let task = Task {
            try await coordinator.perform {
                started.continuation.yield(())
                for _ in 0..<500 {
                    if Task.isCancelled { break }
                    Thread.sleep(forTimeInterval: 0.002)
                }
                try Task.checkCancellation()
                return true
            }
        }

        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Una extracción cancelada no debe devolver un resultado parcial")
        } catch is CancellationError {
            // Expected: the current PDF job stopped at its next cancellation check.
        }
    }
}
