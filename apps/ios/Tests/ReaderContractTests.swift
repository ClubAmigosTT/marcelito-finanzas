import XCTest
@testable import Marcelito

final class ReaderContractTests: XCTestCase {
    func testCanonicalRebuildIsInvalidatedWhenReaderVersionChanges() {
        XCTAssertTrue(FinanceStore.needsCanonicalRebuild(
            completed: true,
            completedReaderVersion: "ios-reader-legacy",
            currentReaderVersion: FinanceStore.readerVersion,
            hasSources: true
        ))
        XCTAssertFalse(FinanceStore.needsCanonicalRebuild(
            completed: true,
            completedReaderVersion: FinanceStore.readerVersion,
            currentReaderVersion: FinanceStore.readerVersion,
            hasSources: true
        ))
        XCTAssertFalse(FinanceStore.needsCanonicalRebuild(
            completed: false,
            completedReaderVersion: nil,
            currentReaderVersion: FinanceStore.readerVersion,
            hasSources: false
        ))
    }

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

    func testAmexLimitAndAvailableProduceCommittedDebt() {
        let text = """
        American Express
        The Platinum Credit Card
        Saldo Anterior Pagos y Créditos Nuevos Cargos Pago para no Pago
        23,150.88 - 32,744.61 + 49,559.88 = 39,966.15 3,197.29
        Límite de Crédito Límite Disponible
        a Agosto 27,2026 150,000.00 MN 99,632.79 MN
        Fecha y Detalle de las operaciones Importe en MN.
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "28_jul_2026_-_27_ago_2026.pdf"
        )

        XCTAssertEqual(snapshot.kind, .card)
        XCTAssertEqual(snapshot.summary?.creditLimit, 150_000)
        XCTAssertEqual(snapshot.summary?.creditAvailable, 99_632.79)
        XCTAssertEqual(snapshot.summary?.debtBalance, 39_966.15)
        XCTAssertEqual(snapshot.summary.map { max(Decimal(0), ($0.creditLimit ?? 0) - ($0.creditAvailable ?? 0)) }, 50_367.21)
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

    func testReaderRejectsAllKnownAdministrativeHeadingsWithAmounts() {
        // These lines deliberately look like dated monetary rows. They are
        // common in scanned/text-layer statements, but none is a movement.
        // Keep this contract broad so a parser change cannot turn a header or
        // account identifier into an expense again.
        let text = """
        Grupo Financiero BBVA
        BBVA México, Institución de Banca Múltiple
        Fecha Descripcion Cargos Abonos Saldo
        01/08/2026 Ciudad de México 123,456.78
        02/08/2026 No. de Serie del Certificado 2026070840014 456,789.01
        03/08/2026 TOTAL IMPORTE CARGOS 22,058.69
        04/08/2026 DEL AL 01/08/2026 31/08/2026 1,030.94
        05/08/2026 fecha de corte 27/08/2026 39,966.15
        06/08/2026 número de cuenta 0123456789 10,000.00
        07/08/2026 RFC ABC123456789 9,999.99
        08/08/2026 cuenta CLABE 012180001234567890 8,888.88
        09/08/2026 saldo disponible 7,777.77
        10/08/2026 total del periodo 6,666.66
        11/08/2026 periodo de facturación 5,555.55
        12/08/2026 OXXO 95.00 935.94
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "bbva-agosto-2026.pdf"
        )

        XCTAssertEqual(snapshot.movements.count, 1)
        XCTAssertEqual(snapshot.movements.first?.title, "OXXO")
        XCTAssertFalse(snapshot.movements.contains { $0.title.localizedCaseInsensitiveContains("saldo") })
        XCTAssertFalse(snapshot.movements.contains { $0.title.localizedCaseInsensitiveContains("periodo") })
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

    func testBankSummaryToleratesOcrRetrosVariant() {
        let text = """
        Banco Santander México, S.A., Institución de Banca Múltiple
        Saldo inicial 37,075.03
        Depósitos 49,222.45
        Retros 61,676.00
        Saldo final 24,621.48
        Detalle de movimientos
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "santander-mayo-2026.pdf"
        )

        XCTAssertEqual(snapshot.summary?.depositTotal, 49_222.45)
        XCTAssertEqual(snapshot.summary?.withdrawalTotal, 61_676.00)
        XCTAssertEqual(snapshot.summary?.cashBalance, 24_621.48)
    }

    func testBankSummaryRecoversFusedOcrSeparators() {
        let text = """
        Banco Santander México, S.A., Institución de Banca Múltiple
        Saldo inicial 5562793
        Depósitos 3618742
        Retros 6416111
        Saldo final 2765424
        Detalle de movimientos
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "santander-agosto-2026.pdf"
        )

        XCTAssertEqual(snapshot.summary?.previousBalance, 55_627.93)
        XCTAssertEqual(snapshot.summary?.depositTotal, 36_187.42)
        XCTAssertEqual(snapshot.summary?.withdrawalTotal, 64_161.11)
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

    func testSantanderOCRAmountUsesSmallRunningBalanceDriftOnly() {
        let repaired = FinanceStore.repairedBankOCRAmountForTesting(
            selected: 30.01,
            selectedText: "30.01",
            previousBalance: 55_627.93,
            runningBalance: 55_597.93
        )
        XCTAssertEqual(NSDecimalNumber(decimal: repaired).doubleValue, 30, accuracy: 0.001)

        let unchanged = FinanceStore.repairedBankOCRAmountForTesting(
            selected: 500,
            selectedText: "500.00",
            previousBalance: 1_000,
            runningBalance: 200
        )
        XCTAssertEqual(NSDecimalNumber(decimal: unchanged).doubleValue, 500, accuracy: 0.001)
    }

    func testSantanderOCRUsesMovementColumnInsteadOfRunningBalance() {
        let rows = FinanceStore.santanderOCRRowsForTesting([
            OCRObservationFixture(text: "16-JUL-2026", x: 0.05, y: 0.80, width: 0.10),
            OCRObservationFixture(text: "PAGO TRANSFERENCIA SPEI", x: 0.18, y: 0.80, width: 0.40),
            OCRObservationFixture(text: "30.00", x: 0.76, y: 0.80, width: 0.08),
            OCRObservationFixture(text: "55,597.93", x: 0.92, y: 0.80, width: 0.08),
            OCRObservationFixture(text: "17-JUL-2026", x: 0.05, y: 0.70, width: 0.10),
            OCRObservationFixture(text: "NOMINA EMPRESA", x: 0.18, y: 0.70, width: 0.40),
            OCRObservationFixture(text: "500.00", x: 0.64, y: 0.70, width: 0.08),
            OCRObservationFixture(text: "56,097.93", x: 0.92, y: 0.70, width: 0.08),
        ], fileName: "Santander agosto 2026.pdf")

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].amount, -30)
        XCTAssertEqual(rows[1].amount, 500)
        XCTAssertFalse(rows.contains { abs(NSDecimalNumber(decimal: $0.amount).doubleValue) > 1_000 })
    }

    func testSantanderOCRCalibratesShiftedColumnsFromHeader() {
        let rows = FinanceStore.santanderOCRRowsForTesting([
            OCRObservationFixture(text: "DEPOSITO", x: 0.50, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "RETIRO", x: 0.64, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "SALDO", x: 0.79, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "16-JUL-2026", x: 0.02, y: 0.80, width: 0.10),
            OCRObservationFixture(text: "PAGO TRANSFERENCIA SPEI", x: 0.10, y: 0.80, width: 0.34),
            OCRObservationFixture(text: "30.00", x: 0.66, y: 0.80, width: 0.08),
            OCRObservationFixture(text: "55,597.93", x: 0.81, y: 0.80, width: 0.08),
            OCRObservationFixture(text: "17-JUL-2026", x: 0.02, y: 0.70, width: 0.10),
            OCRObservationFixture(text: "NOMINA EMPRESA", x: 0.10, y: 0.70, width: 0.34),
            OCRObservationFixture(text: "500.00", x: 0.52, y: 0.70, width: 0.08),
            OCRObservationFixture(text: "56,097.93", x: 0.81, y: 0.70, width: 0.08),
        ], fileName: "Santander agosto 2026.pdf")

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].amount, -30)
        XCTAssertEqual(rows[1].amount, 500)
    }

    func testSantanderOCRIgnoresMultilineFolioTraceAndRunningBalance() {
        let rows = FinanceStore.santanderOCRRowsForTesting([
            OCRObservationFixture(text: "DEPOSITO", x: 0.50, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "RETIRO", x: 0.64, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "SALDO", x: 0.79, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "16-JUL-2026", x: 0.02, y: 0.80, width: 0.10),
            OCRObservationFixture(text: "4309379 PAGO TRANSFERENCIA SPEI HORA 12:10:44", x: 0.10, y: 0.80, width: 0.45),
            OCRObservationFixture(text: "30.00", x: 0.66, y: 0.80, width: 0.08),
            OCRObservationFixture(text: "55,597.93", x: 0.81, y: 0.80, width: 0.08),
            OCRObservationFixture(text: "CLAVE DE RASTREO 202607160014BMOVP020443093790", x: 0.10, y: 0.795, width: 0.55),
            OCRObservationFixture(text: "REF 2603559 DATO NO VERIFICADO POR ESTA INSTITUCION", x: 0.10, y: 0.790, width: 0.55),
        ], fileName: "Santander agosto 2026.pdf")

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].amount, -30)
        XCTAssertFalse(rows[0].title.contains("55,597.93"))
    }

    func testSantanderOCRReconstructsSeveralRowsWithDepositsAndContinuationText() {
        let rows = FinanceStore.santanderOCRRowsForTesting([
            OCRObservationFixture(text: "DEPOSITO", x: 0.58, y: 0.94, width: 0.08),
            OCRObservationFixture(text: "RETIRO", x: 0.71, y: 0.94, width: 0.08),
            OCRObservationFixture(text: "SALDO", x: 0.84, y: 0.94, width: 0.08),

            OCRObservationFixture(text: "16-JUL-2026 4309379 PAGO TRANSFERENCIA SPEI HORA 12:10:44", x: 0.02, y: 0.82, width: 0.55),
            OCRObservationFixture(text: "30.00", x: 0.72, y: 0.82, width: 0.08),
            OCRObservationFixture(text: "55,597.93", x: 0.84, y: 0.82, width: 0.08),
            OCRObservationFixture(text: "CLAVE DE RASTREO 202607160014BMOVP020443093790", x: 0.10, y: 0.805, width: 0.55),
            OCRObservationFixture(text: "REF 2603559 DATO NO VERIFICADO POR ESTA INSTITUCION", x: 0.10, y: 0.79, width: 0.55),

            OCRObservationFixture(text: "17-JUL-2026 1162428 PAGO TRANSFERENCIA SPEI TRANSFERENCIA A VICTORIA", x: 0.02, y: 0.72, width: 0.55),
            OCRObservationFixture(text: "30.00", x: 0.72, y: 0.72, width: 0.08),
            OCRObservationFixture(text: "55,567.93", x: 0.84, y: 0.72, width: 0.08),

            OCRObservationFixture(text: "18-JUL-2026 000100 ABONO PAGO DE NOMINA", x: 0.02, y: 0.62, width: 0.55),
            OCRObservationFixture(text: "500.00", x: 0.58, y: 0.62, width: 0.08),
            OCRObservationFixture(text: "56,067.93", x: 0.84, y: 0.62, width: 0.08),
        ], fileName: "Santander agosto 2026.pdf")

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.amount), [-30, -30, 500])
        XCTAssertEqual(rows[2].flow, .income)
        XCTAssertTrue(rows[0].title.localizedCaseInsensitiveContains("transferencia"))
        XCTAssertFalse(rows.contains {
            $0.title.contains("55,597.93")
                || $0.title.contains("202607160014")
                || $0.title.localizedCaseInsensitiveContains("clave de rastreo")
                || $0.title.localizedCaseInsensitiveContains("a la cuenta")
        })
    }

    func testUnverifiedReadyStatementCannotFeedNativeDashboard() {
        let store = FinanceStore()
        defer { store.clearLocalData() }
        let statement = StatementRecord(
            id: UUID(),
            source: "BBVA",
            period: "agosto 2026",
            fileName: "estado.pdf",
            importedAt: .now,
            transactionCount: 0,
            requiresReview: false,
            kind: .bank,
            reconciliation: StatementReconciliationRecord(
                status: .valid,
                tolerance: Decimal(string: "0.05") ?? Decimal(0.05)
            ),
            sourceDetection: SourceDetectionEvidence(
                source: "BBVA",
                confidence: 0.90,
                status: .review,
                evidence: ["nombre de archivo"],
                ignoredBodyMentions: []
            ),
            readerVersion: FinanceStore.readerVersion
        )
        store.statements = [statement]
        store.movements = []

        XCTAssertTrue(store.dashboardIsBlocked)
        XCTAssertEqual(store.ledgerQuality.validatedStatementCount, 0)
        XCTAssertTrue(store.confirmStatementReviewed(statement))
        XCTAssertTrue(store.statements[0].issuerConfirmedByUser == true)
        XCTAssertFalse(store.dashboardIsBlocked)
        XCTAssertEqual(store.ledgerQuality.validatedStatementCount, 1)
    }
}
