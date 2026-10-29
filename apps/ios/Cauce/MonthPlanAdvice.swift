import Foundation

/// What the history says about planning one month: the typical day-to-day
/// spend per category (without trips or one-offs), what trips usually cost,
/// what was unusual last month, and how each category is usually spent
/// through the month.
struct MonthPlanAdvice {
    struct Unusual: Identifiable, Hashable {
        let id: String
        let title: String
        let amount: Decimal
        let category: String
        let movementIDs: [UUID]
        let isTrip: Bool
    }

    let month: Date
    let sampleMonths: [Date]
    /// True when fewer than two complete months were available.
    let partialHistory: Bool
    /// Median ordinary (non-fixed, non-trip, non-one-off) spend per category.
    let typical: [String: Decimal]
    /// The previous month's ordinary spend per category.
    let lastActual: [String: Decimal]
    /// Average travel spend in the months that had any.
    let tripAverage: Decimal?
    let tripMonths: Int
    let unusualLastMonth: [Unusual]
    /// Per category, the average share of the month's spend done by each day
    /// (index 0 = day 1). Missing categories are spent evenly.
    let pace: [String: [Double]]

    /// Spending people usually trim first when they want a tighter month.
    static let flexibleCategories: Set<String> = [
        "Restaurantes y bares", "Entretenimiento", "Compras personales", "Tiendita",
        "Viajes", "Otros / Por revisar", "Cuidado personal"
    ]

    /// The next plan moves gradually: 70% of last month's own limit and 30%
    /// of what was really spent, so one unusual month does not swing it.
    /// Categories without a previous limit start from the typical month.
    func suggested(previousLimits: [String: Decimal]) -> [String: Decimal] {
        let categories = Set(typical.keys).union(previousLimits.keys.filter { (previousLimits[$0] ?? 0) > 0 })
        var result: [String: Decimal] = [:]
        for category in categories where category != "Viajes" {
            let value: Decimal
            if let previous = previousLimits[category], previous > 0 {
                value = previous * Decimal(string: "0.7")! + (lastActual[category] ?? 0) * Decimal(string: "0.3")!
            } else {
                value = typical[category] ?? 0
            }
            let rounded = Self.round(value)
            if rounded > 0 { result[category] = rounded }
        }
        return result
    }

    /// Share of the month's spend in `category` usually done by `day`.
    func expectedFraction(category: String, day: Int, daysInMonth: Int) -> Double {
        let linear = min(1, Double(day) / Double(max(1, daysInMonth)))
        guard let curve = pace[category], !curve.isEmpty else { return linear }
        return curve[min(curve.count, max(1, day)) - 1]
    }

    /// Rounds to the nearest $50 so suggestions read like a plan, not a sum.
    static func round(_ value: Decimal) -> Decimal {
        var units = value / 50
        var result = Decimal()
        NSDecimalRound(&result, &units, 0, .plain)
        return max(0, result * 50)
    }

    static func median(_ values: [Decimal]) -> Decimal {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Builds the advice from per-month rows. `rowsByMonth` holds the
    /// budget's variable rows of each sample month (newest first) and of the
    /// previous month; trips and one-offs are recognized here.
    static func build(
        month: Date,
        sampleMonths: [Date],
        partialHistory: Bool,
        previousMonth: Date,
        rows: (Date) -> [Movement],
        history: [Movement],
        category: (Movement) -> String,
        isOneOff: (Movement) -> Bool
    ) -> MonthPlanAdvice {
        let calendar = Calendar.current
        struct Split { var ordinary: [Movement] = []; var travel: Decimal = 0; var trips: [MonthSpendingStory.Trip] = []; var travelRows: [Movement] = []; var oneOffs: [Movement] = [] }
        func split(_ monthRows: [Movement]) -> Split {
            let story = MonthSpendingStory.build(rows: monthRows, history: history, category: category)
            let tripIDs = Set(story.trips.flatMap { ($0.travel + $0.local).map(\.id) })
            var result = Split(trips: story.trips)
            for row in monthRows {
                if tripIDs.contains(row.id) {
                    result.travel += row.expenseContribution
                } else if category(row) == "Viajes" || MonthSpendingStory.isTravelProvider(row) {
                    result.travel += row.expenseContribution
                    result.travelRows.append(row)
                } else if isOneOff(row) || (row.expenseContribution >= 1_000
                            && MonthSpendingStory.isTransfer(row)
                            && MonthSpendingStory.bucket(for: row, category: category) == "Transferencias a personas") {
                    result.oneOffs.append(row)
                } else {
                    result.ordinary.append(row)
                }
            }
            return result
        }
        func totals(_ rows: [Movement]) -> [String: Decimal] {
            rows.reduce(into: [String: Decimal]()) { $0[category($1), default: 0] += $1.expenseContribution }
        }

        let splits = sampleMonths.map { (month: $0, split: split(rows($0))) }
        let monthlyTotals = splits.map { totals($0.split.ordinary) }
        var typical: [String: Decimal] = [:]
        for name in Set(monthlyTotals.flatMap(\.keys)) {
            let value = round(median(monthlyTotals.map { max(0, $0[name] ?? 0) }))
            if value > 0 { typical[name] = value }
        }
        let travel = splits.map(\.split.travel).filter { $0 > 0 }
        let tripAverage = travel.isEmpty ? nil : round(travel.reduce(0, +) / Decimal(travel.count))

        // Pace: average cumulative share of each category by day of month.
        var pace: [String: [Double]] = [:]
        for name in typical.keys {
            var curves: [[Double]] = []
            for item in splits {
                let monthRows = item.split.ordinary.filter { category($0) == name }
                let total = monthRows.reduce(Decimal(0)) { $0 + $1.expenseContribution }
                guard total > 0 else { continue }
                var byDay = Array(repeating: 0.0, count: 31)
                for row in monthRows {
                    let day = calendar.component(.day, from: row.date)
                    byDay[day - 1] += NSDecimalNumber(decimal: row.expenseContribution / total).doubleValue
                }
                var running = 0.0
                curves.append(byDay.map { running += $0; return min(1, max(0, running)) })
            }
            guard curves.count >= 2 else { continue }
            pace[name] = (0..<31).map { day in curves.map { $0[day] }.reduce(0, +) / Double(curves.count) }
        }

        // Last month: what ordinarily happened and what stood out.
        let last = split(rows(previousMonth))
        var unusual: [Unusual] = last.trips.map { trip in
            Unusual(id: "trip-\(trip.id)", title: "Viaje a \(trip.city)", amount: trip.total, category: "Viajes",
                    movementIDs: (trip.travel + trip.local).map(\.id), isTrip: true)
        }
        let singles = last.travelRows + last.oneOffs + last.ordinary.filter { $0.expenseContribution >= 1_500 }
        unusual += singles.map { row in
            Unusual(id: row.id.uuidString, title: MonthSpendingStory.line(row).title, amount: row.expenseContribution,
                    category: category(row), movementIDs: [row.id], isTrip: category(row) == "Viajes")
        }
        return MonthPlanAdvice(
            month: month,
            sampleMonths: sampleMonths,
            partialHistory: partialHistory,
            typical: typical,
            lastActual: totals(last.ordinary),
            tripAverage: tripAverage,
            tripMonths: travel.count,
            unusualLastMonth: Array(unusual.sorted { $0.amount > $1.amount }.prefix(8)),
            pace: pace
        )
    }
}

extension FinancialPlanningStore {
    /// History-based advice for planning `month`, cached per ledger state.
    func monthPlanAdvice(_ store: FinanceStore, month: Date) -> MonthPlanAdvice {
        _ = coveredDays(store)
        let key = "\(store.analyticsGeneration)|\(analysisGeneration)|\(monthKey(month))"
        if let cached = adviceCache[key] { return cached }
        let calendar = Calendar.current
        let start = FinancePeriod.month(month).start
        let covered = coveredDays(store)
        // Only the last six months: older ones can predate an account (a card
        // opened later) and would make the typical month look cheaper.
        let candidates = (1...6).compactMap { calendar.date(byAdding: .month, value: -$0, to: start) }
        var samples = Array(candidates.filter { candidate in
            let period = FinancePeriod.month(candidate)
            var day = period.start
            while day < period.end {
                guard covered.contains(day) else { return false }
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
            return true
        }.prefix(6))
        let partial = samples.count < 2
        if partial {
            samples = Array(candidates.filter { !budgetRows(store, period: .month($0)).isEmpty }.prefix(3))
        }
        let previous = calendar.date(byAdding: .month, value: -1, to: start)!
        let oldest = (samples + [previous]).min() ?? previous
        let history = store.netExpenseMovements.filter { $0.date >= oldest && $0.date < start }
        let advice = MonthPlanAdvice.build(
            month: start,
            sampleMonths: samples,
            partialHistory: partial,
            previousMonth: previous,
            rows: { sample in
                self.budgetRows(store, period: .month(sample)).filter {
                    !self.isFixed($0) && $0.expenseContribution != 0 && !$0.classificationTags.contains("loan-interest")
                }
            },
            history: history,
            category: { self.budgetCategory($0) },
            // Only the owner's own "fue de una vez" counts: the automatic
            // taxonomy tags whole categories (cinema, shows) as extraordinario.
            isOneOff: { self.label(for: $0).extraordinary == true }
        )
        if adviceCache.count > 12 { adviceCache.removeAll() }
        adviceCache[key] = advice
        return advice
    }
}
