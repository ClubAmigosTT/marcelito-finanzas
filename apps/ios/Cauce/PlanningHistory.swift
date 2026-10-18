import Foundation

struct CardPaymentLink: Codable {
    let statementID: UUID
    let movementID: UUID
    let identity: String
    var cycleKey: String? = nil
}

struct IncomeRevision: Codable, Equatable {
    let effectiveMonth: Date
    let sources: [PlanningIncomeSource]
}
struct SavingsEntry: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let amount: Decimal
    let note: String
    var closingMonth: String? = nil
}
struct BudgetClosing: Codable {
    let recordedAt: Date
    let recorded: BudgetSnapshot
    let surplus: Decimal
    let destination: SurplusDestination
    let goalID: UUID?
    var categorySpent: [String: Decimal]? = nil
    var fixedSpent: [String: Decimal]? = nil
    func snapshot(in period: FinancePeriod) -> BudgetSnapshot { recorded }
}

extension FinancialPlanningStore {
    /// Import old per-month inputs once, preserving the original preference keys
    /// and any plan already saved in the main budget. Never spread a total into
    /// invented category amounts.
    func migrateLegacyMonthlyPlans(defaults: UserDefaults) {
        guard loadError == nil else { return }
        var changed = false
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("marcelito.monthlyPlan.") && ($0.hasSuffix(".budget") || $0.hasSuffix(".target")) }
        for key in keys {
            let parts = key.split(separator: ".")
            guard parts.count == 5, let year = Int(parts[2]), let month = Int(parts[3]), (1...12).contains(month),
                  let date = Calendar.current.date(from: DateComponents(year: year, month: month)) else { continue }
            let monthKey = monthKey(date)
            guard state.budgets[monthKey]?.legacyImported != true else { continue }
            let hadPlan = state.budgets[monthKey] != nil
            var plan = state.budgets[monthKey] ?? MonthBudgetPlan()
            func amount(_ suffix: String) -> Decimal? {
                guard let text = defaults.string(forKey: "marcelito.monthlyPlan.\(year).\(month)." + suffix),
                      let value = Decimal(string: text.replacingOccurrences(of: ",", with: ".")), !value.isNaN, value >= 0 else { return nil }
                return value
            }
            let oldLimit = amount("budget"), oldSavings = amount("target")
            if hadPlan {
                // Conflicting legacy inputs stay reviewable. They never add a
                // new cap or overwrite an existing savings target silently.
                plan.legacySpendingLimit = oldLimit; plan.legacySavingsTarget = oldSavings
            } else { plan.spendingLimit = oldLimit; plan.savingsTarget = oldSavings ?? 0 }
            plan.legacyImported = true; state.budgets[monthKey] = plan; changed = true
        }
        if changed { _ = save() }
    }
    func cashSurplus(_ store: FinanceStore, month: Date) -> Decimal {
        let range = FinancePeriod.month(month)
        let cashSpent = store.netExpenseMovements.filter { range.contains($0.date) && !isInstallmentRow($0, store: store) }.reduce(Decimal(0)) { $0 + $1.expenseContribution }
        return observedIncome(store, period: range) - cashSpent - commitments(store, month: month) - store.loanPrincipalPaid(in: range)
    }
    @discardableResult func closeMonth(_ month: Date, store: FinanceStore, goalID: UUID? = nil, now: Date = .now) -> Bool {
        let range = FinancePeriod.month(month)
        let snapshot = snapshot(store, month: month, now: now)
        let covered = coveredDays(store)
        var day = range.start
        while day < range.end {
            guard covered.contains(day) else { return false }
            day = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        }
        guard range.end <= now, !store.operationalMetricsBlocked,
              store.monthlyFinancialAudit(for: month).canUseForBudget,
              !plan(for: month).closed, !snapshot.hasUnknownLoans, !snapshot.hasUnknownCommitments else { return false }
        let surplus = cashSurplus(store, month: month)
        let previous = state
        var plan = plan(for: month)
        let assigned = max(0, surplus)
        if assigned == 0 {
            // A deficit month can still be closed without inventing savings.
        } else if plan.surplusDestination == .nextMonth {
            var next = self.plan(for: range.end)
            guard !next.closed else { return false }
            next.carryIn += assigned; state.budgets[monthKey(range.end)] = next
        } else {
            guard let goalID, let index = state.goals.firstIndex(where: { $0.id == goalID && $0.archived != true }) else { return false }
            state.goals[index].saved += assigned
            var entries = state.goals[index].entries ?? []
            entries.append(SavingsEntry(date: now, amount: assigned, note: "Asignación del cierre de \(range.label)", closingMonth: monthKey(month)))
            state.goals[index].entries = entries
        }
        plan.limits = limits(store, month: month); plan.fixedLimits = fixedLimits(store, month: month)
        plan.closed = true
        plan.closing = BudgetClosing(recordedAt: now, recorded: snapshot, surplus: surplus, destination: plan.surplusDestination, goalID: assigned > 0 && plan.surplusDestination == .savings ? goalID : nil, categorySpent: budgetCategoryTotals(store, period: range), fixedSpent: budgetCategoryTotals(store, period: range, fixed: true))
        state.budgets[monthKey(month)] = plan
        if save() { return true }; state = previous; return false
    }
    /// Old closes lack a recorded snapshot. They stay identified as legacy;
    /// never silently credit their surplus to a goal for a second time.
    @discardableResult func reopenMonth(_ month: Date) -> Bool {
        let previous = state
        var plan = plan(for: month)
        guard plan.closed else { return false }
        guard let closing = plan.closing else { return false }
        let assigned = max(0, closing.surplus)
        if assigned == 0 {
            // There was no assignment to reverse.
        } else if closing.destination == .nextMonth {
            let nextKey = monthKey(FinancePeriod.month(month).end)
            var next = state.budgets[nextKey] ?? MonthBudgetPlan()
            guard !next.closed, next.carryIn >= assigned else { return false }
            next.carryIn -= assigned; state.budgets[nextKey] = next
        } else if let index = state.goals.firstIndex(where: { $0.id == closing.goalID }) {
            guard state.goals[index].saved >= assigned else { return false }
            state.goals[index].saved -= assigned
            state.goals[index].entries?.removeAll { $0.closingMonth == monthKey(month) }
        } else { return false }
        plan.closed = false; plan.closing = nil; state.budgets[monthKey(month)] = plan
        if save() { return true }; state = previous; return false
    }
    var activeGoals: [SavingsGoal] { state.goals.filter { $0.archived != true } }
    @discardableResult func saveGoal(_ goal: SavingsGoal) -> Bool {
        guard !goal.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              [goal.target, goal.saved, goal.monthlyContribution].allSatisfy({ !$0.isNaN && $0 >= 0 }), goal.target > 0 else { return false }
        let previous = state
        if let index = state.goals.firstIndex(where: { $0.id == goal.id }) {
            // Corrections to the balance remain visible in the goal's history.
            var updated = goal; updated.entries = state.goals[index].entries
            let delta = goal.saved - state.goals[index].saved
            if delta != 0 { var entries = updated.entries ?? []; entries.append(SavingsEntry(date: .now, amount: delta, note: "Corrección de saldo")); updated.entries = entries }
            state.goals[index] = updated
        } else { state.goals.append(goal) }
        if save() { return true }; state = previous; return false
    }
    @discardableResult func contribute(to goalID: UUID, amount: Decimal, date: Date, note: String) -> Bool {
        guard !amount.isNaN, amount != 0, date <= .now, let index = state.goals.firstIndex(where: { $0.id == goalID }), state.goals[index].saved + amount >= 0 else { return false }
        let previous = state
        state.goals[index].saved += amount
        var entries = state.goals[index].entries ?? []
        entries.append(SavingsEntry(date: date, amount: amount, note: note.isEmpty ? (amount > 0 ? "Aportación registrada" : "Retiro registrado") : note))
        state.goals[index].entries = entries
        if save() { return true }; state = previous; return false
    }
}
