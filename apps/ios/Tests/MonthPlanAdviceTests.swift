import XCTest
@testable import Marcelito

/// Synthetic history: three ordinary months, one with a trip and a one-off.
final class MonthPlanAdviceTests: XCTestCase {
    private let calendar = Calendar.current
    private func date(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }
    private func charge(_ month: Int, _ day: Int, _ title: String, _ amount: Decimal, _ category: String, raw: String? = nil) -> Movement {
        Movement(date: date(month, day), title: title, account: "Tarjeta", category: category, amount: -amount, flow: .expense, kind: .purchase, rawDescription: raw)
    }

    private var rows: [Movement] {
        var result: [Movement] = []
        for month in 1...3 {
            result.append(charge(month, 5, "CAFE CIUDAD DE MEX", 1_000 + Decimal(month) * 100, "Restaurantes y bares"))
            result.append(charge(month, 20, "TACOS CIUDAD DE MEX", 1_000, "Restaurantes y bares"))
            result.append(charge(month, 2, "OXXO MEXICO DF", 300, "Tiendita"))
            result.append(charge(month, 3, "OXXO BENITO JUAREZ", 100, "Tiendita"))
        }
        // March: a trip and an unexplained transfer.
        result.append(charge(3, 1, "VOLARIS CIUDAD DE MEXIC", 3_000, "Viajes"))
        result.append(charge(3, 10, "REST NORTE MONTERREY NL", 900, "Restaurantes y bares"))
        result.append(charge(3, 11, "ESTADIO SN NICOLAS DE", 400, "Entretenimiento"))
        result.append(charge(3, 11, "FARMACIA GUADALUPE NVO.", 200, "Salud"))
        result.append(charge(3, 15, "PAGO TRANSF RAPIDA SPEI", 5_000, "Transferencias a terceros",
                             raw: "PAGO TRANSF RAPIDA SPEI TRANSFERENCIA A PERSONA UNO RFC ABC IVA 0.0"))
        return result
    }

    private func advice() -> MonthPlanAdvice {
        let all = rows
        return MonthPlanAdvice.build(
            month: date(4, 1), sampleMonths: [date(3, 1), date(2, 1), date(1, 1)], partialHistory: false,
            previousMonth: date(3, 1),
            rows: { month in all.filter { self.calendar.isDate($0.date, equalTo: month, toGranularity: .month) } },
            history: all, category: \.category, isOneOff: { _ in false })
    }

    func testTypicalMonthLeavesOutTripsAndOneOffs() {
        let advice = advice()
        // Median of 2,100 / 2,200 / 2,300; the Monterrey dinner is the trip.
        XCTAssertEqual(advice.typical["Restaurantes y bares"], 2_200)
        XCTAssertEqual(advice.typical["Tiendita"], 400)
        XCTAssertNil(advice.typical["Viajes"])
        XCTAssertNil(advice.typical["Transferencias a terceros"])
        XCTAssertEqual(advice.tripAverage, 4_500)
        XCTAssertEqual(advice.tripMonths, 1)
        let unusual = advice.unusualLastMonth
        XCTAssertTrue(unusual.contains { $0.isTrip && $0.title == "Viaje a Monterrey" && $0.amount == 4_500 })
        XCTAssertTrue(unusual.contains { $0.amount == 5_000 && !$0.isTrip })
    }

    func testNextPlanMovesGraduallyFromTheLastLimit() {
        let advice = advice()
        // Last month's limit 3,000 and real ordinary spend 2,300 → 2,790 → 2,800.
        let suggestion = advice.suggested(previousLimits: ["Restaurantes y bares": 3_000])
        XCTAssertEqual(suggestion["Restaurantes y bares"], 2_800)
        XCTAssertEqual(suggestion["Tiendita"], 400)
        XCTAssertNil(suggestion["Viajes"])
    }

    func testPaceFollowsWhenACategoryIsUsuallySpent() {
        let advice = advice()
        // Tiendita: 75% happens on day 2 every month.
        XCTAssertEqual(advice.expectedFraction(category: "Tiendita", day: 2, daysInMonth: 30), 0.75, accuracy: 0.001)
        XCTAssertEqual(advice.expectedFraction(category: "Sin historial", day: 15, daysInMonth: 30), 0.5, accuracy: 0.001)
    }

    func testPaceAlertsOnlyFlagCategoriesClearlyAhead() {
        let alerts = advice().paceAlerts(
            limits: ["Tiendita": 400, "Restaurantes y bares": 2_200],
            spent: ["Tiendita": 700, "Restaurantes y bares": 200], day: 2, daysInMonth: 30)
        // Tiendita usually has 75% (300) spent by day 2; 700 is well ahead.
        XCTAssertEqual(alerts.map(\.category), ["Tiendita"])
        XCTAssertEqual(alerts.first?.expected, 300)
        let small = advice().paceAlerts(limits: ["Sin historial": 3_000], spent: ["Sin historial": 1_700], day: 15, daysInMonth: 30)
        XCTAssertTrue(small.isEmpty, "200 over a linear 1,500 is not worth a warning")
    }
}
