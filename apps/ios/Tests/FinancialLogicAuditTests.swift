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

    private func calendarDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func coveredDays(_ calendar: Calendar, year: Int, month: Int, through day: Int) -> Set<Date> {
        Set((1...day).map { calendar.startOfDay(for: date(calendar, year, month, $0, hour: 0)) })
    }

    private func balance(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, cash: Decimal?, debt: Decimal?) -> FinanceStore.BalanceSnapshot {
        FinanceStore.BalanceSnapshot(date: date(calendar, year, month, day), cash: cash, debt: debt)
    }

    func testSpendingPaceUsesEquivalentPartialPeriodsAndWeeklyRealSpend() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date(calendar, 2026, 9, 17)
        let movements = [
            row(-4_200, date: date(calendar, 2026, 9, 2)),
            row(-3_100, date: date(calendar, 2026, 9, 10)),
            row(-6_797, date: date(calendar, 2026, 9, 17)),
            row(-16_000, date: date(calendar, 2026, 8, 4))
        ]
        let coverage = coveredDays(calendar, year: 2026, month: 8, through: 17)
            .union(coveredDays(calendar, year: 2026, month: 9, through: 17))

        let metrics = SpendingPaceMetrics.calculate(movements: movements, coveredDays: coverage, now: now, calendar: calendar)

        XCTAssertEqual(metrics?.accumulatedSpend, 14_097)
        XCTAssertEqual(metrics?.dailyAverage, Decimal(14_097) / Decimal(17))
        XCTAssertEqual(metrics?.projectedMonth, (Decimal(14_097) / Decimal(17)) * Decimal(30))
        XCTAssertEqual(metrics?.weeklySpend.map(\.amount), [Decimal(4_200), Decimal(3_100), Decimal(6_797)])
        XCTAssertEqual(metrics?.comparisonPercentChange, (Decimal(14_097) - Decimal(16_000)) / Decimal(16_000))
    }

    func testSpendingPaceDoesNotProjectWithIncompleteCoverageOrInventEmptyData() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date(calendar, 2026, 9, 17)
        let oneObservedPurchase = [row(-100, date: date(calendar, 2026, 9, 4))]

        let incomplete = SpendingPaceMetrics.calculate(movements: oneObservedPurchase, coveredDays: [], now: now, calendar: calendar)
        XCTAssertEqual(incomplete?.accumulatedSpend, 100)
        XCTAssertNil(incomplete?.dailyAverage)
        XCTAssertNil(incomplete?.projectedMonth)
        XCTAssertEqual(incomplete?.weeklySpend, [SpendingPaceWeek(number: 1, amount: 100)])
        XCTAssertNil(incomplete?.comparisonPercentChange)
        XCTAssertNil(SpendingPaceMetrics.calculate(movements: [], coveredDays: [], now: now, calendar: calendar))
    }

    func testSpendingPaceShowsObservedWeeksWithoutAssumingUncoveredWeeksAreZero() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date(calendar, 2026, 9, 17)
        let movements = [
            row(-100, date: date(calendar, 2026, 9, 2)),
            row(-250, date: date(calendar, 2026, 9, 16))
        ]

        let metrics = SpendingPaceMetrics.calculate(movements: movements, coveredDays: [], now: now, calendar: calendar)

        XCTAssertEqual(metrics?.accumulatedSpend, 350)
        XCTAssertEqual(metrics?.weeklySpend, [
            SpendingPaceWeek(number: 1, amount: 100),
            SpendingPaceWeek(number: 3, amount: 250)
        ])
        XCTAssertNil(metrics?.dailyAverage)
        XCTAssertNil(metrics?.projectedMonth)
    }

    func testSpendingPaceHandlesZeroNetSpendAndExcludesOwnTransfersAndCardPayments() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date(calendar, 2026, 9, 17)
        let coverage = coveredDays(calendar, year: 2026, month: 9, through: 17)

        let zeroSpend = SpendingPaceMetrics.calculate(movements: [], coveredDays: coverage, now: now, calendar: calendar)
        XCTAssertEqual(zeroSpend?.accumulatedSpend, 0)
        XCTAssertEqual(zeroSpend?.dailyAverage, 0)
        XCTAssertEqual(zeroSpend?.projectedMonth, 0)
        XCTAssertTrue(zeroSpend?.weeklySpend.allSatisfy { $0.amount == 0 } == true)

        withStore { store in
            store.movements = [
                row(-120, kind: .purchase, date: now),
                row(-500, kind: .cardPayment, date: now),
                row(-200, kind: .bankTransfer, date: now),
                row(50, kind: .refund, date: now)
            ]
            let metrics = SpendingPaceMetrics.calculate(
                movements: store.netExpenseMovements,
                coveredDays: coverage,
                now: now,
                calendar: calendar
            )
            XCTAssertEqual(metrics?.accumulatedSpend, 70)
        }
    }

    func testPositionHistoryUsesCompleteCutsAndOnlyAdjacentMonthsForVariation() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let snapshots = [
            balance(calendar, 2026, 5, 31, cash: 100, debt: 20),
            balance(calendar, 2026, 6, 30, cash: 110, debt: 20),
            balance(calendar, 2026, 7, 15, cash: 125, debt: 30),
            balance(calendar, 2026, 7, 31, cash: nil, debt: 30),
            balance(calendar, 2026, 8, 31, cash: 140, debt: 40)
        ]

        let points = PositionHistoryBuilder.monthlyPoints(from: snapshots, calendar: calendar)
        XCTAssertEqual(points.map(\.value), [Decimal(80), Decimal(90), Decimal(95), Decimal(100)])
        XCTAssertEqual(PositionHistoryBuilder.contiguousSuffix(points, limit: 3, calendar: calendar).map(\.value), [Decimal(90), Decimal(95), Decimal(100)])
        let change = PositionHistoryBuilder.monthOverMonthChange(in: points, calendar: calendar)
        XCTAssertEqual(change?.amount, 5)
        XCTAssertEqual(change?.percent, Decimal(5) / Decimal(95))

        let gap = [points[0], points[2]]
        XCTAssertEqual(PositionHistoryBuilder.contiguousSuffix(gap, limit: 6, calendar: calendar).map(\.value), [Decimal(95)])
        XCTAssertNil(PositionHistoryBuilder.monthOverMonthChange(in: gap, calendar: calendar))
    }

    func testPositionCoverageRatioAndSharedScaleHandleZeroDebtAndZeroBalances() {
        XCTAssertEqual(PositionFinancialCalculations.debtCoverageRatio(cash: 55_520, debt: 52_960), Decimal(55_520) / Decimal(52_960))
        XCTAssertNil(PositionFinancialCalculations.debtCoverageRatio(cash: 55_520, debt: 0))
        XCTAssertNil(PositionFinancialCalculations.debtCoverageRatio(cash: -1, debt: 100))

        let scale = PositionBalanceScale(cash: 55_520, debt: 52_960)
        XCTAssertEqual(scale.fraction(for: 55_520), 1)
        XCTAssertEqual(scale.fraction(for: 52_960), NSDecimalNumber(decimal: Decimal(52_960) / Decimal(55_520)).doubleValue)
        XCTAssertEqual(PositionBalanceScale(cash: 0, debt: 0).fraction(for: 0), 0)
    }

    func testAccountStatementStatusTracksMonthlyCutoffAndDueDate() {
        withStore { store in
            store.statements = [
                statement("BBVA", key: "bbva:4922", kind: .bank, period: "15/07/2026 - 14/08/2026"),
                statement("BBVA", key: "bbva:4922", kind: .bank, period: "15/08/2026 - 14/09/2026")
            ]

            let current = store.accountStatementStatus(
                for: "BBVA",
                kind: .bank,
                accountKey: "bbva:4922",
                today: calendarDate(2026, 10, 13)
            )
            XCTAssertEqual(current.state, .current)
            XCTAssertEqual(current.latestCutoff, calendarDate(2026, 9, 14))
            XCTAssertEqual(current.nextCutoff, calendarDate(2026, 10, 14))
            XCTAssertTrue(current.isUpToDate)

            let due = store.accountStatementStatus(
                for: "BBVA",
                kind: .bank,
                accountKey: "bbva:4922",
                today: calendarDate(2026, 10, 14)
            )
            XCTAssertEqual(due.state, .due)
            XCTAssertFalse(due.isUpToDate)
        }
    }

    func testAccountStatementStatusTurnsRedForMissingOrUnreconciledState() {
        withStore { store in
            XCTAssertEqual(
                store.accountStatementStatus(for: "Santander", kind: .bank, accountKey: nil, today: calendarDate(2026, 9, 26)).state,
                .noStatement
            )

            var review = statement("Santander", key: "santander:7079", kind: .bank, period: "01/08/2026 - 31/08/2026")
            review.requiresReview = true
            store.statements = [review]
            let status = store.accountStatementStatus(
                for: "Santander",
                kind: .bank,
                accountKey: "santander:7079",
                today: calendarDate(2026, 9, 1)
            )
            XCTAssertEqual(status.state, .needsReview)
            XCTAssertFalse(status.isUpToDate)
        }
    }

    func testAccountStatementStatusKeepsMonthEndCutoffAtNextMonthEnd() {
        withStore { store in
            store.statements = [
                statement("Santander", key: "santander:7079", kind: .bank, period: "01/07/2026 - 31/08/2026")
            ]

            let status = store.accountStatementStatus(
                for: "Santander",
                kind: .bank,
                accountKey: "santander:7079",
                today: calendarDate(2026, 9, 29)
            )
            XCTAssertEqual(status.latestCutoff, calendarDate(2026, 8, 31))
            XCTAssertEqual(status.nextCutoff, calendarDate(2026, 9, 30))
            XCTAssertEqual(status.state, .current)
        }
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
            let bank = statement("BBVA", key: "bbva:0001", kind: .bank, summary: StatementSummaryRecord(cashBalance: -500))
            XCTAssertEqual(store.statementMetricForTesting(bank).cashBalance, -500)
            let card = statement("Amex", key: "amex:0001", kind: .card,
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
                statement("Amex", key: "amex:0001", kind: .card, summary: StatementSummaryRecord(creditLimit: 10000, creditAvailable: 5000, paymentForNoInterest: 300, msiPending: 1200)),
                statement("Amex", key: "amex:0002", kind: .card, summary: StatementSummaryRecord(creditLimit: 10000, paymentForNoInterest: 400, msiPending: 800))
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

    func testMissingBBVAIdentityRemainsSeparateAndDoesNotReplaceRepeatedPeriod() {
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

            XCTAssertEqual(store.statements.count, 3)
            XCTAssertEqual(store.statements.filter { $0.accountKey == nil }.count, 2)
            XCTAssertTrue(store.statements.contains { $0.id == firstJuly.id })
            XCTAssertTrue(store.statements.contains { $0.id == replacementJuly.id })
            XCTAssertEqual(store.movements.count, 2)
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
