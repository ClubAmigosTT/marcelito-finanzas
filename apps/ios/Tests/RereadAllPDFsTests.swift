import XCTest
@testable import Marcelito

@MainActor
final class RereadAllPDFsTests: XCTestCase {
    func testCacheRemoveAllForgetsEverySavedExtraction() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("marcelito.reader.\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PDFReadingCache(directory: directory)
        let key = String(repeating: "a", count: 64)
        cache.store(["fila"], key: key)
        XCTAssertEqual(cache.load([String].self, key: key), ["fila"])
        cache.removeAll()
        XCTAssertNil(cache.load([String].self, key: key))
    }

    func testRereadWithoutStoredPDFsDoesNothing() async {
        let store = FinanceStore(); store.clearLocalData()
        defer { store.clearLocalData() }
        let result = await store.rereadAllStoredPDFsAsync()
        XCTAssertEqual(result.candidateCount, 0)
        XCTAssertFalse(store.hasCanonicalRebuildPending)
    }

    func testRereadThatCannotReadAPDFKeepsTheCurrentLedger() async throws {
        let store = FinanceStore(); store.clearLocalData()
        defer { store.clearLocalData() }
        let statement = StatementRecord(id: UUID(), source: "BBVA", accountKey: "bbva:4922", period: "01/09/2026 - 30/09/2026", fileName: "fixture.pdf",
            importedAt: .now, transactionCount: 1, requiresReview: false, kind: .bank,
            reconciliation: StatementReconciliationRecord(status: .valid, tolerance: 0),
            readerVersion: FinanceStore.readerVersion)
        var row = Movement(date: .now, title: "COMERCIO SINTETICO", account: "BBVA", category: "Compras personales", amount: -100, flow: .expense, kind: .purchase)
        row.statementId = statement.id
        store.statements = [statement]
        store.movements = [row]
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImportedStatements", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("%PDF-synthetic-unreadable".utf8).write(to: folder.appendingPathComponent("synthetic.pdf"))

        let result = await store.rereadAllStoredPDFsAsync()

        XCTAssertEqual(result.candidateCount, 1)
        XCTAssertEqual(store.statements.map(\.id), [statement.id])
        XCTAssertEqual(store.movements.map(\.id), [row.id])
    }
}
