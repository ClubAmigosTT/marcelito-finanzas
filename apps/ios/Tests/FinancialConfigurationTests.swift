import XCTest
@testable import Marcelito

@MainActor final class FinancialConfigurationTests: XCTestCase {
    private func date(_ month: Int, _ day: Int = 1) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }
    private func row(_ month: Int, _ day: Int, name: String = "Internet", amount: Decimal = -500, account: String = "BBVA", kind: MovementKind = .purchase) -> Movement {
        Movement(date: date(month, day), title: name, account: account, category: "Software y suscripciones", amount: amount, flow: amount > 0 ? .income : .expense, kind: kind)
    }
    private func withStores(_ body: (FinanceStore, FinancialPlanningStore, UserDefaults) -> Void) {
        let original = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("marcelito.") }
        let suite = "marcelito.configuration.tests.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        let store = FinanceStore(); store.clearLocalData()
        defer {
            store.clearLocalData()
            for (key, value) in original { UserDefaults.standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: suite)
        }
        body(store, FinancialPlanningStore(defaults: defaults), defaults)
    }
    func testLegacyPlanningWithoutFixedExpensesKeepsIncomeLabelsAndBudgets() {
        withStores { store, p, defaults in
            let movement = row(6, 10); store.movements = [movement]
            XCTAssertTrue(p.setIncomeSources([PlanningIncomeSource(name: "Nómina", amount: 16500, cadence: "Quincenal")]))
            var label = PersonalExpenseLabel(); label.fixed = false; label.sharedPerson = "Ana"; label.sharedAmount = 100
            p.setLabel(label, for: movement)
            var plan = MonthBudgetPlan(); plan.savingsTarget = 2000; plan.fixedLimits["Salud"] = 600
            p.setPlan(plan, for: date(10))
            var json = try! JSONSerialization.jsonObject(with: defaults.data(forKey: "marcelito.planning.v1")!) as! [String: Any]
            json.removeValue(forKey: "fixedExpenses")
            defaults.set(try! JSONSerialization.data(withJSONObject: json), forKey: "marcelito.planning.v1")
            let loaded = FinancialPlanningStore(defaults: defaults)
            XCTAssertNil(loaded.loadError); XCTAssertTrue(loaded.fixedExpenses.isEmpty)
            let item = PlanningFixedExpense(name: "Renta", amount: 6000, category: "Hogar", startMonth: date(10))
            XCTAssertTrue(loaded.setFixedExpenses([item]))
            let restored = FinancialPlanningStore(defaults: defaults)
            XCTAssertEqual(restored.fixedExpenses, [item]); XCTAssertEqual(restored.monthlyIncome, 33000)
            XCTAssertEqual(restored.label(for: movement).sharedAmount, 100); XCTAssertEqual(restored.label(for: movement).fixed, false)
            XCTAssertEqual(restored.plan(for: date(10)).savingsTarget, 2000); XCTAssertEqual(restored.plan(for: date(10)).fixedLimits["Salud"], 600)
            XCTAssertEqual(store.movements.first?.category, "Software y suscripciones")
        }
    }
    func testFixedExpenseFrequenciesUseExplicitMonthlyReserves() {
        var item = PlanningFixedExpense(name: "Entrenamiento", amount: 100, category: "Entrenamiento", startMonth: date(10))
        XCTAssertEqual(item.monthlyAmount, 100)
        item.cadence = .fortnightly; XCTAssertEqual(item.monthlyAmount, 200)
        item.cadence = .weekly; XCTAssertEqual(item.monthlyAmount, Decimal(string: "433.33"))
        item.cadence = .annual; XCTAssertEqual(item.monthlyAmount, Decimal(string: "8.33"))
    }
    func testDetectionNeedsConfirmationAndDoesNotRecommendIrregularFrequentShops() {
        withStores { store, p, _ in
            let monthly = [row(6, 10), row(7, 10), row(8, 10)]
            let frequent = [row(6, 2, name: "Café", amount: -100), row(6, 8, name: "Café", amount: -40), row(7, 20, name: "Café", amount: -90), row(7, 26, name: "Café", amount: -50)]
            store.movements = monthly + frequent
            let found = p.recurringExpenseSuggestions(store, now: date(10))
            XCTAssertEqual(found.count, 1)
            XCTAssertEqual(found.first(where: { $0.name == "Internet" })?.regular, true)
            XCTAssertEqual(found.first(where: { $0.name == "Internet" })?.cadence, .monthly)
            XCTAssertNil(found.first(where: { $0.name == "Café" }))
            XCTAssertEqual(found.first?.movements.count, 3)
            XCTAssertTrue(p.fixedExpenses.isEmpty); XCTAssertFalse(p.isFixed(monthly[0]))
            XCTAssertTrue(p.fixedLimits(store, month: date(10)).isEmpty)
        }
    }
    func testWeeklyDetectionAndInsufficientHistory() {
        withStores { store, p, _ in
            store.movements = [row(6, 24), row(7, 1), row(7, 8), row(7, 15)]
            XCTAssertEqual(p.recurringExpenseSuggestions(store, now: date(10)).first?.cadence, .weekly)
            store.movements = [row(7, 1), row(7, 8), row(7, 15), row(7, 22)]
            XCTAssertTrue(p.recurringExpenseSuggestions(store, now: date(10)).isEmpty)
            store.movements = [row(6, 10), row(7, 10)]
            XCTAssertTrue(p.recurringExpenseSuggestions(store, now: date(10)).isEmpty)
        }
    }
    func testDetectionExcludesTransfersCardPaymentsExtraordinaryAndLinkedMSI() {
        withStores { store, p, _ in
            var rows: [Movement] = []
            for month in 6...8 {
                rows += [row(month, 10, name: "Propia", kind: .bankTransfer), row(month, 10, name: "Pago tarjeta", kind: .cardPayment), row(month, 10, name: "Ingreso", amount: 500, kind: .income), row(month, 10, name: "Viaje"), row(month, 10, name: "MSI", kind: .msi), row(month, 10, name: "MSI sin registrar", kind: .msi), row(month, 10, name: "SPEI ENVIADO STP")]
            }
            store.movements = rows
            for item in rows where item.title == "Viaje" { var label = PersonalExpenseLabel(); label.extraordinary = true; p.setLabel(label, for: item) }
            let linked = rows.filter { $0.title == "MSI" }
            p.state.installments = [InstallmentCommitment(merchant: "MSI", account: "BBVA", purchaseDate: date(6), total: 1500, monthly: 500, count: 3, firstDueMonth: date(6), linkedMovementIDs: linked.map(\.id), linkedIdentities: [], category: "Compras personales")]
            XCTAssertTrue(p.recurringExpenseSuggestions(store, now: date(10)).isEmpty)
        }
    }
    func testConfirmedExpenseIsScopedByBankAndDatesWithoutChangingCategories() {
        withStores { store, p, defaults in
            let bbva = row(10, 10); let otherBank = row(10, 10, account: "Santander"); let old = row(9, 10)
            store.movements = [bbva, otherBank, old]
            let item = PlanningFixedExpense(name: "Internet", amount: 550, category: "Servicios", matchKey: p.fixedExpenseKey(bbva), account: "BBVA", startMonth: date(10), endMonth: date(11))
            XCTAssertTrue(p.setFixedExpenses([item]))
            XCTAssertTrue(p.isFixed(bbva)); XCTAssertFalse(p.isFixed(otherBank)); XCTAssertFalse(p.isFixed(old))
            XCTAssertEqual(p.fixedLimits(store, month: date(10))["Servicios"], 550)
            XCTAssertEqual(p.budgetCategoryTotals(store, period: .month(date(10)), fixed: true)["Servicios"], 500)
            XCTAssertNil(p.budgetCategoryTotals(store, period: .month(date(10)), fixed: true)["Software y suscripciones"])
            p.state.incomeAmount = 10000
            // Santander is a separate variable expense; BBVA is reserved once.
            XCTAssertEqual(p.snapshot(store, month: date(10), now: date(10, 15)).remaining, 8950)
            XCTAssertTrue(p.fixedLimits(store, month: date(12)).isEmpty)
            XCTAssertEqual(FinancialPlanningStore(defaults: defaults).fixedExpenses, [item])
            XCTAssertEqual(store.movements[0].amount, -500); XCTAssertEqual(store.movements[0].category, "Software y suscripciones")
        }
    }
    func testLinkedFixedIsNotAlsoVariableAndDoesNotDuplicateLegacyFixedRules() {
        withStores { store, p, _ in
            let previous = row(9, 10); let current = row(10, 10)
            store.movements = [previous, current]; p.state.incomeAmount = 10000
            p.state.fixedMerchantRules[p.merchantKey(current)] = true
            XCTAssertEqual(p.fixedLimits(store, month: date(10))["Software y suscripciones"], 500)
            let item = PlanningFixedExpense(name: "Internet", amount: 550, category: "Software y suscripciones", matchKey: p.fixedExpenseKey(current), startMonth: date(10))
            XCTAssertTrue(p.setFixedExpenses([item]))
            let snapshot = p.snapshot(store, month: date(10), now: date(10, 15))
            XCTAssertEqual(snapshot.fixed, 550); XCTAssertEqual(snapshot.variableSpent, 0); XCTAssertEqual(snapshot.remaining, 9450)
            var plan = p.plan(for: date(10)); plan.fixedLimits[item.category] = 600; p.setPlan(plan, for: date(10))
            XCTAssertEqual(p.fixedLimits(store, month: date(10))[item.category], 600)
            var edited = item; edited.amount = 650; XCTAssertTrue(p.setFixedExpenses([edited]))
            XCTAssertEqual(p.fixedLimits(store, month: date(11))[item.category], 650)
        }
    }
    func testManualFixedExceptionAndSharedPartArePreserved() {
        withStores { store, p, _ in
            let ordinary = row(10, 10); let exception = row(10, 20)
            store.movements = [ordinary, exception]
            var label = PersonalExpenseLabel(); label.fixed = false; label.sharedAmount = 100; label.sharedPerson = "Ana"
            p.setLabel(label, for: exception)
            let item = PlanningFixedExpense(name: "Internet", amount: 500, category: "Software y suscripciones", matchKey: p.fixedExpenseKey(ordinary), startMonth: date(10))
            XCTAssertTrue(p.setFixedExpenses([item]))
            XCTAssertTrue(p.isFixed(ordinary)); XCTAssertFalse(p.isFixed(exception))
            XCTAssertEqual(p.budgetCategoryTotals(store, period: .month(date(10)), fixed: false)[item.category], 500)
            XCTAssertEqual(p.label(for: exception).sharedPerson, "Ana")
            XCTAssertTrue(p.setFixedExpenses([])); XCTAssertFalse(p.isFixed(ordinary))
            XCTAssertEqual(p.label(for: exception).fixed, false); XCTAssertEqual(store.movements.count, 2)
        }
    }
    func testConfirmedFixedLeavesVariableHistoryProposalWithoutRewritingPast() {
        withStores { store, p, _ in
            for month in 6...8 {
                let days = Calendar.current.range(of: .day, in: .month, for: date(month))!.count
                let statement = StatementRecord(id: UUID(), source: "BBVA", accountKey: "bbva:1234", period: String(format: "01/%02d/2026 - %02d/%02d/2026", month, days, month), fileName: "fixture.pdf", importedAt: .now, transactionCount: 1, requiresReview: false, kind: .bank,
                    summary: .init(depositTotal: 0, withdrawalTotal: 500, depositCount: 0, withdrawalCount: 1),
                    reconciliation: .init(status: .valid, tolerance: 0, extractedDepositTotal: 0, extractedWithdrawalTotal: 500, extractedMovementCount: 1, expectedMovementCount: 1),
                    sourceDetection: .init(source: "BBVA", confidence: 1, status: .verified, evidence: ["fixture"], ignoredBodyMentions: []), readerVersion: FinanceStore.readerVersion)
                var item = row(month, 10); item.statementId = statement.id; item.extractionEvidence = .init(method: "fixture", page: 1, confidence: 1)
                store.statements.append(statement); store.movements.append(item)
            }
            XCTAssertEqual(p.proposals(store, month: date(9))["Software y suscripciones"], 500)
            let first = store.movements[0]
            let config = PlanningFixedExpense(name: "Internet", amount: 550, category: "Software y suscripciones", matchKey: p.fixedExpenseKey(first), startMonth: date(9))
            XCTAssertTrue(p.setFixedExpenses([config]))
            XCTAssertTrue(p.proposals(store, month: date(9)).isEmpty)
            XCTAssertEqual(p.fixedLimits(store, month: date(9))[config.category], 550)
            XCTAssertFalse(p.isFixed(first)); XCTAssertEqual(p.budgetCategoryTotals(store, period: .month(date(6)), fixed: false)[config.category], 500)
        }
    }
    func testDuplicateInvalidAndFailedSavesKeepExistingConfiguration() {
        withStores { _, p, defaults in
            let item = PlanningFixedExpense(name: "Renta", amount: 6000, category: "Hogar", matchKey: "bbva|renta", startMonth: date(10))
            XCTAssertTrue(p.setFixedExpenses([item]))
            let saved = defaults.data(forKey: "marcelito.planning.v1")
            var duplicate = item; duplicate.id = UUID()
            XCTAssertFalse(p.setFixedExpenses([item, duplicate]))
            var invalid = item; invalid.amount = -10; XCTAssertFalse(p.setFixedExpenses([invalid]))
            invalid = item; invalid.amount = 0; XCTAssertFalse(p.setFixedExpenses([invalid]))
            invalid = item; invalid.endMonth = date(9); XCTAssertFalse(p.setFixedExpenses([invalid]))
            invalid = item; invalid.category = "Ingresos"; XCTAssertFalse(p.setFixedExpenses([invalid]))
            XCTAssertEqual(p.fixedExpenses, [item]); XCTAssertEqual(defaults.data(forKey: "marcelito.planning.v1"), saved)
            let corrupt = Data("invalid".utf8); defaults.set(corrupt, forKey: "marcelito.planning.v1")
            let blocked = FinancialPlanningStore(defaults: defaults)
            XCTAssertFalse(blocked.setFixedExpenses([item])); XCTAssertTrue(blocked.fixedExpenses.isEmpty)
            XCTAssertEqual(defaults.data(forKey: "marcelito.planning.v1"), corrupt)
        }
    }
    func testRecurringSuggestionsRefreshAndConfirmedItemsDoNotReappear() {
        withStores { store, p, _ in
            store.movements = [row(6, 10), row(7, 10), row(8, 10)]
            let suggestion = p.recurringExpenseSuggestions(store, now: date(10)).first!
            for _ in 0..<20 { XCTAssertEqual(p.recurringExpenseSuggestions(store, now: date(10)).count, 1) }
            XCTAssertEqual(p.spendingProjectionBuildCount, 1)
            let config = PlanningFixedExpense(name: suggestion.name, amount: suggestion.amount, category: suggestion.category, matchKey: suggestion.id, startMonth: date(10))
            XCTAssertTrue(p.setFixedExpenses([config])); XCTAssertTrue(p.recurringExpenseSuggestions(store, now: date(10)).isEmpty)
            XCTAssertTrue(p.setFixedExpenses([])); XCTAssertEqual(p.recurringExpenseSuggestions(store, now: date(10)).count, 1)
            store.movements[0].kind = .bankTransfer
            XCTAssertTrue(p.recurringExpenseSuggestions(store, now: date(10)).isEmpty)
        }
    }
    func testFixedOverrunStillReducesAvailableWithoutCountingTheChargeTwice() {
        withStores { store, p, _ in
            let movement = row(10, 10, amount: -800); store.movements = [movement]; p.state.incomeAmount = 10000
            let config = PlanningFixedExpense(name: "Internet", amount: 500, category: "Software y suscripciones", matchKey: p.fixedExpenseKey(movement), startMonth: date(10))
            XCTAssertTrue(p.setFixedExpenses([config]))
            let snapshot = p.snapshot(store, month: date(10), now: date(10, 15))
            XCTAssertEqual(snapshot.fixed, 500); XCTAssertEqual(snapshot.fixedOverrun, 300)
            XCTAssertEqual(snapshot.variableSpent, 0); XCTAssertEqual(snapshot.remaining, 9200)
        }
    }

    func testFixedMerchantIdentityKeepsRecipientsSeparateAndRefreshesEditedEvidence() {
        withStores { _, p, _ in
            let first = row(10, 10, name: "PAGO TRANSFERENCIA A ANA LOPEZ IVA REF 123")
            var second = row(10, 10, name: "PAGO TRANSFERENCIA A MARIA PEREZ IVA REF 456")
            XCTAssertTrue(p.canLinkFixedExpense(first)); XCTAssertTrue(p.canLinkFixedExpense(second))
            XCTAssertNotEqual(p.fixedExpenseKey(first), p.fixedExpenseKey(second))
            let previous = p.fixedExpenseKey(second)
            second.title = "PAGO TRANSFERENCIA A OTRA PERSONA IVA REF 456"
            XCTAssertNotEqual(p.fixedExpenseKey(second), previous)
            XCTAssertFalse(p.canLinkFixedExpense(row(10, 10, name: "SPEI ENVIADO STP")))
        }
    }

    func testPayrollUsesOriginalBankDescriptionAndKeepsActualDepositSelectionAvailable() {
        withStores { store, p, _ in
            var deposits: [Movement] = []
            for (month, day, amount) in [(7, 15, 16500), (7, 31, 16600), (8, 14, 16400), (8, 31, 16500), (8, 31, 40000)] {
                var item = row(month, day, name: "ABONO \(month)\(day)", amount: Decimal(amount), account: "Santander", kind: .income)
                item.normalizedMerchant = "Abono"
                item.rawDescription = "ABONO PAGO DE NOMINA EMPRESA REF \(month)\(day)"
                deposits.append(item)
            }
            let ownTransfer = row(8, 20, name: "Propia", amount: 15000, kind: .bankTransfer)
            let refund = row(8, 21, name: "Devolución", amount: 15000, kind: .refund)
            store.movements = deposits + [ownTransfer, refund]
            let found = p.incomeSuggestions(store, now: date(10))
            XCTAssertEqual(found.count, 1); XCTAssertEqual(found.first?.amount, 16500)
            XCTAssertEqual(found.first?.cadence, "Quincenal"); XCTAssertEqual(found.first?.movements.count, 4)
            let options = p.receivedIncomeOptions(store, now: date(10))
            XCTAssertEqual(options.count, 5); XCTAssertFalse(options.contains(where: { $0.id == ownTransfer.id || $0.id == refund.id }))
            let draft = p.incomeDraft(from: deposits[0], store: store)
            XCTAssertEqual(draft.account, "Santander"); XCTAssertEqual(draft.cadence, "Quincenal")
            XCTAssertTrue(p.incomeSources.isEmpty)
            XCTAssertTrue(p.setIncomeSources([draft]))
            XCTAssertTrue(p.incomeSuggestions(store, now: date(10)).isEmpty)
            XCTAssertEqual(store.movements[0].amount, deposits[0].amount)
        }
    }
    func testManualIncomeSupportsWeeklyAndAnnualWithoutCreatingDeposits() {
        withStores { store, p, defaults in
            let weekly = PlanningIncomeSource(name: "Clases", amount: 100, cadence: "Semanal")
            let annual = PlanningIncomeSource(name: "Ingreso anual", amount: 1200, cadence: "Anual")
            XCTAssertTrue(p.setIncomeSources([weekly, annual])); XCTAssertEqual(p.monthlyIncome, Decimal(string: "533.33"))
            XCTAssertEqual(FinancialPlanningStore(defaults: defaults).incomeSources, [weekly, annual])
            XCTAssertTrue(store.movements.isEmpty)
        }
    }
    func testStricterDetectionPreservesPreviouslyConfirmedFixedExpenses() {
        withStores { store, p, defaults in
            store.movements = [row(6, 2, name: "Café", amount: -100), row(6, 8, name: "Café", amount: -40), row(7, 20, name: "Café", amount: -90), row(7, 26, name: "Café", amount: -50)]
            let saved = PlanningFixedExpense(name: "Café de oficina", amount: 140, category: "Tiendita", matchKey: p.fixedExpenseKey(store.movements[0]), startMonth: date(10))
            XCTAssertTrue(p.setFixedExpenses([saved]))
            XCTAssertTrue(p.recurringExpenseSuggestions(store, now: date(10)).isEmpty)
            XCTAssertEqual(p.fixedLimits(store, month: date(10))["Tiendita"], 140)
            XCTAssertEqual(FinancialPlanningStore(defaults: defaults).fixedExpenses, [saved])
            XCTAssertEqual(store.movements.count, 4)
        }
    }
    func testDismissingSuggestionPersistsAndIsReversibleWithoutClassifyingMovements() {
        withStores { store, p, defaults in
            store.movements = [row(6, 10), row(7, 10), row(8, 10)]
            let suggestion = p.recurringExpenseSuggestions(store, now: date(10)).first!
            XCTAssertTrue(p.setDismissedRecurringExpenses([suggestion.id]))
            XCTAssertTrue(p.recurringExpenseSuggestions(store, now: date(10)).isEmpty)
            let loaded = FinancialPlanningStore(defaults: defaults)
            XCTAssertTrue(loaded.recurringExpenseSuggestions(store, now: date(10)).isEmpty)
            XCTAssertTrue(loaded.fixedExpenses.isEmpty); XCTAssertNil(loaded.label(for: store.movements[0]).fixed)
            XCTAssertTrue(loaded.setDismissedRecurringExpenses([]))
            XCTAssertEqual(loaded.recurringExpenseSuggestions(store, now: date(10)).count, 1)
            XCTAssertEqual(store.movements[0].category, "Software y suscripciones")
        }
    }

}
