import XCTest
@testable import Marcelito

final class AmexDiagnosticTests: XCTestCase {
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
