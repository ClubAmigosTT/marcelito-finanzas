import XCTest
@testable import Marcelito

final class RappiSharedEngineTests: XCTestCase {
    func testLocalEngineIsBundledAndMatchesRappiAccountingContract() throws {
        XCTAssertTrue(RappiSharedEngine.shared.isAvailable)
        let rows = try XCTUnwrap(RappiSharedEngine.shared.parseMovements(
            text: [
                "Tarjeta de crédito RappiCard",
                "Adeudo del periodo anterior = $0.00",
                "Cargos regulares (no a meses) + $100.00",
                "Cargos compras a meses (capital) + $0.00",
                "Pagos y abonos - $40.00",
                "Saldo deudor total $60.00",
                "CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)",
                "__PDF_PAGE_3__",
                "2026-08-01 2026-08-01 MERPAGO*CAFETERIA; RFC: ABC010203AB1 +$50.00",
                "2026-08-02 2026-08-02 COMERCIO DOS +$50.00",
                "2026-08-03 2026-08-03 PAGO POR SPEI -$40.00",
                "Total de cargos +$100.00",
                "Total de abonos -$40.00"
            ].joined(separator: "\n"),
            fileName: "rappi-shared-contract.pdf",
            evidenceMethod: "pdf-text"
        ))

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.amount), [-50, -50, 40])
        XCTAssertEqual(rows[0].rawDescription, "MERPAGO*CAFETERIA; RFC: ABC010203AB1")
        XCTAssertEqual(rows[0].normalizedMerchant, "cafeteria")
        XCTAssertEqual(rows[0].displayMerchant, "Cafeteria")
        XCTAssertEqual(rows[2].kind, .cardPayment)
        XCTAssertEqual(rows[2].flow, .transfer)
        XCTAssertEqual(rows[2].amount, 40)
    }

    func testOCRMarkersStayAttachedToTheFinancialRow() throws {
        let rows = try XCTUnwrap(RappiSharedEngine.shared.parseMovements(
            text: [
                "Tarjeta de crédito RappiCard",
                "Adeudo del periodo anterior = $0.00",
                "Cargos regulares (no a meses) + $50.00",
                "Cargos compras a meses (capital) + $0.00",
                "Pagos y abonos - $40.00",
                "Saldo deudor total $10.00",
                "CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)",
                "__PDF_PAGE_3__",
                "__RAPPI_ROW_BOUNDS__ 3 0.120000 0.420000 0.760000 0.032000 0.820000",
                "2026-08-01 2026-08-01 MERPAGO*CAFETERIA; RFC: ABC010203AB1 +$50.00",
                "__RAPPI_ROW_BOUNDS__ 3 0.120000 0.380000 0.760000 0.032000 0.770000",
                "__RAPPI_ROW_META__ signo OCR corregido por etiqueta inequívoca de abono Rappi",
                "2026-08-02 2026-08-02 PAGO POR SPEI +$40.00",
                "Total de cargos +$50.00",
                "Total de abonos -$40.00"
            ].joined(separator: "\n"),
            fileName: "rappi-ocr-contract.pdf",
            evidenceMethod: "vision-ocr"
        ))

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.amount), [-50, 40])
        XCTAssertEqual(rows.map { $0.extractionEvidence?.page }, [3, 3])
        XCTAssertEqual(rows.map { $0.extractionEvidence?.confidence }, [0.82, 0.77])
        XCTAssertEqual(rows[0].extractionEvidence?.sameVisualRow, true)
        XCTAssertEqual(rows[0].extractionEvidence?.bounds?.x, 0.12)
        XCTAssertTrue(rows[1].extractionEvidence?.selectionReason?.contains("signo OCR corregido") == true)
    }

    func testDateOnlyRowsStayOnThePrintedCalendarDayAfterSwiftBridge() throws {
        let rows = try XCTUnwrap(RappiSharedEngine.shared.parseMovements(
            text: [
                "Tarjeta de crédito RappiCard",
                "Adeudo del periodo anterior = $0.00",
                "Cargos regulares (no a meses) + $10.00",
                "Cargos compras a meses (capital) + $0.00",
                "Pagos y abonos - $0.00",
                "Saldo deudor total $10.00",
                "CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)",
                "__PDF_PAGE_3__",
                "2026-08-01 2026-08-02 COMERCIO EJEMPLO +$10.00",
                "Total de cargos +$10.00",
                "Total de abonos -$0.00"
            ].joined(separator: "\n"),
            fileName: "rappi-date-contract.pdf",
            evidenceMethod: "vision-ocr"
        ))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(formatter.string(from: try XCTUnwrap(rows.first?.date)), "2026-08-01")
    }
}
