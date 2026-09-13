import Charts
import Foundation
import SwiftUI

enum SpendingCalendarMode: String, CaseIterable, Identifiable {
    case day = "Día"
    case week = "Semana"
    case month = "Mes"

    var id: String { rawValue }
}

struct SpendingPeriodRange: Identifiable {
    let start: Date
    let endExclusive: Date
    let title: String
    let subtitle: String
    var id: Date { start }
}

struct SpendingCategoryShare: Identifiable {
    let name: String
    let total: Decimal
    let share: Double
    let movementCount: Int
    var id: String { name }
    var isNetRefund: Bool { total < 0 }
}

struct SpendingExplanation: Identifiable {
    let category: String
    let actual: Decimal
    let expected: Decimal
    var id: String { category }
    var delta: Decimal { actual - expected }
}

struct SpendingPeriodAnalysis {
    let mode: SpendingCalendarMode
    let start: Date
    let endExclusive: Date
    let observedEndExclusive: Date
    let movements: [Movement]
    let evolution: [SpendingDayPoint]
    let expectedTotal: Decimal?
    let comparisonLabel: String
    let secondaryExpectedTotal: Decimal?
    let secondaryComparisonLabel: String?
    let expectedCategoryTotals: [String: Decimal]
    let hasCompleteCoverage: Bool

    var total: Decimal { movements.reduce(0) { $0 + $1.expenseContribution } }
    var movementCount: Int { movements.count }
    var observedDayCount: Int { evolution.count }
    var dailyAverage: Decimal { observedDayCount > 0 ? total / Decimal(observedDayCount) : 0 }
    var purchaseMovements: [Movement] { movements.filter { $0.expenseContribution > 0 } }
    var ticketAverage: Decimal {
        guard !purchaseMovements.isEmpty else { return 0 }
        return purchaseMovements.reduce(0) { $0 + $1.expenseContribution } / Decimal(purchaseMovements.count)
    }
    var delta: Decimal? { expectedTotal.map { total - $0 } }
    var deltaPercent: Double? {
        guard hasCompleteCoverage, let expectedTotal, expectedTotal > 0 else { return nil }
        return NSDecimalNumber(decimal: (total - expectedTotal) / expectedTotal).doubleValue * 100
    }
    var categories: [SpendingCategoryShare] {
        Dictionary(grouping: movements, by: \.category)
            .map { name, rows in
                let value = rows.reduce(Decimal(0)) { $0 + $1.expenseContribution }
                let share = total > 0 ? NSDecimalNumber(decimal: value / total).doubleValue : 0
                return SpendingCategoryShare(name: name, total: value, share: share, movementCount: rows.count)
            }
            .filter { $0.total != 0 }
            .sorted {
                if $0.isNetRefund != $1.isNetRefund { return !$0.isNetRefund }
                return abs($0.total) > abs($1.total)
            }
    }
    var explanations: [SpendingExplanation] {
        let actual = Dictionary(grouping: movements, by: \.category)
            .mapValues { $0.reduce(Decimal(0)) { $0 + $1.expenseContribution } }
        return Set(actual.keys).union(expectedCategoryTotals.keys)
            .map { SpendingExplanation(category: $0, actual: actual[$0, default: 0], expected: expectedCategoryTotals[$0, default: 0]) }
            .filter { $0.delta != 0 }
            .sorted { abs($0.delta) > abs($1.delta) }
    }
}

enum SpendingCalendarExpenseType: String, CaseIterable, Identifiable {
    case ordinary = "Ordinario"
    case extraordinary = "Extraordinario"
    case travel = "Viaje"
    case project = "Proyecto"

    var id: String { rawValue }
}

enum SpendingCalendarReviewStatus: String, CaseIterable, Identifiable {
    case identified = "Clasificados"
    case review = "Por revisar"

    var id: String { rawValue }
}

struct SpendingCalendarFilters: Equatable {
    var category: String?
    var account: String?
    var expenseType: SpendingCalendarExpenseType?
    var reviewStatus: SpendingCalendarReviewStatus?
    var merchantQuery = ""

    var activeCount: Int {
        [category != nil, account != nil, expenseType != nil, reviewStatus != nil, !merchantQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty]
            .filter { $0 }
            .count
    }

    var isEmpty: Bool { activeCount == 0 }
}

struct SpendingDayPoint: Identifiable {
    let date: Date
    let actual: Decimal
    let historicalAverage: Decimal
    let movementCount: Int

    var id: Date { date }
    var delta: Decimal { actual - historicalAverage }
    var actualDouble: Double { NSDecimalNumber(decimal: actual).doubleValue }
    var averageDouble: Double { NSDecimalNumber(decimal: historicalAverage).doubleValue }
}

struct SpendingWeekSummary {
    let start: Date
    let endExclusive: Date
    let points: [SpendingDayPoint]
    let comparableDayCount: Int
    var hasCompleteCoverage: Bool = true

    var actualTotal: Decimal { points.prefix(comparableDayCount).reduce(0) { $0 + $1.actual } }
    var expectedTotal: Decimal { points.prefix(comparableDayCount).reduce(0) { $0 + $1.historicalAverage } }
    var dailyAverage: Decimal { comparableDayCount > 0 ? actualTotal / Decimal(comparableDayCount) : 0 }
    var delta: Decimal { actualTotal - expectedTotal }
    var deltaPercent: Double? {
        guard hasCompleteCoverage, expectedTotal > 0 else { return nil }
        return NSDecimalNumber(decimal: delta / expectedTotal).doubleValue * 100
    }
    var highest: SpendingDayPoint? { points.prefix(comparableDayCount).max { $0.actual < $1.actual } }
    var lowest: SpendingDayPoint? { points.prefix(comparableDayCount).min { $0.actual < $1.actual } }
}

struct SpendingHistoryDay: Identifiable {
    let date: Date
    let total: Decimal
    let expected: Decimal
    let movements: [Movement]
    var isCovered: Bool = true

    var id: Date { date }
    var difference: Decimal { total - expected }
    var ratio: Double {
        guard expected > 0 else { return total > 0 ? 2 : 0 }
        return NSDecimalNumber(decimal: total / expected).doubleValue
    }
}

struct SpendingWeekTrend: Identifiable {
    let start: Date
    let total: Decimal
    var id: Date { start }
    var value: Double { NSDecimalNumber(decimal: total).doubleValue }
}

private struct SpendingBreakdown: Identifiable {
    let name: String
    let total: Decimal
    var id: String { name }
}

struct SpendingCalendarAnalytics {
    let movements: [Movement]
    let selectedDate: Date
    let now: Date
    let calendar: Calendar
    let coverageStartOverride: Date?
    let coverageEndOverride: Date?
    let coveredDays: Set<Date>?

    init(
        movements: [Movement],
        selectedDate: Date,
        now: Date = .now,
        calendar suppliedCalendar: Calendar? = nil,
        coverageStart: Date? = nil,
        coverageEnd: Date? = nil,
        coveredDays: Set<Date>? = nil
    ) {
        var calendar = suppliedCalendar ?? Calendar(identifier: .iso8601)
        if suppliedCalendar == nil {
            calendar.locale = Locale(identifier: "es_MX")
            calendar.timeZone = .current
        }
        self.movements = movements
        self.selectedDate = selectedDate
        self.now = now
        self.calendar = calendar
        coverageStartOverride = coverageStart.map { calendar.startOfDay(for: $0) }
        coverageEndOverride = coverageEnd.map { calendar.startOfDay(for: $0) }
        self.coveredDays = coveredDays.map { Set($0.map { calendar.startOfDay(for: $0) }) }
    }

    var selectedWeekStart: Date {
        calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start ?? calendar.startOfDay(for: selectedDate)
    }

    var selectedWeekEnd: Date {
        calendar.date(byAdding: .day, value: 7, to: selectedWeekStart) ?? selectedWeekStart
    }

    var coverageStart: Date? { coverageStartOverride ?? [movements.map(\.date).min(), coveredDays?.min()].compactMap { $0 }.min().map { calendar.startOfDay(for: $0) } }
    var coverageEnd: Date? { coverageEndOverride ?? [movements.map(\.date).max(), coveredDays?.max()].compactMap { $0 }.max().map { calendar.startOfDay(for: $0) } }

    var dailyMovements: [Date: [Movement]] {
        Dictionary(grouping: movements) { calendar.startOfDay(for: $0.date) }
    }

    func periodAnalysis(for mode: SpendingCalendarMode) -> SpendingPeriodAnalysis {
        let range = periodRange(for: mode, containing: selectedDate)
        let today = calendar.startOfDay(for: now)
        let observedEnd: Date
        if range.start > today {
            observedEnd = range.start
        } else if today >= range.start && today < range.endExclusive {
            observedEnd = min(range.endExclusive, calendar.date(byAdding: .day, value: 1, to: today) ?? range.endExclusive)
        } else {
            observedEnd = range.endExclusive
        }
        let actualRows = movements(in: range.start, end: observedEnd)
        let dayCount = max(0, calendar.dateComponents([.day], from: range.start, to: observedEnd).day ?? 0)
        let samples = comparisonSamples(for: mode, range: range, observedDayCount: dayCount)
        let historical = mode == .month ? historicalMonthSamples(before: range.start, observedDayCount: dayCount) : []
        let points = days(from: range.start, to: observedEnd).map { day in
            let rows = dailyMovements[day, default: []]
            return SpendingDayPoint(date: day, actual: rows.reduce(0) { $0 + $1.expenseContribution }, historicalAverage: 0, movementCount: rows.count)
        }
        return SpendingPeriodAnalysis(
            mode: mode,
            start: range.start,
            endExclusive: range.endExclusive,
            observedEndExclusive: observedEnd,
            movements: actualRows,
            evolution: points,
            expectedTotal: averageTotal(samples),
            comparisonLabel: comparisonLabel(for: mode),
            secondaryExpectedTotal: averageTotal(historical),
            secondaryComparisonLabel: historical.isEmpty ? nil : "promedio mensual histórico comparable",
            expectedCategoryTotals: averageCategories(samples),
            hasCompleteCoverage: dayCount > 0 && points.allSatisfy { coveredDays?.contains($0.date) == true }
        )
    }

    func childRanges(for mode: SpendingCalendarMode) -> [SpendingPeriodRange] {
        let range = periodRange(for: mode, containing: selectedDate)
        switch mode {
        case .month:
            var output: [SpendingPeriodRange] = []
            var cursor = range.start
            while cursor < range.endExclusive {
                let calendarWeekEnd = calendar.dateInterval(of: .weekOfYear, for: cursor)?.end ?? range.endExclusive
                let end = min(range.endExclusive, calendarWeekEnd)
                output.append(SpendingPeriodRange(start: cursor, endExclusive: end,
                    title: "Semana del \(cursor.formatted(.dateTime.day())) al \((calendar.date(byAdding: .day, value: -1, to: end) ?? cursor).formatted(.dateTime.day().month(.abbreviated)))",
                    subtitle: "Ver sus días"))
                cursor = end
            }
            return output
        case .week:
            return days(from: range.start, to: range.endExclusive).map { day in
                SpendingPeriodRange(start: day, endExclusive: calendar.date(byAdding: .day, value: 1, to: day) ?? day,
                    title: day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)), subtitle: "Ver movimientos")
            }
        case .day:
            return []
        }
    }

    func periodRange(for mode: SpendingCalendarMode, containing date: Date) -> (start: Date, endExclusive: Date) {
        switch mode {
        case .day:
            let start = calendar.startOfDay(for: date)
            return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start)
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
            return (start, calendar.date(byAdding: .day, value: 7, to: start) ?? start)
        case .month:
            let interval = calendar.dateInterval(of: .month, for: date)
            let start = interval?.start ?? calendar.startOfDay(for: date)
            return (start, interval?.end ?? start)
        }
    }

    private func comparisonSamples(for mode: SpendingCalendarMode, range: (start: Date, endExclusive: Date), observedDayCount: Int) -> [[Movement]] {
        guard observedDayCount > 0 else { return [] }
        switch mode {
        case .day:
            guard let first = coverageStart else { return [] }
            return days(from: first, to: range.start).filter { coveredDays?.contains($0) == true }.map { dailyMovements[$0, default: []] }
        case .week:
            return (1...8).compactMap { offset -> [Movement]? in
                guard let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: range.start),
                      let end = calendar.date(byAdding: .day, value: observedDayCount, to: start),
                      days(from: start, to: end).allSatisfy({ coveredDays?.contains($0) == true }) else { return nil }
                return movements(in: start, end: end)
            }
        case .month:
            guard let start = calendar.date(byAdding: .month, value: -1, to: range.start),
                  let monthEnd = calendar.date(byAdding: .month, value: 1, to: start),
                  let proposed = calendar.date(byAdding: .day, value: observedDayCount, to: start) else { return [] }
            let end = min(monthEnd, proposed)
            guard days(from: start, to: end).count == observedDayCount,
                  days(from: start, to: end).allSatisfy({ coveredDays?.contains($0) == true }) else { return [] }
            return [movements(in: start, end: end)]
        }
    }

    private func historicalMonthSamples(before selectedMonth: Date, observedDayCount: Int) -> [[Movement]] {
        guard observedDayCount > 0 else { return [] }
        return (1...12).compactMap { offset -> [Movement]? in
            guard let start = calendar.date(byAdding: .month, value: -offset, to: selectedMonth),
                  let monthEnd = calendar.date(byAdding: .month, value: 1, to: start),
                  let proposed = calendar.date(byAdding: .day, value: observedDayCount, to: start) else { return nil }
            let end = min(monthEnd, proposed)
            guard days(from: start, to: end).count == observedDayCount,
                  days(from: start, to: end).allSatisfy({ coveredDays?.contains($0) == true }) else { return nil }
            return movements(in: start, end: end)
        }
    }

    private func movements(in start: Date, end: Date) -> [Movement] {
        movements.filter { $0.date >= start && $0.date < end }
    }

    private func days(from start: Date, to end: Date) -> [Date] {
        guard start < end else { return [] }
        var output: [Date] = []
        var cursor = calendar.startOfDay(for: start)
        while cursor < end {
            output.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? end
        }
        return output
    }

    private func averageTotal(_ samples: [[Movement]]) -> Decimal? {
        guard !samples.isEmpty else { return nil }
        return samples.reduce(Decimal(0)) { result, rows in result + rows.reduce(0) { $0 + $1.expenseContribution } } / Decimal(samples.count)
    }

    private func averageCategories(_ samples: [[Movement]]) -> [String: Decimal] {
        guard !samples.isEmpty else { return [:] }
        var totals: [String: Decimal] = [:]
        for rows in samples { for movement in rows { totals[movement.category, default: 0] += movement.expenseContribution } }
        return totals.mapValues { $0 / Decimal(samples.count) }
    }

    private func comparisonLabel(for mode: SpendingCalendarMode) -> String {
        switch mode {
        case .day: return "promedio diario histórico"
        case .week: return "promedio de las últimas semanas comparables"
        case .month: return "mismos días del mes anterior"
        }
    }

    private func averagesByWeekday(excludingSelectedWeek: Bool) -> [Int: Decimal] {
        guard let first = coverageStart, let last = coverageEnd else { return [:] }
        var totals: [Int: Decimal] = [:]
        var counts: [Int: Int] = [:]
        var cursor = first
        while cursor <= last {
            let isSelectedWeek = excludingSelectedWeek && cursor >= selectedWeekStart && cursor < selectedWeekEnd
            if !isSelectedWeek && (coveredDays?.contains(cursor) ?? false) {
                let weekday = calendar.component(.weekday, from: cursor)
                let total = dailyMovements[cursor, default: []].reduce(Decimal(0)) { $0 + $1.expenseContribution }
                totals[weekday, default: 0] += total
                counts[weekday, default: 0] += 1
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? last.addingTimeInterval(1)
        }
        return totals.reduce(into: [:]) { result, entry in
            let count = counts[entry.key, default: 0]
            result[entry.key] = count > 0 ? entry.value / Decimal(count) : 0
        }
    }

    /// Comparison base. The selected week is excluded so it never improves
    /// or worsens its own benchmark.
    var benchmarkByWeekday: [Int: Decimal] { averagesByWeekday(excludingSelectedWeek: true) }

    /// Stable historical profile. Changing the selected week does not alter
    /// the Histórico tab; only the global expense filters do.
    var historicalBenchmarkByWeekday: [Int: Decimal] { averagesByWeekday(excludingSelectedWeek: false) }

    var historySampleDays: Int {
        (coveredDays ?? []).filter { $0 < selectedWeekStart || $0 >= selectedWeekEnd }.count
    }

    var summary: SpendingWeekSummary {
        let benchmark = benchmarkByWeekday
        let points = (0..<7).compactMap { offset -> SpendingDayPoint? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: selectedWeekStart) else { return nil }
            let rows = dailyMovements[day, default: []]
            let weekday = calendar.component(.weekday, from: day)
            return SpendingDayPoint(
                date: day,
                actual: rows.reduce(0) { $0 + $1.expenseContribution },
                historicalAverage: benchmark[weekday, default: 0],
                movementCount: rows.count
            )
        }
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start
        let comparableDays: Int
        if selectedWeekStart == currentWeekStart {
            comparableDays = min(7, max(0, calendar.dateComponents([.day], from: selectedWeekStart, to: calendar.startOfDay(for: now)).day.map { $0 + 1 } ?? 0))
        } else if selectedWeekStart > calendar.startOfDay(for: now) {
            comparableDays = 0
        } else {
            comparableDays = 7
        }
        return SpendingWeekSummary(start: selectedWeekStart, endExclusive: selectedWeekEnd, points: points, comparableDayCount: comparableDays,
            hasCompleteCoverage: comparableDays > 0 && points.prefix(comparableDays).allSatisfy { coveredDays?.contains($0.date) == true })
    }

    func movements(on date: Date) -> [Movement] {
        dailyMovements[calendar.startOfDay(for: date), default: []]
            .sorted { abs($0.amount) > abs($1.amount) }
    }

    var historyDays: [SpendingHistoryDay] {
        guard let first = coverageStart, let last = coverageEnd else { return [] }
        let benchmark = historicalBenchmarkByWeekday
        var output: [SpendingHistoryDay] = []
        var cursor = first
        while cursor <= last {
            let rows = dailyMovements[cursor, default: []]
            let weekday = calendar.component(.weekday, from: cursor)
            output.append(SpendingHistoryDay(
                date: cursor,
                total: rows.reduce(0) { $0 + $1.expenseContribution },
                expected: benchmark[weekday, default: 0],
                movements: rows.sorted { abs($0.amount) > abs($1.amount) },
                isCovered: coveredDays?.contains(cursor) ?? false
            ))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? last.addingTimeInterval(1)
        }
        return output
    }

    var weekdayAverages: [SpendingDayPoint] {
        let benchmark = historicalBenchmarkByWeekday
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: selectedWeekStart) else { return nil }
            guard benchmark[calendar.component(.weekday, from: day)] != nil else { return nil }
            return SpendingDayPoint(
                date: day,
                actual: benchmark[calendar.component(.weekday, from: day), default: 0],
                historicalAverage: 0,
                movementCount: 0
            )
        }
    }

    var historicalDailyAverage: Decimal {
        let known = historyDays.filter(\.isCovered)
        guard !known.isEmpty else { return 0 }
        return known.reduce(0) { $0 + $1.total } / Decimal(known.count)
    }

    var historicalMedian: Decimal {
        let values = historyDays.filter(\.isCovered).map(\.total).sorted()
        guard !values.isEmpty else { return 0 }
        let middle = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }

    var highestAverageWeekday: SpendingDayPoint? { historicalBenchmarkByWeekday.isEmpty ? nil : weekdayAverages.max { $0.actual < $1.actual } }
    var lowestAverageWeekday: SpendingDayPoint? { historicalBenchmarkByWeekday.isEmpty ? nil : weekdayAverages.min { $0.actual < $1.actual } }

    var recentTrend: [SpendingWeekTrend] {
        guard let first = coverageStart,
              let last = coverageEnd,
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: first)?.start,
              let finalWeek = calendar.dateInterval(of: .weekOfYear, for: last)?.start else { return [] }
        return (0..<12).reversed().compactMap { offset in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: finalWeek),
                  start >= firstWeek,
                  let end = calendar.date(byAdding: .day, value: 7, to: start) else { return nil }
            let total = movements
                .filter { $0.date >= start && $0.date < end }
                .reduce(Decimal(0)) { $0 + $1.expenseContribution }
            return SpendingWeekTrend(start: start, total: total)
        }
    }

    var anomalousDays: [SpendingHistoryDay] {
        Array(historyDays
            .filter { $0.isCovered && $0.total > 0 && $0.expected > 0 }
            .sorted {
                if $0.ratio != $1.ratio { return $0.ratio > $1.ratio }
                return $0.total > $1.total
            }
            .prefix(10))
    }
}

private struct SelectedSpendingDay: Identifiable {
    let date: Date
    var id: Date { date }
}

private struct SelectedSpendingPeriod: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let movementIDs: [UUID]
}

struct SpendingCalendarView: View {
    @Environment(FinanceStore.self) private var store
    @State private var mode: SpendingCalendarMode = .week
    @State private var selectedDate = Date.now
    @State private var didSelectInitialDate = false
    @State private var filters = SpendingCalendarFilters()
    @State private var isFilterPresented = false
    @State private var isDatePickerPresented = false
    @State private var selectedDay: SelectedSpendingDay?
    @State private var selectedPeriod: SelectedSpendingPeriod?

    private var filteredMovements: [Movement] {
        store.netExpenseMovements.filter { spendingMovement($0, matches: filters) }
    }

    private var analytics: SpendingCalendarAnalytics {
        SpendingCalendarAnalytics(
            movements: filteredMovements,
            selectedDate: selectedDate,
            coveredDays: store.spendingCoveredDays(account: filters.account)
        )
    }

    private var categories: [String] { Array(Set(store.netExpenseMovements.map(\.category))).sorted() }
    private var accounts: [String] { Array(Set(store.netExpenseMovements.map(\.account))).sorted() }

    var body: some View {
        NavigationStack {
            Group {
                if store.operationalMetricsBlocked {
                    ScrollView {
                        VStack(spacing: 16) {
                            LedgerQualityBanner(store: store)
                            HistoricalDashboardBlockedCard(store: store)
                        }
                        .padding()
                    }
                } else if store.netExpenseMovements.isEmpty {
                    ContentUnavailableView("Sin gastos", systemImage: "calendar", description: Text("Importa estados conciliados para comparar tus semanas."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if store.dashboardIsProvisional {
                                LedgerQualityBanner(store: store)
                            }
                            calendarHeader
                            filterSummary
                            if filteredMovements.isEmpty {
                                ContentUnavailableView("Sin coincidencias", systemImage: "line.3.horizontal.decrease.circle", description: Text("Cambia o limpia los filtros para ver gastos."))
                            } else {
                                unifiedPeriodView
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 4)
                        .padding(.bottom, 20)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .foregroundStyle(Color.marcelitoNavy)
            .scrollContentBackground(.hidden)
            .background(MarcelitoAmbientBackground())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isFilterPresented = true } label: {
                        Label(filters.activeCount == 0 ? "Filtros" : "Filtros \(filters.activeCount)", systemImage: filters.activeCount == 0 ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityHint("Filtra por categoría, cuenta, tipo o comercio")
                }
            }
            .sheet(isPresented: $isFilterPresented) {
                SpendingCalendarFilterView(filters: $filters, categories: categories, accounts: accounts)
            }
            .sheet(isPresented: $isDatePickerPresented) {
                SpendingPeriodPickerView(date: $selectedDate, mode: mode)
            }
            .sheet(item: $selectedDay) { selection in
                SpendingDayDetailView(
                    date: selection.date,
                    movementIDs: analytics.movements(on: selection.date).map(\.id),
                    filters: filters,
                    usesStableHistory: true
                )
            }
            .sheet(item: $selectedPeriod) { selection in
                SpendingPeriodDetailView(selection: selection, filters: filters)
            }
            .onAppear {
                guard !didSelectInitialDate else { return }
                selectedDate = store.netExpenseMovements.map(\.date).max() ?? .now
                didSelectInitialDate = true
            }
        }
    }

    private var calendarHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calendario")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Picker("Vista", selection: $mode) {
                ForEach(SpendingCalendarMode.allCases) { option in Text(option.rawValue).tag(option) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            coverageLabel
        }
    }

    private var filterSummary: some View {
        Group {
            if !filters.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let category = filters.category { filterChip(category) }
                        if let account = filters.account { filterChip(account) }
                        if let type = filters.expenseType { filterChip(type.rawValue) }
                        if let status = filters.reviewStatus { filterChip(status.rawValue) }
                        if !filters.merchantQuery.isEmpty { filterChip("Comercio: \(filters.merchantQuery)") }
                        Button("Limpiar") { filters = SpendingCalendarFilters() }
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }

    private var coverageLabel: some View {
        Group {
            if let first = store.netExpenseMovements.map(\.date).min(),
               let last = store.netExpenseMovements.map(\.date).max() {
                Label(
                    "Gastos reales conciliados · \(first.formatted(.dateTime.day().month(.abbreviated).year())) a \(last.formatted(.dateTime.day().month(.abbreviated).year()))",
                    systemImage: "checkmark.seal"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func filterChip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.marcelitoNavy.opacity(0.09), in: Capsule())
    }

    private var currentAnalysis: SpendingPeriodAnalysis { analytics.periodAnalysis(for: mode) }

    private var unifiedPeriodView: some View {
        let analysis = currentAnalysis
        return Group {
            periodNavigator(analysis)
            periodSummary(analysis)
            comparisonCard(analysis)
            categoryCard(analysis)
            SpendingEvolutionChart(analysis: analysis) { date in
                selectedDate = date
                mode = .day
            }
            explanationCard(analysis)
            drillDownCard(analysis)
        }
    }

    private func periodNavigator(_ analysis: SpendingPeriodAnalysis) -> some View {
        HStack(spacing: 12) {
            Button { shiftPeriod(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(periodTitle(analysis)).font(.headline)
                Text(periodSubtitle(analysis)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cambiar") { isDatePickerPresented = true }.font(.caption.weight(.semibold))
            Button { shiftPeriod(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    private func periodSummary(_ analysis: SpendingPeriodAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summarySentence(analysis))
                .font(.system(.title2, design: .rounded).weight(.bold))
                .minimumScaleFactor(0.72)
            Text("Consumo real: excluye transferencias propias y pagos de tarjetas. El ticket promedio usa solo cargos.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                SpendingMetricTile(title: "Promedio diario", value: analysis.dailyAverage.formatted(.currency(code: "MXN").precision(.fractionLength(0))))
                SpendingMetricTile(title: "Movimientos", value: "\(analysis.movementCount)")
                SpendingMetricTile(title: "Ticket promedio", value: analysis.ticketAverage.formatted(.currency(code: "MXN").precision(.fractionLength(0))))
            }
        }
        .marcelitoCard(radius: 20, padding: 14)
    }

    private func comparisonCard(_ analysis: SpendingPeriodAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cómo se compara").font(.headline)
            if let expected = analysis.expectedTotal, analysis.hasCompleteCoverage {
                comparisonRow(total: analysis.total, expected: expected, label: analysis.comparisonLabel)
                if let secondary = analysis.secondaryExpectedTotal, let label = analysis.secondaryComparisonLabel {
                    Divider().opacity(0.55)
                    comparisonRow(total: analysis.total, expected: secondary, label: label)
                }
            } else {
                Label("Falta cobertura histórica comparable; no mostramos una variación engañosa.", systemImage: "info.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .marcelitoCard(radius: 20, padding: 14)
    }

    private func comparisonRow(total: Decimal, expected: Decimal, label: String) -> some View {
        let delta = total - expected
        let percent = expected > 0 ? NSDecimalNumber(decimal: delta / expected).doubleValue * 100 : nil
        return VStack(alignment: .leading, spacing: 3) {
            Text(percent.map { "Gastaste \(String(format: "%.0f%%", abs($0))) \($0 >= 0 ? "más" : "menos") que tu \(label)." } ?? "No existe una base distinta de cero para calcular porcentaje.")
                .font(.subheadline.weight(.semibold))
            Text("\(delta >= 0 ? "+" : "−")\(abs(delta).formatted(.currency(code: "MXN").precision(.fractionLength(0)))) · referencia: \(expected.formatted(.currency(code: "MXN").precision(.fractionLength(0))))")
                .font(.caption).foregroundStyle(delta > 0 ? Color.marcelitoDanger : Color.marcelitoSuccess)
        }
    }

    private func categoryCard(_ analysis: SpendingPeriodAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("En qué gastaste").font(.headline)
            if analysis.categories.isEmpty {
                Text("No hay consumo clasificado en este periodo.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(Array(analysis.categories.prefix(6))) { category in
                    Button {
                        let rows = analysis.movements.filter { $0.category == category.name }
                        selectedPeriod = SelectedSpendingPeriod(title: category.name, subtitle: periodTitle(analysis), movementIDs: rows.map(\.id))
                    } label: {
                        VStack(spacing: 5) {
                            HStack {
                                Text(category.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                Spacer()
                                Text(category.total, format: .currency(code: "MXN").precision(.fractionLength(0))).monospacedDigit()
                                Text(category.isNetRefund ? String(format: "%.0f%% · devolución", category.share * 100) : String(format: "%.0f%%", category.share * 100))
                                    .font(.caption)
                                    .foregroundStyle(category.isNetRefund ? Color.marcelitoSuccess : .secondary)
                                    .frame(width: category.isNetRefund ? 112 : 40, alignment: .trailing)
                            }
                            ProgressView(value: max(0, min(1, category.share)))
                                .tint(category.isNetRefund ? Color.marcelitoSuccess : Color.marcelitoNavySoft)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if analysis.categories.contains(where: \.isNetRefund) {
                    Text("Las devoluciones se muestran con signo negativo. Por eso una categoría de consumo puede superar 100%, pero todos los porcentajes firmados reconcilian al total neto.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .marcelitoCard(radius: 20, padding: 14)
    }

    private func explanationCard(_ analysis: SpendingPeriodAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Qué explica tu gasto").font(.headline)
            if analysis.expectedTotal == nil || !analysis.hasCompleteCoverage {
                Text("Necesitamos un periodo comparable cubierto para separar las diferencias por categoría.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if analysis.explanations.isEmpty {
                Text("No hay diferencias observables frente al periodo de comparación.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text(explanationSentence(analysis)).font(.subheadline.weight(.medium))
                ForEach(Array(analysis.explanations.prefix(3))) { item in
                    HStack {
                        Text(item.category).lineLimit(1)
                        Spacer()
                        Text(item.delta >= 0 ? "+" : "−") + Text(abs(item.delta), format: .currency(code: "MXN").precision(.fractionLength(0)))
                    }
                    .font(.caption)
                    .foregroundStyle(item.delta > 0 ? Color.marcelitoDanger : Color.marcelitoSuccess)
                }
                Text("Diferencias calculadas únicamente con movimientos observados por categoría.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .marcelitoCard(fill: Color.marcelitoCreamTint, radius: 18, padding: 12)
    }

    @ViewBuilder
    private func drillDownCard(_ analysis: SpendingPeriodAnalysis) -> some View {
        if mode == .day {
            VStack(alignment: .leading, spacing: 10) {
                Text("Movimientos del día").font(.headline)
                ForEach(analysis.movements.sorted { abs($0.expenseContribution) > abs($1.expenseContribution) }) { movement in
                    NavigationLink { MovementDetailView(movement: movement) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(movement.title).lineLimit(1)
                                Text("\(movement.category) · \(movement.account)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(movement.expenseContribution, format: .currency(code: "MXN").precision(.fractionLength(2))).monospacedDigit()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                    if movement.id != analysis.movements.last?.id { Divider() }
                }
            }.marcelitoCard()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(mode == .month ? "Semanas del mes" : "Días de la semana").font(.headline)
                ForEach(analytics.childRanges(for: mode)) { range in
                    let total = filteredMovements.filter { $0.date >= range.start && $0.date < range.endExclusive }.reduce(Decimal(0)) { $0 + $1.expenseContribution }
                    Button {
                        selectedDate = range.start
                        mode = mode == .month ? .week : .day
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) { Text(range.title).font(.subheadline.weight(.medium)); Text(range.subtitle).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(total, format: .currency(code: "MXN").precision(.fractionLength(0))).monospacedDigit()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }.buttonStyle(.plain)
                }
            }.marcelitoCard()
        }
    }

    private func periodTitle(_ analysis: SpendingPeriodAnalysis) -> String {
        switch analysis.mode {
        case .day: return analysis.start.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        case .week:
            let end = analytics.calendar.date(byAdding: .day, value: -1, to: analysis.endExclusive) ?? analysis.start
            return "Semana del \(analysis.start.formatted(.dateTime.day())) al \(end.formatted(.dateTime.day().month(.abbreviated).year()))"
        case .month: return analysis.start.formatted(.dateTime.month(.wide).year())
        }
    }

    private func periodSubtitle(_ analysis: SpendingPeriodAnalysis) -> String {
        analysis.observedDayCount < max(1, analytics.calendar.dateComponents([.day], from: analysis.start, to: analysis.endExclusive).day ?? 1)
            ? "Periodo en curso · \(analysis.observedDayCount) días observados"
            : "Periodo completo"
    }

    private func summarySentence(_ analysis: SpendingPeriodAnalysis) -> String {
        let period = analysis.mode == .day ? "Este día" : analysis.mode == .week ? "Esta semana" : "Este mes"
        return "\(period) gastaste \(analysis.total.formatted(.currency(code: "MXN").precision(.fractionLength(0))))"
    }

    private func explanationSentence(_ analysis: SpendingPeriodAnalysis) -> String {
        guard let delta = analysis.delta else { return "Sin comparación disponible." }
        let direction = delta >= 0 ? "más" : "menos"
        let items = analysis.explanations.prefix(3).map { "\($0.category) \($0.delta >= 0 ? "+" : "−")\(abs($0.delta).formatted(.currency(code: "MXN").precision(.fractionLength(0))))" }.joined(separator: ", ")
        return "Gastaste \(abs(delta).formatted(.currency(code: "MXN").precision(.fractionLength(0)))) \(direction) de lo comparable. Las mayores diferencias son: \(items)."
    }

    private func shiftPeriod(_ amount: Int) {
        let component: Calendar.Component = mode == .day ? .day : mode == .week ? .weekOfYear : .month
        selectedDate = analytics.calendar.date(byAdding: component, value: amount, to: selectedDate) ?? selectedDate
    }

    private var weekView: some View {
        let summary = analytics.summary
        return Group {
            weekNavigator(summary)
            weekHero(summary)
            if !summary.hasCompleteCoverage {
                Text("Gasto observado: faltan días o cuentas por cubrir. La desviación porcentual queda pendiente; sin movimientos no significa gasto cero.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if analytics.historySampleDays < 21 {
                Label("La comparación todavía tiene poca historia; mejorará al importar más semanas.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Color.marcelitoAmber)
                    .padding(.horizontal, 4)
            }
            WeeklySpendingChart(points: summary.points) { date in selectedDay = SelectedSpendingDay(date: date) }
            executiveWeekInsight(summary)
        }
    }

    private func weekNavigator(_ summary: SpendingWeekSummary) -> some View {
        HStack(spacing: 12) {
            Button { shiftWeek(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text("Semana del \(summary.start.formatted(.dateTime.day())) al \((analytics.calendar.date(byAdding: .day, value: -1, to: summary.endExclusive) ?? summary.start).formatted(.dateTime.day().month(.abbreviated).year()))")
                    .font(.headline)
                Text("vs promedio histórico").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cambiar") { isDatePickerPresented = true }
                .font(.caption.weight(.semibold))
            Button { shiftWeek(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }

    private func weekHero(_ summary: SpendingWeekSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Resumen semanal").font(.headline)
                Spacer()
                Text(summary.comparableDayCount < 7 ? "\(summary.comparableDayCount) días" : "7 días")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                SpendingMetricTile(title: "Total semanal", value: summary.actualTotal.formatted(.currency(code: "MXN").precision(.fractionLength(0))), prominent: true)
                SpendingMetricTile(title: "Promedio diario", value: summary.dailyAverage.formatted(.currency(code: "MXN").precision(.fractionLength(0))))
                SpendingMetricTile(title: "vs histórico", value: comparisonText(summary), color: comparisonColor(summary))
                SpendingMetricTile(title: "Movimientos", value: "\(summary.points.reduce(0) { $0 + $1.movementCount })")
            }
        }
        .marcelitoCard(radius: 20, padding: 14)
        .contentShape(Rectangle())
        .onTapGesture {
            let rows = filteredMovements.filter { $0.date >= summary.start && $0.date < summary.endExclusive }
            selectedPeriod = SelectedSpendingPeriod(
                title: "Detalle de la semana",
                subtitle: summary.start.formatted(.dateTime.day().month(.abbreviated)) + " – " + (analytics.calendar.date(byAdding: .day, value: -1, to: summary.endExclusive) ?? summary.start).formatted(.dateTime.day().month(.abbreviated).year()),
                movementIDs: rows.map(\.id)
            )
        }
        .accessibilityHint("Toca para ver el desglose y los montos más altos de la semana")
        .accessibilityValue(summary.comparableDayCount < 7 ? "Comparación acumulada para \(summary.comparableDayCount) días transcurridos" : "Comparación contra los mismos siete días del promedio histórico")
        .accessibilityAddTraits(.isButton)
    }

    private func executiveWeekInsight(_ summary: SpendingWeekSummary) -> some View {
        Button {
            guard let highest = summary.highest else { return }
            selectedDay = SelectedSpendingDay(date: highest.date)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Color.marcelitoAmber)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lectura automática").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(weekInsightText(summary)).font(.subheadline.weight(.medium)).multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .marcelitoCard(fill: Color.marcelitoCreamTint, radius: 18, padding: 12)
    }

    private func weeklyDayList(_ summary: SpendingWeekSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Detalle diario").font(.headline)
            ForEach(summary.points) { point in
                Button { selectedDay = SelectedSpendingDay(date: point.date) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))).font(.subheadline.weight(.medium))
                            Text(dayComparison(point)).font(.caption).foregroundStyle(dayComparisonColor(point))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(point.actual, format: .currency(code: "MXN").precision(.fractionLength(0))).monospacedDigit()
                            Text("\(point.movementCount) movimiento(s)").font(.caption).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                if point.id != summary.points.last?.id { Divider() }
            }
        }
        .marcelitoCard()
    }

    private var historyView: some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Patrón histórico").font(.headline)
                    Spacer()
                    Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("La mediana representa un día típico sin distorsión por compras extraordinarias")
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    SpendingMetricTile(title: "Promedio diario", value: (analytics.coveredDays?.isEmpty ?? true) ? "Sin cobertura" : analytics.historicalDailyAverage.formatted(.currency(code: "MXN").precision(.fractionLength(0))))
                    SpendingMetricTile(title: "Mediana diaria", value: (analytics.coveredDays?.isEmpty ?? true) ? "Sin cobertura" : analytics.historicalMedian.formatted(.currency(code: "MXN").precision(.fractionLength(0))))
                    SpendingMetricTile(title: "Cobertura", value: "\(analytics.historyDays.filter(\.isCovered).count) días")
                }
                Divider().opacity(0.55)
                if let highest = analytics.highestAverageWeekday {
                    HistoricalDayKPI(title: "Día más caro", day: highest.date, value: highest.actual, color: .marcelitoAmber)
                }
                if let lowest = analytics.lowestAverageWeekday {
                    HistoricalDayKPI(title: "Día más barato", day: lowest.date, value: lowest.actual, color: .marcelitoSuccess)
                }
            }
            .marcelitoCard(radius: 20, padding: 14)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedPeriod = SelectedSpendingPeriod(
                    title: "Detalle histórico",
                    subtitle: "Todos los días incluidos por los filtros",
                    movementIDs: filteredMovements.map(\.id)
                )
            }
            .accessibilityHint("Toca para ver el desglose y el Top 10 histórico")
            .accessibilityAddTraits(.isButton)
            HistoricalWeekdayChart(points: analytics.weekdayAverages)
            HistoricalSpendingHeatmap(days: Array(analytics.historyDays.suffix(84))) { day in selectedDay = SelectedSpendingDay(date: day) }
            historyExecutiveInsight
            HistoricalWeeklyTrendChart(points: analytics.recentTrend)
            anomalousDayList
        }
    }

    private var historyExecutiveInsight: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Color.marcelitoAmber)
            VStack(alignment: .leading, spacing: 3) {
                Text("Lectura automática").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(historyInsightText).font(.subheadline.weight(.medium))
            }
        }
        .marcelitoCard(fill: Color.marcelitoCreamTint, radius: 18, padding: 12)
    }

    private var anomalousDayList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Días más fuera de lo normal").font(.headline)
            ForEach(analytics.anomalousDays) { day in
                Button { selectedDay = SelectedSpendingDay(date: day.date) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(day.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).year())).font(.subheadline.weight(.medium))
                            Text(anomalyText(day)).font(.caption).foregroundStyle(day.ratio > 1 ? Color.marcelitoDanger : Color.marcelitoSuccess)
                        }
                        Spacer()
                        Text(day.total, format: .currency(code: "MXN").precision(.fractionLength(0))).monospacedDigit()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .marcelitoCard()
    }

    private func shiftWeek(_ amount: Int) {
        selectedDate = analytics.calendar.date(byAdding: .weekOfYear, value: amount, to: selectedDate) ?? selectedDate
    }

    private func comparisonText(_ summary: SpendingWeekSummary) -> String {
        guard let percent = summary.deltaPercent else { return "Sin base" }
        return String(format: "%+.0f%%", percent)
    }

    private func comparisonColor(_ summary: SpendingWeekSummary) -> Color {
        guard let percent = summary.deltaPercent else { return .secondary }
        return percent > 10 ? .marcelitoDanger : percent < -10 ? .marcelitoSuccess : .marcelitoAmber
    }

    private func dayComparison(_ point: SpendingDayPoint) -> String {
        guard point.historicalAverage > 0 else { return "Sin promedio histórico" }
        return point.delta >= 0
            ? "\(abs(point.delta).formatted(.currency(code: "MXN").precision(.fractionLength(0)))) arriba del promedio"
            : "\(abs(point.delta).formatted(.currency(code: "MXN").precision(.fractionLength(0)))) abajo del promedio"
    }

    private func dayComparisonColor(_ point: SpendingDayPoint) -> Color {
        point.delta > 0 ? .marcelitoDanger : .marcelitoSuccess
    }

    private func anomalyText(_ day: SpendingHistoryDay) -> String {
        guard day.expected > 0 else { return "Sin base histórica para ese día" }
        return String(format: "%.0f%% %@ del promedio", abs((day.ratio - 1) * 100), day.ratio >= 1 ? "arriba" : "abajo")
    }

    private func weekInsightText(_ summary: SpendingWeekSummary) -> String {
        guard let highest = summary.highest else { return "Aún no hay suficiente información para interpretar esta semana." }
        let share = summary.actualTotal > 0
            ? NSDecimalNumber(decimal: highest.actual / summary.actualTotal).doubleValue * 100
            : 0
        let direction: String
        if let percent = summary.deltaPercent {
            if percent > 10 { direction = "más alta que el promedio" }
            else if percent < -10 { direction = "más baja que el promedio" }
            else { direction = "en línea con el promedio" }
        } else {
            direction = "sin suficiente base histórica"
        }
        return "Semana \(direction); \(highest.date.formatted(.dateTime.weekday(.wide))) concentró \(String(format: "%.0f", share))% del gasto."
    }

    private var historyInsightText: String {
        guard let highest = analytics.highestAverageWeekday,
              let lowest = analytics.lowestAverageWeekday else {
            return "Importa más semanas para identificar un patrón diario estable."
        }
        return "Tu día históricamente más caro es \(highest.date.formatted(.dateTime.weekday(.wide))) y el más ligero es \(lowest.date.formatted(.dateTime.weekday(.wide)))."
    }

    private func topBreakdown(in summary: SpendingWeekSummary, by key: (Movement) -> String) -> (name: String, total: Decimal)? {
        let rows = filteredMovements.filter { $0.date >= summary.start && $0.date < summary.endExclusive }
        return Dictionary(grouping: rows, by: key)
            .map { (name: $0.key, total: $0.value.reduce(0) { $0 + $1.expenseContribution }) }
            .max { $0.total < $1.total }
    }
}

private func spendingExpenseType(for movement: Movement) -> SpendingCalendarExpenseType {
    let tags = Set(movement.classificationTags.map { $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased() })
    let category = movement.category.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
    if tags.contains("proyecto") || category.contains("proyecto") || category.contains("club amigos") { return .project }
    if movement.travelRelated || tags.contains("viaje") { return .travel }
    if tags.contains("extraordinario") { return .extraordinary }
    return .ordinary
}

private func spendingMovement(_ movement: Movement, matches filters: SpendingCalendarFilters) -> Bool {
    if let category = filters.category, movement.category != category { return false }
    if let account = filters.account, movement.account != account { return false }
    if let expenseType = filters.expenseType, spendingExpenseType(for: movement) != expenseType { return false }
    if let status = filters.reviewStatus {
        let isReview = ["Por revisar", "Sin categoría", "Otros / Por revisar", "Otros gastos"].contains(movement.category)
        if status == .review && !isReview { return false }
        if status == .identified && isReview { return false }
    }
    let query = filters.merchantQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty || movement.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

private struct SpendingMiniMetric: View {
    let title: String
    let value: String
    var color: Color = .marcelitoNavy

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(color).monospacedDigit().minimumScaleFactor(0.72).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SpendingMetricTile: View {
    let title: String
    let value: String
    var color: Color = .marcelitoNavy
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(prominent ? .headline.weight(.bold) : .subheadline.weight(.semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .minimumScaleFactor(0.68)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.marcelitoNavy.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct HistoricalDayKPI: View {
    let title: String
    let day: Date
    let value: Decimal
    let color: Color

    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(day.formatted(.dateTime.weekday(.wide))).font(.subheadline.weight(.semibold))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(value, format: .currency(code: "MXN").precision(.fractionLength(0)))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                Text("ticket habitual").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private func spendingWeekdayLabel(_ date: Date) -> String {
    switch Calendar(identifier: .iso8601).component(.weekday, from: date) {
    case 1: return "D"
    case 2: return "L"
    case 3: return "M"
    case 4: return "Mi"
    case 5: return "J"
    case 6: return "V"
    default: return "S"
    }
}

private struct SpendingMovementEvolutionPoint: Identifiable {
    let index: Int
    let movement: Movement
    var id: UUID { movement.id }
    var value: Double { NSDecimalNumber(decimal: movement.expenseContribution).doubleValue }
}

private struct SpendingEvolutionChart: View {
    let analysis: SpendingPeriodAnalysis
    let selectDay: (Date) -> Void

    private var movementPoints: [SpendingMovementEvolutionPoint] {
        analysis.movements.sorted { $0.date < $1.date }.enumerated().map { SpendingMovementEvolutionPoint(index: $0.offset + 1, movement: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Evolución del gasto").font(.headline)
            Text(chartSubtitle).font(.caption).foregroundStyle(.secondary)
            if analysis.mode == .day {
                Chart(movementPoints) { point in
                    BarMark(x: .value("Movimiento", point.index), y: .value("Gasto", point.value), width: .fixed(12))
                        .foregroundStyle(Color.marcelitoNavySoft)
                        .cornerRadius(3)
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: min(6, max(2, movementPoints.count)))) }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 154)
            } else {
                Chart(analysis.evolution) { point in
                    BarMark(x: .value("Día", point.date, unit: .day), y: .value("Gasto", point.actualDouble), width: .fixed(analysis.mode == .week ? 18 : 8))
                        .foregroundStyle(Color.marcelitoNavySoft.opacity(0.78))
                        .cornerRadius(3)
                }
                .chartXAxis {
                    if analysis.mode == .week {
                        AxisMarks(values: analysis.evolution.map(\.date)) { value in
                            AxisValueLabel { if let date = value.as(Date.self) { Text(spendingWeekdayLabel(date)) } }
                        }
                    } else {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.day()) }
                    }
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { event in
                                guard let frame = proxy.plotFrame else { return }
                                let x = event.location.x - geometry[frame].origin.x
                                guard let date: Date = proxy.value(atX: x),
                                      let nearest = analysis.evolution.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) else { return }
                                selectDay(nearest.date)
                            })
                    }
                }
                .frame(height: 164)
                Text("Toca un día para abrir su detalle.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .marcelitoCard(radius: 20, padding: 14)
    }

    private var chartSubtitle: String {
        switch analysis.mode {
        case .day: return "Distribución de los movimientos del día"
        case .week: return "Gasto real de cada uno de los siete días"
        case .month: return "Gasto real acumulado día por día"
        }
    }
}

private struct WeeklySpendingChart: View {
    let points: [SpendingDayPoint]
    let select: (Date) -> Void

    private var maximumID: Date? { points.max { $0.actual < $1.actual }?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Gasto por día").font(.headline)
                Spacer()
                HStack(spacing: 5) {
                    Capsule().fill(Color.marcelitoNavySoft).frame(width: 14, height: 5)
                    Text("Real").font(.caption2)
                    Rectangle().fill(Color.marcelitoAmber).frame(width: 14, height: 1)
                    Text("Promedio").font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            Chart(points) { point in
                BarMark(
                    x: .value("Día", point.date, unit: .day),
                    y: .value("Gasto", point.actualDouble),
                    width: .fixed(18)
                )
                .foregroundStyle(point.id == maximumID ? Color.marcelitoAmber : Color.marcelitoNavySoft.opacity(0.72))
                .cornerRadius(4)
                LineMark(
                    x: .value("Día", point.date, unit: .day),
                    y: .value("Promedio", point.averageDouble)
                )
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                .foregroundStyle(Color.marcelitoNavyDeep.opacity(0.62))
            }
            .chartXAxis {
                AxisMarks(values: points.map(\.date)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(spendingWeekdayLabel(date)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { _ in
                    AxisGridLine().foregroundStyle(Color.marcelitoLine.opacity(0.5))
                    AxisValueLabel().font(.caption2).foregroundStyle(.secondary)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { event in
                            guard let frame = proxy.plotFrame else { return }
                            let plot = geometry[frame]
                            let x = event.location.x - plot.origin.x
                            guard let tapped: Date = proxy.value(atX: x),
                                  let nearest = points.min(by: { abs($0.date.timeIntervalSince(tapped)) < abs($1.date.timeIntervalSince(tapped)) }) else { return }
                            select(nearest.date)
                        })
                }
            }
            .frame(height: 164)
            Text("Toca una barra para ver monto, diferencia y movimientos.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .marcelitoCard(radius: 20, padding: 14)
    }
}

private struct HistoricalWeekdayChart: View {
    let points: [SpendingDayPoint]

    private var maximumID: Date? { points.max { $0.actual < $1.actual }?.id }
    private var minimumID: Date? { points.min { $0.actual < $1.actual }?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Promedio por día").font(.headline)
            Text("Patrón habitual de lunes a domingo").font(.caption).foregroundStyle(.secondary)
            Chart(points) { point in
                BarMark(
                    x: .value("Día", point.date, unit: .day),
                    y: .value("Promedio", point.actualDouble),
                    width: .fixed(16)
                )
                .foregroundStyle(
                    point.id == maximumID ? Color.marcelitoAmber :
                    point.id == minimumID ? Color.marcelitoSuccess :
                    Color.marcelitoNavySoft.opacity(0.58)
                )
                .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: points.map(\.date)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(spendingWeekdayLabel(date)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { _ in
                    AxisGridLine().foregroundStyle(Color.marcelitoLine.opacity(0.45))
                    AxisValueLabel().font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(height: 154)
        }
        .marcelitoCard(radius: 20, padding: 14)
    }
}

private struct HistoricalWeeklyTrendChart: View {
    let points: [SpendingWeekTrend]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tendencia de 12 semanas").font(.headline)
            Chart(points) { point in
                LineMark(x: .value("Semana", point.start), y: .value("Gasto", point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.marcelitoAmber)
                AreaMark(x: .value("Semana", point.start), y: .value("Gasto", point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [Color.marcelitoAmber.opacity(0.24), .clear], startPoint: .top, endPoint: .bottom))
            }
            .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: 3)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 190)
        }
        .marcelitoCard()
    }
}

private struct HistoricalSpendingHeatmap: View {
    let days: [SpendingHistoryDay]
    let select: (Date) -> Void
    private let columns = Array(repeating: GridItem(.flexible(minimum: 22, maximum: 36), spacing: 4), count: 7)

    private var maximum: Decimal { days.map(\.total).max() ?? 0 }
    private var leadingBlankCount: Int {
        guard let first = days.first else { return 0 }
        let weekday = Calendar(identifier: .iso8601).component(.weekday, from: first.date)
        return (weekday + 5) % 7
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mapa de intensidad").font(.headline)
            Text("84 días de gasto diario").font(.caption).foregroundStyle(.secondary)
            HStack {
                ForEach(Array(["L", "M", "Mi", "J", "V", "S", "D"].enumerated()), id: \.offset) { _, label in
                    Text(label).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(0..<leadingBlankCount, id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fit) }
                ForEach(days) { day in
                    Button { select(day.date) } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(day.isCovered ? heatColor(day.total) : Color.marcelitoLine.opacity(0.12))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(Text(day.date.formatted(.dateTime.day())).font(.system(size: 7, weight: .medium)).foregroundStyle(day.total > maximum / 2 ? .white : Color.marcelitoNavy))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(day.date.formatted(date: .long, time: .omitted)), \(day.isCovered ? day.total.formatted(.currency(code: "MXN")) : "Cobertura incompleta")")
                }
            }
            HStack(spacing: 5) {
                Text("Bajo").font(.caption2).foregroundStyle(.secondary)
                ForEach(1...5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.marcelitoNavy.opacity(0.10 + Double(level) * 0.16))
                        .frame(width: 16, height: 7)
                }
                Text("Alto").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Pálido: cobertura incompleta").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .marcelitoCard(radius: 20, padding: 14)
    }

    private func heatColor(_ total: Decimal) -> Color {
        guard maximum > 0 else { return Color.marcelitoLine.opacity(0.35) }
        let ratio = max(0, min(1, NSDecimalNumber(decimal: total / maximum).doubleValue))
        if ratio == 0 { return Color.marcelitoLine.opacity(0.35) }
        return Color.marcelitoNavy.opacity(0.18 + ratio * 0.82)
    }
}

private struct SpendingCalendarFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filters: SpendingCalendarFilters
    let categories: [String]
    let accounts: [String]

    var body: some View {
        NavigationStack {
            Form {
                Section("Categoría") {
                    Picker("Categoría", selection: $filters.category) {
                        Text("Todas").tag(String?.none)
                        ForEach(categories, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                }
                Section("Cuenta o tarjeta") {
                    Picker("Cuenta", selection: $filters.account) {
                        Text("Todas").tag(String?.none)
                        ForEach(accounts, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                }
                Section("Tipo de gasto") {
                    Picker("Tipo", selection: $filters.expenseType) {
                        Text("Todos").tag(SpendingCalendarExpenseType?.none)
                        ForEach(SpendingCalendarExpenseType.allCases) { Text($0.rawValue).tag(Optional($0)) }
                    }
                }
                Section("Estado") {
                    Picker("Estado", selection: $filters.reviewStatus) {
                        Text("Todos").tag(SpendingCalendarReviewStatus?.none)
                        ForEach(SpendingCalendarReviewStatus.allCases) { Text($0.rawValue).tag(Optional($0)) }
                    }
                }
                Section("Comercio") {
                    TextField("Buscar descripción", text: $filters.merchantQuery)
                        .textInputAutocapitalization(.characters)
                }
                if !filters.isEmpty {
                    Section { Button("Limpiar todos los filtros", role: .destructive) { filters = SpendingCalendarFilters() } }
                }
            }
            .navigationTitle("Filtros")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SpendingPeriodPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var date: Date
    let mode: SpendingCalendarMode

    var body: some View {
        NavigationStack {
            DatePicker(mode.rawValue, selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Elegir \(mode.rawValue.lowercased())")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

private struct SpendingPeriodDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(FinanceStore.self) private var store
    let selection: SelectedSpendingPeriod
    let filters: SpendingCalendarFilters

    private var movements: [Movement] {
        let identifiers = Set(selection.movementIDs)
        return store.netExpenseMovements
            .filter { identifiers.contains($0.id) && spendingMovement($0, matches: filters) }
            .sorted { abs($0.amount) > abs($1.amount) }
    }

    private var total: Decimal { movements.reduce(0) { $0 + $1.expenseContribution } }
    private var categories: [SpendingBreakdown] {
        Dictionary(grouping: movements, by: { $0.category })
            .map { SpendingBreakdown(name: $0.key, total: $0.value.reduce(0) { $0 + $1.expenseContribution }) }
            .sorted { $0.total > $1.total }
    }
    private var accounts: [SpendingBreakdown] {
        Dictionary(grouping: movements, by: { $0.account })
            .map { SpendingBreakdown(name: $0.key, total: $0.value.reduce(0) { $0 + $1.expenseContribution }) }
            .sorted { $0.total > $1.total }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(total, format: .currency(code: "MXN").precision(.fractionLength(0)))
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .monospacedDigit()
                        Text(selection.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        Text("\(movements.count) movimiento(s)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                if !movements.isEmpty {
                    Section("Categorías principales") {
                        ForEach(categories.prefix(5)) { row in
                            LabeledContent(row.name, value: row.total.formatted(.currency(code: "MXN").precision(.fractionLength(0))))
                        }
                    }
                    Section("Cuentas principales") {
                        ForEach(accounts.prefix(5)) { row in
                            LabeledContent(row.name, value: row.total.formatted(.currency(code: "MXN").precision(.fractionLength(0))))
                        }
                    }
                    Section("Top 10 montos") {
                        ForEach(Array(movements.prefix(10))) { movement in
                            NavigationLink {
                                MovementDetailView(movement: movement)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(movement.title).lineLimit(1)
                                        Spacer()
                                        Text(movement.expenseContribution, format: .currency(code: "MXN").precision(.fractionLength(2))).monospacedDigit()
                                    }
                                    Text("\(movement.date.formatted(.dateTime.day().month(.abbreviated))) · \(movement.category) · \(movement.account)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(selection.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
        }
    }
}

private struct SpendingDayDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(FinanceStore.self) private var store
    let date: Date
    let movementIDs: [UUID]
    let filters: SpendingCalendarFilters
    let usesStableHistory: Bool

    private var filteredAllMovements: [Movement] {
        store.netExpenseMovements.filter { spendingMovement($0, matches: filters) }
    }

    private var movements: [Movement] {
        let identifiers = Set(movementIDs)
        return filteredAllMovements
            .filter { identifiers.contains($0.id) }
            .sorted { abs($0.amount) > abs($1.amount) }
    }

    private var expected: Decimal {
        let analytics = SpendingCalendarAnalytics(
            movements: filteredAllMovements,
            selectedDate: date,
            coveredDays: store.spendingCoveredDays(account: filters.account)
        )
        let weekday = analytics.calendar.component(.weekday, from: date)
        let benchmark = usesStableHistory ? analytics.historicalBenchmarkByWeekday : analytics.benchmarkByWeekday
        return benchmark[weekday, default: 0]
    }

    private var total: Decimal { movements.reduce(0) { $0 + $1.expenseContribution } }
    private var categoryTotals: [SpendingBreakdown] {
        Dictionary(grouping: movements, by: { $0.category })
            .map { SpendingBreakdown(name: $0.key, total: $0.value.reduce(0) { $0 + $1.expenseContribution }) }
            .sorted { $0.total > $1.total }
    }
    private var accountTotals: [SpendingBreakdown] {
        Dictionary(grouping: movements, by: { $0.account })
            .map { SpendingBreakdown(name: $0.key, total: $0.value.reduce(0) { $0 + $1.expenseContribution }) }
            .sorted { $0.total > $1.total }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(total, format: .currency(code: "MXN").precision(.fractionLength(0)))
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        Text(expected > 0 ? comparison : "Sin promedio histórico suficiente")
                            .foregroundStyle(total > expected ? Color.marcelitoDanger : Color.marcelitoSuccess)
                        Text("\(movements.count) movimiento(s)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                if !categoryTotals.isEmpty {
                    Section("Por categoría") {
                        ForEach(categoryTotals) { row in LabeledContent(row.name, value: row.total.formatted(.currency(code: "MXN").precision(.fractionLength(0)))) }
                    }
                    Section("Por cuenta") {
                        ForEach(accountTotals) { row in LabeledContent(row.name, value: row.total.formatted(.currency(code: "MXN").precision(.fractionLength(0)))) }
                    }
                    Section(movements.count > 10 ? "Top 10 montos" : "Movimientos") {
                        ForEach(Array(movements.prefix(10))) { movement in
                            NavigationLink {
                                MovementDetailView(movement: movement)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(movement.title).lineLimit(1)
                                        Spacer()
                                        Text(movement.expenseContribution, format: .currency(code: "MXN").precision(.fractionLength(2))).monospacedDigit()
                                    }
                                    Text("\(movement.category) · \(movement.account)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if movements.count > 10 {
                        Section("Otros movimientos") {
                            ForEach(Array(movements.dropFirst(10))) { movement in
                                NavigationLink {
                                    MovementDetailView(movement: movement)
                                } label: {
                                    HStack {
                                        Text(movement.title).lineLimit(1)
                                        Spacer()
                                        Text(movement.expenseContribution, format: .currency(code: "MXN").precision(.fractionLength(2))).monospacedDigit()
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
        }
    }

    private var comparison: String {
        let difference = total - expected
        return difference >= 0
            ? "\(abs(difference).formatted(.currency(code: "MXN").precision(.fractionLength(0)))) arriba del promedio"
            : "\(abs(difference).formatted(.currency(code: "MXN").precision(.fractionLength(0)))) abajo del promedio"
    }
}
