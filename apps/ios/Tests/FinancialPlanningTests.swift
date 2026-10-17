import XCTest
@testable import Marcelito

@MainActor final class FinancialPlanningTests: XCTestCase {
    private func date(_ month: Int, _ day: Int, year: Int = 2026) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
    private func row(_ month: Int, _ day: Int, _ amount: Decimal, kind: MovementKind = .purchase, category: String = "Tiendita") -> Movement {
        Movement(date: date(month, day), title: "Comercio", account: "BBVA", category: category, amount: amount, flow: amount > 0 ? .income : .expense, kind: kind)
    }
    private func withStores(_ body: (FinanceStore, FinancialPlanningStore, UserDefaults) -> Void) {
        let original = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("marcelito.") }
        let suite = "marcelito.planning.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = FinanceStore(); store.clearLocalData()
        defer {
            store.clearLocalData()
            for (key, value) in original { UserDefaults.standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: suite)
        }
        body(store, FinancialPlanningStore(defaults: defaults), defaults)
    }
    func testLargeBookProjectionIsReusedAcrossTabsAndPeriodChanges() {
        withStores { store, p, _ in
            store.movements = (0..<1377).map { index in row(6 + index % 3, 1 + index % 27, -100) }
            let period = FinancePeriod(start: FinancePeriod.month(date(1, 1)).start, end: FinancePeriod.month(date(12, 1)).end)
            for _ in 0..<20 {
                XCTAssertEqual(p.expenseRows(store, period: period).count, 1377)
                XCTAssertEqual(p.total(store, period: period), 137700)
                XCTAssertEqual(p.personalTotal(store, period: period), 137700)
                _ = p.budgetCategoryTotals(store, period: .month(date(6, 1)), fixed: false)
            }
            XCTAssertEqual(p.spendingProjectionBuildCount, 1)
            let snapshot = store.movements
            XCTAssertEqual(snapshot.count, 1377)
            XCTAssertTrue(snapshot.allSatisfy { $0.amount == -100 })
        }
    }
    func testCachedProjectionsRefreshAfterInMemoryAccountingAndCategoryEdits() {
        withStores { store, p, _ in
            store.movements = [row(6, 1, -100)]
            let version = store.ledgerVersion
            XCTAssertEqual(p.total(store, period: .month(date(6, 1))), 100)
            _ = p.budgetCategoryTotals(store, period: .month(date(6, 1)))
            store.movements[0].category = "Salud"
            XCTAssertEqual(p.budgetCategoryTotals(store, period: .month(date(6, 1)))["Salud"], 100)
            XCTAssertNil(p.budgetCategoryTotals(store, period: .month(date(6, 1)))["Tiendita"])
            store.movements[0].kind = .bankTransfer
            XCTAssertEqual(p.total(store, period: .month(date(6, 1))), 0)
            XCTAssertTrue(store.netExpenseMovements.isEmpty)
            XCTAssertEqual(store.ledgerVersion, version)
            XCTAssertEqual(p.spendingProjectionBuildCount, 3)
        }
    }
    func testCachedPersonalTotalsRefreshAfterLabelsAndMerchantRules() {
        withStores { store, p, _ in
            let movement = row(6, 1, -1000); store.movements = [movement]
            let period = FinancePeriod.month(date(6, 1))
            XCTAssertEqual(p.personalTotal(store, period: period), 1000)
            var label = PersonalExpenseLabel(); label.sharedAmount = 300; label.sharedPerson = "Amiga"
            p.setLabel(label, for: movement)
            XCTAssertEqual(p.personalTotal(store, period: period), 700)
            label.extraordinary = true; p.setLabel(label, for: movement)
            XCTAssertEqual(p.personalTotal(store, period: period), 0)
            label.extraordinary = false; p.setLabel(label, for: movement)
            p.state.fixedMerchantRules[p.merchantKey(movement)] = true
            XCTAssertEqual(p.budgetCategoryTotals(store, period: period, fixed: true)["Tiendita"], 1000)
            XCTAssertTrue(p.budgetCategoryTotals(store, period: period, fixed: false).isEmpty)
            XCTAssertEqual(store.movements[0].amount, -1000)
        }
    }
    func testCachedMSIMatchesUniqueRebuiltIdentityButPreservesAmbiguousRows() {
        withStores { store, p, _ in
            let movement = row(6, 1, -100); store.movements = [movement]
            let plan = InstallmentCommitment(merchant: "MSI", account: "BBVA", purchaseDate: date(5, 1), total: 300, monthly: 100, count: 3, firstDueMonth: date(6, 1), linkedMovementIDs: [UUID()], linkedIdentities: [p.identity(movement)], category: "Compras personales")
            p.state.installments = [plan]
            XCTAssertEqual(p.total(store, period: .month(date(6, 1))), 0)
            XCTAssertEqual(p.total(store, period: .month(date(5, 1))), 300)
            var duplicate = movement; duplicate.id = UUID(); store.movements.append(duplicate)
            XCTAssertEqual(p.total(store, period: .month(date(6, 1))), 200)
            XCTAssertEqual(p.total(store, period: .month(date(5, 1))), 0)
            p.state.installments[0].linkedMovementIDs = [movement.id]
            XCTAssertEqual(p.total(store, period: .month(date(6, 1))), 100)
            XCTAssertEqual(p.total(store, period: .month(date(5, 1))), 300)
        }
    }
    func testSliderPlanChangesStayLiveAndFlushWithoutRebuildingSpending() {
        withStores { store, p, defaults in
            store.movements = [row(6, 1, -100)]
            p.state.incomeAmount = 3000; p.save()
            let before = defaults.data(forKey: "marcelito.planning.v1")
            let revision = p.revision
            XCTAssertEqual(p.snapshot(store, month: date(6, 1), now: date(6, 15)).remaining, 2900)
            for value in 1...20 {
                var plan = p.plan(for: date(6, 1)); plan.savingsTarget = Decimal(value * 10)
                p.setPlan(plan, for: date(6, 1), persist: false)
            }
            XCTAssertEqual(p.snapshot(store, month: date(6, 1), now: date(6, 15)).remaining, 2700)
            XCTAssertEqual(p.spendingProjectionBuildCount, 1)
            XCTAssertEqual(p.revision, revision)
            XCTAssertEqual(defaults.data(forKey: "marcelito.planning.v1"), before)
            XCTAssertTrue(p.hasUnsavedPlanChanges)
            p.savePendingPlanChanges()
            XCTAssertFalse(p.hasUnsavedPlanChanges)
            XCTAssertEqual(FinancialPlanningStore(defaults: defaults).plan(for: date(6, 1)).savingsTarget, 200)
            XCTAssertEqual(defaults.data(forKey: "marcelito.planning.v1.backup"), before)
        }
    }
    func testCachedIncomeProjectionRefreshesWhenAnEntryChangesKind() {
        withStores { store, p, _ in
            store.movements = [row(6, 1, 15000, kind: .income)]
            XCTAssertEqual(p.observedIncome(store, period: .month(date(6, 1))), 15000)
            store.movements[0].kind = .bankTransfer
            XCTAssertEqual(p.observedIncome(store, period: .month(date(6, 1))), 0)
            XCTAssertTrue(store.realIncomeMovements.isEmpty)
        }
    }
    func testPlanningAmountsRequireTheWholeValueAndKeepCents() {
        XCTAssertEqual(parsePlanningAmount("$16,500.25"), Decimal(string: "16500.25"))
        XCTAssertNil(parsePlanningAmount("12oops"))
        XCTAssertNil(parsePlanningAmount("12.3.4"))
        XCTAssertNil(parsePlanningAmount("100.001"))
        XCTAssertNil(parsePlanningAmount("-100"))
        XCTAssertEqual(parsePlanningAmount("48.5821", precision: 4), Decimal(string: "48.5821"))
    }
    func testPesoPositionChangeWorksFromZeroWithoutInventingPercent() {
        let points = [PositionHistoryPoint(monthStart: FinancePeriod.month(date(8, 1)).start, value: 0), PositionHistoryPoint(monthStart: FinancePeriod.month(date(9, 1)).start, value: 31080)]
        XCTAssertEqual(PositionHistoryBuilder.monthAmountChange(in: points, calendar: .current), 31080)
        XCTAssertNil(PositionHistoryBuilder.monthOverMonthChange(in: points, calendar: .current))
        XCTAssertNil(PositionHistoryBuilder.monthAmountChange(in: Array(points.suffix(1)), calendar: .current))
    }
    func testNaturalMonthAndEndExclusiveAcrossYearBoundary() {
        let month = FinancePeriod.month(date(12, 20))
        XCTAssertTrue(month.contains(date(12, 31)))
        XCTAssertFalse(month.contains(date(1, 1, year: 2027)))
        XCTAssertEqual(Calendar.current.component(.day, from: month.start), 1)
        XCTAssertTrue(month.label.lowercased().contains("diciembre"))
    }
    func testRangeNormalizesReversedDatesAndOneDay() {
        let range = FinancePeriod.selected(.range, date: date(6, 15), from: date(6, 20), through: date(6, 1))
        XCTAssertTrue(range.contains(date(6, 1))); XCTAssertTrue(range.contains(date(6, 20))); XCTAssertFalse(range.contains(date(6, 21)))
        let day = FinancePeriod.selected(.day, date: date(6, 15), from: date(6, 1), through: date(6, 20))
        XCTAssertTrue(day.contains(date(6, 15))); XCTAssertFalse(day.contains(date(6, 16)))
        XCTAssertFalse(day.label.contains("15–15"))
    }
    func testWeekIsSevenDaysAndMonthRangeUsesSpanishLabel() {
        let week = FinancePeriod.selected(.week, date: date(9, 17), from: date(9, 1), through: date(9, 30))
        XCTAssertEqual(Calendar.current.component(.day, from: week.start), 14)
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: week.start, to: week.end).day, 7)
        let range = FinancePeriod.selected(.range, date: date(9, 1), from: date(1, 1), through: date(9, 30))
        XCTAssertTrue(range.label.hasPrefix("Ene–")); XCTAssertTrue(range.label.hasSuffix("2026"))
    }
    func testPeriodNavigationDoesNotSkipShortMonthsOrYearBoundaries() {
        let january = FinancePeriod.month(date(1, 31))
        let february = january.shifted(by: 1, mode: .month)
        XCTAssertEqual(Calendar.current.component(.month, from: february.start), 2)
        XCTAssertEqual(Calendar.current.component(.day, from: february.start), 1)
        XCTAssertEqual(february.shifted(by: 1, mode: .month).start, FinancePeriod.month(date(3, 1)).start)
        XCTAssertEqual(february.shifted(by: -1, mode: .month), january)
        let december = FinancePeriod.month(date(12, 31))
        XCTAssertEqual(Calendar.current.component(.year, from: december.shifted(by: 1, mode: .month).start), 2027)
        let year = FinancePeriod.selected(.year, date: date(2, 29, year: 2024), from: date(1, 1), through: date(1, 1))
        XCTAssertEqual(year.label, "2024")
        XCTAssertEqual(year.months().count, 12)
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: year.start, to: year.end).day, 366)
        let next = year.shifted(by: 1, mode: .year)
        XCTAssertEqual(next.label, "2025")
        XCTAssertEqual(Calendar.current.component(.month, from: next.start), 1)
        XCTAssertEqual(next.shifted(by: -1, mode: .year), year)
    }
    func testDayWeekAndCustomRangeNavigationPreserveCalendarLength() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let day = FinancePeriod.selected(.day, date: anchor, from: anchor, through: anchor, calendar: calendar)
        let tomorrow = day.shifted(by: 1, mode: .day, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: tomorrow.start), 9)
        XCTAssertEqual(tomorrow.shifted(by: -1, mode: .day, calendar: calendar), day)
        let week = FinancePeriod.selected(.week, date: date(12, 31), from: date(12, 31), through: date(12, 31))
        let nextWeek = week.shifted(by: 1, mode: .week)
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: week.start, to: nextWeek.start).day, 7)
        XCTAssertEqual(Calendar.current.component(.weekday, from: nextWeek.start), 2)
        let range = FinancePeriod.selected(.range, date: date(1, 1), from: date(1, 28), through: date(2, 3))
        let nextRange = range.shifted(by: 1, mode: .range)
        XCTAssertEqual(nextRange.start, range.end)
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: nextRange.start, to: nextRange.end).day, 7)
        XCTAssertEqual(nextRange.shifted(by: -1, mode: .range), range)
    }
    func testHorizontalPeriodSwipeDoesNotCaptureVerticalScrollingOrSmallDrags() {
        XCTAssertEqual(periodSwipeDirection(horizontal: -100, vertical: 10), 1)
        XCTAssertEqual(periodSwipeDirection(horizontal: 100, vertical: -10), -1)
        XCTAssertNil(periodSwipeDirection(horizontal: 10, vertical: -150))
        XCTAssertNil(periodSwipeDirection(horizontal: 80, vertical: 60))
        XCTAssertNil(periodSwipeDirection(horizontal: 30, vertical: 0))
    }
    func testAnnualSpendingUsesChargeDatesAndExistingAccountingExclusions() {
        withStores { store, planning, _ in
            let year = FinancePeriod.selected(.year, date: date(6, 1), from: date(6, 1), through: date(6, 1))
            store.movements = [row(1, 2, -100), row(12, 31, -200), row(6, 10, -1000, kind: .cardPayment), row(6, 11, -2000, kind: .bankTransfer), row(6, 12, 15000, kind: .income), row(1, 1, -300)]
            store.movements[5].date = date(1, 1, year: 2027)
            XCTAssertEqual(planning.personalTotal(store, period: year), 300)
            XCTAssertEqual(planning.observedIncome(store, period: year), 15000)
            XCTAssertEqual(planning.expenseRows(store, period: year).count, 2)
        }
    }
    func testQuincenalIncomeAndNoIncomeAreDifferent() {
        withStores { _, p, defaults in
            XCTAssertNil(p.monthlyIncome)
            p.state.incomeAmount = 16500; p.state.incomeCadence = "Quincenal"; p.save()
            XCTAssertEqual(p.monthlyIncome, 33000)
            XCTAssertEqual(FinancialPlanningStore(defaults: defaults).monthlyIncome, 33000)
            p.state.incomeAmount = 0; XCTAssertEqual(p.monthlyIncome, 0)
        }
    }
    func testMultipleIncomeSourcesPersistAndNeverCreateDeposits() {
        withStores { store, planning, defaults in
            let salary = PlanningIncomeSource(name: "Nómina Santander", amount: 16500, cadence: "Quincenal", account: "Santander")
            let other = PlanningIncomeSource(name: "BBVA", amount: 15000, cadence: "Mensual", account: "BBVA")
            XCTAssertTrue(planning.setIncomeSources([salary, other]))
            XCTAssertEqual(planning.monthlyIncome, 48000)
            XCTAssertEqual(planning.state.incomeAmount, 48000) // older-version aggregate
            XCTAssertEqual(planning.state.incomeCadence, "Mensual")
            XCTAssertTrue(store.movements.isEmpty)
            let loaded = FinancialPlanningStore(defaults: defaults)
            XCTAssertEqual(loaded.incomeSources, [salary, other])
            XCTAssertEqual(loaded.monthlyIncome, 48000)
            XCTAssertEqual(loaded.snapshot(store, month: date(10, 1), now: date(10, 16)).income, 48000)
            XCTAssertEqual(loaded.observedIncome(store, period: .month(date(10, 1))), 0)
        }
    }
    func testLegacyIncomeMigrationPreservesAmountAndPlanningMetadata() throws {
        withStores { _, planning, defaults in
            planning.state.incomeAmount = 16500; planning.state.incomeCadence = "Quincenal"
            planning.state.goals = [SavingsGoal(name: "Fondo", target: 10000, saved: 200, monthlyContribution: 500)]
            planning.save()
            // Genuine old JSON does not contain the new optional key.
            var json = try! JSONSerialization.jsonObject(with: defaults.data(forKey: "marcelito.planning.v1")!) as! [String: Any]
            json.removeValue(forKey: "incomeSources")
            defaults.set(try! JSONSerialization.data(withJSONObject: json), forKey: "marcelito.planning.v1")
            let old = FinancialPlanningStore(defaults: defaults)
            XCTAssertNil(old.loadError)
            XCTAssertEqual(old.monthlyIncome, 33000)
            XCTAssertEqual(old.incomeSources.first?.name, "Ingreso habitual")
            XCTAssertEqual(old.incomeSources.first?.id, old.incomeSources.first?.id)
            let additional = PlanningIncomeSource(name: "Otro ingreso", amount: 15000, cadence: "Mensual")
            XCTAssertTrue(old.setIncomeSources(old.incomeSources + [additional]))
            XCTAssertEqual(old.monthlyIncome, 48000)
            XCTAssertEqual(old.state.goals.first?.saved, 200)
            XCTAssertNotNil(defaults.data(forKey: "marcelito.planning.v1.backup"))
        }
    }
    func testEditingAndDeletingAnIncomeSourceDoesNotRestoreLegacyTotal() {
        withStores { _, p, defaults in
            var source = PlanningIncomeSource(name: "Nómina", amount: 100, cadence: "Quincenal")
            XCTAssertTrue(p.setIncomeSources([source]))
            source.amount = 200
            XCTAssertTrue(p.setIncomeSources([source])); XCTAssertEqual(p.monthlyIncome, 400)
            XCTAssertTrue(p.setIncomeSources([])); XCTAssertNil(p.monthlyIncome)
            let reloaded = FinancialPlanningStore(defaults: defaults)
            XCTAssertTrue(reloaded.incomeSources.isEmpty); XCTAssertNil(reloaded.monthlyIncome)
            XCTAssertTrue(p.setIncomeSources([PlanningIncomeSource(name: "Sin ingreso temporal", amount: 0, cadence: "Mensual")]))
            XCTAssertEqual(p.monthlyIncome, 0)
        }
    }
    func testInvalidIncomeChangesPreserveSavedSources() {
        withStores { _, p, _ in
            let source = PlanningIncomeSource(name: "Nómina", amount: 100, cadence: "Mensual")
            XCTAssertTrue(p.setIncomeSources([source]))
            XCTAssertFalse(p.setIncomeSources([source, source]))
            XCTAssertFalse(p.setIncomeSources([PlanningIncomeSource(name: "  ", amount: 100, cadence: "Mensual")]))
            XCTAssertFalse(p.setIncomeSources([PlanningIncomeSource(name: "Inválido", amount: -1, cadence: "Mensual")]))
            XCTAssertEqual(p.incomeSources, [source])
        }
    }
    func testSantanderPayrollWithChangingFoliosAndSeparateBBVAIncome() {
        withStores { store, p, _ in
            var payroll: [Movement] = []
            for (month, day, reference) in [(7, 15, "123"), (7, 31, "456"), (8, 14, "789"), (8, 31, "987")] {
                var value = row(month, day, 16500, kind: .income)
                value.account = "Santander"; value.title = "ABONO NOMINA EMPRESA REF \(reference)"
                payroll.append(value)
            }
            let deposits = [row(6, 27, 15000, kind: .income), row(7, 27, 15000, kind: .income), row(8, 27, 15000, kind: .income)].map { value in
                var result = value; result.title = "SPEI RECIBIDONVIO"; return result
            }
            var transfer = row(9, 27, 15000, kind: .bankTransfer); transfer.title = "SPEI RECIBIDONVIO"
            store.movements = payroll + deposits + [transfer]
            let found = p.incomeSuggestions(store)
            XCTAssertEqual(found.count, 2)
            XCTAssertEqual(found.first(where: { $0.movement.account == "Santander" })?.cadence, "Quincenal")
            XCTAssertEqual(found.first(where: { $0.movement.account == "BBVA" })?.cadence, "Mensual")
            let bbva = found.first(where: { $0.movement.account == "BBVA" })!
            XCTAssertTrue(p.setIncomeSources([PlanningIncomeSource(name: bbva.name, amount: bbva.amount, cadence: bbva.cadence, detectedKey: bbva.id)]))
            XCTAssertEqual(p.incomeSuggestions(store).count, 1)
            XCTAssertEqual(p.incomeSuggestions(store).first?.movement.account, "Santander")
            XCTAssertEqual(store.movements.count, 8)
        }
    }
    func testLatestAvailablePeriodUsesActualDataAndKeepsAccountScope() {
        withStores { store, p, _ in
            var bbva = row(9, 14, -100); bbva.account = "BBVA"
            var santander = row(8, 15, -200); santander.account = "Santander"
            let future = row(11, 1, -300)
            let transfer = row(10, 15, 1000, kind: .bankTransfer)
            store.movements = [bbva, santander, future, transfer]
            let now = date(10, 16)
            XCTAssertEqual(p.initialExpenseDate(store, now: now), bbva.date)
            XCTAssertEqual(p.latestMovementDate(store, account: "Santander", now: now), santander.date)
            XCTAssertFalse(p.hasData(store, period: .month(now)))
            XCTAssertEqual(p.latestDataDate(store, now: now), bbva.date)
            store.movements = []
            XCTAssertEqual(p.initialExpenseDate(store, now: now), now)
            XCTAssertNil(p.latestDataDate(store, now: now))
        }
    }
    func testTransfersAndCardPaymentsRemainExcludedWithRealIncome() {
        withStores { s, p, _ in
            s.movements = [row(6, 12, -100), row(6, 13, -500, kind: .cardPayment), row(6, 14, -200, kind: .bankTransfer), row(6, 15, 200, kind: .bankTransfer), row(6, 16, 15000, kind: .income)]
            XCTAssertEqual(p.total(s, period: .month(date(6, 1))), 100)
            XCTAssertEqual(p.observedIncome(s, period: .month(date(6, 1))), 15000)
        }
    }
    func testSharedPartAndExtraordinaryDoNotChangeAuditedLedger() {
        withStores { s, p, defaults in
            let first = row(6, 12, -1000); let second = row(6, 13, -3000)
            s.movements = [first, second]
            var label = PersonalExpenseLabel(); label.sharedPerson = "Amiga"; label.sharedAmount = 400
            p.setLabel(label, for: first)
            var extra = PersonalExpenseLabel(); extra.extraordinary = true; p.setLabel(extra, for: second)
            XCTAssertEqual(p.personalTotal(s, period: .month(date(6, 1))), 600)
            XCTAssertEqual(p.total(s, period: .month(date(6, 1))), 4000)
            XCTAssertEqual(s.movements[0].amount, -1000)
            let reloaded = FinancialPlanningStore(defaults: defaults)
            XCTAssertEqual(reloaded.label(for: first).outstanding, 400)
            label.collectedAmount = 400; reloaded.setLabel(label, for: first)
            XCTAssertEqual(reloaded.label(for: first).outstanding, 0)
            XCTAssertEqual(reloaded.personalTotal(s, period: .month(date(6, 1))), 600)
        }
    }
    func testExtraordinaryGeneralizesTravelAndExplicitOrdinaryChoicePersists() {
        withStores { s, p, defaults in
            var movement = row(6, 1, -100); movement.travelRelated = true
            s.movements = [movement]
            XCTAssertTrue(p.isExtraordinary(movement))
            XCTAssertEqual(p.personalTotal(s, period: .month(date(6, 1))), 0)
            var label = p.label(for: movement); label.extraordinary = false; p.setLabel(label, for: movement)
            XCTAssertEqual(p.personalTotal(s, period: .month(date(6, 1))), 100)
            XCTAssertFalse(FinancialPlanningStore(defaults: defaults).isExtraordinary(movement))
            XCTAssertTrue(s.movements[0].travelRelated)
        }
    }
    func testSharedAmountCannotExceedPurchase() {
        withStores { _, p, _ in
            let movement = row(6, 1, -100)
            var label = PersonalExpenseLabel(); label.sharedAmount = 300; label.collectedAmount = 400
            p.setLabel(label, for: movement)
            XCTAssertEqual(p.label(for: movement).sharedAmount, 100)
            XCTAssertEqual(p.label(for: movement).collectedAmount, 100)
        }
    }
    func testMSIIsFullPurchaseOnceAndMonthlyCashCommitment() {
        withStores { s, p, defaults in
            let monthly = row(6, 8, -1000, kind: .msi)
            let later = row(7, 8, -1000, kind: .msi)
            s.movements = [monthly, later]
            p.state.installments = [InstallmentCommitment(merchant: "Compra", account: "BBVA", purchaseDate: date(5, 20), total: 3000, monthly: 1000, count: 3, firstDueMonth: date(6, 1), linkedMovementIDs: [monthly.id, later.id], linkedIdentities: [p.identity(monthly), p.identity(later)], category: "Compras personales")]
            XCTAssertEqual(p.total(s, period: .month(date(5, 1))), 3000)
            XCTAssertEqual(p.total(s, period: .month(date(6, 1))), 0)
            XCTAssertEqual(p.total(s, period: .month(date(7, 1))), 0)
            XCTAssertEqual(p.commitmentTotal(in: date(6, 1)), 1000)
            XCTAssertEqual(p.commitmentTotal(in: date(9, 1)), 0)
            XCTAssertEqual(p.budgetCategoryTotals(s, period: .month(date(5, 1))).values.reduce(0, +), 0)
            p.save(); let replay = FinancialPlanningStore(defaults: defaults)
            XCTAssertEqual(replay.total(s, period: .month(date(5, 1))), 3000)
            XCTAssertEqual(s.movements[0].kind, .msi)
        }
    }
    func testInstallmentsCarryExactLastCents() {
        let plan = InstallmentCommitment(merchant: "Compra", account: "Amex", purchaseDate: date(5, 1), total: 100, monthly: Decimal(string: "33.34")!, count: 3, firstDueMonth: date(6, 1), linkedMovementIDs: [], linkedIdentities: [], category: "Compras personales")
        XCTAssertEqual(plan.due(in: date(6, 1)), Decimal(string: "33.34"))
        XCTAssertEqual(plan.due(in: date(8, 1)), Decimal(string: "33.32"))
        XCTAssertEqual(plan.remaining(after: date(8, 1)), 0)
    }
    func testFixedAndVariableSameCategoryHaveIndependentLimits() {
        withStores { s, p, _ in
            let fixed = row(6, 1, -500); let variable = row(6, 2, -100)
            s.movements = [fixed, variable]
            var label = PersonalExpenseLabel(); label.fixed = true; p.setLabel(label, for: fixed)
            p.state.incomeAmount = 3000
            var plan = MonthBudgetPlan(); plan.fixedLimits["Tiendita"] = 600; plan.limits["Tiendita"] = 1000; plan.savingsTarget = 200
            p.setPlan(plan, for: date(6, 1))
            let snapshot = p.snapshot(s, month: date(6, 1), now: date(6, 15))
            XCTAssertEqual(snapshot.fixed, 600); XCTAssertEqual(snapshot.variableSpent, 100)
            XCTAssertEqual(snapshot.available, 2200); XCTAssertEqual(snapshot.remaining, 2100)
            XCTAssertEqual(snapshot.remainingDays, 16)
            XCTAssertEqual(snapshot.daily, Decimal(string: "131.25"))
            XCTAssertEqual(p.limits(s, month: date(6, 1))["Tiendita"], 1000)
            XCTAssertEqual(p.fixedLimits(s, month: date(6, 1))["Tiendita"], 600)
        }
    }
    func testMissingHistoryIsNotZeroBudgetOrColchon() {
        withStores { s, p, _ in
            s.movements = [row(6, 1, -100)]
            XCTAssertTrue(p.proposals(s, month: date(7, 1)).isEmpty)
            XCTAssertNil(p.ordinaryMonthlyAverage(s, before: date(7, 1)))
            let ended = p.snapshot(s, month: date(6, 1), now: date(7, 1))
            XCTAssertEqual(ended.remainingDays, 0); XCTAssertNil(ended.daily)
            XCTAssertFalse(p.hasData(s, period: .month(date(8, 1))))
        }
    }
    func testEducationAliasDoesNotEraseITAMManualCategory() {
        withStores { s, p, _ in
            let movement = row(6, 1, -10000, category: "ITAM"); s.movements = [movement]
            XCTAssertEqual(p.category(movement), "Educación")
            XCTAssertEqual(s.movements[0].category, "ITAM")
        }
    }
    func testRecurrenceRequiresCadenceAmountAndThreeObservations() {
        withStores { _, p, _ in
            let recurring = [row(1, 10, -100), row(2, 10, -100), row(3, 10, -100)]
            XCTAssertEqual(p.recurring(recurring).count, 1)
            XCTAssertEqual(p.recurring(recurring).first?.annualCost, 1200)
            XCTAssertTrue(p.recurring(Array(recurring.prefix(2))).isEmpty)
            XCTAssertTrue(p.recurring([row(1, 10, -100), row(2, 10, -100), row(3, 10, -1000)]).isEmpty)
        }
    }
    func testMetadataDoesNotMistakeCATOrCutoffForDueDate() {
        let value = CardDocumentMetadata.parse("Fecha de corte: 27/09/2026\nCAT 85%\nFecha límite de pago: 17/10/2026\nTasa de interés ordinaria anual: 48.5%")
        XCTAssertEqual(Calendar.current.component(.day, from: value.dueDate!), 17)
        XCTAssertEqual(value.annualRate, Decimal(string: "0.485"))
        XCTAssertNil(CardDocumentMetadata.parse("CAT 85%\nFecha de corte 27/09/2026").annualRate)
        XCTAssertNil(CardDocumentMetadata.parse("Fecha límite de pago 17/10").dueDate)
    }
    func testSpanishDueDateAndDebtIncludesPrintedPendingMSI() {
        let metadata = CardDocumentMetadata.parse("Fecha límite de pago 17 de octubre de 2026")
        XCTAssertEqual(Calendar.current.component(.month, from: metadata.dueDate!), 10)
        withStores { s, _, _ in
            let statement = StatementRecord(id: UUID(), source: "Amex", period: "01/06/2026 - 30/06/2026", fileName: "fixture.pdf", importedAt: .now, transactionCount: 0, requiresReview: false, kind: .card, summary: .init(statementBalance: 200, msiPending: 800))
            XCTAssertEqual(s.statementMetricForTesting(statement).debtBalance, 1000)
            var authoritative = statement; authoritative.summary?.creditLimit = 10000; authoritative.summary?.creditAvailable = 9000
            XCTAssertEqual(s.statementMetricForTesting(authoritative).debtBalance, 1000)
        }
    }
    func testSavingsGoalAndUncoveredCloseCannotAssignUnprovenSurplus() {
        withStores { store, p, _ in
            let goal = SavingsGoal(name: "Fondo", target: 10000, saved: 1000, monthlyContribution: 2000)
            p.state.goals = [goal]
            XCTAssertEqual(goal.estimatedMonths, 5)
            XCTAssertFalse(p.closeMonth(date(6,1),store:store,goalID:goal.id))
            XCTAssertEqual(p.state.goals[0].saved,1000)
            XCTAssertFalse(p.closeMonth(date(12,1),store:store,goalID:goal.id))
        }
    }
    func testMedianUsesThreeCoveredMonthsAndKeepsFixedSeparate() {
        withStores { s, p, _ in
            for (month, amount) in [(1, Decimal(100)), (2, Decimal(300)), (3, Decimal(200))] {
                let c = Calendar.current
                let days = c.range(of: .day, in: .month, for: date(month, 1))!.count
                let period = String(format: "01/%02d/2026 - %02d/%02d/2026", month, days, month)
                let statement = StatementRecord(id: UUID(), source: "BBVA", accountKey: "bbva:1234", period: period, fileName: "fixture.pdf", importedAt: .now, transactionCount: 1, requiresReview: false, kind: .bank,
                    summary: .init(depositTotal: 0, withdrawalTotal: amount, depositCount: 0, withdrawalCount: 1),
                    reconciliation: .init(status: .valid, tolerance: 0, extractedDepositTotal: 0, extractedWithdrawalTotal: amount, extractedMovementCount: 1, expectedMovementCount: 1),
                    sourceDetection: .init(source: "BBVA", confidence: 1, status: .verified, evidence: ["fixture"], ignoredBodyMentions: []), readerVersion: FinanceStore.readerVersion)
                s.statements.append(statement)
                var purchase = row(month, 10, -amount)
                purchase.statementId = statement.id; purchase.extractionEvidence = .init(method: "fixture", page: 1, confidence: 1)
                s.movements.append(purchase)
            }
            let proposed = p.proposals(s, month: date(4, 1))
            XCTAssertEqual(proposed["Tiendita"], 200)
            var plan = MonthBudgetPlan(); plan.limits["Tiendita"] = 500; p.setPlan(plan, for: date(4, 1))
            XCTAssertEqual(p.limits(s, month: date(4, 1))["Tiendita"], 500)
            var fixed = PersonalExpenseLabel(); fixed.fixed = true; p.setLabel(fixed, for: s.movements[2])
            XCTAssertEqual(p.proposals(s, month: date(4, 1))["Tiendita"], 100)
            XCTAssertEqual(p.fixedLimits(s, month: date(4, 1))["Tiendita"], 200)
        }
    }
    func testUnlinkedMSIWithUnknownMonthlyLoadBlocksAvailable() {
        withStores { s, p, _ in
            p.state.incomeAmount = 10000
            let statement = StatementRecord(id: UUID(), source: "Amex", accountKey: "amex:1234", period: "01/06/2026 - 30/06/2026", fileName: "fixture.pdf", importedAt: .now, transactionCount: 0, requiresReview: false, kind: .card,
                summary: .init(creditLimit: 10000, creditAvailable: 9000, msiPending: 800),
                reconciliation: .init(status: .valid, tolerance: 0),
                sourceDetection: .init(source: "Amex", confidence: 1, status: .verified, evidence: ["fixture"], ignoredBodyMentions: []), readerVersion: FinanceStore.readerVersion)
            s.statements = [statement]
            let snapshot = p.snapshot(s, month: date(6, 1), now: date(6, 15))
            XCTAssertTrue(snapshot.hasUnknownCommitments)
            XCTAssertNil(snapshot.remaining)
        }
    }
    func testCorruptedPlanningDataIsNotOverwritten() {
        withStores { _, _, defaults in
            let data = Data("invalid".utf8); defaults.set(data, forKey: "marcelito.planning.v1")
            let p = FinancialPlanningStore(defaults: defaults)
            XCTAssertNotNil(p.loadError); XCTAssertFalse(p.save())
            XCTAssertEqual(defaults.data(forKey: "marcelito.planning.v1"), data)
        }
    }
}
