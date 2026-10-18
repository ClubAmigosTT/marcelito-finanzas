import XCTest
#if canImport(Marcelito)
@testable import Marcelito
#endif

final class LoanBookTests: XCTestCase {
    static let fixture = """
    10/07/2026 11:17:49 am
    SISTEMA DE AYUDAS FINANCIERAS
    Estado de Cuenta Préstamo en Amortización ( UDIS )
    Clave Única: 000000999 Nombre: PERSONA DE PRUEBA
    Adeudo Total de Capital: 270.00 UDIS Total Pagos: 3 Pagados: 1
    Por pagar: 1 Vencidos: 1
    Fecha de Inicio: 20/05/2026 Fecha de Termino: 20/07/2026
    1 20/05/2026 Pagado 100.00 90.00 10.00 0 25/05/2026 $600.00 60.00 $500.00 50.00 $100.00 10.00 10001
    __PAGE_2__
    0 26/05/2026 $400.00 40.00 $400.00 40.00 $0.00 0.00 10002
    2 20/06/2026 Vencido 100.00 90.00 10.00 1 30/06/2026 $500.00 50.00 $400.00 40.00 $100.00 10.00 10003
    3 20/07/2026 Por Pagar 100.00 90.00 10.00 0
    Total de Doctos (UDIS) 300.00 270.00 30.00 $1,500.00 150.00 $1,300.00 130.00 $200.00 20.00
    Menos Pagos Amortización 150.00 130.00 20.00
    Menos Condonaciones 0.00 0.00 0.00
    Total Amortización (UDIS) 150.00 140.00 10.00
    """
    private func statement(_ text: String = fixture, fingerprint: String = "fixture") throws -> LoanStatement {
        try ITAMLoanReader.parse(text: text, fingerprint: fingerprint, filename: "synthetic.pdf")
    }
    private func day(_ text: String) -> Date { LoanMath.day(text)! }
    func testPartialInstallmentAndContinuationSurvivePageBoundary() throws {
        let s = try statement()
        XCTAssertEqual(s.installments.count, 3); XCTAssertEqual(s.allocations.count, 3)
        XCTAssertEqual(s.status(s.installments[0]), "Pagada con atraso")
        XCTAssertEqual(s.paid(s.installments[0]), 100); XCTAssertEqual(s.remaining(s.installments[0]), 0)
        XCTAssertEqual(s.overdueTotal, 50); XCTAssertEqual(s.status(s.installments[1]), "Vencida · abono parcial")
        XCTAssertEqual(s.accruedUnpaidInterest, 0); XCTAssertEqual(s.recognizedDebt, 140)
    }
    func testIncompleteAndMismatchedStatementsNeverImport() {
        XCTAssertThrowsError(try statement(Self.fixture.replacingOccurrences(of: "3 20/07/2026 Por Pagar 100.00 90.00 10.00 0", with: "")))
        XCTAssertThrowsError(try statement(Self.fixture.replacingOccurrences(of: "$400.00 40.00 $400.00", with: "$900.00 40.00 $400.00")))
        XCTAssertThrowsError(try statement(Self.fixture.replacingOccurrences(of: "150.00 140.00 10.00", with: "150.00 240.00 10.00")))
        XCTAssertThrowsError(try statement(Self.fixture + "\n3 20/07/2026 Por Pagar 100.00 90.00 10.00 0"))
    }
    func testReimportIsIdempotentAndDoesNotResetConfiguration() throws {
        let b = LoanBook(defaults: nil); let s = try statement()
        XCTAssertTrue(try b.importStatement(s))
        try b.setQuote(value: 10, date: day("10/07/2026"))
        try b.setCatchUp(250, accountID: s.accountID, month: day("20/07/2026"))
        let receipt = try XCTUnwrap(s.receipts.first)
        try b.confirmLink(accountID: s.accountID, receipt: receipt, movementID: UUID(), identity: "bank-1", amount: receipt.total)
        XCTAssertFalse(try b.importStatement(s)); XCTAssertEqual(b.state.accounts.count, 1)
        XCTAssertEqual(b.state.accounts[0].statements.count, 1); XCTAssertEqual(b.state.links.count, 1)
        XCTAssertEqual(b.reserve(month: day("20/07/2026"), paid: 0).reserved, 1250)
    }
    func testOlderSnapshotDoesNotReplaceLatestOrRemoveLinks() throws {
        let b = LoanBook(defaults: nil); let latest = try statement(); try b.importStatement(latest)
        let older = try statement(Self.fixture.replacingOccurrences(of: "10/07/2026 11:", with: "09/07/2026 11:"), fingerprint: "older")
        try b.importStatement(older)
        XCTAssertEqual(b.state.accounts[0].latest?.id, latest.id)
        XCTAssertThrowsError(try b.importStatement(statement(fingerprint: "conflicting-same-date")))
        XCTAssertEqual(b.state.accounts[0].statements.count, 2)
    }
    func testDebtExcludesFutureInterestAndNeverFallsWithTime() throws {
        let b = LoanBook(defaults: nil); try b.importStatement(statement())
        XCTAssertNil(b.debt(asOf: day("11/07/2026")))
        try b.setQuote(value: 10, date: day("10/07/2026"))
        XCTAssertEqual(b.debt(asOf: day("11/07/2026")), 1400)
        XCTAssertEqual(b.debt(asOf: day("11/09/2026")), 1400)
        XCTAssertNil(b.debt(asOf: day("09/07/2026")))
        XCTAssertNotEqual(b.debt(), 1500)
    }
    func testQuotesCannotBeFutureNegativeOrLeakIntoHistory() throws {
        let b = LoanBook(defaults: nil)
        XCTAssertThrowsError(try b.setQuote(value: -1, date: day("01/07/2026")))
        XCTAssertThrowsError(try b.setQuote(value: 10, date: day("11/07/2026"), now: day("10/07/2026")))
        try b.setQuote(value: 10, date: day("10/07/2026"))
        XCTAssertNil(b.quote(asOf: day("09/07/2026")))
        XCTAssertEqual(b.quote(asOf: day("11/07/2026"))?.value, 10)
    }
    func testOfficialUDIFeedParsesPublishedValues() throws {
        let json = #"{"messageCode":200,"response":"OK","ListaIndicadores":[{"codIndicador":39705,"codTipoIndicador":159,"fecha":"01-09-2026","valor":"8.811040"},{"codIndicador":1,"codTipoIndicador":158,"fecha":"01-09-2026","valor":"17.5"}],"TotalIndicadores":2}"#
        let quotes = try LoanUDIFeed.parse(Data(json.utf8))
        XCTAssertEqual(quotes.count, 1)
        XCTAssertEqual(quotes.first?.value, Decimal(string: "8.811040"))
        XCTAssertEqual(quotes.first?.date, Calendar.current.startOfDay(for: day("01/09/2026")))
        XCTAssertEqual(LoanUDIFeed.url(from: day("01/09/2026"), to: day("03/09/2026")).absoluteString,
            "https://sidof.segob.gob.mx/dof/sidof/indicadores/159/01-09-2026/03-09-2026")
    }
    func testOfficialQuotesFillMissingDaysAndKeepTypedValues() throws {
        let b = LoanBook(defaults: nil); try b.importStatement(statement())
        XCTAssertNil(b.debt(asOf: day("11/07/2026")))
        try b.setQuote(value: 10, date: day("10/07/2026"))
        let official = [
            LoanUDIQuote(date: day("09/07/2026"), value: 9, source: LoanUDIFeed.source),
            LoanUDIQuote(date: day("10/07/2026"), value: 11, source: LoanUDIFeed.source),
        ]
        XCTAssertEqual(try b.mergeOfficialQuotes(official, now: day("11/07/2026")), 1)
        XCTAssertEqual(b.quote(asOf: day("09/07/2026"))?.value, 9)
        XCTAssertEqual(b.quote(asOf: day("10/07/2026"))?.value, 10)
        XCTAssertEqual(try b.mergeOfficialQuotes(official, now: day("11/07/2026")), 0)
        XCTAssertNotNil(b.earliestQuoteNeeded)
    }
    func testReserveUsesWholePaymentOnceAndExtraDoesNotChangeDebt() throws {
        let b = LoanBook(defaults: nil); let s = try statement(); try b.importStatement(s)
        XCTAssertNil(b.reserve(month: day("20/07/2026"), paid: 0).reserved)
        try b.setQuote(value: 10, date: day("10/07/2026"))
        try b.setCatchUp(500, accountID: s.accountID, month: day("20/07/2026"))
        XCTAssertEqual(b.reserve(month: day("20/07/2026"), paid: 1000).reserved, 1500)
        XCTAssertEqual(b.reserve(month: day("20/07/2026"), paid: 2500).reserved, 2500)
        XCTAssertEqual(b.debt(), 1400)
        XCTAssertEqual(b.reserve(month: day("20/08/2026"), paid: 0).reserved, 0)
    }
    func testSingleBankPaymentCannotLinkTwiceOrToWrongAmount() throws {
        let b = LoanBook(defaults: nil); let s = try statement(); try b.importStatement(s)
        let receipts = s.receipts; let id = UUID()
        XCTAssertThrowsError(try b.confirmLink(accountID: s.accountID, receipt: receipts[0], movementID: id, identity: "a", amount: -1))
        try b.confirmLink(accountID: s.accountID, receipt: receipts[0], movementID: id, identity: "a", amount: -receipts[0].total)
        XCTAssertThrowsError(try b.confirmLink(accountID: s.accountID, receipt: receipts[0], movementID: UUID(), identity: "b", amount: -receipts[0].total))
        XCTAssertThrowsError(try b.confirmLink(accountID: s.accountID, receipt: receipts[1], movementID: id, identity: "c", amount: -receipts[1].total))
        XCTAssertThrowsError(try b.confirmLink(accountID: s.accountID, receipt: receipts[1], movementID: UUID(), identity: "a", amount: -receipts[1].total))
        try b.unlink(receipts[0].id); XCTAssertTrue(b.state.links.isEmpty)
    }
    func testNoQuoteNeededForAnEmptyLoanBookAndNoFakeZeroForUnknownDebt() throws {
        let b = LoanBook(defaults: nil); XCTAssertEqual(b.debt(), 0); XCTAssertEqual(b.reserve(month: .now, paid: 0).reserved, 0)
        try b.importStatement(statement()); XCTAssertNil(b.debt())
    }
    func testPastDueAfterStatementIsUnconfirmedInsteadOfInventedDelinquency() throws {
        let s = try statement()
        XCTAssertEqual(s.status(s.installments[2], now: day("01/08/2026")), "Sin pago confirmado · actualiza el estado")
        XCTAssertEqual(s.overdue.count, 1)
    }
    func testPersistenceKeepsLinksQuotesCatchUpAndBacksUpPriorBook() throws {
        let suite = "marcelito.loan.tests.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let b = LoanBook(defaults: defaults); let s = try statement(); try b.importStatement(s)
        try b.setQuote(value: 10, date: day("10/07/2026")); try b.setCatchUp(123, accountID: s.accountID, month: day("20/07/2026"))
        let r = s.receipts[0]; try b.confirmLink(accountID: s.accountID, receipt: r, movementID: UUID(), identity: "stable", amount: -r.total)
        let loaded = LoanBook(defaults: defaults)
        XCTAssertNil(loaded.loadError); XCTAssertEqual(loaded.state.links, b.state.links); XCTAssertEqual(loaded.debt(), 1400)
        XCTAssertEqual(loaded.reserve(month: day("20/07/2026"), paid: 0).reserved, 1123)
        XCTAssertNotNil(defaults.data(forKey: LoanBook.storageKey + ".backup"))
    }
    func testCorruptOrFutureSchemaDoesNotOverwriteSavedEvidence() throws {
        let suite = "marcelito.loan.corrupt.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for data in [Data("bad-json".utf8), Data(#"{"schema":2,"accounts":[],"quotes":[],"links":[],"catchUp":{}}"#.utf8)] {
            defaults.set(data, forKey: LoanBook.storageKey)
            let b = LoanBook(defaults: defaults); XCTAssertNotNil(b.loadError)
            XCTAssertThrowsError(try b.importStatement(statement()))
            XCTAssertEqual(defaults.data(forKey: LoanBook.storageKey), data)
        }
    }
    func testBankResolverKeepsOnlyConfirmedUniqueUnchangedEvidence() throws {
        let b = LoanBook(defaults: nil); let s = try statement(); try b.importStatement(s)
        let receipt = s.receipts[0]; let original = UUID()
        try b.confirmLink(accountID: s.accountID, receipt: receipt, movementID: original, identity: "stable", amount: -receipt.total)
        func row(_ id: UUID, key: String = "stable", date: Date? = nil, amount: Decimal? = nil, eligible: Bool = true) -> LoanBankEvidence {
            LoanBankEvidence(id: id, identity: key, date: date ?? receipt.date, amount: amount ?? -receipt.total, canRepayLoan: eligible)
        }
        XCTAssertEqual(LoanPaymentResolver.resolve(state: b.state, bank: [row(original)]).count, 1)
        let rebuilt = UUID()
        XCTAssertNotNil(LoanPaymentResolver.resolve(state: b.state, bank: [row(rebuilt)])[rebuilt])
        XCTAssertTrue(LoanPaymentResolver.resolve(state: b.state, bank: [row(rebuilt), row(UUID())]).isEmpty)
        XCTAssertTrue(LoanPaymentResolver.resolve(state: b.state, bank: [row(original, amount: -123)]).isEmpty)
        XCTAssertTrue(LoanPaymentResolver.resolve(state: b.state, bank: [row(original, eligible: false)]).isEmpty)
        XCTAssertTrue(LoanPaymentResolver.resolve(state: b.state, bank: [row(original, date: day("01/01/2026"))]).isEmpty)
        XCTAssertTrue(LoanPaymentResolver.resolve(state: b.state, bank: []).isEmpty)
    }
    func testNewBankRowsAreNeverAutomaticallyAssumedToBeLoanPayments() throws {
        let b = LoanBook(defaults: nil); let s = try statement(); try b.importStatement(s)
        let receipt = s.receipts[0]
        let bank = LoanBankEvidence(id: UUID(), identity: "same-amount", date: receipt.date, amount: -receipt.total, canRepayLoan: true)
        XCTAssertTrue(LoanPaymentResolver.resolve(state: b.state, bank: [bank]).isEmpty)
    }
    func testPaymentsMadeBeforeADueMonthReduceItsReserveButSameMonthPaymentsDoNot() throws {
        var text = Self.fixture.replacingOccurrences(of: "3 20/07/2026 Por Pagar 100.00 90.00 10.00 0", with: "3 20/07/2026 Por Pagar 100.00 90.00 10.00 0 26/05/2026 $500.00 50.00 $500.00 50.00 $0.00 0.00 10004")
        text = text.replacingOccurrences(of: "$1,500.00 150.00 $1,300.00 130.00 $200.00 20.00", with: "$2,000.00 200.00 $1,800.00 180.00 $200.00 20.00")
            .replacingOccurrences(of: "Menos Pagos Amortización 150.00 130.00 20.00", with: "Menos Pagos Amortización 200.00 180.00 20.00")
            .replacingOccurrences(of: "150.00 140.00 10.00", with: "100.00 90.00 10.00")
        let s = try statement(text); let b = LoanBook(defaults: nil); try b.importStatement(s)
        try b.setQuote(value: 10, date: day("01/06/2026"))
        XCTAssertEqual(b.reserve(month: day("20/07/2026"), paid: 0).reserved, 500)
        XCTAssertEqual(b.reserve(month: day("20/06/2026"), paid: 500).reserved, 1000)
    }
    func testUDIInputPreservesSixDecimalsAndAcceptsDecimalCommaWithoutMultiplyingTheRate() {
        XCTAssertEqual(LoanMath.udiInput("8.123456"), Decimal(string: "8.123456"))
        XCTAssertEqual(LoanMath.udiInput("8,123456"), Decimal(string: "8.123456"))
        XCTAssertNil(LoanMath.udiInput("8.1234567")); XCTAssertNil(LoanMath.udiInput("1,000.00"))
        XCTAssertNil(LoanMath.udiInput("-8.12")); XCTAssertNil(LoanMath.udiInput("sin valor"))
    }
    func testDifferentContractsForSameStudentDoNotOverwriteEachOther() throws {
        let first = try statement()
        let second = try statement(Self.fixture.replacingOccurrences(of: "Fecha de Inicio: 20/05/2026", with: "Fecha de Inicio: 20/05/2025"), fingerprint: "second-contract")
        let sameContract = try statement(Self.fixture.replacingOccurrences(of: "Clave Única: 000000999", with: "Clave Única: 999"), fingerprint: "same-contract-padding")
        XCTAssertEqual(first.accountID, sameContract.accountID)
        XCTAssertNotEqual(first.accountID, second.accountID)
        let b = LoanBook(defaults: nil); try b.importStatement(first); try b.importStatement(second)
        XCTAssertEqual(b.state.accounts.count, 2)
    }
    func testPrivateITAMPDFWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["MARCELITO_ITAM_REGRESSION_PDF"] else { throw XCTSkip("Private PDF is opt-in; no bank data is stored in the repository.") }
        let s = try LoanPDFReader.read(URL(fileURLWithPath: path))
        XCTAssertEqual(s.installments.count, 55); XCTAssertEqual(s.receipts.count, 33)
        XCTAssertEqual(s.principalRemaining, Decimal(string: "37640.80")); XCTAssertEqual(s.overdueTotal, Decimal(string: "3477.65")); XCTAssertEqual(s.accruedUnpaidInterest, Decimal(string: "150.10"))
        XCTAssertEqual(s.receipts.reduce(0) { $0 + $1.total }, Decimal(string: "140712.73"))
        let july = try XCTUnwrap(s.receipts.first { LoanMath.dayKey($0.date) == "2026-07-08" && $0.total == 10000 })
        XCTAssertEqual(july.total, 10000); XCTAssertEqual(july.installments, [16, 17]); XCTAssertEqual(july.interest, Decimal(string: "279.98"))
        let june = try XCTUnwrap(s.receipts.first { LoanMath.dayKey($0.date) == "2026-06-30" }); XCTAssertEqual(june.total, Decimal(string: "9999.98"))
        let b = LoanBook(defaults: nil); try b.importStatement(s); XCTAssertFalse(try b.importStatement(s))
    }
}
