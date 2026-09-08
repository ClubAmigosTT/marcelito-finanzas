import XCTest
import PDFKit
import UIKit
@testable import Marcelito

/// Synthetic geometry regressions, not certification of the private PDF corpus.
final class SantanderIndependentRowsTests: XCTestCase {
    func testCellConsensusRequiresRepeatedCompleteReadings() {
        XCTAssertEqual(FinanceStore.santanderCellConsensus(["54,977.93", "54977.93", nil]), "54,977.93")
        XCTAssertEqual(FinanceStore.santanderCellConsensus(["", "", nil]), "")
        XCTAssertNil(FinanceStore.santanderCellConsensus(["54,977.93", nil, "noise"]))
        XCTAssertNil(FinanceStore.santanderCellConsensus(["54,977.93", "54,977.93", "4,977.93"]))
        XCTAssertNil(FinanceStore.santanderCellConsensus(["", "", "500.00"]))
        for invalid in ["RFC 500.00", "500.00 800.00", "54,97.93", "5497793", "500.001"] {
            XCTAssertNil(FinanceStore.santanderCellConsensus([invalid, invalid, invalid]))
        }
    }

    private var header: [OCRObservationFixture] {
        [OCRObservationFixture(text: "Detalle de movimientos cuenta de cheques", x: 0.09, y: 0.96, width: 0.42),
         OCRObservationFixture(text: "FECHA FOLIO DESCRIPCION DEPOSITO RETIRO SALDO", x: 0.05, y: 0.90, width: 0.89)]
    }

    func testAugustDiagnosticSeparatorsAndCropNoiseRecoverBalanceChain() throws {
        let first = try XCTUnwrap(FinanceStore.santanderCellConsensus([
            "54 977 93", "54 97793", "54 97793"
        ]))
        let second = try XCTUnwrap(FinanceStore.santanderCellConsensus([
            "54,177.93", "54,177.93 --...al.-", "54,177.93 - a1.-"
        ]))
        XCTAssertEqual(first, "54977.93")
        XCTAssertEqual(second, "54,177.93")
        let fixtures = header + row(1, amount: "500.00", balance: first)
            + row(2, amount: "800.00", balance: second)
            + row(3, amount: "100.00", balance: "54,077.93")
            + [OCRObservationFixture(text: "TOTAL", x: 0.20, y: 0.10, width: 0.10)]
        let result = FinanceStore.santanderTableSnapshotForTesting(fixtures,
            fileName: "statement.pdf", openingBalance: Decimal(string: "55477.93")!)
        XCTAssertEqual(result.diagnostics.map(\.accepted), [true, true, true])
        XCTAssertEqual(result.movements.map(\.amount), [-500, -800, -100])
    }

    func testCellNormalizationDoesNotInventDecimalsOrDiscardNumericConflicts() {
        for invalid in ["5497793", "54 9779", "54 97 93", "54,97.93", "500.001",
                        "RFC 500.00", "500.00 800.00", "500.00 - 800.00",
                        "500.00 - a1.-", "500.00 - $", "-500.00"] {
            XCTAssertNil(FinanceStore.santanderNormalizedCellReading(invalid), invalid)
        }
        XCTAssertNil(FinanceStore.santanderCellConsensus(["54 977 93", "54 97793", "4,977.93"]))
        XCTAssertNil(FinanceStore.santanderCellConsensus(["54 977 93", nil, "noise"]))
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

    private func read(_ rows: [OCRObservationFixture], pdf: PDFDocument? = nil) -> (movements: [Movement], diagnostics: [OCRRowDiagnostic]) {
        let footer = OCRObservationFixture(page: rows.map(\.page).max() ?? 0, text: "TOTAL", x: 0.20, y: 0.10, width: 0.10)
        return FinanceStore.santanderTableSnapshotForTesting(header + rows + [footer], fileName: "julio-2026.pdf", openingBalance: 1000, recoveryPDF: pdf)
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

    func testDanglingRFCOnFirstDescriptionLineDoesNotRejectARealWithdrawal() {
        for amount in ["40.00", "63.00"] {
            let balance = amount == "40.00" ? "960.00" : "937.00"
            let fixtures = row(1, amount: amount, balance: balance).filter { !$0.text.hasPrefix("PAGO COMERCIO") }
                + [OCRObservationFixture(text: "PAGO TRANSF RAPIDA SPEI TRANSFERENCIA A COMERCIO RFC", x: 0.20, y: 0.82, width: 0.38)]
            let result = read(fixtures)
            XCTAssertEqual(result.diagnostics.map(\.accepted), [true])
            XCTAssertEqual(result.movements.first?.title, "PAGO TRANSF RAPIDA SPEI TRANSFERENCIA A COMERCIO")
        }
    }

    func testDanglingRFCDoesNotDisableAdministrativeRejectionOrBalanceGate() {
        let metadata = row(1, amount: "40.00", balance: "960.00").filter { !$0.text.hasPrefix("PAGO COMERCIO") }
        let result = read(metadata + [OCRObservationFixture(text: "SALDO DISPONIBLE RFC", x: 0.20, y: 0.82, width: 0.30)])
        XCTAssertTrue(result.movements.isEmpty)
        let mismatch = read(row(1, amount: "40.00", balance: "950.00")
            + [OCRObservationFixture(text: "RFC", x: 0.20, y: 0.80, width: 0.05)])
        XCTAssertTrue(mismatch.movements.isEmpty)
    }

    func testBalanceRetryCannotBeAbortedByUnrelatedWithdrawalCrop() throws {
        XCTAssertEqual(FinanceStore.santanderRetryCells(problem: "santander.balance-cell-missing-or-ambiguous"), [2])
        XCTAssertEqual(FinanceStore.santanderRetryCells(problem: nil), [0, 1, 2])
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage()
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)]
            ("NOISE 30.00" as NSString).draw(at: CGPoint(x: 0.73 * 612, y: 0.16 * 792), withAttributes: attributes)
            ("970.00" as NSString).draw(at: CGPoint(x: 0.86 * 612, y: 0.16 * 792), withAttributes: attributes)
        }
        let result = read(row(1, amount: "30.00", balance: nil)
            + row(2, amount: "40.00", balance: "930.00"), pdf: try XCTUnwrap(PDFDocument(data: data)))
        XCTAssertEqual(result.movements.map(\.amount), [-30, -40])
        XCTAssertEqual(result.diagnostics.map(\.accepted), [true, true])
        XCTAssertEqual(result.diagnostics[0].cellRetryTexts?[1], "not-read")
        XCTAssertEqual(result.diagnostics[0].cellTexts, ["", "30.00", "970.00"])
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

    func testNativeVisionCropRecoversMissingMovementOnHighConfidencePage() throws {
        // A generated, nonfinancial page exercises the real PDFKit -> CGImage
        // -> Vision retry, rather than mocking its result or certifying totals.
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)]
            ("30.00" as NSString).draw(at: CGPoint(x: 0.74 * 612, y: 0.16 * 792), withAttributes: attributes)
            ("970.00" as NSString).draw(at: CGPoint(x: 0.86 * 612, y: 0.16 * 792), withAttributes: attributes)
        }
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        for _ in 0..<3 {
            let result = read(row(1, amount: nil, balance: "970.00"), pdf: pdf)
            XCTAssertEqual(result.movements.map(\.amount), [-30])
            XCTAssertEqual(result.diagnostics.map(\.accepted), [true])
            XCTAssertTrue(result.diagnostics[0].reason.contains("relectura de celdas sí"))
            XCTAssertEqual(result.diagnostics[0].cellTexts, ["", "30.00", "970.00"])
            XCTAssertTrue(result.diagnostics[0].cellRetryTexts?[1].contains("2x:") == true)
        }
    }
}
