import XCTest
@testable import Marcelito

/// Synthetic month: city charges, a trip with its flight, transfers read by
/// concept, a repeated gym pass and an unexplained transfer.
final class MonthSpendingStoryTests: XCTestCase {
    private func day(_ value: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: value, hour: 12))!
    }

    private func charge(_ value: Int, _ title: String, _ amount: Decimal, account: String = "Tarjeta", category: String = "Otros / Por revisar", raw: String? = nil) -> Movement {
        Movement(date: day(value), title: title, account: account, category: category, amount: -amount, flow: .expense, kind: .purchase, rawDescription: raw)
    }

    private func story(_ rows: [Movement]) -> MonthSpendingStory {
        MonthSpendingStory.build(rows: rows, history: rows, category: \.category)
    }

    func testTripCollectsCityChargesAndTheFlightBeforeIt() throws {
        let rows = [
            charge(2, "CAFE UNO CIUDAD DE MEX", 100, category: "Restaurantes y bares"),
            charge(3, "TACOS DOS CIUDAD DE MEX", 120, category: "Restaurantes y bares"),
            charge(4, "TIENDA TRES MEXICO DF", 80, category: "Tiendita"),
            charge(6, "SUPER CUATRO BENITO JUAREZ", 60, category: "Tiendita"),
            charge(5, "VOLARIS CIUDAD DE MEXIC", 2_000, category: "Viajes"),
            charge(10, "REST NORTE MONTERREY NL", 500, category: "Restaurantes y bares"),
            charge(11, "ESTADIO SN NICOLAS DE", 300),
            charge(11, "FARMACIA SUC GUADALUPE NVO.", 150, category: "Salud"),
            charge(20, "CLOUDFLARE SAN FRANCISCO", 90, category: "Software y suscripciones")
        ]
        let story = story(rows)
        let trip = try XCTUnwrap(story.trips.first)
        XCTAssertEqual(story.trips.count, 1)
        XCTAssertEqual(trip.city, "Monterrey")
        XCTAssertEqual(trip.local.count, 3)
        XCTAssertEqual(trip.travel.map(\.amount), [2_000])
        XCTAssertEqual(trip.total, 2_950)
        // Nothing is counted twice: trips plus groups add up to the month.
        XCTAssertEqual(story.tripsTotal + story.groups.reduce(0) { $0 + $1.total }, story.total)
        XCTAssertFalse(story.groups.contains { $0.name == "Viajes" })
        XCTAssertTrue(story.summary.contains { $0.contains("Monterrey") })
    }

    func testTransfersAreReadByConceptAndUnexplainedOnesAreFlagged() {
        let rows = [
            charge(3, "PAGO TRANSFERENCIA SPEI HORA 19:05:17", 900, account: "Banco", category: "Transferencias a terceros",
                   raw: "PAGO TRANSFERENCIA SPEI HORA 19:05:17 ENVIADO A BANCO AL CLIENTE PERSONA UNO (1) CONCEPTO TIGRES VS EQUIPO"),
            charge(4, "PAGO TRANSF RAPIDA SPEI TRANSFERENCIA A PERSONA DOS RFC", 4_000, account: "Banco", category: "Transferencias a terceros",
                   raw: "PAGO TRANSF RAPIDA SPEI TRANSFERENCIA A PERSONA DOS RFC ABC IVA 0.0 REF 123"),
            charge(5, "PAGO TRANSFERENCIA SPEI HORA 12:08:53", 1_400, account: "Banco", category: "Transferencias a terceros",
                   raw: "PAGO TRANSFERENCIA SPEI HORA 12:08:53 AL CLIENTE PERSONA TRES (1) CONCEPTO TRANSFERENCIA A TOTAL PASS"),
            charge(6, "TOTAL PASS SAPI DE CV MEXICO CITY", 1_700),
            charge(7, "OXXO CENTRO", 50, category: "Tiendita")
        ]
        let story = story(rows)
        XCTAssertEqual(story.groups.first { $0.name == "Entretenimiento" }?.total, 900)
        XCTAssertEqual(story.groups.first { $0.name == "Deporte" }?.total, 3_100)
        XCTAssertEqual(story.groups.first { $0.name == "Transferencias a personas" }?.total, 4_000)
        XCTAssertEqual(MonthSpendingStory.line(rows[0]).title, "Transferencia: Tigres Vs Equipo · Persona Uno")
        XCTAssertEqual(MonthSpendingStory.line(rows[1]).title, "Transferencia: Persona Dos")
        XCTAssertTrue(story.alerts.contains { $0.id == "repeat-TotalPass" })
        XCTAssertTrue(story.alerts.contains { $0.movementIDs == [rows[1].id] })
        XCTAssertFalse(story.alerts.contains { $0.movementIDs == [rows[0].id] })
        XCTAssertTrue(story.summary.contains { $0.contains("cargo más grande") })
        // The unexplained $4,000 transfer is not "day to day" spending.
        XCTAssertTrue(story.summary.contains { $0.contains("lo que más pesa es deporte") })
    }

    func testCoverageAcceptsPeriodsThatSpellBothDays() {
        XCTAssertTrue(FinanceStore.periodNamesBothDays("16-sep-2026 al 15-oct-2026"))
        XCTAssertTrue(FinanceStore.periodNamesBothDays("del 28 de septiembre al 27 de octubre de 2026 dias del periodo: 30 dias"))
        XCTAssertFalse(FinanceStore.periodNamesBothDays("Octubre 2026"))
        let range = FinanceStore.statementRange(from: "16-sep-2026 al 15-oct-2026")
        XCTAssertEqual(range.map { Calendar(identifier: .gregorian).component(.day, from: $0.upperBound) }, 15)
    }

    func testBankNoiseIsRemovedFromTitlesAndConcepts() {
        XCTAssertEqual(MonthSpendingStory.cleanTitle("0025638 CONSUMO LOCAL AJENO TERMINACION 1234 07OCT26 SEM 980701STA 7 ELEVEN CENTRO MEXICO DF"), "7 ELEVEN CENTRO MEXICO DF")
        XCTAssertEqual(MonthSpendingStory.cleanTitle("0024741 DISP ATM PROPIO TARJ DEB X1 TERMINACION 1234 22SEP26"), "Retiro en cajero")
        let row = charge(9, "PAGO TRANSF RAPIDA SPEI", 300, raw: "PAGO TRANSF RAPIDA SPEI N TIENDA ABC9802121F4 IVA 0.0 REF 1")
        XCTAssertEqual(MonthSpendingStory.transferConcept(row), "N Tienda")
        let other = charge(9, "PAGO TRANSF RAPIDA SPEI", 300, raw: "CONCEPTO TRANSFERENCIA A INSTITUTO DEL DEPORTE 14,782.59 DE")
        XCTAssertEqual(MonthSpendingStory.transferConcept(other), "Instituto del Deporte")
    }

    func testCoverageNotesMakeTheSummaryPartial() {
        let story = MonthSpendingStory.build(rows: [charge(2, "OXXO CENTRO", 50, category: "Tiendita")], history: [], category: \.category,
                                             coverageNotes: ["Banco: datos hasta el 15 mar."])
        XCTAssertTrue(story.summary[0].hasPrefix("Llevas"))
        XCTAssertEqual(story.alerts.map(\.text), ["Banco: datos hasta el 15 mar."])
    }
}
