import XCTest
import Observation
import SwiftUI
import UIKit
@testable import Marcelito

/// Opt-in regression with a private PDF. The document stays outside Git.
@MainActor final class PDFImportRegressionTests: XCTestCase {
    func testAsyncImportKeepsProgressAndObservedStateOnMainActor() async throws {
        let original = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("marcelito.") }
        let store = FinanceStore(); store.clearLocalData()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-bbva-\(UUID()).pdf")
        defer {
            store.clearLocalData(); try? FileManager.default.removeItem(at: url)
            for (key, value) in original { UserDefaults.standard.set(value, forKey: key) }
        }
        // Intentionally incomplete controls: exercise the real PDF service
        // without accepting fabricated financial rows or private fixtures.
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage()
            ("BBVA\nEstado de Cuenta\nLibretón Básico Cuenta Digital\nPeriodo DEL 01/09/2026 AL 30/09/2026" as NSString).draw(in: CGRect(x: 30, y: 30, width: 550, height: 300), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        }
        try data.write(to: url)
        let callback = expectation(description: "Progress returns to the UI actor")
        withObservationTracking { _ = store.statements } onChange: {
            XCTAssertTrue(Thread.isMainThread, "Observed ledger changes must execute on MainActor.")
        }
        let result = try await store.importPDFAsync(from: url, allowOCR: false, forceFresh: true) { _ in
            XCTAssertTrue(Thread.isMainThread, "Progress callbacks must execute on MainActor.")
            callback.fulfill()
        }
        await fulfillment(of: [callback], timeout: 2)
        XCTAssertTrue(result.requiresReview)
        XCTAssertEqual(store.statements.count, 1)
        XCTAssertTrue(store.movements.isEmpty, "Incomplete controls must not create canonical financial rows.")
    }

    func testPrivateBBVAImportAndReimportThroughTheUIService() async throws {
        guard let path = ProcessInfo.processInfo.environment["MARCELITO_IMPORT_REGRESSION_PDF"], !path.isEmpty else {
            throw XCTSkip("Define MARCELITO_IMPORT_REGRESSION_PDF para reproducir la importación privada.")
        }
        let url = URL(fileURLWithPath: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let original = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("marcelito.") }
        let store = FinanceStore(); store.clearLocalData()
        defer {
            store.clearLocalData()
            for (key, value) in original { UserDefaults.standard.set(value, forKey: key) }
        }
        withObservationTracking {
            _ = store.movements; _ = store.statements
        } onChange: {
            XCTAssertTrue(Thread.isMainThread, "Import must update the observed ledger on the main actor, never on the PDF worker.")
        }
        let planningSuite = "marcelito.import.planning.\(UUID())"; let defaults = UserDefaults(suiteName: planningSuite)!
        defer { defaults.removePersistentDomain(forName: planningSuite) }
        let planning = FinancialPlanningStore(defaults: defaults)
        // Render the real account screen while the asynchronous service runs.
        // A CLI-only parser test cannot catch observed-state/UI concurrency.
        let host = UIHostingController(rootView: AccountsView().environment(store).environment(planning))
        host.loadViewIfNeeded(); host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844); host.view.layoutIfNeeded()
        print("IMPORT_REGRESSION starting fresh async reader")
        let imported = try await store.importPDFAsync(from: url, forceFresh: true) { _ in
            XCTAssertTrue(Thread.isMainThread, "Import progress updates SwiftUI state and must remain on the main actor.")
            print("IMPORT_REGRESSION extraction returned; applying ledger")
        }
        host.view.layoutIfNeeded(); await Task.yield()
        print("IMPORT_REGRESSION import returned")
        XCTAssertEqual(imported.source, "BBVA")
        XCTAssertEqual(imported.kind, .bank)
        XCTAssertEqual(imported.reconciliation?.status, .valid)
        XCTAssertFalse(imported.requiresReview)
        let controls = try XCTUnwrap(imported.summary)
        let expectedRows = try XCTUnwrap(controls.depositCount) + XCTUnwrap(controls.withdrawalCount)
        XCTAssertEqual(imported.imported, expectedRows)
        XCTAssertEqual(store.movements.count, expectedRows)
        XCTAssertEqual(store.statements.count, 1)
        store.runAutomaticAuditIfNeeded(trigger: "import.regression")
        _ = store.balanceHistory; _ = store.netExpenseMovements; _ = store.realIncomeMovements
        if let row = store.movements.first {
            _ = planning.snapshot(store, month: row.date)
            _ = planning.expenseRows(store, period: .month(row.date))
        }
        _ = planning.recurringExpenseSuggestions(store)
        let expense = try XCTUnwrap(store.netExpenseMovements.first)
        XCTAssertTrue(store.updateCategory(for: expense, to: "Salud", applyToMerchant: false))
        print("IMPORT_REGRESSION starting fresh reimport")
        let repeated = try await store.importPDFAsync(from: url, forceFresh: true)
        XCTAssertEqual(repeated.reconciliation?.status, .valid)
        XCTAssertEqual(store.statements.count, 1)
        XCTAssertEqual(store.movements.count, expectedRows)
        XCTAssertTrue(store.movements.contains { $0.date == expense.date && $0.amount == expense.amount && $0.category == "Salud" && $0.manuallyReviewed })
        print("IMPORT_REGRESSION completed with reconciled rows and preserved manual category")
        let calendar = Calendar.current
        let month = calendar.date(byAdding: .month, value: -3, to: FinancePeriod.month(expense.date).start)!
        let period = FinancePeriod.month(month)
        let dayFormat = DateFormatter(); dayFormat.locale = Locale(identifier: "en_US_POSIX"); dayFormat.dateFormat = "dd/MM/yyyy"
        let closing = calendar.date(byAdding: .day, value: -1, to: period.end)!
        let historyID = UUID()
        let history = StatementRecord(id: historyID, source: "BBVA", accountKey: imported.accountKey,
            period: dayFormat.string(from: month) + " - " + dayFormat.string(from: closing), fileName: "synthetic-history.pdf", importedAt: .now, transactionCount: 1377, requiresReview: false, kind: .bank,
            summary: .init(previousBalance: 200000, statementBalance: 62300, depositTotal: 0, withdrawalTotal: 137700, depositCount: 0, withdrawalCount: 1377),
            reconciliation: .init(status: .valid, tolerance: 0, extractedDepositTotal: 0, extractedWithdrawalTotal: 137700, extractedMovementCount: 1377, expectedMovementCount: 1377),
            sourceDetection: .init(source: "BBVA", confidence: 1, status: .verified, evidence: ["synthetic fixture"], ignoredBodyMentions: []), readerVersion: FinanceStore.readerVersion)
        let historical = (0..<1377).map { index in
            var movement = Movement(date: calendar.date(byAdding: .day, value: index % 27, to: month)!, title: "Comercio QA \(index % 50)", account: "BBVA", category: "Salud", amount: -100, flow: .expense, statementId: historyID, kind: .purchase,
                extractionEvidence: .init(method: "fixture", page: 1, confidence: 1, sourceText: "synthetic history \(index)"))
            movement.manuallyReviewed = true
            return movement
        }
        store.statements.append(history); store.movements.append(contentsOf: historical)
        let originalIDs = Set(historical.map(\.id))
        _ = store.netExpenseMovements; _ = store.balanceHistory
        _ = planning.snapshot(store, month: expense.date)
        host.view.layoutIfNeeded(); await Task.yield()
        withObservationTracking { _ = store.movements; _ = store.statements } onChange: {
            XCTAssertTrue(Thread.isMainThread, "Loaded-book updates must also stay on MainActor.")
        }
        let loaded = try await store.importPDFAsync(from: url, forceFresh: true)
        host.view.layoutIfNeeded(); await Task.yield()
        XCTAssertEqual(loaded.reconciliation?.status, .valid)
        XCTAssertEqual(store.statements.count, 2)
        XCTAssertEqual(store.movements.count, 1377 + expectedRows)
        XCTAssertEqual(Set(store.movements.filter { originalIDs.contains($0.id) }.map(\.id)), originalIDs)
        XCTAssertTrue(store.movements.filter { originalIDs.contains($0.id) }.allSatisfy { $0.category == "Salud" && $0.amount == -100 })
        print("IMPORT_REGRESSION loaded-book import completed without dropping historical rows")
    }
}
