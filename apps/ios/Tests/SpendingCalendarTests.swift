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

    private func expense(_ day: Date, amount: Decimal, title: String = "Gasto") -> Movement {
        Movement(
            date: day,
            title: title,
            account: "BBVA",
            category: "Tiendita",
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
            calendar: calendar
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
            coverageEnd: date(2026, 7, 26)
        )

        let monday = calendar.component(.weekday, from: date(2026, 7, 13))
        XCTAssertEqual(analytics.benchmarkByWeekday[monday], 70)
    }
}
