import XCTest
@testable import Marcelito

final class MovementListFilterTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Mexico_City")!
        return value
    }

    private func date(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    private func statement(_ bank: String) -> StatementRecord {
        StatementRecord(id: UUID(), source: bank, period: "15/06/2026 - 14/07/2026",
            fileName: "fixture.pdf", importedAt: date(7, 15), transactionCount: 6, requiresReview: false)
    }

    private func movement(_ statement: StatementRecord, month: Int = 6) -> Movement {
        var row = Movement(date: date(month, 20), title: "SPEI ENVIADO", account: statement.source,
            category: "Transferencia", amount: -3000, flow: .transfer, kind: .bankTransfer)
        row.statementId = statement.id
        return row
    }

    func testBankAndExactStatementExcludeOtherBanksAndOtherCuts() {
        let bbva = statement("BBVA"), otherCut = statement("BBVA"), santander = statement("Santander")
        let filter = MovementListFilter(bank: "BBVA", statementID: bbva.id)
        XCTAssertTrue(filter.includes(movement(bbva), statement: bbva, calendar: calendar))
        XCTAssertFalse(filter.includes(movement(otherCut), statement: otherCut, calendar: calendar))
        XCTAssertFalse(filter.includes(movement(santander), statement: santander, calendar: calendar))
    }

    func testCalendarMonthIsMovementDateRatherThanStatementPeriod() {
        let bbva = statement("BBVA")
        let month = MovementListFilter(bank: "BBVA", month: date(6, 1), statementID: bbva.id)
        XCTAssertTrue(month.includes(movement(bbva), statement: bbva, calendar: calendar))
        XCTAssertFalse(month.includes(movement(bbva, month: 7), statement: bbva, calendar: calendar))
        let cut = MovementListFilter(statementID: bbva.id)
        XCTAssertTrue(cut.includes(movement(bbva, month: 7), statement: bbva, calendar: calendar))
    }

    func testSearchCombinesWithFiltersAndDoesNotChangeAccounting() {
        let bbva = statement("BBVA"), santander = statement("Santander")
        let filter = MovementListFilter(bank: "BBVA", month: date(6, 1), query: "SPEI")
        let row = movement(bbva)
        XCTAssertTrue(filter.includes(row, statement: bbva, calendar: calendar))
        XCTAssertFalse(filter.includes(movement(santander), statement: santander, calendar: calendar))
        XCTAssertEqual(row.amount, -3000)
        XCTAssertEqual(row.kind, .bankTransfer)
        XCTAssertEqual(row.category, "Transferencia")
    }

    func testNoSelectionIncludesAllAndManualRowsUseAccount() {
        let bbva = statement("BBVA")
        var row = movement(bbva)
        row.statementId = nil
        XCTAssertTrue(MovementListFilter().includes(row, statement: nil, calendar: calendar))
        XCTAssertTrue(MovementListFilter(bank: "BBVA").includes(row, statement: nil, calendar: calendar))
        XCTAssertFalse(MovementListFilter(statementID: bbva.id).includes(row, statement: nil, calendar: calendar))
    }
}
