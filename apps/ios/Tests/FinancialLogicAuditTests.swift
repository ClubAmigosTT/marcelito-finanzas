import XCTest
@testable import Marcelito

@MainActor
final class FinancialLogicAuditTests: XCTestCase {
    private func withStore(_ run: (FinanceStore) throws -> Void) rethrows {
        let store = FinanceStore()
        store.clearLocalData()
        defer { store.clearLocalData() }
        try run(store)
    }

    private func row(_ amount: Decimal, kind: MovementKind = .purchase, date: Date = .now, title: String = "Comercio ejemplo") -> Movement {
        Movement(date: date, title: title, account: "BBVA", category: "Compras personales", amount: amount,
            flow: amount > 0 ? .income : .expense, kind: kind)
    }

    private func statement(_ source: String, key: String, kind: StatementKind, summary: StatementSummaryRecord = .init()) -> StatementRecord {
        StatementRecord(id: UUID(), source: source, accountKey: key, period: "01/08/2026 - 31/08/2026",
            fileName: "fixture.pdf", importedAt: .now, transactionCount: 0, requiresReview: false, kind: kind,
            summary: summary, reconciliation: StatementReconciliationRecord(status: .valid, tolerance: 0),
            sourceDetection: SourceDetectionEvidence(source: source, confidence: 0.999, status: .verified,
                evidence: ["encabezado verificado"], ignoredBodyMentions: []), readerVersion: FinanceStore.readerVersion)
    }

    func testRefundClosesCategoryCalendarMonthlyAndFlow() {
        withStore { store in
            store.movements = [row(-1000), row(200, kind: .refund)]
            XCTAssertEqual(store.consolidatedRealSpend, 800)
            XCTAssertEqual(store.monthlyExpense, 800)
            XCTAssertEqual(store.netExpenseMovements.reduce(0) { $0 + $1.expenseContribution }, 800)
            XCTAssertEqual(store.cashFlowHistory.reduce(0) { $0 + $1.expense }, 800)
            XCTAssertEqual(store.netFlow, -800)
            let calendar = SpendingCalendarAnalytics(movements: store.netExpenseMovements, selectedDate: .now)
            XCTAssertEqual(calendar.summary.actualTotal, 800)
        }
    }

    func testRefundsCanExceedPurchasesWithoutClamping() {
        withStore { store in
            store.movements = [row(-100), row(200, kind: .refund)]
            XCTAssertEqual(store.consolidatedRealSpend, -100)
            XCTAssertEqual(store.netFlow, 100)
        }
    }

    func testScreenshotAndManualUseSameCalendarMonth() {
        withStore { store in
            let old = Calendar.current.date(byAdding: .month, value: -1, to: .now)!
            var screenshot = row(-200, date: old)
            screenshot.extractionEvidence = MovementExtractionEvidence(method: "screenshot-vision", confidence: 1)
            store.movements = [row(-100), screenshot, row(-300, date: old)]
            XCTAssertEqual(store.monthlyExpense, 100)
            XCTAssertTrue(store.dashboardIsProvisional)
            XCTAssertEqual(store.consolidatedRealSpend, 600)
        }
    }

    func testLocalUberIsNotTravelAndManualTagWins() {
        withStore { store in
            let uber = row(-100, title: "UBER TRIP")
            store.movements = [uber]
            XCTAssertEqual(store.travelSpend, 0)
            store.updateClassification(for: uber, kind: .purchase, travelRelated: true)
            XCTAssertEqual(store.travelSpend, 100)
            store.updateClassification(for: uber, kind: .purchase, travelRelated: false)
            XCTAssertEqual(store.travelSpend, 0)
        }
    }

    func testSignedCashAndNoInventedObligations() {
        withStore { store in
            let bank = statement("BBVA", key: "bbva:1", kind: .bank, summary: StatementSummaryRecord(cashBalance: -500))
            XCTAssertEqual(store.statementMetricForTesting(bank).cashBalance, -500)
            let card = statement("Amex", key: "amex:1", kind: .card,
                summary: StatementSummaryRecord(previousBalance: 5000, newCharges: 1000, msiOriginalDeferred: 12000))
            let metric = store.statementMetricForTesting(card)
            XCTAssertNil(metric.paymentForNoInterest)
            XCTAssertNil(metric.msiPending)
            XCTAssertNil(metric.msiMonthlyLoad)
        }
    }

    func testAllCardsIncludedAndMissingValueNotZero() {
        withStore { store in
            store.statements = [
                statement("Amex", key: "amex:1", kind: .card, summary: StatementSummaryRecord(creditLimit: 10000, creditAvailable: 5000, paymentForNoInterest: 300, msiPending: 1200)),
                statement("Amex", key: "amex:2", kind: .card, summary: StatementSummaryRecord(creditLimit: 10000, paymentForNoInterest: 400, msiPending: 800))
            ]
            XCTAssertEqual(store.latestMsiPending, 2000)
            XCTAssertEqual(store.latestPaymentForNoInterest, 700)
            XCTAssertNil(store.creditAvailable)
            XCTAssertNil(store.creditUsed)
            XCTAssertNil(store.creditUtilizationRate)
        }
    }

    func testMissingCalendarDaysAreNotZeroSamples() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .day, value: 30, to: start)!
        let after = calendar.date(byAdding: .day, value: 60, to: start)!
        let analytics = SpendingCalendarAnalytics(movements: [row(-100, date: start), row(-100, date: end)],
            selectedDate: after, now: after, coveredDays: [start, end])
        XCTAssertEqual(analytics.historicalDailyAverage, 100)
        XCTAssertEqual(analytics.historicalMedian, 100)
        XCTAssertEqual(analytics.historySampleDays, 2)
        XCTAssertEqual(analytics.historyDays.filter(\.isCovered).count, 2)
    }

    func testFutureDaysDoNotChangePartialWeek() {
        let calendar = Calendar(identifier: .iso8601)
        let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7))!
        let friday = calendar.date(byAdding: .day, value: 4, to: monday)!
        let analytics = SpendingCalendarAnalytics(movements: [row(-100, date: monday), row(-900, date: friday)],
            selectedDate: monday, now: monday, calendar: calendar)
        XCTAssertEqual(analytics.summary.actualTotal, 100)
        XCTAssertEqual(analytics.summary.dailyAverage, 100)
        XCTAssertEqual(analytics.summary.highest?.date, monday)
    }

    func testDifferentAccountsCannotDeduplicateSamePurchase() {
        withStore { store in
            let a = statement("BBVA", key: "bbva:1111", kind: .bank)
            let b = statement("BBVA", key: "bbva:2222", kind: .bank)
            store.statements = [a,b]
            var first = row(-100); first.statementId = a.id
            var second = row(-100, date: first.date); second.statementId = b.id
            store.movements = [first, second]
            store.normalizeFinanceForTesting()
            XCTAssertEqual(store.movements.count, 2)
        }
    }

    func testManualReviewSurvivesNormalization() {
        withStore { store in
            let movement = row(-100, title: "SPEI TRANSFERENCIA MARCELO DIAZ")
            store.movements = [movement]
            store.updateClassification(for: movement, kind: .purchase, travelRelated: false)
            store.normalizeFinanceForTesting()
            XCTAssertEqual(store.movements.first?.kind, .purchase)
            XCTAssertTrue(store.movements.first?.manuallyReviewed == true)
        }
    }

    private func capture(_ source: BankScreenshotSource, key: String?, title: String, amount: Decimal, fingerprint: String) -> BankScreenshotImportResult {
        let evidence = MovementExtractionEvidence(method: "screenshot-vision", page: 1, confidence: 0.99,
            sourceText: "\(title) \(amount)", selectedAmount: amount)
        let movement = BankScreenshotMovement(date: .now, title: title, displayedAmount: amount, normalizedAmount: amount,
            pending: false, confidence: 0.99, imageFingerprint: fingerprint, evidence: evidence)
        return BankScreenshotImportResult(source: source, accountKey: key, importedAt: .now,
            inputs: [BankScreenshotInput(data: Data([1]), fileName: "synthetic.image")], imageFingerprints: [fingerprint], movements: [movement], warnings: [])
    }

    func testScreenshotsInDifferentAccountsStaySeparate() throws {
        try withStore { store in
            _ = try store.saveBankScreenshotImport(capture(.bbva, key: "bbva:1111", title: "TIENDA EJEMPLO", amount: -100, fingerprint: "audit-a"))
            let second = try store.saveBankScreenshotImport(capture(.bbva, key: "bbva:2222", title: "TIENDA EJEMPLO", amount: -100, fingerprint: "audit-b"))
            XCTAssertEqual(second.duplicateCount, 0)
            XCTAssertEqual(store.consolidatedRealSpend, 200)
        }
    }

    func testAmbiguousScreenshotDuplicateRetainedUntilDecision() throws {
        try withStore { store in
            _ = try store.saveBankScreenshotImport(capture(.bbva, key: nil, title: "TIENDA EJEMPLO", amount: -100, fingerprint: "audit-a"))
            let second = try store.saveBankScreenshotImport(capture(.bbva, key: nil, title: "TIENDA EJEMPLO", amount: -100, fingerprint: "audit-b"))
            XCTAssertEqual(second.duplicateCount, 1)
            XCTAssertEqual(store.consolidatedRealSpend, 200)
            store.resolveScreenshotDuplicates(captureID: second.captureID, keepBoth: [])
            XCTAssertEqual(store.consolidatedRealSpend, 100)
        }
    }

    func testOfficialSameAmountDifferentMerchantCannotConsumeCapture() throws {
        try withStore { store in
            let bank = statement("BBVA", key: "bbva:1111", kind: .bank)
            store.statements = [bank]
            var official = row(-100, title: "RESTAURANTE EJEMPLO")
            official.statementId = bank.id
            store.movements = [official]
            let receipt = try store.saveBankScreenshotImport(capture(.bbva, key: "bbva:1111", title: "FARMACIA DISTINTA", amount: -100, fingerprint: "audit-c"))
            XCTAssertEqual(receipt.confirmedCount, 0)
            XCTAssertEqual(receipt.provisionalCount, 1)
        }
    }

    func testOwnScreenshotTransferWithAccountAndOwnerEvidence() throws {
        try withStore { store in
            _ = try store.saveBankScreenshotImport(capture(.bbva, key: "bbva:1111", title: "SPEI ENVIADO MARCELO DIAZ REF ABCDE99", amount: -100, fingerprint: "audit-a"))
            _ = try store.saveBankScreenshotImport(capture(.santander, key: "santander:2222", title: "SPEI RECIBIDO MARCELO DIAZ REF ABCDE99", amount: 100, fingerprint: "audit-b"))
            XCTAssertEqual(store.movements.filter { $0.kind == .bankTransfer }.count, 2)
            XCTAssertEqual(store.consolidatedRealSpend, 0)
            XCTAssertEqual(store.realIncome, 0)
            XCTAssertEqual(store.totalTransfers, 100)
        }
    }
}
