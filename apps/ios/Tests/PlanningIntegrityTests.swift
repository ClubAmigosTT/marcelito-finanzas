import XCTest
@testable import Marcelito

@MainActor final class PlanningIntegrityTests: XCTestCase {
    private func date(_ month: Int, _ day: Int = 1) -> Date { Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))! }
    private func withStores(_ body: (FinanceStore, FinancialPlanningStore, UserDefaults) throws -> Void) rethrows {
        let original = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("marcelito.") }
        let name = "marcelito.integrity.\(UUID())"
        let suite = UserDefaults(suiteName: name)!
        let store = FinanceStore(); store.clearLocalData()
        defer {
            store.clearLocalData()
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("marcelito.") { UserDefaults.standard.removeObject(forKey: key) }
            for (key, value) in original { UserDefaults.standard.set(value, forKey: key) }
            suite.removePersistentDomain(forName: name)
        }
        try body(store, FinancialPlanningStore(defaults: suite), suite)
    }
    private func row(_ amount: Decimal, title: String = "OXXO", extra: Bool = false) -> Movement {
        Movement(date: date(9,15), title: title, account: "BBVA", category: "Otros / Por revisar", amount: amount, flow: amount < 0 ? .expense : .income, kind: amount < 0 ? .purchase : .income, travelRelated: extra)
    }
    private func coverSeptember(_ store: FinanceStore) {
        let record = StatementRecord(id: UUID(), source: "BBVA", accountKey: "bbva:1234", period: "01/09/2026 - 30/09/2026", fileName: "fixture.pdf", importedAt: .now, transactionCount: 2, requiresReview: false, kind: .bank,
            summary: .init(depositTotal: 10000, withdrawalTotal: 2000, depositCount: 1, withdrawalCount: 1),
            reconciliation: .init(status: .valid, tolerance: 0, extractedDepositTotal: 10000, extractedWithdrawalTotal: 2000, extractedMovementCount: 2, expectedMovementCount: 2),
            sourceDetection: .init(source: "BBVA", confidence: 1, status: .verified, evidence: ["fixture"], ignoredBodyMentions: []), readerVersion: FinanceStore.readerVersion)
        store.statements = [record]
        store.movements = [row(10000), row(-2000)].map { item in
            var item = item; item.statementId = record.id; item.extractionEvidence = .init(method: "fixture", page: 1, confidence: 1); return item
        }
    }
    func testRemainingIncludesExtraordinaryAndUncollectedSharedWithoutCreatingIncome() {
        withStores { store, p, _ in
            p.state.incomeAmount = 10000
            let shared = row(-2000)
            store.movements = [row(-1000), row(-3000, extra: true), shared]
            p.setLabel(.init(sharedPerson: "Ana", sharedAmount: 1000), for: shared)
            XCTAssertEqual(p.total(store, period: .month(date(9))), 6000)
            XCTAssertEqual(p.snapshot(store, month: date(9), now: date(9,17)).remaining, 4000)
            var label = p.label(for: shared); label.collectedAmount = 1000; p.setLabel(label, for: shared)
            XCTAssertEqual(p.snapshot(store, month: date(9), now: date(9,17)).remaining, 4000)
            XCTAssertTrue(store.realIncomeMovements.isEmpty)
            XCTAssertEqual(store.movements.map(\.amount), [-1000,-3000,-2000])
        }
    }
    func testIncomeEffectiveDatesAndReloadPreserveEarlierMonths() {
        withStores { _, p, defaults in
            p.state.incomeAmount = 10000
            XCTAssertTrue(p.setIncomeSources([.init(name: "Nuevo sueldo", amount: 12000, cadence: "Mensual")], effectiveFrom: date(10)))
            XCTAssertEqual(p.monthlyIncome(for: date(9)),10000); XCTAssertEqual(p.monthlyIncome(for: date(10)),12000)
            XCTAssertEqual(FinancialPlanningStore(defaults: defaults).monthlyIncome(for: date(9)),10000)
        }
    }
    func testLegacyPlanMigrationDoesNotOverwriteExistingBudget() {
        withStores { _, p, defaults in
            var existing = p.plan(for: date(9)); existing.savingsTarget = 2000; p.setPlan(existing, for: date(9))
            defaults.set("5000",forKey:"marcelito.monthlyPlan.2026.9.budget")
            defaults.set("1000",forKey:"marcelito.monthlyPlan.2026.9.target")
            let loaded = FinancialPlanningStore(defaults: defaults)
            XCTAssertNil(loaded.plan(for: date(9)).spendingLimit)
            XCTAssertEqual(loaded.plan(for: date(9)).legacySpendingLimit,5000)
            XCTAssertEqual(loaded.plan(for: date(9)).savingsTarget,2000)
            var plan = loaded.plan(for: date(9)); plan.spendingLimit = 6000; loaded.setPlan(plan,for:date(9))
            XCTAssertEqual(FinancialPlanningStore(defaults:defaults).plan(for:date(9)).spendingLimit,6000)
        }
    }
    func testClosingIsFrozenIdempotentAndReopeningReversesItsDestination() {
        withStores { store, p, defaults in
            coverSeptember(store); p.state.incomeAmount = 10000
            let goal = SavingsGoal(name:"Fondo",target:20000,saved:1000,monthlyContribution:1000)
            XCTAssertTrue(p.saveGoal(goal))
            XCTAssertTrue(p.closeMonth(date(9),store:store,goalID:goal.id,now:date(10,17)))
            let remaining = p.snapshot(store,month:date(9)).remaining
            XCTAssertEqual(p.state.goals[0].saved,9000)
            XCTAssertFalse(p.closeMonth(date(9),store:store,goalID:goal.id,now:date(10,17)))
            XCTAssertTrue(p.setIncomeSources([.init(name:"Corregido",amount:15000,cadence:"Mensual")],effectiveFrom:date(9)))
            XCTAssertEqual(p.snapshot(store,month:date(9)).remaining,remaining)
            XCTAssertEqual(FinancialPlanningStore(defaults:defaults).snapshot(store,month:date(9)).remaining,remaining)
            XCTAssertTrue(p.reopenMonth(date(9))); XCTAssertEqual(p.state.goals[0].saved,1000)
            XCTAssertFalse(p.reopenMonth(date(9)))
        }
    }
    func testCloseRefusesPartialCoverageAndLegacyCloseCannotCreditAgain() {
        withStores { store, p, _ in
            p.state.incomeAmount = 10000
            let goal = SavingsGoal(name:"Fondo",target:20000,saved:1000,monthlyContribution:1000); XCTAssertTrue(p.saveGoal(goal))
            XCTAssertFalse(p.closeMonth(date(9),store:store,goalID:goal.id,now:date(10,17)))
            var plan = p.plan(for:date(9)); plan.closed = true; p.setPlan(plan,for:date(9))
            coverSeptember(store)
            XCTAssertFalse(p.closeMonth(date(9),store:store,goalID:goal.id,now:date(10,17)))
            XCTAssertEqual(p.state.goals[0].saved,1000)
        }
    }
    func testUndoCategoryRestoresRuleAndPreviouslyAssignedInformation() {
        withStores { store, _, _ in
            let first = row(-100), second = row(-200)
            store.movements = [first,second]
            XCTAssertTrue(store.updateCategory(for:first,to:"Tiendita",applyToMerchant:true))
            XCTAssertGreaterThan(store.categoryUndoCount,0)
            XCTAssertTrue(store.undoLastCategoryChange())
            XCTAssertEqual(store.movements.map(\.category),[first.category,second.category])
            XCTAssertEqual(store.movements.map(\.amount),[-100,-200])
            XCTAssertFalse(store.undoLastCategoryChange())
        }
    }
    func testGoalContributionsCannotCreateNegativeBalance() {
        withStores { _, p, _ in
            let goal = SavingsGoal(name:"Fondo",target:20000,saved:1000,monthlyContribution:1000); XCTAssertTrue(p.saveGoal(goal))
            XCTAssertTrue(p.contribute(to:goal.id,amount:500,date:date(9),note:"Ahorro"))
            XCTAssertFalse(p.contribute(to:goal.id,amount:-2000,date:date(9),note:"Retiro"))
            XCTAssertEqual(p.state.goals[0].saved,1500)
            XCTAssertEqual(p.state.goals[0].entries?.count,1)
        }
    }
    func testCardCycleCountsOnlyConfirmedPaymentAndNeverAnIncomeDeposit() {
        withStores { store, p, _ in
            let statement = StatementRecord(id: UUID(), source: "Amex", accountKey: "amex:1003", period: "28/08/2026 - 27/09/2026", fileName: "fixture.pdf", importedAt: .now, transactionCount: 0, requiresReview: false, kind: .card, summary: .init(paymentForNoInterest: 1000))
            store.statements = [statement]
            var payment = row(-1000, title:"Pago Amex"); payment.kind = .cardPayment; payment.date = date(10,3)
            var deposit = row(15000, title:"Ingreso externo"); deposit.date = date(10,3)
            store.movements = [payment,deposit]
            XCTAssertEqual(store.cyclePayment(statement,planning:p)?.paid,0)
            p.state.cardPaymentLinks = [.init(statementID:statement.id,movementID:payment.id,identity:FinanceStore.loanBankIdentity(payment),cycleKey:store.cardCycleKey(statement))]
            XCTAssertEqual(store.cyclePayment(statement,planning:p)?.paid,1000)
            XCTAssertEqual(store.cyclePayment(statement,planning:p)?.remaining,0)
            store.movements[0].kind = .purchase
            XCTAssertEqual(store.cyclePayment(statement,planning:p)?.paid,0)
        }
    }

}
