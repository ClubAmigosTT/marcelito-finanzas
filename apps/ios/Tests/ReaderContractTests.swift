import XCTest
@testable import Marcelito

final class ReaderContractTests: XCTestCase {
    func testInstitutionalHeaderWinsOverCounterpartyMention() {
        let text = """
        Grupo Financiero BBVA
        BBVA México, Institución de Banca Múltiple
        Cuenta de cheques
        Fecha Descripcion
        01/08/2026 NOMINA EMPRESA 10,000.00 20,000.00
        02/08/2026 TRANSFERENCIA SANTANDER 125.00 19,875.00
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "estado-renombrado.pdf"
        )

        XCTAssertEqual(snapshot.source, "BBVA")
        XCTAssertEqual(snapshot.sourceDetection.status, .verified)
        XCTAssertTrue(snapshot.sourceDetection.ignoredBodyMentions.contains("Santander"))
        XCTAssertEqual(snapshot.kind, .bank)
        XCTAssertEqual(snapshot.movements.count, 2)
        XCTAssertTrue(snapshot.movements.contains { $0.kind == .income })
        XCTAssertFalse(snapshot.movements.contains { $0.title.localizedCaseInsensitiveContains("total importe") })
    }

    func testBBVAInstitutionalEvidenceWinsBeforeMovementTable() {
        let text = """
        BBVA México, Institución de Banca Múltiple, Grupo Financiero BBVA México
        Transferencia recibida de Santander
        Estado de cuenta
        Detalle de Movimientos Realizados
        05/AGO SPEI RECIBIDO SANTANDER 4,500.00 6,116.63
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "estado-renombrado.pdf"
        )

        XCTAssertEqual(snapshot.source, "BBVA")
        XCTAssertEqual(snapshot.sourceDetection.status, .verified)
    }

    func testAmexCreditRowIsNotSilentlyConvertedToPurchase() {
        let text = """
        American Express
        The Platinum Credit Card
        Fecha y Detalle de las operaciones Importe en MN.
        01/08/2026 AMAZON MX 123.45
        02/08/2026 MONTO A DIFERIR A MESES SIN INTERESES 500.00 CR
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "amex-agosto-2026.pdf"
        )

        XCTAssertEqual(snapshot.source, "Amex")
        XCTAssertEqual(snapshot.kind, .card)
        XCTAssertEqual(snapshot.movements.count, 2)
        XCTAssertTrue(snapshot.movements.contains { $0.kind == .credit && $0.amount > 0 })
        XCTAssertFalse(snapshot.movements.contains { $0.title.localizedCaseInsensitiveContains("fecha y detalle") })
    }

    func testReaderRejectsAdministrativeNumericRows() {
        let text = """
        Grupo Financiero BBVA
        BBVA México, Institución de Banca Múltiple
        Fecha Descripcion
        03/08/2026 Ciudad de México No. de Serie del Certificado 2026070840014 123,456.78
        05/08/2026 SPEI RECIBIDO 1234567
        04/08/2026 OXXO 95.00 1,200.00
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "bbva-agosto-2026.pdf"
        )

        XCTAssertEqual(snapshot.movements.count, 1)
        XCTAssertTrue(snapshot.movements.first?.title.localizedCaseInsensitiveContains("OXXO") == true)
        XCTAssertFalse(snapshot.movements.contains { $0.title.localizedCaseInsensitiveContains("certificado") })
    }

    func testBankShortMonthDatesKeepTheOperationYear() {
        let text = """
        Grupo Financiero BBVA
        BBVA México, Institución de Banca Múltiple
        Detalle de Movimientos Realizados
        FECHA OPER LIQ DESCRIPCION CARGOS ABONOS SALDO
        23/JUL 22/JUL FACEBK *XR4NKVVF52 120.00 3,469.63
        27/JUL 27/JUL SPEI RECIBIDO INFLUENCER MARKETING 15,000.00 18,469.63
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "bbva-agosto-2026.pdf"
        )

        XCTAssertEqual(snapshot.source, "BBVA")
        XCTAssertEqual(snapshot.movements.count, 2)
        XCTAssertTrue(snapshot.movements.allSatisfy { Calendar.current.component(.year, from: $0.date) == 2026 })
        XCTAssertEqual(snapshot.movements.first?.amount, -120)
        XCTAssertEqual(snapshot.movements.last?.amount, 15_000)
    }

    func testOcrMonthAndDayRepairsStayInsideDateToken() {
        let text = """
        Grupo Financiero BBVA
        BBVA México, Institución de Banca Múltiple
        Detalle de Movimientos Realizados
        FECHA OPER LIQ DESCRIPCION CARGOS ABONOS SALDO
        O5/AG0 TIENDA DE PRUEBA 125.00 1,030.94
        OBIAGO NOMINA EMPRESA 1,000.00 2,030.94
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "bbva-agosto-2026.pdf"
        )

        XCTAssertEqual(snapshot.movements.count, 2)
        XCTAssertTrue(snapshot.movements.allSatisfy { Calendar.current.component(.month, from: $0.date) == 8 })
        XCTAssertEqual(snapshot.movements.first?.amount, -125)
        XCTAssertEqual(snapshot.movements.last?.amount, 1_000)
    }

    func testMatchingUsesMagnitudeWhenCounterpartSignsDiffer() {
        XCTAssertTrue(FinanceStore.matchingAmountsForTesting(-1_000, 1_000))
        XCTAssertTrue(FinanceStore.matchingAmountsForTesting(-1_000.005, 1_000))
        XCTAssertFalse(FinanceStore.matchingAmountsForTesting(-1_000, 1_001))
    }

    func testTextRowsRetainPageAndSourceFragment() {
        let text = """
        __PDF_PAGE_2__
        Grupo Financiero BBVA
        BBVA México, Institución de Banca Múltiple
        Detalle de Movimientos Realizados
        01/08/2026 SUPERMERCADO 120.00 880.00
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "bbva-agosto-2026.pdf"
        )

        XCTAssertEqual(snapshot.movements.count, 1)
        XCTAssertEqual(snapshot.movements.first?.extractionEvidence?.page, 2)
        XCTAssertFalse(snapshot.movements.first?.extractionEvidence?.sourceText?.isEmpty ?? true)
    }

    func testBankSummaryChoosesOpeningBalanceThatReconciles() {
        let text = """
        Banco Santander México, S.A., Institución de Banca Múltiple, Grupo Financiero Santander México
        Saldo promedio 50,129.64 — Saldoinicial 55,627.93
        + Depósitos 36,187.42
        − Retiros 64,161.11
        = Saldo final 27,654.24
        Gráfico cuenta de cheques
        Otros cargos $64,161.11 Saldo inicial $5,627.93
        Detalle de movimientos
        16-JUL-2026 PAGO TRANSFERENCIA SPEI 64,161.11 55,597.93
        17-JUL-2026 NOMINA 36,187.42 27,654.24
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "santander-agosto-2026.pdf"
        )

        XCTAssertEqual(snapshot.summary?.previousBalance, 55_627.93)
        XCTAssertEqual(snapshot.summary?.cashBalance, 27_654.24)
    }

    func testHiddenAdministrativeTextLayerFallsBackToOCR() {
        let hiddenLayer = String(repeating: "saldo cuenta metadata ", count: 12)
        XCTAssertTrue(FinanceStore.shouldUseOCR(extractedText: hiddenLayer, allowOCR: true))
    }

    func testStructuredMonthDateTextLayerDoesNotForceOCR() {
        let text = String(repeating: "16-JUL-2026 17-JUL-2026 COMPRA SUPERMERCADO 120.00 ", count: 5)
            + "Detalle de Movimientos Realizados"
        XCTAssertFalse(FinanceStore.shouldUseOCR(extractedText: text, allowOCR: true))
        XCTAssertFalse(FinanceStore.shouldUseOCR(extractedText: text, allowOCR: false))
    }
}
