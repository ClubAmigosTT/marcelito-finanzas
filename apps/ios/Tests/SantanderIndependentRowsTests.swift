import XCTest
@testable import Marcelito

/// Synthetic geometry regressions, not certification of the private PDF corpus.
final class SantanderIndependentRowsTests: XCTestCase {
    private var header: [OCRObservationFixture] {
        [OCRObservationFixture(text: "Detalle de movimientos cuenta de cheques", x: 0.09, y: 0.96, width: 0.42),
         OCRObservationFixture(text: "FECHA FOLIO DESCRIPCION DEPOSITO RETIRO SALDO", x: 0.05, y: 0.90, width: 0.89)]
    }

    private func row(_ n: Int, amount: String?, balance: String?, page: Int = 0) -> [OCRObservationFixture] {
        let y = 0.82 - Double(n - 1) * 0.10
        var result = [
            OCRObservationFixture(page: page, text: "\(15 + n)-JUL-2026", x: 0.05, y: y, width: 0.08),
            OCRObservationFixture(page: page, text: "PAGO COMERCIO \(n)", x: 0.20, y: y, width: 0.25)
        ]
        if let amount { result.append(OCRObservationFixture(page: page, text: amount, x: 0.74, y: y, width: 0.08)) }
        if let balance { result.append(OCRObservationFixture(page: page, text: balance, x: 0.86, y: y, width: 0.08)) }
        return result
    }

    private func read(_ rows: [OCRObservationFixture]) -> (movements: [Movement], diagnostics: [OCRRowDiagnostic]) {
        FinanceStore.santanderTableSnapshotForTesting(header + rows, fileName: "julio-2026.pdf", openingBalance: 1000)
    }

    func testMissingMovementDoesNotCascadeToFollowingRowsEvenAcrossPages() {
        for page in [0, 1] {
            let result = read(row(1, amount: "30.00", balance: "970.00")
                + row(2, amount: nil, balance: "940.00")
                + row(3, amount: "40.00", balance: "900.00", page: page))
            XCTAssertEqual(result.movements.map(\.amount), [-30, -40])
            XCTAssertEqual(result.diagnostics.map(\.accepted), [true, false, true])
            XCTAssertTrue(result.diagnostics[1].reason.hasPrefix("santander.movement-cell-missing;"))
            XCTAssertEqual(result.diagnostics[2].rowOrdinal, 3)
            XCTAssertEqual(result.diagnostics[2].cellTexts, ["", "40.00", "900.00"])
            XCTAssertNotNil(result.diagnostics[2].rowBounds)
        }
    }

    func testMissingPrintedBalanceClearsLinkAndLaterRowsResume() {
        let result = read(row(1, amount: "30.00", balance: "970.00")
            + row(2, amount: "30.00", balance: nil)
            + row(3, amount: "40.00", balance: "900.00")
            + row(4, amount: "50.00", balance: "850.00"))
        XCTAssertEqual(result.diagnostics.map(\.accepted), [true, false, false, true])
        XCTAssertTrue(result.diagnostics[2].reason.hasPrefix("santander.previous-printed-balance-unavailable;"))
        XCTAssertEqual(result.movements.map(\.amount), [-30, -50])
    }

    func testWrongPrintedBalanceOnlyBreaksAdjacentEquations() {
        let result = read(row(1, amount: "30.00", balance: "970.00")
            + row(2, amount: "30.00", balance: "999.00")
            + row(3, amount: "40.00", balance: "900.00")
            + row(4, amount: "50.00", balance: "850.00"))
        XCTAssertEqual(result.diagnostics.map(\.accepted), [true, false, false, true])
        XCTAssertEqual(result.movements.map(\.amount), [-30, -50])
    }

    func testZeroPrintedBalanceIsAValidControl() {
        let result = read(row(1, amount: "1,000.00", balance: "0.00"))
        XCTAssertEqual(result.movements.map(\.amount), [-1000])
        XCTAssertEqual(result.diagnostics.map(\.accepted), [true])
    }

    func testBothMoneyColumnsRejectWithoutGuessingFromBalance() {
        let result = read(row(1, amount: "30.00", balance: "970.00") + [
            OCRObservationFixture(text: "30.00", x: 0.62, y: 0.82, width: 0.08)
        ])
        XCTAssertTrue(result.movements.isEmpty)
        XCTAssertTrue(result.diagnostics[0].reason.hasPrefix("santander.movement-cell-ambiguous;"))
    }

    func testContinuationNumbersCannotBecomeMoneyCells() {
        let result = read(row(1, amount: "30.00", balance: "970.00") + [
            OCRObservationFixture(text: "COMPRA EN TIENDA", x: 0.20, y: 0.78, width: 0.24),
            OCRObservationFixture(text: "9,999.99", x: 0.74, y: 0.78, width: 0.08)
        ])
        XCTAssertEqual(result.movements.map(\.amount), [-30])
        XCTAssertTrue(result.movements.first?.title.contains("COMPRA EN TIENDA") == true)
    }

    func testNoMissingThirtyPesoMovementCanBeInventedFromBalances() {
        let result = read(row(1, amount: "30.00", balance: "940.00"))
        XCTAssertTrue(result.movements.isEmpty)
        XCTAssertEqual(result.diagnostics[0].selectedAmount, 30)
        XCTAssertTrue(result.diagnostics[0].reason.hasPrefix("santander.running-balance-mismatch;"))
    }

    func testRowGateRejectsMatchingTotalsWithAnyUnresolvedRow() {
        let valid = StatementReconciliationRecord(status: .valid, tolerance: 0)
        let failed = OCRRowDiagnostic(page: 1, rawText: "unreadable", reason: "santander.movement-cell-missing", accepted: false)
        let passed = OCRRowDiagnostic(page: 1, rawText: "readable", reason: "santander.row-verified", accepted: true)
        XCTAssertEqual(FinanceStore.santanderRowGate(valid, source: "Santander", diagnostics: [passed, failed]).status, .invalid)
        XCTAssertEqual(FinanceStore.santanderRowGate(valid, source: "Santander", diagnostics: []).status, .invalid)
        XCTAssertEqual(FinanceStore.santanderRowGate(valid, source: "Santander", diagnostics: [passed]).status, .valid)
        for source in ["BBVA", "Amex"] {
            XCTAssertEqual(FinanceStore.santanderRowGate(valid, source: source, diagnostics: [failed]).status, .valid)
        }
    }

    func testCropFlipsVisionYAndStaysWithinTheFixedCell() {
        for y in [0.0, 0.5, 0.875] {
            let pixels = FinanceStore.santanderCropPixelRect(CGRect(x: 0.75, y: y, width: 0.125, height: 0.125), width: 1024, height: 2048)
            XCTAssertEqual(pixels, CGRect(x: 768, y: (1 - y - 0.125) * 2048, width: 128, height: 256))
        }
        XCTAssertEqual(FinanceStore.santanderCropPixelRect(CGRect(x: -1, y: -1, width: 3, height: 3), width: 100, height: 200), CGRect(x: 0, y: 0, width: 100, height: 200))
        XCTAssertEqual(FinanceStore.santanderCropPixelRect(CGRect(x: 2, y: 2, width: 1, height: 1), width: 100, height: 200), .zero)
    }

    func testPrivateRowEvidenceRoundTripsAndOldReportsStillDecode() throws {
        let diagnostic = read(row(1, amount: "30.00", balance: "970.00")).diagnostics[0]
        let decoded = try JSONDecoder().decode(OCRRowDiagnostic.self, from: JSONEncoder().encode(diagnostic))
        XCTAssertEqual(decoded.cellTexts, ["", "30.00", "970.00"])
        XCTAssertEqual(decoded.rowOrdinal, 1)
        let old = Data(#"{"id":"old","rawText":"old","reason":"old","accepted":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(OCRRowDiagnostic.self, from: old).cellTexts)
    }

    func testPublicErrorDoesNotContainFinancialValuesOrDescriptions() {
        XCTAssertEqual(NativeCorpusFileReport.redactedRowError("santander.running-balance-mismatch; saldo anterior 87801.76; COMERCIO"), "santander.running-balance-mismatch")
        XCTAssertEqual(NativeCorpusFileReport.redactedRowError("importe 87801.76"), "row-extraction-rejected")
        XCTAssertNil(NativeCorpusFileReport.redactedRowError(nil))
    }
}
