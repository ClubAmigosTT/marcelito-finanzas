import XCTest
@testable import Marcelito

/// A re-read that comes out worse for one PDF keeps that PDF's previous,
/// reconciled reading instead of dropping it from the ledger.
@MainActor
final class RebuildPreservationTests: XCTestCase {
    private func statement(_ status: StatementReconciliationStatus, fingerprint: String, review: Bool = false) -> StatementRecord {
        StatementRecord(id: UUID(), source: "Tarjeta", accountKey: "tarjeta:1001", period: "01/06/2026 - 30/06/2026", fileName: "fixture.pdf",
                        importedAt: .now, transactionCount: 1, requiresReview: review, kind: .card,
                        reconciliation: StatementReconciliationRecord(status: status, tolerance: 0),
                        sourceFingerprint: fingerprint, readerVersion: FinanceStore.readerVersion)
    }

    private func row(_ statement: StatementRecord, _ amount: Decimal) -> Movement {
        Movement(date: .now, title: "TIENDA", account: "Tarjeta", category: "Tiendita", amount: amount, flow: .expense, statementId: statement.id, kind: .purchase)
    }

    func testWorseReadingKeepsThePreviousStatementAndRows() {
        let previous = statement(.valid, fingerprint: "pdf-a")
        let previousRow = row(previous, -100)
        let fresh = statement(.invalid, fingerprint: "pdf-a", review: true)
        let scratch = FinanceStore(); scratch.clearLocalData(); defer { scratch.clearLocalData() }
        scratch.statements = [fresh]
        scratch.movements = [row(fresh, -90)]

        XCTAssertEqual(scratch.preserveReconciledStatements(from: [previous], movements: [previousRow]), 1)
        XCTAssertEqual(scratch.statements.map(\.id), [previous.id])
        XCTAssertEqual(scratch.movements.map(\.id), [previousRow.id])
    }

    func testBetterOrDifferentReadingsAreLeftAlone() {
        let previous = statement(.valid, fingerprint: "pdf-a")
        let fresh = statement(.valid, fingerprint: "pdf-a")
        let other = statement(.invalid, fingerprint: "pdf-b")
        let scratch = FinanceStore(); scratch.clearLocalData(); defer { scratch.clearLocalData() }
        scratch.statements = [fresh, other]

        XCTAssertEqual(scratch.preserveReconciledStatements(from: [previous, statement(.invalid, fingerprint: "pdf-b")], movements: []), 0)
        XCTAssertEqual(Set(scratch.statements.map(\.id)), [fresh.id, other.id])
    }
}
