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

    private func statement(
        _ source: String,
        key: String?,
        kind: StatementKind,
        period: String = "01/08/2026 - 31/08/2026",
        importedAt: Date = .now,
        summary: StatementSummaryRecord = .init()
    ) -> StatementRecord {
        StatementRecord(id: UUID(), source: source, accountKey: key, period: period,
            fileName: "fixture.pdf", importedAt: importedAt, transactionCount: 0, requiresReview: false, kind: kind,
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

    func testMissingBBVAIdentityJoinsOnlyKnownAccountAndReplacesRepeatedPeriod() {
        withStore { store in
            let known = statement("BBVA", key: "bbva:4922", kind: .bank, period: "15/03/2026 - 14/04/2026")
            let firstJuly = statement("BBVA", key: nil, kind: .bank, period: "15/07/2026 - 14/08/2026",
                importedAt: Date(timeIntervalSince1970: 1_786_000_000))
            let replacementJuly = statement("BBVA", key: nil, kind: .bank, period: "15/07/2026 - 14/08/2026",
                importedAt: Date(timeIntervalSince1970: 1_787_000_000))
            store.statements = [known, firstJuly, replacementJuly]
            var oldRow = row(-100, date: Date(timeIntervalSince1970: 1_786_500_000), title: "COMPRA REPETIDA")
            oldRow.statementId = firstJuly.id
            var replacementRow = oldRow
            replacementRow.id = UUID()
            replacementRow.statementId = replacementJuly.id
            store.movements = [oldRow, replacementRow]

            store.normalizeFinanceForTesting()

            XCTAssertEqual(store.statements.count, 2)
            XCTAssertTrue(store.statements.allSatisfy { $0.accountKey == "bbva:4922" })
            XCTAssertTrue(store.statements.contains { $0.id == replacementJuly.id })
            XCTAssertFalse(store.statements.contains { $0.id == firstJuly.id })
            XCTAssertEqual(store.movements.count, 1)
            XCTAssertEqual(store.movements.first?.statementId, replacementJuly.id)
        }
    }

    func testMissingIdentityIsNotGuessedWhenIssuerHasTwoKnownAccounts() {
        withStore { store in
            store.statements = [
                statement("BBVA", key: "bbva:1111", kind: .bank, period: "15/01/2026 - 14/02/2026"),
                statement("BBVA", key: "bbva:2222", kind: .bank, period: "15/02/2026 - 14/03/2026"),
                statement("BBVA", key: nil, kind: .bank, period: "15/03/2026 - 14/04/2026")
            ]

            store.normalizeFinanceForTesting()

            XCTAssertEqual(store.statements.count, 3)
            XCTAssertEqual(store.statements.filter { $0.accountKey == nil }.count, 1)
        }
    }

    func testBBVAAccountNumberCanAppearAfterLongCoverPage() {
        let cover = Array(repeating: "Aviso legal del estado", count: 180).joined(separator: "\n")
        let text = "BBVA MEXICO\n\(cover)\nNo. de Cuenta 1575694922\nDetalle de Movimientos Realizados"

        let snapshot = FinanceStore.readerParseSnapshotForTesting(text: text, fileName: "bbva.pdf", sourceHint: "BBVA")

        XCTAssertEqual(snapshot.accountKey, "bbva:4922")
    }

    func testBBVAForeignChargeWithoutPrintedBalanceKeepsAuthorizationEvidence() {
        let text = """
        BBVA MEXICO, S.A., INSTITUCION DE BANCA MULTIPLE
        Periodo DEL 15/11/2025 AL 14/12/2025
        No. de Cuenta 1575694922
        Saldo Anterior 1,222.92
        Depósitos / Abonos (+) 0 0.00
        Retiros / Cargos (-) 2 99.89
        Saldo Final 1,123.03
        Detalle de Movimientos Realizados
        18/NOV 16/NOV FACEBK *UG4FT6ZNY2 40.89
        USD 2.22TC018.4189AUT: 057867 Referencia ******1945
        18/NOV 18/NOV Google One 59.00 1,123.03 1,123.03
        Total de Movimientos
        TOTAL IMPORTE CARGOS 99.89 TOTAL MOVIMIENTOS CARGOS 2
        TOTAL IMPORTE ABONOS 0.00 TOTAL MOVIMIENTOS ABONOS 0
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "Diciembre BBVA 25.pdf",
            sourceHint: "BBVA"
        )

        XCTAssertEqual(snapshot.movements.count, 2)
        XCTAssertEqual(snapshot.movements.reduce(Decimal.zero) { $0 + abs($1.amount) }, Decimal(string: "99.89"))
        XCTAssertTrue(snapshot.movements.allSatisfy { $0.amount < 0 })
        XCTAssertEqual(snapshot.movements.first?.extractionEvidence?.selectedColumn, "CARGOS (USD/TC/AUT)")
    }

    func testBBVARunningBalanceOverridesMisleadingPaymentDescriptionInDepositColumn() {
        let text = """
        BBVA MEXICO, S.A., INSTITUCION DE BANCA MULTIPLE
        Periodo DEL 15/03/2026 AL 14/04/2026
        No. de Cuenta 1575694922
        Saldo Anterior 66.87
        Depósitos / Abonos (+) 2 4,000.00
        Retiros / Cargos (-) 1 2,000.00
        Saldo Final 2,066.87
        Detalle de Movimientos Realizados
        27/MAR 27/MAR SPEI RECIBIDOSANTANDER 2,000.00
        27/MAR 27/MAR PAGO CUENTA DE TERCERO 2,000.00
        27/MAR 27/MAR PAGO CUENTA DE TERCERO 2,000.00 2,066.87 2,066.87
        Total de Movimientos
        TOTAL IMPORTE CARGOS 2,000.00 TOTAL MOVIMIENTOS CARGOS 1
        TOTAL IMPORTE ABONOS 4,000.00 TOTAL MOVIMIENTOS ABONOS 2
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "Abril BBVA.pdf",
            sourceHint: "BBVA"
        )

        XCTAssertEqual(snapshot.movements.count, 3)
        XCTAssertEqual(snapshot.movements.map(\.amount), [2_000, -2_000, 2_000])
        XCTAssertEqual(snapshot.movements.last?.extractionEvidence?.selectedColumn, "ABONOS (saldo corrido)")
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

    func testRappiReviewSurvivesReplacementStatementAndMovementIDs() {
        withStore { store in
            let original = statement("Rappi", key: "rappi:1234", kind: .card)
            let date = Date(timeIntervalSince1970: 1785715200)
            var movement = row(-100, date: date, title: "COMERCIO EJEMPLO")
            movement.account = "Rappi"
            movement.statementId = original.id
            store.statements = [original]
            store.movements = [movement]
            store.updateClassification(for: movement, kind: .purchase, travelRelated: true)
            store.updateCategory(for: movement, to: "Salud")

            let replacement = statement("Rappi", key: "rappi:1234", kind: .card)
            var reread = row(-100, date: date, title: "COMERCIO EJEMPLO")
            reread.account = "Rappi"
            reread.statementId = replacement.id
            store.statements = [replacement]
            store.movements = [reread]
            store.normalizeFinanceForTesting()
            XCTAssertEqual(store.movements.count, 1)
            XCTAssertEqual(store.movements.first?.category, "Salud")
            XCTAssertEqual(store.movements.first?.travelRelated, true)
            XCTAssertEqual(store.movements.first?.manuallyReviewed, true)
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
