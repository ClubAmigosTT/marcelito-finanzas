import Foundation
import XCTest
#if canImport(Marcelito)
@testable import Marcelito
#endif

final class RecurringPatternTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private func row(_ month: Int, _ day: Int, _ amount: Decimal = 500, year: Int = 2026) -> RecurringObservation {
        RecurringObservation(date: calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!, amount: amount)
    }
    func testFrequentShopsWithoutStableAmountsAreNotFixedExpenses() {
        XCTAssertNil(RecurringPattern.detect([row(6, 2, 100), row(6, 8, 40), row(7, 20, 90), row(7, 26, 50)], calendar: calendar))
    }
    func testSameTicketWithoutPeriodicDatesIsNotEnough() {
        XCTAssertNil(RecurringPattern.detect([row(6, 1), row(6, 2), row(7, 3), row(7, 4)], calendar: calendar))
    }
    func testThreeMonthlyChargesRetainTheirEvidence() {
        let rows = [row(6, 10), row(7, 10, 510), row(8, 10, 490)]
        let found = RecurringPattern.detect(rows, calendar: calendar)
        XCTAssertEqual(found?.cadence, .monthly); XCTAssertEqual(found?.amount, 500)
        XCTAssertEqual(found?.observations.count, 3)
    }
    func testMonthEndsAndShortFebruaryRemainMonthly() {
        XCTAssertEqual(RecurringPattern.detect([row(1, 31), row(2, 28), row(3, 31)], calendar: calendar)?.cadence, .monthly)
    }
    func testMissingStatementDoesNotTurnMonthlyBillIntoFortnightly() {
        let found = RecurringPattern.detect([row(6, 10), row(7, 10), row(9, 10)], calendar: calendar)
        XCTAssertEqual(found?.cadence, .monthly); XCTAssertEqual(found?.observations.count, 3)
    }
    func testBonusDoesNotEraseSupportedFortnightlySalary() {
        let rows = [row(7, 15, 16500), row(7, 31, 16600), row(8, 14, 16400), row(8, 31, 16500), row(8, 31, 40000)]
        let found = RecurringPattern.detect(rows, calendar: calendar)
        XCTAssertEqual(found?.cadence, .fortnightly); XCTAssertEqual(found?.amount, 16500)
        XCTAssertEqual(found?.observations.count, 4)
    }
    func testMinorityOfMatchingPaymentsDoesNotCreateSuggestion() {
        XCTAssertNil(RecurringPattern.detect([row(6, 10, 500), row(7, 10, 500), row(8, 10, 500), row(9, 10, 2000), row(10, 10, 3000)], calendar: calendar))
    }
    func testWeeklyPatternNeedsFourPaymentsAndTwoMonths() {
        XCTAssertEqual(RecurringPattern.detect([row(6, 24), row(7, 1), row(7, 8), row(7, 15)], calendar: calendar)?.cadence, .weekly)
        XCTAssertNil(RecurringPattern.detect([row(7, 1), row(7, 8), row(7, 15), row(7, 22)], calendar: calendar))
        XCTAssertNil(RecurringPattern.detect([row(6, 24), row(7, 1), row(7, 8)], calendar: calendar))
    }
    func testTwoChargesAndDuplicateDatesAreInsufficient() {
        XCTAssertNil(RecurringPattern.detect([row(6, 10), row(7, 10)], calendar: calendar))
        XCTAssertNil(RecurringPattern.detect([row(6, 10), row(7, 10), row(7, 10), row(8, 10)], calendar: calendar))
    }
    func testPayrollDescriptorsIgnoreChangingReferencesButKeepEmployersSeparate() {
        let first = RecurringPattern.payrollDescriptor("ABONO NÓMINA EMPRESA UNO REF 123 JULIO 2026")
        XCTAssertEqual(first, RecurringPattern.payrollDescriptor("ABONO NOMINA EMPRESA UNO REF 987 AGOSTO 2026"))
        XCTAssertNotEqual(first, RecurringPattern.payrollDescriptor("ABONO NOMINA EMPRESA DOS REF 987 AGOSTO 2026"))
        XCTAssertTrue(RecurringPattern.hasPayrollEvidence(["ABONO PAGO DE NOMINA EMPRESA"]))
        XCTAssertFalse(RecurringPattern.hasPayrollEvidence(["SUPER NOMINA", "CUENTA NOMINA", "SPEI RECIBIDO"]))
    }
    func testFrequenciesConvertToExplicitMonthlyAmounts() {
        XCTAssertEqual(RecurringCadence.fortnightly.monthlyAmount(16500), 33000)
        XCTAssertEqual(RecurringCadence.weekly.monthlyAmount(100), Decimal(string: "433.33"))
        XCTAssertEqual(RecurringCadence.annual.monthlyAmount(1200), 100)
        XCTAssertEqual(RecurringCadence.monthly.monthlyAmount(15000), 15000)
    }
    func testBankDatesWithSpanishMonthAbbreviationsDoNotSplitPayrollByMonth() {
        let first = RecurringPattern.payrollDescriptor("15/JUL 15/JUL ABONO NOMINA EMPRESA REF 123 16,500.00")
        XCTAssertEqual(first, RecurringPattern.payrollDescriptor("15/AGO 15/AGO ABONO NOMINA EMPRESA REF 456 16,500.00"))
        XCTAssertEqual(first, RecurringPattern.payrollDescriptor("15-SEP-2026 ABONO NOMINA EMPRESA REF 789 16,500.00"))
        XCTAssertNotEqual(first, RecurringPattern.payrollDescriptor("15/AGO ABONO NOMINA OTRA EMPRESA REF 456 16,500.00"))
    }
    func testZeroAndInvalidAmountsDoNotProduceIncomeOrFixedBill() {
        XCTAssertNil(RecurringPattern.detect([row(6, 10, 0), row(7, 10, -5), row(8, 10, .nan)], calendar: calendar))
    }
}
