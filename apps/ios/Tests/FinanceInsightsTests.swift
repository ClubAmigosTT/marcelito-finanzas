import XCTest
@testable import Marcelito

@MainActor
final class FinanceInsightsTests: XCTestCase {
    private func withStores(_ body: (FinanceStore, FinancialPlanningStore) throws -> Void) rethrows {
        let suite = "marcelito.insights.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = FinanceStore(); store.clearLocalData()
        UserDefaults.standard.removeObject(forKey: FinanceStore.dismissedUnusualKey)
        defer { store.clearLocalData(); UserDefaults.standard.removeObject(forKey: FinanceStore.dismissedUnusualKey); defaults.removePersistentDomain(forName: suite) }
        try body(store, FinancialPlanningStore(defaults: defaults))
    }
    private func day(_ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }
    private func bank() -> StatementRecord {
        StatementRecord(id: UUID(), source: "BBVA", accountKey: "bbva:4922", period: "01/04/2026 - 31/10/2026", fileName: "fixture.pdf",
            importedAt: .now, transactionCount: 0, requiresReview: false, kind: .bank,
            reconciliation: StatementReconciliationRecord(status: .valid, tolerance: 0),
            sourceDetection: SourceDetectionEvidence(source: "BBVA", confidence: 1, status: .verified, evidence: ["fixture"], ignoredBodyMentions: []),
            readerVersion: FinanceStore.readerVersion)
    }
    private func spend(_ amount: Decimal, _ date: Date, _ title: String, statement: StatementRecord, kind: MovementKind = .purchase, category: String = "Compras personales") -> Movement {
        var row = Movement(date: date, title: title, account: "BBVA", category: category, amount: -amount, flow: .expense, kind: kind)
        row.statementId = statement.id
        return row
    }

    func testDuplicatePriceIncreaseAndNewFeeAreFlaggedOnce() {
        withStores { store, _ in
            let statement = bank()
            store.statements = [statement]
            store.movements = [
                spend(85, day(10, 5), "UBER TRIP", statement: statement),
                spend(85, day(10, 5), "UBER TRIP", statement: statement),
                spend(199, day(7, 3), "SPOTIFY P123", statement: statement),
                spend(199, day(8, 3), "SPOTIFY P124", statement: statement),
                spend(199, day(9, 3), "SPOTIFY P125", statement: statement),
                spend(239, day(10, 3), "SPOTIFY P126", statement: statement),
                spend(45, day(10, 8), "COMISION POR SALDO MINIMO", statement: statement, kind: .fee, category: "Comisiones y finanzas"),
            ]
            let charges = store.unusualCharges(now: day(10, 15))
            XCTAssertEqual(charges.filter { $0.kind == .duplicate }.count, 1)
            XCTAssertEqual(charges.filter { $0.kind == .priceIncrease }.count, 1)
            XCTAssertEqual(charges.filter { $0.kind == .newFee }.count, 1)
            store.dismissUnusualCharge(charges[0])
            XCTAssertEqual(store.unusualCharges(now: day(10, 15)).count, 2)
        }
    }

    func testMonthEndProjectionScalesObservedDaysOnly() {
        withStores { store, planning in
            let statement = bank()
            store.statements = [statement]
            store.movements = (1...10).map { spend(100, day(9, $0), "COMERCIO \($0)", statement: statement) }
            let projection = planning.monthEndProjection(store, month: day(9, 1), now: day(9, 10))
            XCTAssertEqual(projection?.observedDays, 10)
            XCTAssertEqual(projection?.spent, 1000)
            XCTAssertEqual(projection?.projected, 3000)
        }
    }

    func testMonthlySummaryListsTheBiggestCategoryChanges() {
        withStores { store, planning in
            let statement = bank()
            store.statements = [statement]
            store.movements = [
                spend(1000, day(8, 10), "RESTAURANTE A", statement: statement, category: "Restaurantes y bares"),
                spend(3000, day(9, 10), "RESTAURANTE B", statement: statement, category: "Restaurantes y bares"),
                spend(500, day(9, 12), "FARMACIA", statement: statement, category: "Salud"),
            ]
            let summary = planning.monthlySummary(store, month: day(9, 1))
            XCTAssertEqual(summary?.spend, 3500)
            XCTAssertEqual(summary?.changes.first?.category, "Restaurantes y bares")
            XCTAssertEqual(summary?.changes.first?.change, 2000)
        }
    }

    func testGoalDeadlineGivesTheMonthlyAmountNeeded() {
        let goal = SavingsGoal(name: "Liquidar ITAM", target: 120000, saved: 20000, monthlyContribution: 5000, targetDate: day(12, 15))
        // October through December: three months.
        XCTAssertEqual(goal.requiredMonthly(now: day(10, 19)), Decimal(string: "33334"))
        XCTAssertNil(SavingsGoal(name: "Sin fecha", target: 1000, saved: 0, monthlyContribution: 0).requiredMonthly())
    }

    func testCSVQuotesFieldsAndStartsWithByteOrderMark() {
        let statement = bank()
        var row = Movement(date: day(9, 1), title: "CAFÉ \"LA ESQUINA\", CDMX", account: "BBVA", category: "Restaurantes y bares", amount: -85.5, flow: .expense, kind: .purchase)
        row.statementId = statement.id
        let csv = MovementsExport.csv([row], statements: [statement])
        XCTAssertTrue(csv.hasPrefix("\"Fecha\",\"Cuenta\""))
        XCTAssertTrue(csv.contains("\"CAFÉ \"\"LA ESQUINA\"\", CDMX\""))
        XCTAssertTrue(csv.contains("\"-85.5\""))
        XCTAssertEqual(Array(MovementsExport.data([row], statements: [statement]).prefix(3)), [0xEF, 0xBB, 0xBF])
    }
}
