import XCTest
@testable import Marcelito

final class SpendingCalendarTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .iso8601)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func expense(_ day: Date, amount: Decimal, title: String = "Gasto", category: String = "Tiendita") -> Movement {
        Movement(
            date: day,
            title: title,
            account: "BBVA",
            category: category,
            amount: -abs(amount),
            flow: .expense,
            kind: .purchase
        )
    }

    func testSelectedWeekUsesSevenCalendarDaysIncludingZeroSpendDays() {
        let rows = [
            expense(date(2026, 7, 6), amount: 70),
            expense(date(2026, 7, 13), amount: 140),
            expense(date(2026, 7, 19), amount: 1),
        ]
        let analytics = SpendingCalendarAnalytics(
            movements: rows,
            selectedDate: date(2026, 7, 13),
            now: date(2026, 8, 1),
            calendar: calendar,
            coveredDays: Set((0..<14).map { calendar.date(byAdding: .day, value: $0, to: date(2026, 7, 6))! })
        )

        XCTAssertEqual(analytics.summary.points.count, 7)
        XCTAssertEqual(analytics.summary.points[0].actual, 140)
        XCTAssertEqual(analytics.summary.points[1].actual, 0)
        XCTAssertEqual(analytics.summary.points[0].historicalAverage, 70)
        XCTAssertEqual(analytics.summary.comparableDayCount, 7)
    }

    func testHistoricalProfileDoesNotChangeWithSelectedWeek() {
        let rows = [
            expense(date(2026, 7, 6), amount: 70),
            expense(date(2026, 7, 13), amount: 140),
            expense(date(2026, 7, 20), amount: 210),
        ]
        let first = SpendingCalendarAnalytics(movements: rows, selectedDate: date(2026, 7, 6), calendar: calendar)
        let second = SpendingCalendarAnalytics(movements: rows, selectedDate: date(2026, 7, 20), calendar: calendar)

        XCTAssertEqual(first.historicalBenchmarkByWeekday, second.historicalBenchmarkByWeekday)
        XCTAssertEqual(first.historicalDailyAverage, second.historicalDailyAverage)
        XCTAssertEqual(first.historicalMedian, second.historicalMedian)
    }

    func testCurrentWeekComparesOnlyElapsedDays() {
        let monday = date(2026, 9, 7)
        let analytics = SpendingCalendarAnalytics(
            movements: [expense(monday, amount: 100)],
            selectedDate: monday,
            now: date(2026, 9, 9),
            calendar: calendar
        )

        XCTAssertEqual(analytics.summary.comparableDayCount, 3)
        XCTAssertEqual(NSDecimalNumber(decimal: analytics.summary.dailyAverage).doubleValue, 33.333, accuracy: 0.001)
    }

    func testFilteredBenchmarkKeepsFullLedgerCoverageAndCountsZeroDays() {
        let filteredRows = [expense(date(2026, 7, 13), amount: 140, title: "Restaurante")]
        let analytics = SpendingCalendarAnalytics(
            movements: filteredRows,
            selectedDate: date(2026, 7, 20),
            now: date(2026, 8, 1),
            calendar: calendar,
            coverageStart: date(2026, 7, 6),
            coverageEnd: date(2026, 7, 26),
            coveredDays: Set((0..<21).map { calendar.date(byAdding: .day, value: $0, to: date(2026, 7, 6))! })
        )

        let monday = calendar.component(.weekday, from: date(2026, 7, 13))
        XCTAssertEqual(analytics.benchmarkByWeekday[monday], 70)
    }

    func testDayUsesHistoricalCoveredDaysIncludingZeroSpendDays() {
        let first = date(2026, 9, 1)
        let selected = date(2026, 9, 4)
        let analytics = SpendingCalendarAnalytics(
            movements: [expense(first, amount: 100), expense(selected, amount: 200)],
            selectedDate: selected,
            now: date(2026, 9, 13),
            calendar: calendar,
            coveredDays: Set((0..<4).map { calendar.date(byAdding: .day, value: $0, to: first)! })
        )

        let result = analytics.periodAnalysis(for: .day)
        XCTAssertEqual(result.total, 200)
        XCTAssertEqual(result.expectedTotal, Decimal(100) / 3)
        XCTAssertEqual(result.movementCount, 1)
        XCTAssertEqual(result.ticketAverage, 200)
    }

    func testCurrentWeekUsesSameElapsedDaysFromPriorWeeks() {
        let selected = date(2026, 9, 7)
        var rows: [Movement] = [expense(selected, amount: 300)]
        rows += [expense(date(2026, 8, 24), amount: 100), expense(date(2026, 8, 31), amount: 200)]
        let coverageStart = date(2026, 8, 24)
        let analytics = SpendingCalendarAnalytics(
            movements: rows,
            selectedDate: selected,
            now: date(2026, 9, 9),
            calendar: calendar,
            coveredDays: Set((0..<17).map { calendar.date(byAdding: .day, value: $0, to: coverageStart)! })
        )

        let result = analytics.periodAnalysis(for: .week)
        XCTAssertEqual(result.observedDayCount, 3)
        XCTAssertEqual(result.expectedTotal, 150)
        XCTAssertEqual(result.total, 300)
        XCTAssertEqual(result.deltaPercent ?? 0, 100, accuracy: 0.001)
    }

    func testIncompleteMonthComparesOnlySameNumberOfDays() {
        let august = date(2026, 8, 1)
        let september = date(2026, 9, 1)
        let rows = [
            expense(date(2026, 8, 2), amount: 80),
            expense(date(2026, 8, 12), amount: 9_000),
            expense(date(2026, 9, 2), amount: 100),
        ]
        let analytics = SpendingCalendarAnalytics(
            movements: rows,
            selectedDate: september,
            now: date(2026, 9, 5),
            calendar: calendar,
            coveredDays: Set((0..<36).map { calendar.date(byAdding: .day, value: $0, to: august)! })
        )

        let result = analytics.periodAnalysis(for: .month)
        XCTAssertEqual(result.observedDayCount, 5)
        XCTAssertEqual(result.expectedTotal, 80)
        XCTAssertEqual(result.total, 100)
    }

    func testCategorySharesAndExplanationReconcileToComparableTotals() {
        let previousWeek = date(2026, 8, 31)
        let selectedWeek = date(2026, 9, 7)
        let rows = [
            expense(previousWeek, amount: 100, category: "Restaurantes"),
            expense(calendar.date(byAdding: .day, value: 1, to: previousWeek)!, amount: 50, category: "Viajes"),
            expense(selectedWeek, amount: 250, category: "Restaurantes"),
            expense(calendar.date(byAdding: .day, value: 1, to: selectedWeek)!, amount: 25, category: "Viajes"),
        ]
        let analytics = SpendingCalendarAnalytics(
            movements: rows,
            selectedDate: selectedWeek,
            now: date(2026, 9, 13),
            calendar: calendar,
            coveredDays: Set((0..<14).map { calendar.date(byAdding: .day, value: $0, to: previousWeek)! })
        )

        let result = analytics.periodAnalysis(for: .week)
        XCTAssertEqual(result.categories.reduce(Decimal(0)) { $0 + $1.total }, result.total)
        XCTAssertEqual(result.expectedCategoryTotals.values.reduce(Decimal(0), +), result.expectedTotal)
        XCTAssertEqual(result.explanations.reduce(Decimal(0)) { $0 + $1.delta }, result.delta)
        XCTAssertEqual(result.categories.first?.name, "Restaurantes")
    }

    func testMonthDrillsIntoCalendarWeeksAndWeekIntoSevenDays() {
        let selected = date(2026, 9, 13)
        let analytics = SpendingCalendarAnalytics(movements: [], selectedDate: selected, now: selected, calendar: calendar)
        let monthChildren = analytics.childRanges(for: .month)
        XCTAssertFalse(monthChildren.isEmpty)
        XCTAssertEqual(monthChildren.first?.start, date(2026, 9, 1))
        XCTAssertEqual(monthChildren.last?.endExclusive, date(2026, 10, 1))
        XCTAssertEqual(analytics.childRanges(for: .week).count, 7)
        XCTAssertTrue(analytics.childRanges(for: .day).isEmpty)
    }
}
