import XCTest
import PDFKit
@testable import Marcelito

final class AmexDiagnosticTests: XCTestCase {
    func testNativeTextSeparatesMerchantPricesReferencesFXAndInstallments() {
        let text = """
        American Express
        Fecha y Detalle de las operaciones Importe en MN.
        05 de Agosto MERCADOPAGO TIENDA 000077708
        RFCABC123456789 /REF987654321
        48.00
        06 de Agosto GRACIAS POR SU PAGO EN LINEA 500.00 CR
        Total de las transacciones en $ 48.00
        07 de Agosto $1.50 FRESH PIZZA NEW YORK
        Dólar U.S.A. 4.50 TC:17.85555
        80.35
        08 de Agosto COMERCIO COLOMBIA 106.63
        Peso Colombiano 19,000.00 TC:0.00561
        Total de Transacciones en Moneda Extranjera 186.98
        Transacciones de Meses sin Intereses
        27 de Agosto MESES EN AUTOMÁTICO EXTRANJERO 60.00
        CARGO 01 DE03
        Total de Meses sin Intereses 60.00
        Resumen de Meses sin Intereses
        27 de Agosto 900.00 0.00 840.00 1 de 15 60.00
        """
        let rows = FinanceStore.amexTextRowsForTesting(text, fileName: "2026.pdf")
        XCTAssertEqual(rows.map(\.amount), [-48, -500, Decimal(string: "-80.35")!, Decimal(string: "-106.63")!, -60])
        XCTAssertEqual(rows.map(\.kind), [.purchase, .cardPayment, .purchase, .purchase, .msi])
        XCTAssertEqual(rows.filter(\.foreignCurrency).count, 2)
        XCTAssertTrue(rows[2].title.contains("$1.50"))
    }

    func testFooterAndFollowingPageDatesCannotPolluteLastPurchase() {
        let text = """
        American Express
        __pdf_page_2__
        Fecha y Detalle de las operaciones
        31 de Julio CINE 290.00Estado de Cuenta Página 3
        27-Ago-2026 27-Sep-2026
        Fecha y Detalle de las operaciones
        01 de Agosto TIENDA 62.00
        Este no es un documento con validez fiscal
        17 de Septiembre PAGO MINIMO 300.00
        """
        XCTAssertEqual(FinanceStore.amexTextRowsForTesting(text, fileName: "2026.pdf").map(\.amount), [-290, -62])
    }

    func testMissingMXNDoesNotUseSourceCurrencyOrExchangeRate() {
        let text = """
        American Express
        Fecha y Detalle de las operaciones
        Total de las transacciones en $ 0.00
        06 de Agosto COMERCIO
        Peso Colombiano 19,000.00 TC:0.00561
        Total de Transacciones en Moneda Extranjera 106.63
        """
        XCTAssertTrue(FinanceStore.amexTextRowsForTesting(text, fileName: "2026.pdf").isEmpty)
        XCTAssertEqual(FinanceStore.amexTextDiagnosticsForTesting(text, fileName: "2026.pdf").first?.reason, "amex.mxn-cell-ambiguous")
    }

    func testRejectedAmexRowBlocksEvenCompensatingTotals() {
        let rejected = OCRRowDiagnostic(page: 2, rawText: "synthetic", reason: "amex.mxn-cell-ambiguous", accepted: false)
        let result = FinanceStore.santanderRowGate(StatementReconciliationRecord(status: .valid, tolerance: 0),
            source: "Amex", diagnostics: [rejected])
        XCTAssertEqual(result.status, .invalid)
    }

    /// Real PDFs stay private. Skipping this test is NOT certification.
    func testThreePrivateAmexCutsWithActualPDFKitText() throws {
        guard let directory = ProcessInfo.processInfo.environment["MARCELITO_AMEX_PDF_DIR"] else {
            throw XCTSkip("Private Amex PDFs unavailable; real PDFKit goldens not certified")
        }
        let cases = [("1-28_may_2026_-_27_jun_2026.pdf", "28034.19", 93),
                     ("6-28_jun_2026_-_27_jul_2026.pdf", "46711.63", 147),
                     ("7-28_jul_2026_-_27_ago_2026.pdf", "33177.48", 108)]
        for (name, total, count) in cases {
            let pdf = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: directory).appendingPathComponent(name)))
            let text = (0..<pdf.pageCount).map { "__pdf_page_\($0 + 1)__\n" + (pdf.page(at: $0)?.string ?? "") }.joined(separator: "\n")
            for _ in 0..<3 {
                let rows = FinanceStore.amexTextRowsForTesting(text, fileName: name)
                XCTAssertEqual(rows.count, count, name)
                XCTAssertEqual(rows.filter { $0.kind == .purchase }.reduce(Decimal.zero) { $0 - $1.amount }, Decimal(string: total), name)
                XCTAssertTrue(FinanceStore.amexTextDiagnosticsForTesting(text, fileName: name).allSatisfy(\.accepted), name)
                XCTAssertTrue(FinanceStore.selectableTextLayerReconcilesForTesting(text: text, fileName: name), name)
            }
        }
    }

    private let text = """
    American Express
    Fecha y Detalle de las operaciones
    05/JUL/2026 TIENDA EJEMPLO 120.00
    31/FEB/2026 TIENDA FECHA INVALIDA 30.00
    Total de las transacciones en 120.00
    06/JUL/2026 TIENDA EXTRANJERA 50.00
    Total de transacciones en moneda extranjera 50.00
    """

    func testTraceIncludesRejectedDatesAndPreservesSectionAndAmountCandidates() {
        let rows = FinanceStore.amexTextRowsForTesting(text, fileName: "Amex-2026.pdf")
        let trace = FinanceStore.amexTextDiagnosticsForTesting(text, fileName: "Amex-2026.pdf")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(trace.count, 3)
        XCTAssertEqual(trace.filter(\.accepted).count, rows.count)
        XCTAssertTrue(trace.contains { !$0.accepted && $0.reason == "amex.date-invalid" })
        XCTAssertTrue(trace.contains { $0.selectedColumn == "MONEDA_EXTRANJERA" && $0.selectedAmount == 50 })
        XCTAssertTrue(trace.contains { $0.cellTexts?.contains(where: { $0.contains("120.00") }) == true })
        XCTAssertTrue(rows.allSatisfy { $0.extractionEvidence?.method == "pdf-text" })
    }

    func testPrivateExportRetainsControlsAndCandidateSemantics() throws {
        let movements = FinanceStore.amexTextRowsForTesting(text, fileName: "Amex-2026.pdf")
        let trace = FinanceStore.amexTextDiagnosticsForTesting(text, fileName: "Amex-2026.pdf")
        let file = NativeCorpusDiagnosticFile(file: "document-01.pdf", sourceFileName: "synthetic.pdf",
            source: "Amex", mode: "pdf-text", status: "invalid", reconciliationReason: "synthetic",
            rows: trace, candidateRows: movements.map(NativeAuditRow.init),
            declaredControls: StatementSummaryRecord(newTransactions: 170),
            reconciliation: StatementReconciliationRecord(status: .invalid, tolerance: 0))
        let report = NativeCorpusDiagnosticReport(schemaVersion: 1, generatedAt: .now,
            readerVersion: FinanceStore.readerVersion, files: [file])
        let url = try report.writeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let files = try XCTUnwrap(object["files"] as? [[String: Any]])
        XCTAssertNotNil(files[0]["declaredControls"])
        XCTAssertNotNil(files[0]["reconciliation"])
        let candidates = try XCTUnwrap(files[0]["candidateRows"] as? [[String: Any]])
        XCTAssertNotNil(candidates[0]["kind"])
        XCTAssertNotNil(candidates[0]["flow"])
        XCTAssertNotNil(candidates[0]["section"])
        XCTAssertNotNil(candidates[0]["selectionReason"])
    }
}
