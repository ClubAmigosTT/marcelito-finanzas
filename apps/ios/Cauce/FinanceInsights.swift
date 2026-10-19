import Foundation

/// A charge worth a second look: a possible duplicate, a price increase on a
/// recurring charge, or a bank fee not seen before.
struct UnusualCharge: Identifiable {
    enum Kind: String { case duplicate, priceIncrease, newFee }
    let id: String
    let kind: Kind
    let movement: Movement
    let message: String
}

struct MonthEndProjection: Equatable {
    let month: FinancePeriod
    let spent: Decimal
    let observedDays: Int
    let daysInMonth: Int
    let projected: Decimal
    let budget: Decimal?
}

struct MonthlySummary: Equatable {
    struct CategoryChange: Equatable { let category: String; let amount: Decimal; let change: Decimal }
    let month: FinancePeriod
    let income: Decimal
    let spend: Decimal
    var saving: Decimal { income - spend }
    let changes: [CategoryChange]
}

extension FinanceStore {
    static let dismissedUnusualKey = "marcelito.insights.dismissed.v1"

    var dismissedUnusualCharges: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.dismissedUnusualKey) ?? [])
    }

    func dismissUnusualCharge(_ charge: UnusualCharge) {
        var dismissed = dismissedUnusualCharges
        dismissed.insert(charge.id)
        UserDefaults.standard.set(Array(dismissed), forKey: Self.dismissedUnusualKey)
    }

    /// Charges of the last `days` days that deserve a look. Each rule is
    /// conservative: a duplicate needs the same account, day, amount and
    /// concept; a price increase needs at least two earlier charges of the
    /// same concept and a rise of 5% and $10 or more; a new fee is a
    /// commission whose concept never appeared in the previous six months.
    func unusualCharges(now: Date = .now, days: Int = 60) -> [UnusualCharge] {
        let calendar = Calendar.current
        guard let from = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)),
              let history = calendar.date(byAdding: .month, value: -6, to: from) else { return [] }
        let expenses = netExpenseMovements.filter { $0.expenseContribution > 0 && $0.date <= now }
        let recent = expenses.filter { $0.date >= from }
        let dismissed = dismissedUnusualCharges
        func concept(_ movement: Movement) -> String {
            (movement.normalizedMerchant ?? movement.title)
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
                .replacingOccurrences(of: #"[0-9]+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"[^a-z]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        var result: [UnusualCharge] = []

        let sameDay = Dictionary(grouping: recent) { movement in
            "\(movement.account)|\(LoanMath.dayKey(movement.date))|\(movement.expenseContribution)|\(concept(movement))"
        }
        for rows in sameDay.values where rows.count > 1 {
            let ordered = rows.sorted { $0.id.uuidString < $1.id.uuidString }
            for duplicate in ordered.dropFirst() {
                result.append(UnusualCharge(id: "dup|" + duplicate.id.uuidString, kind: .duplicate, movement: duplicate,
                    message: "Posible cobro duplicado: \(rows.count) cargos iguales de \(planningMoney(duplicate.expenseContribution)) el mismo día."))
            }
        }

        let byConcept = Dictionary(grouping: expenses.filter { $0.date >= history }, by: concept)
        for (key, rows) in byConcept where !key.isEmpty {
            let ordered = rows.sorted { $0.date < $1.date }
            guard let latest = ordered.last, latest.date >= from else { continue }
            let earlier = ordered.dropLast().filter { calendar.dateComponents([.day], from: $0.date, to: latest.date).day ?? 0 >= 20 }
            if earlier.count >= 2, RecurringPattern.isKnownSubscription(latest.title) || earlier.count >= 3 {
                let values = earlier.map(\.expenseContribution).sorted()
                let median = values[values.count / 2]
                if median > 0, latest.expenseContribution >= median * Decimal(string: "1.05")!, latest.expenseContribution - median >= 10 {
                    result.append(UnusualCharge(id: "price|" + latest.id.uuidString, kind: .priceIncrease, movement: latest,
                        message: "Subió de \(planningMoney(median)) a \(planningMoney(latest.expenseContribution))."))
                }
            }
            let isFee = latest.kind == .fee || latest.category == "Comisiones y finanzas"
            if isFee, ordered.filter({ $0.date < from }).isEmpty, ordered.count == 1 {
                result.append(UnusualCharge(id: "fee|" + latest.id.uuidString, kind: .newFee, movement: latest,
                    message: "Comisión nueva de \(planningMoney(latest.expenseContribution)) que no aparecía antes."))
            }
        }
        return result.filter { !dismissed.contains($0.id) }.sorted { $0.movement.date > $1.movement.date }
    }
}

extension FinancialPlanningStore {
    /// Spend so far in the month divided by the days that have data, times
    /// the days in the month. Days after the newest statement or screenshot
    /// are not treated as zero spend.
    func monthEndProjection(_ store: FinanceStore, month: Date = .now, now: Date = .now) -> MonthEndProjection? {
        let calendar = Calendar.current
        let period = FinancePeriod.month(month)
        guard let latest = latestDataDate(store, now: now), latest >= period.start else { return nil }
        let horizon = min(calendar.startOfDay(for: latest), calendar.date(byAdding: .day, value: -1, to: period.end) ?? latest)
        let observedDays = (calendar.dateComponents([.day], from: period.start, to: horizon).day ?? 0) + 1
        let daysInMonth = calendar.range(of: .day, in: .month, for: period.start)?.count ?? 30
        guard observedDays >= 5 else { return nil }
        let observedEnd = calendar.date(byAdding: .day, value: 1, to: horizon) ?? period.end
        let spent = expenseRows(store, period: FinancePeriod(start: period.start, end: observedEnd)).reduce(Decimal(0)) { $0 + $1.expenseContribution }
        let projected = observedDays >= daysInMonth ? spent : spent / Decimal(observedDays) * Decimal(daysInMonth)
        let budget = consumptionBudget(store, month: month)
        return MonthEndProjection(month: period, spent: spent, observedDays: observedDays, daysInMonth: daysInMonth,
            projected: projected, budget: budget > 0 ? budget : nil)
    }

    /// Income, spend, saving and the three categories that moved the most
    /// against the month before.
    func monthlySummary(_ store: FinanceStore, month: Date) -> MonthlySummary? {
        let calendar = Calendar.current
        let period = FinancePeriod.month(month)
        guard hasData(store, period: period), let previousStart = calendar.date(byAdding: .month, value: -1, to: period.start) else { return nil }
        let current = categoryTotals(store, period: period)
        let previous = categoryTotals(store, period: FinancePeriod.month(previousStart))
        let changes = Set(current.keys).union(previous.keys).map { category in
            MonthlySummary.CategoryChange(category: category, amount: current[category] ?? 0, change: (current[category] ?? 0) - (previous[category] ?? 0))
        }
        .filter { $0.change != 0 }
        .sorted { abs(NSDecimalNumber(decimal: $0.change).doubleValue) > abs(NSDecimalNumber(decimal: $1.change).doubleValue) }
        return MonthlySummary(month: period, income: observedIncome(store, period: period), spend: total(store, period: period), changes: Array(changes.prefix(3)))
    }
}

extension Decimal {
    /// Whole pesos, rounded up, for suggested targets.
    var roundedPesos: Decimal {
        var value = self, rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .up)
        return rounded
    }
}
