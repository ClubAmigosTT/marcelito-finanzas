import Charts
import Foundation
import SwiftUI

enum SpendingCalendarMode: String, CaseIterable, Identifiable {
    case week = "Semana"
    case history = "Histórico"

    var id: String { rawValue }
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

    var actualTotal: Decimal { points.reduce(0) { $0 + $1.actual } }
    var expectedTotal: Decimal { points.prefix(comparableDayCount).reduce(0) { $0 + $1.historicalAverage } }
    var dailyAverage: Decimal { comparableDayCount > 0 ? actualTotal / Decimal(comparableDayCount) : 0 }
    var delta: Decimal { actualTotal - expectedTotal }
    var deltaPercent: Double? {
        guard expectedTotal > 0 else { return nil }
        return NSDecimalNumber(decimal: delta / expectedTotal).doubleValue * 100
    }
    var highest: SpendingDayPoint? { points.max { $0.actual < $1.actual } }
    var lowest: SpendingDayPoint? { points.min { $0.actual < $1.actual } }
}

struct SpendingHistoryDay: Identifiable {
    let date: Date
    let total: Decimal
    let expected: Decimal
    let movements: [Movement]

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

    init(
        movements: [Movement],
        selectedDate: Date,
        now: Date = .now,
        calendar suppliedCalendar: Calendar? = nil,
        coverageStart: Date? = nil,
        coverageEnd: Date? = nil
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
    }

    var selectedWeekStart: Date {
        calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start ?? calendar.startOfDay(for: selectedDate)
    }

    var selectedWeekEnd: Date {
        calendar.date(byAdding: .day, value: 7, to: selectedWeekStart) ?? selectedWeekStart
    }

    var coverageStart: Date? { coverageStartOverride ?? movements.map(\.date).min().map { calendar.startOfDay(for: $0) } }
    var coverageEnd: Date? { coverageEndOverride ?? movements.map(\.date).max().map { calendar.startOfDay(for: $0) } }

    var dailyMovements: [Date: [Movement]] {
        Dictionary(grouping: movements) { calendar.startOfDay(for: $0.date) }
    }

    private func averagesByWeekday(excludingSelectedWeek: Bool) -> [Int: Decimal] {
        guard let first = coverageStart, let last = coverageEnd else { return [:] }
        var totals: [Int: Decimal] = [:]
        var counts: [Int: Int] = [:]
        var cursor = first
        while cursor <= last {
            let isSelectedWeek = excludingSelectedWeek && cursor >= selectedWeekStart && cursor < selectedWeekEnd
            if !isSelectedWeek {
                let weekday = calendar.component(.weekday, from: cursor)
                let total = dailyMovements[cursor, default: []].reduce(Decimal(0)) { $0 + abs($1.amount) }
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
        guard let first = coverageStart, let last = coverageEnd else { return 0 }
        return max(0, (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1 - 7)
    }

    var summary: SpendingWeekSummary {
        let benchmark = benchmarkByWeekday
        let points = (0..<7).compactMap { offset -> SpendingDayPoint? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: selectedWeekStart) else { return nil }
            let rows = dailyMovements[day, default: []]
            let weekday = calendar.component(.weekday, from: day)
            return SpendingDayPoint(
                date: day,
                actual: rows.reduce(0) { $0 + abs($1.amount) },
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
        return SpendingWeekSummary(start: selectedWeekStart, endExclusive: selectedWeekEnd, points: points, comparableDayCount: comparableDays)
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
                total: rows.reduce(0) { $0 + abs($1.amount) },
                expected: benchmark[weekday, default: 0],
                movements: rows.sorted { abs($0.amount) > abs($1.amount) }
            ))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? last.addingTimeInterval(1)
        }
        return output
    }

    var weekdayAverages: [SpendingDayPoint] {
        let benchmark = historicalBenchmarkByWeekday
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: selectedWeekStart) else { return nil }
            return SpendingDayPoint(
                date: day,
                actual: benchmark[calendar.component(.weekday, from: day), default: 0],
                historicalAverage: 0,
                movementCount: 0
            )
        }
    }

    var historicalDailyAverage: Decimal {
        guard !historyDays.isEmpty else { return 0 }
        return historyDays.reduce(0) { $0 + $1.total } / Decimal(historyDays.count)
    }

    var historicalMedian: Decimal {
        let values = historyDays.map(\.total).sorted()
        guard !values.isEmpty else { return 0 }
        let middle = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }

    var highestAverageWeekday: SpendingDayPoint? { weekdayAverages.max { $0.actual < $1.actual } }
    var lowestAverageWeekday: SpendingDayPoint? { weekdayAverages.min { $0.actual < $1.actual } }

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
                .reduce(Decimal(0)) { $0 + abs($1.amount) }
            return SpendingWeekTrend(start: start, total: total)
        }
    }

    var anomalousDays: [SpendingHistoryDay] {
        Array(historyDays
            .filter { $0.total > 0 && $0.expected > 0 }
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
        store.realExpenseMovements.filter { spendingMovement($0, matches: filters) }
    }

    private var analytics: SpendingCalendarAnalytics {
        SpendingCalendarAnalytics(
            movements: filteredMovements,
            selectedDate: selectedDate,
            coverageStart: store.realExpenseMovements.map(\.date).min(),
            coverageEnd: store.realExpenseMovements.map(\.date).max()
        )
    }

    private var categories: [String] { Array(Set(store.realExpenseMovements.map(\.category))).sorted() }
    private var accounts: [String] { Array(Set(store.realExpenseMovements.map(\.account))).sorted() }

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
                } else if store.realExpenseMovements.isEmpty {
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
                            } else if mode == .week {
                                weekView
                            } else {
                                historyView
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
                SpendingWeekPickerView(date: $selectedDate)
            }
            .sheet(item: $selectedDay) { selection in
                SpendingDayDetailView(
                    date: selection.date,
                    movementIDs: analytics.movements(on: selection.date).map(\.id),
                    filters: filters,
                    usesStableHistory: mode == .history
                )
            }
            .sheet(item: $selectedPeriod) { selection in
                SpendingPeriodDetailView(selection: selection, filters: filters)
            }
            .onAppear {
                guard !didSelectInitialDate else { return }
                selectedDate = store.realExpenseMovements.map(\.date).max() ?? .now
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
            if let first = store.realExpenseMovements.map(\.date).min(),
               let last = store.realExpenseMovements.map(\.date).max() {
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

    private var weekView: some View {
        let summary = analytics.summary
        return Group {
            weekNavigator(summary)
            weekHero(summary)
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
                    SpendingMetricTile(title: "Promedio diario", value: analytics.historicalDailyAverage.formatted(.currency(code: "MXN").precision(.fractionLength(0))))
                    SpendingMetricTile(title: "Mediana diaria", value: analytics.historicalMedian.formatted(.currency(code: "MXN").precision(.fractionLength(0))))
                    SpendingMetricTile(title: "Cobertura", value: "\(analytics.historyDays.count) días")
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
            .map { (name: $0.key, total: $0.value.reduce(0) { $0 + abs($1.amount) }) }
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
                            .fill(heatColor(day.total))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(Text(day.date.formatted(.dateTime.day())).font(.system(size: 7, weight: .medium)).foregroundStyle(day.total > maximum / 2 ? .white : Color.marcelitoNavy))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(day.date.formatted(date: .long, time: .omitted)), \(day.total.formatted(.currency(code: "MXN")))")
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
                Text("Toca un día para ver detalles").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .marcelitoCard(radius: 20, padding: 14)
    }

    private func heatColor(_ total: Decimal) -> Color {
        guard maximum > 0 else { return Color.marcelitoLine.opacity(0.35) }
        let ratio = min(1, NSDecimalNumber(decimal: total / maximum).doubleValue)
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

private struct SpendingWeekPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var date: Date

    var body: some View {
        NavigationStack {
            DatePicker("Semana", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Elegir semana")
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
        return store.realExpenseMovements
            .filter { identifiers.contains($0.id) && spendingMovement($0, matches: filters) }
            .sorted { abs($0.amount) > abs($1.amount) }
    }

    private var total: Decimal { movements.reduce(0) { $0 + abs($1.amount) } }
    private var categories: [SpendingBreakdown] {
        Dictionary(grouping: movements, by: { $0.category })
            .map { SpendingBreakdown(name: $0.key, total: $0.value.reduce(0) { $0 + abs($1.amount) }) }
            .sorted { $0.total > $1.total }
    }
    private var accounts: [SpendingBreakdown] {
        Dictionary(grouping: movements, by: { $0.account })
            .map { SpendingBreakdown(name: $0.key, total: $0.value.reduce(0) { $0 + abs($1.amount) }) }
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
                                        Text(abs(movement.amount), format: .currency(code: "MXN").precision(.fractionLength(2))).monospacedDigit()
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
        store.realExpenseMovements.filter { spendingMovement($0, matches: filters) }
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
            coverageStart: store.realExpenseMovements.map(\.date).min(),
            coverageEnd: store.realExpenseMovements.map(\.date).max()
        )
        let weekday = analytics.calendar.component(.weekday, from: date)
        let benchmark = usesStableHistory ? analytics.historicalBenchmarkByWeekday : analytics.benchmarkByWeekday
        return benchmark[weekday, default: 0]
    }

    private var total: Decimal { movements.reduce(0) { $0 + abs($1.amount) } }
    private var categoryTotals: [SpendingBreakdown] {
        Dictionary(grouping: movements, by: { $0.category })
            .map { SpendingBreakdown(name: $0.key, total: $0.value.reduce(0) { $0 + abs($1.amount) }) }
            .sorted { $0.total > $1.total }
    }
    private var accountTotals: [SpendingBreakdown] {
        Dictionary(grouping: movements, by: { $0.account })
            .map { SpendingBreakdown(name: $0.key, total: $0.value.reduce(0) { $0 + abs($1.amount) }) }
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
                                        Text(abs(movement.amount), format: .currency(code: "MXN").precision(.fractionLength(2))).monospacedDigit()
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
                                        Text(abs(movement.amount), format: .currency(code: "MXN").precision(.fractionLength(2))).monospacedDigit()
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
