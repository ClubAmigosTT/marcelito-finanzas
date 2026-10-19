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
            store.updateCategory(for: movement, to: "Salud", applyToMerchant: false)

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

    private func capture(_ source: BankScreenshotSource, key: String?, rows: [(String, Decimal)], fingerprint: String) -> BankScreenshotImportResult {
        let movements = rows.map { title, amount in
            BankScreenshotMovement(date: .now, title: title, displayedAmount: amount, normalizedAmount: amount,
                pending: false, confidence: 0.99, imageFingerprint: fingerprint,
                evidence: MovementExtractionEvidence(method: "screenshot-vision", page: 1, confidence: 0.99,
                    sourceText: "\(title) \(amount)", selectedAmount: amount))
        }
        return BankScreenshotImportResult(source: source, accountKey: key, importedAt: .now,
            inputs: [BankScreenshotInput(data: Data([1]), fileName: "synthetic.image")], imageFingerprints: [fingerprint], movements: movements, warnings: [])
    }

    func testTwoIdenticalScreenshotRowsLinkToTwoIdenticalOfficialRows() throws {
        try withStore { store in
            let bank = statement("BBVA", key: "bbva:1111", kind: .bank)
            store.statements = [bank]
            var first = row(-85, title: "UBER TRIP"); first.statementId = bank.id
            var second = row(-85, title: "UBER TRIP"); second.statementId = bank.id
            store.movements = [first, second]
            let receipt = try store.saveBankScreenshotImport(capture(.bbva, key: "bbva:1111",
                rows: [("UBER TRIP", -85), ("UBER TRIP", -85)], fingerprint: "audit-tie"))
            XCTAssertEqual(receipt.confirmedCount, 2)
            XCTAssertEqual(store.consolidatedRealSpend, 170)
        }
    }

    func testRappiScreenshotLinksDespiteCardVersusAccountDigits() throws {
        try withStore { store in
            let card = statement("Rappi", key: "rappi:4321", kind: .card)
            store.statements = [card]
            var official = row(-250, title: "RESTAURANTE EJEMPLO")
            official.account = "Rappi"
            official.statementId = card.id
            store.movements = [official]
            let receipt = try store.saveBankScreenshotImport(capture(.rappi, key: "rappi:9876",
                title: "RESTAURANTE EJEMPLO", amount: -250, fingerprint: "audit-rappi"))
            XCTAssertEqual(receipt.confirmedCount, 1)
            XCTAssertEqual(receipt.provisionalCount, 0)
        }
    }

    func testDeletingTheOriginalCaptureReleasesItsConfirmedDuplicate() throws {
        try withStore { store in
            let original = try store.saveBankScreenshotImport(capture(.bbva, key: nil, title: "TIENDA EJEMPLO", amount: -100, fingerprint: "audit-a"))
            let copy = try store.saveBankScreenshotImport(capture(.bbva, key: nil, title: "TIENDA EJEMPLO", amount: -100, fingerprint: "audit-b"))
            store.resolveScreenshotDuplicates(captureID: copy.captureID, keepBoth: [])
            XCTAssertEqual(store.consolidatedRealSpend, 100)
            let deleted = try XCTUnwrap(store.screenshotCaptures.first { $0.id == original.captureID })
            store.deleteBankScreenshotCapture(deleted)
            XCTAssertEqual(store.consolidatedRealSpend, 100)
        }
    }

    func testStatementWithOneRowResolvesAnUndecidedScreenshotCopy() throws {
        try withStore { store in
            _ = try store.saveBankScreenshotImport(capture(.bbva, key: nil, title: "TIENDA EJEMPLO", amount: -100, fingerprint: "audit-a"))
            let copy = try store.saveBankScreenshotImport(capture(.bbva, key: nil, title: "TIENDA EJEMPLO", amount: -100, fingerprint: "audit-b"))
            XCTAssertEqual(copy.duplicateCount, 1)
            XCTAssertEqual(store.consolidatedRealSpend, 200)

            let bank = statement("BBVA", key: "bbva:1111", kind: .bank)
            var official = row(-100, title: "TIENDA EJEMPLO")
            official.statementId = bank.id
            store.statements = [bank]
            store.movements.append(official)
            store.reconcileBankScreenshotsAgainstOfficialLedger()
            XCTAssertEqual(store.consolidatedRealSpend, 100)
        }
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
    private func seedTransfer(_ store: FinanceStore, sharedReference: Bool = true) {
        let bank = statement("BBVA", key: "bbva:1111", kind: .bank)
        let destination = statement("Santander", key: "santander:2222", kind: .bank)
        store.statements = [bank, destination]
        var outgoing = row(-3000, date: calendarDate(2026, 8, 31), title: sharedReference ? "SPEI ENVIADO REF ABC123" : "SPEI ENVIADO")
        outgoing.statementId = bank.id
        var incoming = row(3000, kind: .income, date: calendarDate(2026, 9, 1), title: sharedReference ? "SPEI RECIBIDO REF ABC123" : "SPEI RECIBIDO")
        incoming.account = "Santander"
        incoming.statementId = destination.id
        store.movements = [outgoing, incoming]
    }

    private func assertTransferPair(_ store: FinanceStore, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(store.movements.count, 2, file: file, line: line)
        guard store.movements.count == 2 else { return }
        XCTAssertEqual(store.movements[0].matchedMovementId, store.movements[1].id, file: file, line: line)
        XCTAssertEqual(store.movements[1].matchedMovementId, store.movements[0].id, file: file, line: line)
        XCTAssertTrue(store.movements.allSatisfy { $0.kind == .bankTransfer && $0.flow == .transfer }, file: file, line: line)
        XCTAssertEqual(store.consolidatedRealSpend, 0, file: file, line: line)
        XCTAssertEqual(store.realIncome, 0, file: file, line: line)
    }

    func testCategoryBeforePairingDoesNotLockAccounting() {
        withStore { store in
            seedTransfer(store)
            _ = store.updateCategory(for: store.movements[0], to: "Itam", applyToMerchant: false)
            XCTAssertEqual(store.movements[0].manuallyAccountingReviewed, false)
            store.normalizeFinanceForTesting()
            assertTransferPair(store)
            XCTAssertEqual(store.movements[0].category, "Itam")
        }
    }

    func testCategoryAfterPairingPreservesReciprocityAcrossNormalizationAndReload() {
        withStore { store in
            seedTransfer(store)
            store.normalizeFinanceForTesting()
            _ = store.updateCategory(for: store.movements[0], to: "Entrenamiento", applyToMerchant: false)
            store.normalizeFinanceForTesting()
            assertTransferPair(store)
            let reopened = FinanceStore()
            assertTransferPair(reopened)
            XCTAssertEqual(reopened.movements[0].category, "Entrenamiento")
        }
    }

    func testManualTransferMatchesBothSidesWithIndependentEvidence() {
        withStore { store in
            seedTransfer(store)
            store.updateClassification(for: store.movements[0], kind: .bankTransfer, travelRelated: false)
            assertTransferPair(store)
        }
    }

    func testConfirmedPairSurvivesNewRowIDsAndPreservesCategories() {
        withStore { store in
            seedTransfer(store, sharedReference: false)
            _ = store.updateCategory(for: store.movements[0], to: "Itam", applyToMerchant: false)
            XCTAssertTrue(store.confirmOwnTransfer(store.movements[0], counterpart: store.movements[1]))
            var reread = store.movements
            for index in reread.indices {
                reread[index].id = UUID()
                reread[index].matchedMovementId = nil
                reread[index].manuallyReviewed = false
                reread[index].manuallyAccountingReviewed = nil
                reread[index].confirmedCounterpartKey = nil
                reread[index].kind = reread[index].amount < 0 ? .purchase : .income
                reread[index].flow = reread[index].amount < 0 ? .expense : .income
            }
            store.movements = reread
            store.normalizeFinanceForTesting()
            assertTransferPair(store)
            XCTAssertEqual(store.movements[0].category, "Itam")
        }
    }

    func testLegacyManualAccountingDecisionAndCodableStayProtected() throws {
        try withStore { store in
            seedTransfer(store)
            store.movements[0].manuallyReviewed = true
            store.movements[0].category = "Salud"
            let data = try JSONEncoder().encode(store.movements[0])
            let decoded = try JSONDecoder().decode(Movement.self, from: data)
            XCTAssertNil(decoded.manuallyAccountingReviewed)
            XCTAssertTrue(decoded.accountingReviewLocked)
            store.normalizeFinanceForTesting()
            XCTAssertEqual(store.movements[0].category, "Salud")
            XCTAssertEqual(store.movements[0].kind, .purchase)
            XCTAssertNil(store.movements[0].matchedMovementId)
        }
    }

    func testOneCentDifferenceCannotBeAutomaticallyReconciled() {
        withStore { store in
            seedTransfer(store)
            store.movements[1].amount = Decimal(string: "3000.01")!
            store.normalizeFinanceForTesting()
            XCTAssertTrue(store.movements.allSatisfy { $0.matchedMovementId == nil })
        }
    }

    private func seedNvioSalaryAndUnrelatedWithdrawal(_ store: FinanceStore, stalePair: Bool = false) {
        let bbva = statement("BBVA", key: "bbva:4922", kind: .bank)
        let santander = statement("Santander", key: "santander:1111", kind: .bank)
        store.statements = [bbva, santander]
        var salary = row(15000, kind: .income, date: calendarDate(2026, 6, 27), title: "SPEI RECIBIDONVIO")
        salary.statementId = bbva.id
        var withdrawal = row(-15000, date: calendarDate(2026, 6, 30), title: "TRANSFERENCIA A MARCELO ANDRES DIAZ SANC")
        withdrawal.account = "Santander"
        withdrawal.statementId = santander.id
        if stalePair {
            salary.kind = .bankTransfer; salary.flow = .transfer
            withdrawal.kind = .bankTransfer; withdrawal.flow = .transfer
            salary.matchedMovementId = withdrawal.id; withdrawal.matchedMovementId = salary.id
            salary.reconciliationReason = "importe exacto · dirección explícita"
            withdrawal.reconciliationReason = salary.reconciliationReason
            salary.reconciliationConfidence = 100; withdrawal.reconciliationConfidence = 100
            salary.category = "Binance (salarios)"
            salary.manuallyReviewed = true; salary.manuallyAccountingReviewed = false
        }
        store.movements = [salary, withdrawal]
    }

    func testNvioIncomeCannotMatchSantanderByOwnerAmountAndThreeDays() {
        withStore { store in
            seedNvioSalaryAndUnrelatedWithdrawal(store)
            store.normalizeFinanceForTesting()
            XCTAssertTrue(store.movements.allSatisfy { $0.matchedMovementId == nil })
            XCTAssertEqual(store.realIncome, 15000)
            // "TRANSFERENCIA A MARCELO ANDRES DIAZ SANC" moves money to the
            // owner's own account: it is not spend even without a counterpart.
            XCTAssertEqual(store.consolidatedRealSpend, 0)
        }
    }

    func testStaleAutomaticNvioPairIsRevalidatedWithoutLosingCategory() {
        withStore { store in
            seedNvioSalaryAndUnrelatedWithdrawal(store, stalePair: true)
            store.normalizeFinanceForTesting()
            XCTAssertTrue(store.movements.allSatisfy { $0.matchedMovementId == nil })
            XCTAssertEqual(store.realIncome, 15000)
            XCTAssertEqual(store.movements[0].category, "Binance (salarios)")
            XCTAssertTrue(store.movements[0].manuallyReviewed)
            _ = store.updateCategory(for: store.movements[0], to: "Binance (salarios)", applyToMerchant: false)
            FinanceStore.recordCanonicalRebuildCompletion(in: .standard)
            let reopened = FinanceStore()
            XCTAssertEqual(reopened.realIncome, 15000)
            XCTAssertEqual(reopened.movements[0].category, "Binance (salarios)")
        }
    }

    func testActualSantanderOwnTransferKeepsIndependentBankLink() {
        withStore { store in
            seedTransfer(store, sharedReference: false)
            store.movements[0].title = "SPEI ENVIADO SANTANDER MARCELO ANDRES DIAZ SANC"
            store.movements[1].title = "SPEI RECIBIDOBBVA"
            store.normalizeFinanceForTesting()
            assertTransferPair(store)
            store.normalizeFinanceForTesting()
            assertTransferPair(store)
        }
    }

    func testHumanConfirmedPairWithoutPrintedReferenceRemainsProtected() {
        withStore { store in
            seedTransfer(store, sharedReference: false)
            XCTAssertTrue(store.confirmOwnTransfer(store.movements[0], counterpart: store.movements[1]))
            store.normalizeFinanceForTesting()
            assertTransferPair(store)
        }
    }

    func testUserConfirmedRappiPaymentExcludesSpendAndKeepsCategoryAfterReload() {
        withStore { store in
            let bbva = statement("BBVA", key: "bbva:4922", kind: .bank)
            store.statements = [bbva]
            var payment = row(-10000, date: calendarDate(2026, 6, 30), title: "SPEI ENVIADO STP")
            payment.statementId = bbva.id
            store.movements = [payment]
            _ = store.updateCategory(for: payment, to: "Transporte", applyToMerchant: false)
            store.updateClassification(for: store.movements[0], kind: .cardPayment, travelRelated: false)
            XCTAssertEqual(store.consolidatedRealSpend, 0)
            XCTAssertEqual(store.movements[0].category, "Transporte")
            FinanceStore.recordCanonicalRebuildCompletion(in: .standard)
            let reopened = FinanceStore()
            XCTAssertEqual(reopened.consolidatedRealSpend, 0)
            XCTAssertEqual(reopened.movements[0].kind, .cardPayment)
            XCTAssertEqual(reopened.movements[0].category, "Transporte")
        }
    }

    private func seedMonthlyAudit(_ store: FinanceStore, cashEnd: Decimal = 800) {
        let bankBefore = statement("BBVA", key: "bbva:4922", kind: .bank,
            period: "01/05/2026 - 31/05/2026", summary: .init(cashBalance: 1000))
        let bankAfter = statement("BBVA", key: "bbva:4922", kind: .bank,
            period: "01/06/2026 - 30/06/2026", summary: .init(cashBalance: cashEnd))
        let cardBefore = statement("Amex", key: "amex:1003", kind: .card,
            period: "01/05/2026 - 31/05/2026", summary: .init(debtBalance: 500))
        let cardAfter = statement("Amex", key: "amex:1003", kind: .card,
            period: "01/06/2026 - 30/06/2026", summary: .init(debtBalance: 650))
        store.statements = [bankBefore, bankAfter, cardBefore, cardAfter]
        var income = row(100, kind: .income, date: calendarDate(2026, 6, 15))
        income.statementId = bankAfter.id
        var purchase = row(-500, date: calendarDate(2026, 6, 15))
        purchase.account = "Amex"; purchase.statementId = cardAfter.id
        var refund = row(50, kind: .refund, date: calendarDate(2026, 6, 16))
        refund.account = "Amex"; refund.statementId = cardAfter.id
        var payment = row(-300, kind: .cardPayment, date: calendarDate(2026, 6, 17))
        payment.flow = .transfer; payment.statementId = bankAfter.id
        var receipt = row(300, kind: .cardPayment, date: calendarDate(2026, 6, 17))
        receipt.account = "Amex"; receipt.flow = .transfer; receipt.statementId = cardAfter.id
        store.movements = [income, purchase, refund, payment, receipt]
    }

    func testMonthlyAuditSeparatesExternalIncomeSpendRefundsAndFundingPayments() {
        withStore { store in
            seedMonthlyAudit(store)
            let report = store.monthlyFinancialAudit(for: calendarDate(2026, 6, 1))
            XCTAssertEqual(report.total(.income), 100)
            XCTAssertEqual(report.total(.spending), 500)
            XCTAssertEqual(report.total(.refunds), 50)
            XCTAssertEqual(report.netSpending, 450)
            XCTAssertEqual(report.total(.cardPayment), 300)
            XCTAssertEqual(report.rows[.cardPayment]?.count, 1)
            XCTAssertTrue(report.hasCompleteCoverage)
            XCTAssertTrue(report.bridge?.reconciles == true)
            XCTAssertEqual(report.bridge?.difference, 0)
        }
    }

    func testMonthlyFundingDifferenceIsVisibleRatherThanForcedToZero() {
        withStore { store in
            seedMonthlyAudit(store, cashEnd: 900)
            let report = store.monthlyFinancialAudit(for: calendarDate(2026, 6, 1))
            XCTAssertEqual(report.bridge?.difference, 100)
            XCTAssertFalse(report.bridge?.reconciles ?? true)
        }
    }

    func testPartialCoverageAndDifferentCutoffsDoNotInventMonthlyBalances() {
        withStore { store in
            seedMonthlyAudit(store)
            store.statements[1].period = "15/06/2026 - 14/07/2026"
            let report = store.monthlyFinancialAudit(for: calendarDate(2026, 6, 1))
            XCTAssertFalse(report.hasCompleteCoverage)
            XCTAssertNil(report.bridge)
            XCTAssertFalse(report.canUseForBudget)
        }
    }

    func testRejectedPairPersistsWithoutChangingTypesOrCategoriesAndCanBeReset() {
        withStore { store in
            seedTransfer(store, sharedReference: false)
            let pair = store.pendingTransferReviewPairs[0]
            let priorCategory = store.movements[0].category
            store.rejectTransferPair(pair)
            XCTAssertEqual(store.pendingTransferReviewPairs.count, 0)
            XCTAssertEqual(store.movements[0].kind, .purchase)
            XCTAssertEqual(store.movements[0].category, priorCategory)
            FinanceStore.recordCanonicalRebuildCompletion(in: .standard)
            let reopened = FinanceStore()
            XCTAssertEqual(reopened.pendingTransferReviewPairs.count, 0)
            reopened.resetRejectedTransferPairs()
            XCTAssertEqual(reopened.pendingTransferReviewPairs.count, 1)
        }
    }

    func testConfirmedIncomeIsNotSuggestedAsOwnTransferAgain() {
        withStore { store in
            seedTransfer(store, sharedReference: false)
            store.updateClassification(for: store.movements[1], kind: .income, travelRelated: false)
            XCTAssertEqual(store.pendingTransferReviewPairs.count, 0)
            XCTAssertEqual(store.realIncome, 3000)
        }
    }

    func testMonthlyBridgeUsesFullCreditUsageIncludingDeferredDebt() {
        withStore { store in
            seedMonthlyAudit(store)
            store.statements[2].summary?.creditLimit = 1000
            store.statements[2].summary?.creditAvailable = 500
            store.statements[3].summary?.creditLimit = 1000
            store.statements[3].summary?.creditAvailable = 100
            let report = store.monthlyFinancialAudit(for: calendarDate(2026, 6, 1))
            XCTAssertEqual(report.bridge?.debtChange, 400)
            XCTAssertEqual(report.bridge?.difference, -250)
        }
    }

    func testUnpairedOwnTransferKeepsItsKindAcrossRepeatedReconciliation() {
        withStore { store in
            _ = store.updateTransferOwnerAliases(["Marcelo Diaz"])
            let bank = statement("BBVA", key: "bbva:1111", kind: .bank)
            store.statements = [bank]
            var outgoing = row(-5000, kind: .bankTransfer, date: calendarDate(2026, 8, 20),
                title: "TRASPASO A CUENTA PROPIA MARCELO DIAZ")
            outgoing.flow = .transfer
            outgoing.statementId = bank.id
            store.movements = [outgoing]

            store.normalizeFinanceForTesting()
            let firstSpend = store.consolidatedRealSpend
            let firstFlow = store.movements.first?.flow
            store.normalizeFinanceForTesting()
            store.normalizeFinanceForTesting()

            XCTAssertEqual(store.movements.first?.flow, firstFlow)
            XCTAssertEqual(store.movements.first?.kind, .bankTransfer)
            XCTAssertEqual(store.consolidatedRealSpend, firstSpend)
        }
    }

    func testSPEIToTheOwnersOwnNameIsNotSpendEvenWithoutTheOtherAccount() {
        withStore { store in
            let bank = statement("BBVA", key: "bbva:1111", kind: .bank)
            store.statements = [bank]
            var own = row(-15000, date: calendarDate(2026, 9, 30), title: "SPEI ENVIADO NU MEXICO")
            own.rawDescription = "SPEI ENVIADO NU MEXICO 0123 MARCELO ANDRES DIAZ SANCHEZ"
            own.kind = nil
            own.statementId = bank.id
            var other = row(-5400, date: calendarDate(2026, 9, 29), title: "SPEI ENVIADO BANORTE")
            other.rawDescription = "SPEI ENVIADO BANORTE 0456 ALICIA GABRIELA"
            other.kind = nil
            other.statementId = bank.id
            store.movements = [own, other]
            store.normalizeFinanceForTesting()

            XCTAssertEqual(store.movements.first { $0.id == own.id }?.flow, .transfer)
            XCTAssertEqual(store.consolidatedRealSpend, 5400)
            store.normalizeFinanceForTesting()
            XCTAssertEqual(store.consolidatedRealSpend, 5400)
        }
    }

    func testOwnNameSplitByOCRInTheDescriptionIsStillAnOwnTransfer() {
        withStore { store in
            let santander = statement("Santander", key: "santander:7079", kind: .bank)
            let bbva = statement("BBVA", key: "bbva:4922", kind: .bank)
            store.statements = [santander, bbva]
            var split = row(-1000, date: calendarDate(2026, 4, 29), title: "PAGO TRANSF RAPIDA SPEI TRANSFERENCIA A MARCELO ANDRES DIAZ SANC IVA REF 6265157")
            split.account = "Santander"; split.kind = nil; split.statementId = santander.id
            split.rawDescription = "29-ABR-2026 5134658 PAGO TRANSF RAPIDA SPEI TRANSFERENCIA A MARCELO ANDRES DIAZ 1,000.00 29,320.83 SANC RFC DISM9802121F4"
            var glued = row(-500, date: calendarDate(2025, 12, 1), title: "SPEI ENVIADO SANTANDER")
            glued.kind = nil; glued.statementId = bbva.id
            glued.rawDescription = "01/DIC SPEI ENVIADO SANTANDER 500.00 0811250Marcelo Andres Diaz Sanchez Referencia 0091099472"
            store.movements = [split, glued]
            store.normalizeFinanceForTesting()
            XCTAssertTrue(store.movements.allSatisfy { $0.flow == .transfer })
            XCTAssertEqual(store.consolidatedRealSpend, 0)
        }
    }

    func testInterchangeableCardPaymentsArePairedByDate() {
        withStore { store in
            let santander = statement("Santander", key: "santander:7079", kind: .bank)
            let rappi = statement("Rappi", key: "rappi:9040", kind: .card)
            store.statements = [santander, rappi]
            @MainActor func funding(_ day: Int) -> Movement {
                var m = row(-1000, date: calendarDate(2026, 4, day), title: "PAGO TRANSFERENCIA SPEI CONCEPTO TRANSFERENCIA A MADS RAPPI")
                m.account = "Santander"; m.statementId = santander.id
                m.rawDescription = "ENVIADO A STP A LA CUENTA 646180120648657422 AL CLIENTE MARCELO ANDRES DIAZ SANCHEZ CONCEPTO TRANSFERENCIA A MADS RAPPI"
                return m
            }
            @MainActor func credit(_ day: Int) -> Movement {
                var m = row(1000, kind: .cardPayment, date: calendarDate(2026, 4, day), title: "PAGO POR SPEI")
                m.account = "Rappi"; m.flow = .transfer; m.statementId = rappi.id
                return m
            }
            store.movements = [funding(16), funding(17), funding(20), credit(16), credit(17), credit(18)]
            store.normalizeFinanceForTesting()
            XCTAssertTrue(store.movements.allSatisfy { $0.matchedMovementId != nil })
            XCTAssertEqual(store.consolidatedRealSpend, 0)
            store.normalizeFinanceForTesting()
            XCTAssertEqual(store.consolidatedRealSpend, 0)
        }
    }

    func testReissuedRappiNumberWithBalanceContinuityIsOneAccount() {
        withStore { store in
            let august = statement("Rappi", key: "rappi:9040", kind: .card, period: "22/07/2026 - 21/08/2026",
                summary: .init(statementBalance: 2728.5, debtBalance: 2728.5, creditLimit: 16000, creditAvailable: 13271.5))
            var september = statement("Rappi", key: "rappi:6121", kind: .card, period: "22/08/2026 - 21/09/2026",
                summary: .init(debtBalance: Decimal(string: "2592.34"), creditLimit: 16000, creditAvailable: Decimal(string: "13407.66")))
            september.summary?.previousBalance = Decimal(string: "2728.50")
            september.summary?.statementBalance = Decimal(string: "2592.34")
            store.statements = [august, september]
            store.normalizeFinanceForTesting()
            XCTAssertEqual(Set(store.statements.compactMap(\.accountKey)), ["rappi:9040"])
            XCTAssertEqual(store.creditLimit, 16000)
            XCTAssertEqual(store.cardDebtTotal, Decimal(string: "2592.34"))
        }
    }

    func testLedgerLargerThanTheUserDefaultsLimitIsStoredAndMigrated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-store-\(UUID())")
        let suite = "marcelito.ledger.storage.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }

        // iOS refuses UserDefaults values of 4 MB or more; files have no such limit.
        let large = Data(repeating: 7, count: 5_000_000)
        LedgerStorage.set(large, forKey: "marcelito.ledger.active.v1", defaults: defaults, directory: directory)
        XCTAssertEqual(LedgerStorage.data(forKey: "marcelito.ledger.active.v1", defaults: defaults, directory: directory), large)
        XCTAssertNil(defaults.data(forKey: "marcelito.ledger.active.v1"))

        // A value left in UserDefaults by an older build moves to a file once read.
        let legacy = Data("legacy-reviews".utf8)
        defaults.set(legacy, forKey: "marcelito.manualReviews.v1")
        XCTAssertEqual(LedgerStorage.data(forKey: "marcelito.manualReviews.v1", defaults: defaults, directory: directory), legacy)
        XCTAssertNil(defaults.data(forKey: "marcelito.manualReviews.v1"))
        XCTAssertEqual(LedgerStorage.allValues(directory: directory)["marcelito.manualReviews.v1"], legacy)

        LedgerStorage.remove(forKey: "marcelito.ledger.active.v1", defaults: defaults, directory: directory)
        XCTAssertNil(LedgerStorage.data(forKey: "marcelito.ledger.active.v1", defaults: defaults, directory: directory))
    }

    func testImportedLedgerSurvivesReopeningTheStore() {
        withStore { store in
            let bank = statement("BBVA", key: "bbva:4922", kind: .bank, summary: .init(cashBalance: 1_000))
            var purchase = row(-250, title: "COMERCIO EJEMPLO")
            purchase.statementId = bank.id
            store.statements = [bank]
            store.movements = [purchase]
            store.normalizeFinanceForTesting()
            _ = store.updateCategory(for: store.movements[0], to: "Salud", applyToMerchant: false)
            let reopened = FinanceStore()
            XCTAssertEqual(reopened.statements.count, 1)
            XCTAssertEqual(reopened.movements.first?.category, "Salud")
        }
    }

    func testRecipientlessTransferAnswerBecomesAConceptRule() {
        withStore { store in
            let bbva = statement("BBVA", key: "bbva:4922", kind: .bank)
            store.statements = [bbva]
            var first = row(-2000, date: calendarDate(2026, 3, 1), title: "PAGO CUENTA DE TERCERO")
            first.kind = nil; first.statementId = bbva.id
            var second = row(-10000, date: calendarDate(2026, 3, 9), title: "PAGO CUENTA DE TERCERO")
            second.kind = nil; second.statementId = bbva.id
            var small = row(-300, date: calendarDate(2026, 3, 10), title: "PAGO CUENTA DE TERCERO")
            small.kind = nil; small.statementId = bbva.id
            store.movements = [first, second, small]
            store.normalizeFinanceForTesting()
            XCTAssertEqual(store.pendingOwnershipReviews.map(\.id), [second.id, first.id])
            XCTAssertEqual(store.consolidatedRealSpend, 12300)

            store.resolveTransferOwnership(store.movements.first { $0.id == first.id }!, ownAccount: true, applyToConcept: true)
            XCTAssertTrue(store.pendingOwnershipReviews.isEmpty)
            XCTAssertEqual(store.consolidatedRealSpend, 0)

            let key = store.ownershipDescriptorKey(store.movements[0])
            store.removeTransferOwnershipRule(key)
            // The explicitly answered row keeps its answer; the others return.
            XCTAssertEqual(store.consolidatedRealSpend, 10300)
        }
    }

    func testBankDepositLabelledAbonoIsIncomeNotAccountingCredit() {
        withStore { store in
            let bank = statement("BBVA", key: "bbva:1111", kind: .bank)
            store.statements = [bank]
            var payroll = row(25000, date: calendarDate(2026, 8, 15), title: "ABONO NOMINA EMPRESA SA")
            payroll.kind = nil
            payroll.statementId = bank.id
            store.movements = [payroll]
            XCTAssertEqual(store.realIncome, 25000)
        }
    }

    func testRowsWithoutYearAreAnchoredToACycleThatCrossesNewYear() {
        let cycle = "16/12/2025 - 15/01/2026"
        let december = row(-4000, date: calendarDate(2026, 12, 20))   // "20 de Diciembre" read with 2026
        let januaryEarly = row(-100, date: calendarDate(2025, 1, 5))  // "05/ENE" read with 2025
        let alreadyRight = row(-50, date: calendarDate(2026, 1, 10))
        let msiOriginalPurchase = row(-1200, date: calendarDate(2025, 6, 3))

        let anchored = FinanceStore.movementsAnchoredToStatementPeriod(
            [december, januaryEarly, alreadyRight, msiOriginalPurchase], period: cycle)

        XCTAssertEqual(anchored.map(\.date), [
            calendarDate(2025, 12, 20), calendarDate(2026, 1, 5),
            calendarDate(2026, 1, 10), calendarDate(2025, 6, 3),
        ])
    }

    func testRowsInsideASingleYearCycleAreNotShifted() {
        let rows = [row(-10, date: calendarDate(2026, 8, 1)), row(-20, date: calendarDate(2026, 8, 31))]
        let anchored = FinanceStore.movementsAnchoredToStatementPeriod(rows, period: "01/08/2026 - 31/08/2026")
        XCTAssertEqual(anchored.map(\.date), rows.map(\.date))
    }

    func testTwoDigitYearIsReadInsteadOfTheDefaultYear() {
        XCTAssertEqual(FinanceStore.parseDateForTesting("28/12/25", defaultYear: 2026), calendarDate(2025, 12, 28))
        XCTAssertEqual(FinanceStore.parseDateForTesting("05 de ene de 2026"), calendarDate(2026, 1, 5))
        XCTAssertEqual(FinanceStore.parseDateForTesting("05/ENE", defaultYear: 2026), calendarDate(2026, 1, 5))
    }

    func testOCRAmountWithRepeatedSeparatorsIsNotTruncated() {
        XCTAssertEqual(FinanceStore.parseAmountForTesting("54.977.93"), Decimal(string: "54977.93"))
        XCTAssertEqual(FinanceStore.parseAmountForTesting("54,977,93"), Decimal(string: "54977.93"))
        XCTAssertEqual(FinanceStore.parseAmountForTesting("1.234.567"), 1234567)
        XCTAssertEqual(FinanceStore.parseAmountForTesting("1,234.56-"), Decimal(string: "-1234.56"))
        XCTAssertEqual(FinanceStore.parseAmountForTesting("$1,234.56"), Decimal(string: "1234.56"))
        XCTAssertEqual(FinanceStore.parseAmountForTesting("1.234,56"), Decimal(string: "1234.56"))
        XCTAssertNil(FinanceStore.parseAmountForTesting("1,234.56CR"))
    }

    func testReusedFileNameDoesNotReplaceAnotherMonth() {
        var march = statement("BBVA", key: "bbva:1111", kind: .bank, period: "01/03/2026 - 31/03/2026")
        march.fileName = "EstadoCuenta.pdf"
        march.sourceFingerprint = nil

        XCTAssertNil(FinanceStore.legacyStatementForReimport(
            in: [march], fileName: "EstadoCuenta.pdf", source: "BBVA", period: "01/04/2026 - 30/04/2026"))
        XCTAssertEqual(FinanceStore.legacyStatementForReimport(
            in: [march], fileName: "EstadoCuenta.pdf", source: "BBVA", period: "01/03/2026 - 31/03/2026")?.id, march.id)
        XCTAssertNil(FinanceStore.legacyStatementForReimport(
            in: [march], fileName: "EstadoCuenta.pdf", source: "Santander", period: "01/03/2026 - 31/03/2026"))
    }

    func testOneAccountWithoutDayLevelPeriodsDoesNotMarkEveryMonthPartial() {
        let calendar = Calendar.current
        func days(_ from: Date, _ count: Int) -> Set<Date> {
            Set((0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: from)) })
        }
        let bank = days(calendarDate(2026, 8, 1), 61)          // 1 ago – 30 sep
        let card = days(calendarDate(2026, 7, 28), 62)         // 28 jul – 27 sep
        let closedCard = days(calendarDate(2026, 1, 1), 31)    // stopped in January
        let monthOnlyLabel = Set<Date>()                       // e.g. a "Julio 2026" period

        let covered = FinanceStore.commonCoverage([bank, card, closedCard, monthOnlyLabel])

        XCTAssertTrue(covered.contains(calendar.startOfDay(for: calendarDate(2026, 8, 15))))
        XCTAssertTrue(covered.contains(calendar.startOfDay(for: calendarDate(2026, 9, 27))))
        // The current card has no statement for 28–30 Sep yet: still partial.
        XCTAssertFalse(covered.contains(calendar.startOfDay(for: calendarDate(2026, 9, 29))))
        // Before the bank account existed, only the card constrains coverage.
        XCTAssertTrue(covered.contains(calendar.startOfDay(for: calendarDate(2026, 7, 30))))
    }

    func testManualKindCannotContradictTheAmountSign() {
        withStore { store in
            store.addMovement(title: "Intereses ganados", account: "BBVA", category: "Ingresos",
                amount: 1200, flow: .income, date: calendarDate(2026, 8, 10))
            let deposit = store.movements[0]

            XCTAssertFalse(store.updateClassification(for: deposit, kind: .interest, travelRelated: false))
            XCTAssertFalse(store.updateClassification(for: deposit, kind: .purchase, travelRelated: false))
            XCTAssertEqual(store.movements.first(where: { $0.id == deposit.id })?.flow, .income)

            XCTAssertTrue(store.updateClassification(for: deposit, kind: .income, travelRelated: false))
            XCTAssertEqual(store.movements.first(where: { $0.id == deposit.id })?.flow, .income)
            XCTAssertFalse(FinanceStore.selectableKinds(forAmount: 1200).contains(.purchase))
            XCTAssertFalse(FinanceStore.selectableKinds(forAmount: -1200).contains(.refund))
        }
    }

    func testTravelToggleDoesNotTurnAnIncomeIntoSpend() {
        withStore { store in
            store.addMovement(title: "Pago cliente", account: "BBVA", category: "Ingresos",
                amount: 20000, flow: .income, date: calendarDate(2026, 8, 10))
            var deposit = store.movements[0]
            deposit.kind = nil
            XCTAssertEqual(FinanceStore.displayKind(for: deposit), .income)

            store.updateTravelRelated(for: deposit, travelRelated: true)
            let updated = store.movements.first(where: { $0.id == deposit.id })
            XCTAssertEqual(updated?.flow, .income)
            XCTAssertEqual(updated?.amount, 20000)
            XCTAssertEqual(updated?.travelRelated, true)
        }
    }

    func testRebuildCommitKeepsChangesMadeWhileItWasRunning() {
        var kept = statement("BBVA", key: "bbva:1234", kind: .bank)
        kept.sourceFingerprint = "kept"
        var deleted = statement("Amex", key: "amex:1111", kind: .card)
        deleted.sourceFingerprint = "deleted"
        let baseline = [kept, deleted]

        // The rebuild re-read both PDFs into fresh statement ids.
        var rebuiltKept = kept; rebuiltKept.id = UUID()
        var rebuiltDeleted = deleted; rebuiltDeleted.id = UUID()
        var keptRow = row(-100); keptRow.statementId = rebuiltKept.id
        var deletedRow = row(-200); deletedRow.statementId = rebuiltDeleted.id
        let seededManual = row(-50, title: "Manual previo")

        // Meanwhile the user added a manual row, imported a new PDF and
        // deleted the Amex statement.
        var imported = statement("Santander", key: "santander:9999", kind: .bank)
        imported.sourceFingerprint = "imported"
        var importedRow = row(-300); importedRow.statementId = imported.id
        let addedManual = row(-75, title: "Manual durante la reconstrucción")

        let merged = FinanceStore.mergeConcurrentLedgerChanges(
            rebuiltMovements: [seededManual, keptRow, deletedRow],
            rebuiltStatements: [rebuiltKept, rebuiltDeleted],
            liveMovements: [addedManual, seededManual, importedRow],
            liveStatements: [kept, imported],
            baselineStatements: baseline
        )

        XCTAssertEqual(Set(merged.statements.map(\.id)), [rebuiltKept.id, imported.id])
        XCTAssertEqual(Set(merged.movements.map(\.id)), [addedManual.id, seededManual.id, keptRow.id, importedRow.id])
    }

    func testRebuildCommitPrefersAStatementReimportedWhileRunning() {
        var original = statement("BBVA", key: "bbva:1234", kind: .bank)
        original.sourceFingerprint = "same-pdf"
        var rebuilt = original; rebuilt.id = UUID()
        var reimported = original; reimported.id = UUID()
        var rebuiltRow = row(-100); rebuiltRow.statementId = rebuilt.id
        var reimportedRow = row(-100); reimportedRow.statementId = reimported.id

        let merged = FinanceStore.mergeConcurrentLedgerChanges(
            rebuiltMovements: [rebuiltRow],
            rebuiltStatements: [rebuilt],
            liveMovements: [reimportedRow],
            liveStatements: [original, reimported],
            baselineStatements: [original]
        )

        XCTAssertEqual(merged.statements.map(\.id), [reimported.id])
        XCTAssertEqual(merged.movements.map(\.id), [reimportedRow.id])
    }

    // MARK: - Auditoría B

    func testCardWithFavorBalanceDoesNotFailTheCreditControl() {
        withStore { store in
            store.statements = [
                statement("Amex", key: "amex:0001", kind: .card, summary: StatementSummaryRecord(creditLimit: 10_000, creditAvailable: 10_500)),
                statement("Amex", key: "amex:0002", kind: .card, summary: StatementSummaryRecord(creditLimit: 20_000, creditAvailable: 15_000))
            ]
            XCTAssertEqual(store.creditUsed, 5_000)
            let credit = store.consistencyChecks.first { $0.id == "credit" }
            XCTAssertEqual(credit?.expected, 5_000)
            XCTAssertEqual(credit?.passed, true)
            XCTAssertEqual(store.ledgerQuality.failedConsistencyCheckCount, 0)
        }
    }

    private func unclassified(_ amount: Decimal, _ title: String, on record: StatementRecord) -> Movement {
        var movement = row(amount, date: calendarDate(2026, 8, 15), title: title)
        movement.kind = nil
        movement.account = record.source
        movement.statementId = record.id
        return movement
    }

    func testKeywordClassificationRespectsTheSignOfTheMovement() {
        withStore { store in
            let bank = statement("BBVA", key: "bbva:1111", kind: .bank)
            let card = statement("Amex", key: "amex:1003", kind: .card)
            store.statements = [bank, card]
            store.movements = [
                unclassified(-3_000, "LIVERPOOL INSURGENTES", on: card),
                unclassified(1_500, "BONIFICACION COMISION", on: card),
                unclassified(200, "DEVOLUCION COMISION", on: bank),
                unclassified(5_000, "PAGO RECIBIDO CLIENTE SA", on: bank),
                unclassified(-4_000, "PAGO CREDITO AUTOMOTRIZ", on: bank)
            ]
            // 3,000 + 4,000 of real spend, minus the 1,500 bonificación and
            // the 200 commission refund.
            XCTAssertEqual(store.consolidatedRealSpend, 5_300)
            XCTAssertEqual(store.realIncome, 5_000)
        }
    }

    func testBBVATextChargeColumnIsNeverARefundOrACardPaymentForALoan() {
        let text = """
        BBVA MEXICO, S.A., INSTITUCION DE BANCA MULTIPLE
        Periodo DEL 15/03/2026 AL 14/04/2026
        No. de Cuenta 1575694922
        Saldo Anterior 5,000.00
        Depósitos / Abonos (+) 0 0.00
        Retiros / Cargos (-) 2 4,300.00
        Saldo Final 700.00
        Detalle de Movimientos Realizados
        27/MAR 27/MAR DEVOLUCION SPEI CLIENTE 300.00 4,700.00 4,700.00
        28/MAR 28/MAR PAGO CREDITO AUTOMOTRIZ 4,000.00 700.00 700.00
        Total de Movimientos
        TOTAL IMPORTE CARGOS 4,300.00 TOTAL MOVIMIENTOS CARGOS 2
        TOTAL IMPORTE ABONOS 0.00 TOTAL MOVIMIENTOS ABONOS 0
        """

        let rows = FinanceStore.readerParseSnapshotForTesting(text: text, fileName: "Abril BBVA.pdf", sourceHint: "BBVA").movements

        XCTAssertEqual(rows.map(\.amount), [-300, -4_000])
        XCTAssertNotEqual(rows.first?.kind, .refund)
        XCTAssertNotEqual(rows.last?.kind, .cardPayment)
        XCTAssertEqual(rows.last?.flow, .expense)
    }

    func testBBVAOCRChargeColumnWinsOverDepositWordsInTheConcept() {
        let fixtures = [
            OCRObservationFixture(text: "Detalle de Movimientos Realizados", x: 0.02, y: 0.98, width: 0.52),
            OCRObservationFixture(text: "FECHA", x: 0.04, y: 0.94, width: 0.06),
            OCRObservationFixture(text: "DESCRIPCION", x: 0.20, y: 0.94, width: 0.14),
            OCRObservationFixture(text: "CARGOS", x: 0.60, y: 0.94, width: 0.08),
            OCRObservationFixture(text: "ABONOS", x: 0.72, y: 0.94, width: 0.08),
            OCRObservationFixture(text: "SALDO", x: 0.84, y: 0.94, width: 0.08),

            OCRObservationFixture(text: "23/JUL", x: 0.02, y: 0.82, width: 0.10),
            OCRObservationFixture(text: "DEPOSITO A TERCERO ABONO", x: 0.13, y: 0.82, width: 0.40),
            OCRObservationFixture(text: "500.00", x: 0.60, y: 0.82, width: 0.08),
            OCRObservationFixture(text: "3,000.00", x: 0.84, y: 0.82, width: 0.08),

            OCRObservationFixture(text: "24/JUL", x: 0.02, y: 0.72, width: 0.10),
            OCRObservationFixture(text: "DEVOLUCION SPEI CLIENTE", x: 0.13, y: 0.72, width: 0.40),
            OCRObservationFixture(text: "100.00", x: 0.60, y: 0.72, width: 0.08),
            OCRObservationFixture(text: "2,900.00", x: 0.84, y: 0.72, width: 0.08),
        ]

        let rows = FinanceStore.bbvaOCRRowsForTesting(fixtures, fileName: "BBVA-agosto-2026.pdf")

        XCTAssertEqual(rows.map(\.amount), [-500, -100])
        XCTAssertTrue(rows.allSatisfy { $0.flow != .income })
        XCTAssertFalse(rows.contains { $0.kind == .refund })
    }

    func testAmexOCRBonificacionDeComisionIsARefundNotAFee() {
        let rows = FinanceStore.amexOCRRowsForTesting([
            OCRObservationFixture(page: 1, text: "Fecha y Detalle de las operaciones", x: 0.05, y: 0.92, width: 0.40),
            OCRObservationFixture(page: 1, text: "5 de Agosto", x: 0.05, y: 0.82, width: 0.16),
            OCRObservationFixture(page: 1, text: "BONIFICACION COMISION", x: 0.18, y: 0.82, width: 0.28),
            OCRObservationFixture(page: 1, text: "1,500.00 CR", x: 0.86, y: 0.82, width: 0.10),
        ], fileName: "28_jul_2026_-_27_ago_2026.pdf")

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.amount, 1_500)
        XCTAssertEqual(rows.first?.kind, .refund)
    }

    func testRealMerchantsAreNotDiscardedAsAdministrativeText() {
        for merchant in ["TOTAL PLAY", "TOTAL PASS", "RECARGA SALDO TELCEL", "UBER EATS CIUDAD DE MEXICO", "ANUALIDAD DE LA TARJETA"] {
            XCTAssertFalse(FinanceStore.isAdministrativeTitleForTesting(merchant), merchant)
        }
        for label in ["TOTAL IMPORTE CARGOS", "TOTAL DE MOVIMIENTOS", "SALDO ANTERIOR", "CIUDAD DE MEXICO CP 06600", "PAGINA 2 DE 5", "Pago mínimo"] {
            XCTAssertTrue(FinanceStore.isAdministrativeTitleForTesting(label), label)
        }
    }

    func testAmexOCRKeepsTheDatedAnnualFeeRow() {
        let rows = FinanceStore.amexOCRRowsForTesting([
            OCRObservationFixture(page: 1, text: "Fecha y Detalle de las operaciones", x: 0.05, y: 0.92, width: 0.40),
            OCRObservationFixture(page: 1, text: "5 de Agosto", x: 0.05, y: 0.82, width: 0.16),
            OCRObservationFixture(page: 1, text: "ANUALIDAD DE LA TARJETA", x: 0.18, y: 0.82, width: 0.28),
            OCRObservationFixture(page: 1, text: "1,800.00", x: 0.86, y: 0.82, width: 0.08),
            OCRObservationFixture(page: 1, text: "6 de Agosto", x: 0.05, y: 0.70, width: 0.16),
            OCRObservationFixture(page: 1, text: "TOTAL PLAY", x: 0.18, y: 0.70, width: 0.28),
            OCRObservationFixture(page: 1, text: "649.00", x: 0.86, y: 0.70, width: 0.08),
        ], fileName: "28_jul_2026_-_27_ago_2026.pdf")

        XCTAssertEqual(rows.map(\.amount), [-1_800, -649])
        XCTAssertEqual(rows.first?.kind, .fee)
    }

    func testSummaryReadsMinimumAndInterestFromTheirOwnLabels() {
        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: """
            American Express
            The Platinum Credit Card
            Pago mínimo más meses sin intereses 1,957.97
            Pago para no generar intereses 3,996.62
            Pago mínimo 1,200.00
            Intereses 150.00
            """,
            fileName: "sample-card-period-3.pdf"
        )

        XCTAssertEqual(snapshot.summary?.minimumPlusMsi, Decimal(string: "1957.97"))
        XCTAssertEqual(snapshot.summary?.minimumPayment, 1_200)
        XCTAssertEqual(snapshot.summary?.interest, 150)
    }

    func testSummaryKeepsACreditBalanceMarkedCRAsFavorNotDebt() {
        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: """
            American Express
            The Platinum Credit Card
            Saldo anterior 300.00
            Saldo al corte 1,250.00 CR
            """,
            fileName: "sample-card-period-3.pdf"
        )

        XCTAssertEqual(snapshot.summary?.previousBalance, 300)
        XCTAssertEqual(snapshot.summary?.statementBalance, -1_250)
        XCTAssertEqual(snapshot.summary?.debtBalance, -1_250)
    }

    func testReaderSeamUsesTheProductionTextParsers() {
        // Production has no selectable-text parser for Santander: it reads the
        // fixed Vision columns. The seam must not invent rows with a generic
        // scan that a real import would never keep.
        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: """
            Banco Santander México
            PERIODO 01-JUL-2026 AL 31-JUL-2026
            FECHA FOLIO DESCRIPCION DEPOSITO RETIRO SALDO
            01-JUL-2026 1234567 CONSUMO LOCAL TIENDA 30.00 1000.00
            """,
            fileName: "santander-julio-2026.pdf",
            sourceHint: "Santander"
        )

        XCTAssertTrue(snapshot.movements.isEmpty)
    }

    func testWithoutCardsOrLoansDebtIsZeroAndPatrimonyIsKnown() {
        withStore { store in
            store.statements = [statement("BBVA", key: "bbva:4922", kind: .bank, summary: .init(cashBalance: 1_000))]
            XCTAssertEqual(store.debtTotal, 0)
            XCTAssertEqual(store.liquidPatrimony, 1_000)
            XCTAssertEqual(store.balanceHistory.last?.patrimony, 1_000)
        }
    }

    func testCardPaymentAfterTheBankCutoffIsNotCountedTwiceInPatrimony() {
        withStore { store in
            let bank = statement("BBVA", key: "bbva:4922", kind: .bank,
                period: "16/07/2026 - 15/08/2026", summary: .init(cashBalance: 10_000))
            let card = statement("Amex", key: "amex:1003", kind: .card,
                period: "28/07/2026 - 27/08/2026", summary: .init(debtBalance: 2_000))
            store.statements = [bank, card]
            var payment = row(3_000, kind: .cardPayment, date: calendarDate(2026, 8, 20), title: "GRACIAS POR SU PAGO")
            payment.account = "Amex"; payment.flow = .transfer; payment.statementId = card.id
            store.movements = [payment]

            XCTAssertEqual(store.cashAvailable, 10_000)
            XCTAssertEqual(store.cardPaymentsAfterBankCutoff, 3_000)
            XCTAssertEqual(store.liquidPatrimony, 5_000)
            XCTAssertEqual(store.consistencyChecks.first { $0.id == "patrimony" }?.passed, true)
        }
    }

    func testSavingsRateComparesIncomeAndSpendOfTheSameMonths() {
        withStore { store in
            let july = statement("BBVA", key: "bbva:4922", kind: .bank, period: "01/07/2026 - 31/07/2026", summary: .init(cashBalance: 10_000))
            let august = statement("BBVA", key: "bbva:4922", kind: .bank, period: "01/08/2026 - 31/08/2026", summary: .init(cashBalance: 15_000))
            let card = statement("Amex", key: "amex:1003", kind: .card, period: "01/08/2026 - 31/08/2026", summary: .init(debtBalance: 5_000))
            store.statements = [july, august, card]
            var julyIncome = row(10_000, kind: .income, date: calendarDate(2026, 7, 15), title: "NOMINA")
            julyIncome.statementId = july.id
            var augustIncome = row(10_000, kind: .income, date: calendarDate(2026, 8, 15), title: "NOMINA")
            augustIncome.statementId = august.id
            var purchase = row(-5_000, date: calendarDate(2026, 8, 20))
            purchase.account = "Amex"; purchase.statementId = card.id
            store.movements = [julyIncome, augustIncome, purchase]

            XCTAssertEqual(store.savingsRate, Decimal(string: "0.5"))
        }
    }

    func testPositionHistoryKeepsPointsBeforeACardWasFirstLoaded() {
        withStore { store in
            let julyBank = statement("BBVA", key: "bbva:4922", kind: .bank, period: "01/07/2026 - 31/07/2026", summary: .init(cashBalance: 9_000))
            let augustBank = statement("BBVA", key: "bbva:4922", kind: .bank, period: "01/08/2026 - 31/08/2026", summary: .init(cashBalance: 10_000))
            let augustCard = statement("Amex", key: "amex:1003", kind: .card, period: "01/08/2026 - 31/08/2026", summary: .init(debtBalance: 2_000))
            store.statements = [julyBank, augustBank, augustCard]

            XCTAssertEqual(store.balanceHistory.map(\.patrimony), [9_000, 8_000])
        }
    }

    func testClosedAccountLeavesCurrentTotalsButKeepsItsHistory() {
        withStore { store in
            let open = statement("BBVA", key: "bbva:4922", kind: .bank, period: "01/08/2026 - 31/08/2026", summary: .init(cashBalance: 10_000))
            let closedJuly = statement("Santander", key: "santander:1111", kind: .bank, period: "01/07/2026 - 31/07/2026", summary: .init(cashBalance: 2_000))
            let openJuly = statement("BBVA", key: "bbva:4922", kind: .bank, period: "01/07/2026 - 31/07/2026", summary: .init(cashBalance: 9_000))
            store.statements = [open, openJuly, closedJuly]
            XCTAssertEqual(store.cashAvailable, 12_000)

            store.setAccountClosed(true, source: "Santander", kind: .bank, accountKey: "santander:1111")

            XCTAssertTrue(store.isAccountClosed(source: "Santander", kind: .bank, accountKey: "santander:1111"))
            XCTAssertEqual(store.cashAvailable, 10_000)
            XCTAssertEqual(store.liquidPatrimony, 10_000)
            // July still includes the closed account; August no longer does.
            XCTAssertEqual(store.balanceHistory.map(\.cash), [11_000, 10_000])
            XCTAssertEqual(store.accountStatementStatus(for: "Santander", kind: .bank, accountKey: "santander:1111").state, .closed)

            store.setAccountClosed(false, source: "Santander", kind: .bank, accountKey: "santander:1111")
            XCTAssertEqual(store.cashAvailable, 12_000)
        }
    }

    func testClosedAccountsSurviveReloadAndAreBackedUp() {
        withStore { store in
            store.statements = [statement("Santander", key: "santander:1111", kind: .bank, summary: .init(cashBalance: 2_000))]
            store.setAccountClosed(true, source: "Santander", kind: .bank, accountKey: "santander:1111")
            XCTAssertTrue(FinanceStore().closedAccountKeys.contains("santander:1111"))
            XCTAssertTrue(FinanceBackup.allowed(FinanceStore.closedAccountsKey))
        }
        XCTAssertTrue(FinanceStore().closedAccountKeys.isEmpty)
    }
}
