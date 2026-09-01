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

    func testAccountIdentityUsesOnlyHeaderLastFourDigits() {
        let text = """
        BBVA México, Institución de Banca Múltiple, Grupo Financiero BBVA México
        Estado de cuenta
        No. de Cuenta 9988776655
        Fecha Descripcion Cargos Abonos Saldo
        05/08/2026 SPEI RECIBIDO SANTANDER 4,500.00 6,116.63
        06/08/2026 TRANSFERENCIA A CUENTA 111122223333444455 100.00 6,016.63
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "sample-bank-bbva.pdf"
        )

        XCTAssertEqual(snapshot.accountKey, "bbva:6655")
        XCTAssertFalse(snapshot.accountKey?.contains("9988776655") == true)
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

    func testInstitutionalBBVAHeaderBeatsAConflictingSantanderFilename() {
        let text = """
        BBVA México, Institución de Banca Múltiple, Grupo Financiero BBVA México
        Estado de cuenta
        Detalle de Movimientos Realizados
        05/AGO SPEI RECIBIDO SANTANDER 4,500.00 6,116.63
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "sample-bank-period-3.pdf"
        )

        XCTAssertEqual(snapshot.source, "BBVA")
        XCTAssertEqual(snapshot.sourceDetection.status, .verified)
        XCTAssertTrue(snapshot.sourceDetection.evidence.contains { $0.contains("encabezado institucional BBVA") })
    }

    func testConflictingLegalFooterDoesNotUseFilenameFallback() {
        let text = """
        Detalle de Movimientos Realizados
        01/08/2026 CARGO SUPERMERCADO 100.00
        BBVA México, Institución de Banca Múltiple, Grupo Financiero BBVA México
        Banco Santander México, Institución de Banca Múltiple, Grupo Financiero Santander
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "sample-bank-period-3.pdf"
        )

        XCTAssertEqual(snapshot.source, "Importado")
        XCTAssertEqual(snapshot.sourceDetection.status, .unknown)
        XCTAssertTrue(snapshot.sourceDetection.evidence.contains { $0.contains("marcadores legales conflictivos") })
    }

    func testConflictingInstitutionalHeaderDoesNotUseFilenameFallback() {
        let text = """
        BBVA México, Institución de Banca Múltiple, Grupo Financiero BBVA México
        Banco Santander México, Institución de Banca Múltiple, Grupo Financiero Santander
        Detalle de Movimientos Realizados
        01/08/2026 CARGO SUPERMERCADO 100.00
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "sample-bank-period-3.pdf"
        )

        XCTAssertEqual(snapshot.source, "Importado")
        XCTAssertEqual(snapshot.sourceDetection.status, .unknown)
        XCTAssertTrue(snapshot.sourceDetection.evidence.contains { $0.contains("marcadores legales conflictivos") })
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
            fileName: "sample-card-period-3.pdf"
        )

        XCTAssertEqual(snapshot.source, "Amex")
        XCTAssertEqual(snapshot.kind, .card)
        XCTAssertEqual(snapshot.movements.count, 2)
        XCTAssertTrue(snapshot.movements.contains { $0.kind == .credit && $0.amount > 0 })
        XCTAssertFalse(snapshot.movements.contains { $0.title.localizedCaseInsensitiveContains("fecha y detalle") })
    }

    func testAmexForeignRowUsesTheLocalMXNAmount() {
        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: """
            American Express
            The Platinum Credit Card
            Fecha y Detalle de las operaciones Importe en MN.
            19 de Junio CHIPOTLE 5071 NEW YORK
            RFC123456789 /REF123456789
            Dólar U.S.A. 19.05 TC:17.79265
            338.95
            """,
            fileName: "sample-card-period-3.pdf"
        )

        XCTAssertEqual(snapshot.movements.count, 1)
        XCTAssertEqual(snapshot.movements.first?.amount, -338.95)
        XCTAssertTrue(snapshot.movements.first?.foreignCurrency == true)
        XCTAssertFalse(snapshot.movements.first?.title.contains("19.05") == true)
    }

    func testAmexSectionTotalsIgnoreFutureMSIInstallments() {
        let movements = [
            Movement(date: .now, title: "Compras nacionales", account: "Amex", category: "Comidas", amount: -496.50, flow: .expense, kind: .purchase),
            Movement(date: .now, title: "Monto a diferir", account: "Amex", category: "Finanzas", amount: 27_537.69, flow: .income, kind: .credit),
            Movement(date: .now, title: "Compras extranjeras", account: "Amex", category: "Comidas", amount: -27_537.69, flow: .expense, kind: .purchase, foreignCurrency: true),
            Movement(date: .now, title: "Meses sin intereses", account: "Amex", category: "Finanzas", amount: -9_179.23, flow: .expense, kind: .msi)
        ]
        var summary = StatementSummaryRecord()
        summary.domesticTransactionTotal = 27_041.19
        summary.foreignTransactionTotal = 27_537.69
        summary.newCharges = 37_213.42

        let reconciliation = FinanceStore.reconcileStatementForTesting(
            kind: .card,
            summary: summary,
            movements: movements
        )

        XCTAssertEqual(reconciliation.status, .valid, reconciliation.reason ?? "")
    }

    func testAmexTextReaderUsesOnlyMovementSectionsAndReconciles() {
        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: """
            American Express
            The Platinum Credit Card
            Límite de Crédito Límite Disponible
            a Agosto 27,2026 10,000.00 MN 9,000.00 MN
            23,150.88 - 32,744.61 + 950.00 = 950.00 300.00
            Nuevas transacciones: 900.00
            Total Nuevos Cargos: 950.00
            MARCELO ANDRES DIAZ SANCHEZ 27-Ago-2026 27-Sep-2026
            Fecha y Detalle de las operaciones Importe en MN.
            05 de Agosto SUPERMERCADO 700.00
            27 de Agosto MONTO A DIFERIR MESES EN AUTOMÁTICO 100.00
            CR
            Total de las transacciones en $ de MARCELO ANDRES DIAZ SANCHEZ 600.00
            Estado de Cuenta Página 3
            MARCELO ANDRES DIAZ SANCHEZ 27-Ago-2026 27-Sep-2026
            Fecha y Detalle de las operaciones Importe en MN.
            6 de Agosto HOLAFLY DUBLIN
            Euro 15,50 TC:20.00
            200.00
            Total de Transacciones en Moneda Extranjera de MARCELO ANDRES DIAZ SANCHEZ 200.00
            Transacciones de Meses sin Intereses
            27 de Agosto MESES EN AUTOMÁTICO EXTRANJERO
            CARGO 01 DE 03
            50.00
            Total de Meses sin Intereses 50.00
            Resumen de Meses sin Intereses
            27 de Ago 9,593.73 0.00% 6,395.82 1 de 3 3,197.91
            """,
            fileName: "28_jul_2026_-_27_ago_2026.pdf"
        )

        XCTAssertEqual(snapshot.source, "Amex")
        XCTAssertEqual(snapshot.kind, .card)
        XCTAssertEqual(snapshot.summary?.domesticTransactionTotal, 600)
        XCTAssertEqual(snapshot.summary?.foreignTransactionTotal, 200)
        XCTAssertEqual(snapshot.movements.count, 4)
        XCTAssertEqual(snapshot.movements.filter { $0.kind == .purchase }.count, 2)
        XCTAssertEqual(snapshot.movements.filter { $0.kind == .credit }.count, 1)
        XCTAssertEqual(snapshot.movements.filter { $0.kind == .msi }.count, 1)
        XCTAssertEqual(
            snapshot.movements.filter { $0.flow == .expense }.reduce(Decimal.zero) { $0 + abs($1.amount) },
            Decimal(string: "950.00")!
        )
        XCTAssertFalse(snapshot.movements.contains { $0.title.localizedCaseInsensitiveContains("estado de cuenta") })

        let reconciliation = FinanceStore.reconcileStatementForTesting(
            kind: .card,
            summary: snapshot.summary,
            movements: snapshot.movements
        )
        XCTAssertEqual(reconciliation.status, .valid, reconciliation.reason ?? "")
    }

    func testBBVAStatementRebuildsAllMovementRowsAndExcludesBalances() {
        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: """
            BBVA MEXICO, S.A., INSTITUCION DE BANCA MULTIPLE, GRUPO FINANCIERO BBVA MEXICO
            Comportamiento
            Saldo Anterior 3,589.63
            Depósitos / Abonos (+) 2 19,500.00
            Retiros / Cargos (-) 9 22,058.69
            Saldo Final 1,030.94
            Detalle de Movimientos Realizados
            FECHA SALDO OPER LIQ DESCRIPCION REFERENCIA CARGOS ABONOS OPERACION LIQUIDACION
            23/JUL 22/JUL FACEBK *XR4NKVVF52 120.00 3,469.63 3,469.63
            27/JUL 27/JUL SPEI RECIBIDO NVIO 15,000.00 18,469.63 18,469.63
            29/JUL 29/JUL SPEI ENVIADO STP 13,000.00 5,469.63 5,369.63
            30/JUL 30/JUL SPEI ENVIADO STP 500.00
            30/JUL 29/JUL TELEF MOVIS MC INSURGE 100.00 4,869.63 4,869.63
            03/AGO 04/AGO PAGO CUENTA DE TERCERO 3,253.00 1,616.63 4,869.63
            05/AGO 05/AGO SPEI RECIBIDO SANTANDER 4,500.00 6,116.63 6,116.63
            06/AGO 06/AGO RETIRO CAJERO AUTOMATICO 4,515.83 1,600.80 1,530.94
            07/AGO 06/AGO COMISION CAJERO RED 60.23
            07/AGO 06/AGO IVA REP TARJ TIT 9.63 1,530.94 1,530.94
            10/AGO 10/AGO SPEI ENVIADO STP 500.00 1,030.94 1,030.94
            TOTAL IMPORTE CARGOS 22,058.69 TOTAL MOVIMIENTOS CARGOS 9
            TOTAL IMPORTE ABONOS 19,500.00 TOTAL MOVIMIENTOS ABONOS 2
            """,
            fileName: "sample-bank-bbva.pdf"
        )

        XCTAssertEqual(snapshot.source, "BBVA")
        XCTAssertEqual(
            snapshot.movements.count,
            11,
            snapshot.movements.map { "\($0.title)=\($0.amount)" }.joined(separator: " | ")
        )
        let charges = snapshot.movements.filter { $0.amount < 0 }
            .reduce(Decimal.zero) { $0 + abs($1.amount) }
        let deposits = snapshot.movements.filter { $0.amount > 0 }
            .reduce(Decimal.zero) { $0 + $1.amount }
        XCTAssertEqual(
            charges,
            Decimal(string: "22058.69")!,
            snapshot.movements.map { "\($0.title)=\($0.amount)" }.joined(separator: " | ")
        )
        XCTAssertEqual(deposits, Decimal(string: "19500.00")!)
        XCTAssertFalse(snapshot.movements.contains { $0.title.localizedCaseInsensitiveContains("saldo") })
    }

    func testAmexLimitAndAvailableProduceCommittedDebt() {
        let text = """
        American Express
        The Platinum Credit Card
        Saldo Anterior Pagos y Créditos Nuevos Cargos Pago para no Pago
        3,200.00 - 1,000.00 + 1,117.75 = 3,317.75 300.00
        Límite de Crédito Límite Disponible
        a Agosto 27,2026 20,000.00 MN 16,682.25 MN
        Fecha y Detalle de las operaciones Importe en MN.
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "sample-card-period-3.pdf"
        )

        XCTAssertEqual(snapshot.kind, .card)
        XCTAssertEqual(snapshot.summary?.creditLimit, 20_000)
        XCTAssertEqual(snapshot.summary?.creditAvailable, Decimal(string: "16682.25"))
        XCTAssertEqual(snapshot.summary?.debtBalance, 3_317.75)
        XCTAssertEqual(snapshot.summary.map { max(Decimal(0), ($0.creditLimit ?? 0) - ($0.creditAvailable ?? 0)) }, 3_317.75)
    }

    func testAmexSummaryKeepsMinimumPlusMsiSeparate() {
        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: """
            American Express
            The Platinum Credit Card
            Pago mínimo más meses sin intereses 1,957.97
            Pago para no generar intereses 3,996.62
            """,
            fileName: "sample-card-period-3.pdf"
        )

        XCTAssertEqual(snapshot.summary?.minimumPlusMsi, 1_957.97)
        XCTAssertEqual(snapshot.summary?.paymentForNoInterest, 3_996.62)
    }

    func testReaderRejectsAdministrativeNumericRows() {
        let text = """
        Grupo Financiero BBVA
        BBVA México, Institución de Banca Múltiple
        Fecha Descripcion
        03/08/2026 Ciudad de México No. de Serie del Certificado 2030010100001 123,456.78
        05/08/2026 SPEI RECIBIDO 1234567
        04/08/2026 OXXO 95.00 1,200.00
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "sample-bank-bbva.pdf"
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
        02/08/2026 No. de Serie del Certificado 2030010100001 456,789.01
        03/08/2026 TOTAL IMPORTE CARGOS 22,058.69
        04/08/2026 DEL AL 01/08/2026 31/08/2026 1,230.94
        05/08/2026 fecha de corte 27/08/2026 3,996.62
        06/08/2026 número de cuenta 0123456789 10,000.00
        07/08/2026 RFC ABC123456789 9,999.99
        08/08/2026 cuenta CLABE 111122223333444455 8,888.88
        09/08/2026 saldo disponible 7,777.77
        10/08/2026 total del periodo 6,666.66
        11/08/2026 periodo de facturación 5,555.55
        12/08/2026 OXXO 95.00 935.94
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "sample-bank-bbva.pdf"
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
            fileName: "sample-bank-bbva.pdf"
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
        O5/AG0 TIENDA DE PRUEBA 125.00 1,230.94
        OBIAGO NOMINA EMPRESA 1,000.00 2,030.94
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "sample-bank-bbva.pdf"
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
            fileName: "sample-bank-bbva.pdf"
        )

        XCTAssertEqual(snapshot.movements.count, 1)
        XCTAssertEqual(snapshot.movements.first?.extractionEvidence?.page, 2)
        XCTAssertFalse(snapshot.movements.first?.extractionEvidence?.sourceText?.isEmpty ?? true)
    }

    func testBankSummaryChoosesOpeningBalanceThatReconciles() {
        let text = """
        Banco Santander México, S.A., Institución de Banca Múltiple, Grupo Financiero Santander México
        Saldo promedio 50,129.64 — Saldoinicial 5562.79
        + Depósitos 3,618.74
        − Retiros 6,416.11
        = Saldo final 2,765.42
        Gráfico cuenta de cheques
        Otros cargos $6,416.11 Saldo inicial $562.79
        Detalle de movimientos
        16-JUL-2026 PAGO TRANSFERENCIA SPEI 6,416.11 5,559.79
        17-JUL-2026 NOMINA 3,618.74 2,765.42
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "sample-bank-period-3.pdf"
        )

        XCTAssertEqual(snapshot.summary?.previousBalance, 5562.79)
        XCTAssertEqual(snapshot.summary?.cashBalance, 2_765.42)
    }

    func testBankSummaryToleratesOcrRetrosVariant() {
        let text = """
        Banco Santander México, S.A., Institución de Banca Múltiple
        Saldo inicial 3,707.50
        Depósitos 4,922.25
        Retros 6,167.60
        Saldo final 2,462.48
        Detalle de movimientos
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "sample-bank-period-1.pdf"
        )

        XCTAssertEqual(snapshot.summary?.depositTotal, 4_922.25)
        XCTAssertEqual(snapshot.summary?.withdrawalTotal, 6_167.60)
        XCTAssertEqual(snapshot.summary?.cashBalance, 2_462.48)
    }

    func testBankSummaryRecoversFusedOcrSeparators() {
        let text = """
        Banco Santander México, S.A., Institución de Banca Múltiple
        Saldo inicial 1234567
        Depósitos 2345678
        Retros 0876543
        Saldo final 2703702
        Detalle de movimientos
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "sample-bank-period-3.pdf"
        )

        XCTAssertEqual(snapshot.summary?.previousBalance, 12_345.67)
        XCTAssertEqual(snapshot.summary?.depositTotal, Decimal(string: "23456.78"))
        XCTAssertEqual(snapshot.summary?.withdrawalTotal, 8_765.43)
        XCTAssertEqual(snapshot.summary?.cashBalance, 27_037.02)
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

    func testAmexTextRowsWithContinuationAmountsDoNotForceOCR() {
        let text = "American Express\nFecha y Detalle de las operaciones Importe en MN.\n"
            + String(repeating: "5 de Agosto AMAZON MX\nRFC123456789 /REFABC123\n123.45\n", count: 4)

        XCTAssertFalse(FinanceStore.shouldUseOCR(extractedText: text, allowOCR: true))
    }

    func testProvenAmexTextLayerWinsOverOCRHeuristic() {
        let text = """
        American Express
        The Platinum Credit Card
        Límite de Crédito Límite Disponible
        a Agosto 27,2026 10,000.00 MN 9,000.00 MN
        23,150.88 - 32,744.61 + 950.00 = 950.00 300.00
        Nuevas transacciones: 900.00
        Total Nuevos Cargos: 950.00
        Fecha y Detalle de las operaciones Importe en MN.
        05 de Agosto SUPERMERCADO 700.00
        27 de Agosto MONTO A DIFERIR MESES EN AUTOMÁTICO 100.00 CR
        Total de las transacciones en $ de MARCELO ANDRES DIAZ SANCHEZ 600.00
        Fecha y Detalle de las operaciones Importe en MN.
        6 de Agosto HOLAFLY DUBLIN Euro 15,50 TC:20.00 200.00
        Total de Transacciones en Moneda Extranjera de MARCELO ANDRES DIAZ SANCHEZ 200.00
        Transacciones de Meses sin Intereses
        27 de Agosto MESES EN AUTOMÁTICO EXTRANJERO CARGO 01 DE 03 50.00
        Total de Meses sin Intereses 50.00
        """

        XCTAssertTrue(FinanceStore.selectableTextLayerReconcilesForTesting(
            text: text,
            fileName: "28_jul_2026_-_27_ago_2026.pdf"
        ))
    }

    func testTableHeaderWithoutPlausibleRowsFallsBackToOCR() {
        let text = String(repeating: "RFC DIRECCION CERTIFICADO SALDO ", count: 30)
            + "Detalle de Movimientos Realizados\n"
            + "Periodo 16-JUL-2026 AL 15-AGO-2026\n"
            + "No. de Cuenta 9988776655"
        XCTAssertTrue(FinanceStore.shouldUseOCR(extractedText: text, allowOCR: true))
    }

    func testSantanderOCRAmountUsesSmallRunningBalanceDriftOnly() {
        let repaired = FinanceStore.repairedBankOCRAmountForTesting(
            selected: 30.01,
            selectedText: "30.01",
            previousBalance: 12_345.67,
            runningBalance: 12_315.67
        )
        XCTAssertEqual(NSDecimalNumber(decimal: repaired).doubleValue, 30, accuracy: 0.001)

        let unchanged = FinanceStore.repairedBankOCRAmountForTesting(
            selected: 500,
            selectedText: "500.00",
            previousBalance: 1_000,
            runningBalance: 200
        )
        XCTAssertEqual(NSDecimalNumber(decimal: unchanged).doubleValue, 500, accuracy: 0.001)

        let leadingOne = FinanceStore.repairedBankOCRAmountForTesting(
            selected: 160,
            selectedText: "160.00",
            previousBalance: 12_345.67,
            runningBalance: 12_285.67
        )
        XCTAssertEqual(NSDecimalNumber(decimal: leadingOne).doubleValue, 60, accuracy: 0.001)

        let leadingOneWithThreeDigits = FinanceStore.repairedBankOCRAmountForTesting(
            selected: 1_693,
            selectedText: "1693.00",
            previousBalance: 9_876.54,
            runningBalance: 9_183.54
        )
        XCTAssertEqual(NSDecimalNumber(decimal: leadingOneWithThreeDigits).doubleValue, 693, accuracy: 0.001)
    }

    func testSantanderOCRUsesMovementColumnInsteadOfRunningBalance() {
        let rows = FinanceStore.santanderOCRRowsForTesting([
            OCRObservationFixture(text: "16-JUL-2026", x: 0.05, y: 0.80, width: 0.10),
            OCRObservationFixture(text: "PAGO TRANSFERENCIA SPEI", x: 0.18, y: 0.80, width: 0.40),
            OCRObservationFixture(text: "30.00", x: 0.76, y: 0.80, width: 0.08),
            OCRObservationFixture(text: "5,559.79", x: 0.92, y: 0.80, width: 0.08),
            OCRObservationFixture(text: "17-JUL-2026", x: 0.05, y: 0.70, width: 0.10),
            OCRObservationFixture(text: "NOMINA EMPRESA", x: 0.18, y: 0.70, width: 0.40),
            OCRObservationFixture(text: "500.00", x: 0.64, y: 0.70, width: 0.08),
            OCRObservationFixture(text: "56,097.93", x: 0.92, y: 0.70, width: 0.08),
        ], fileName: "sample-bank-period-3.pdf")

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].amount, -30)
        XCTAssertEqual(rows[1].amount, 500)
        XCTAssertFalse(rows.contains { abs(NSDecimalNumber(decimal: $0.amount).doubleValue) > 1_000 })
    }

    func testAmexOCRUsesLocalAmountAfterForeignCurrencyConversion() {
        let rows = FinanceStore.amexOCRRowsForTesting([
            // Cover/header content must not become a movement merely because
            // it contains a cutoff date and payment amount.
            OCRObservationFixture(page: 0, text: "Estado de Cuenta", x: 0.05, y: 0.92, width: 0.30),
            OCRObservationFixture(page: 0, text: "27-Ago-2026", x: 0.40, y: 0.84, width: 0.14),
            // Page 2 starts the actual transaction table.
            OCRObservationFixture(page: 1, text: "Fecha y Detalle de las operaciones", x: 0.05, y: 0.92, width: 0.40),
            OCRObservationFixture(page: 1, text: "5 de Agosto", x: 0.05, y: 0.82, width: 0.16),
            OCRObservationFixture(page: 1, text: "SUPERMERCADO", x: 0.18, y: 0.82, width: 0.28),
            OCRObservationFixture(page: 1, text: "123.45", x: 0.86, y: 0.82, width: 0.08),
            OCRObservationFixture(page: 1, text: "6 de Agosto", x: 0.05, y: 0.70, width: 0.16),
            OCRObservationFixture(page: 1, text: "BOLD CO S A S", x: 0.18, y: 0.70, width: 0.28),
            OCRObservationFixture(page: 1, text: "Peso Colombiano", x: 0.18, y: 0.66, width: 0.24),
            OCRObservationFixture(page: 1, text: "183,600.00", x: 0.70, y: 0.66, width: 0.12),
            OCRObservationFixture(page: 1, text: "TC:0.00562", x: 0.70, y: 0.62, width: 0.12),
            OCRObservationFixture(page: 1, text: "1,031.17", x: 0.86, y: 0.58, width: 0.10),
        ], fileName: "28_jul_2026_-_27_ago_2026.pdf")

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].amount, Decimal(string: "-123.45")!)
        XCTAssertEqual(rows[1].amount, Decimal(string: "-1031.17")!)
        XCTAssertFalse(rows.contains { abs(NSDecimalNumber(decimal: $0.amount).doubleValue) > 2_000 })
    }

    func testAmexOCRUsesRightmostLocalAmountWhenVisionReturnsWholeRow() {
        // A few Vision revisions return the merchant, source currency, TC and
        // local amount as one observation. The parser must use the visual
        // right-hand amount rather than the last numeric token in the string.
        let rows = FinanceStore.amexOCRRowsForTesting([
            OCRObservationFixture(page: 1, text: "Fecha y Detalle de las operaciones", x: 0.05, y: 0.92, width: 0.40),
            OCRObservationFixture(
                page: 1,
                text: "6 de Agosto BOLD CO S A S MEDELLIN 1,031.17 Peso Colombiano 183,600.00 TC:0.00562",
                x: 0.02,
                y: 0.82,
                width: 0.96
            ),
        ], fileName: "28_jul_2026_-_27_ago_2026.pdf")

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].amount, Decimal(string: "-1031.17")!)
        XCTAssertFalse(rows.contains { abs(NSDecimalNumber(decimal: $0.amount).doubleValue) > 2_000 })
    }

    func testAmexOCRUsesConvertedAmountWhenSourceCurrencyPrecedesIt() {
        // This is the actual order printed by the Amex statement: source
        // currency, source amount, exchange rate, then the local MXN amount.
        // The source amount must never become the consolidated expense.
        let rows = FinanceStore.amexOCRRowsForTesting([
            OCRObservationFixture(page: 4, text: "Fecha y Detalle de las operaciones", x: 0.05, y: 0.92, width: 0.40),
            OCRObservationFixture(
                page: 4,
                text: "6 de Agosto BOLD CO S A S MEDELLIN",
                x: 0.02,
                y: 0.82,
                width: 0.48
            ),
            OCRObservationFixture(page: 4, text: "Peso Colombiano", x: 0.18, y: 0.78, width: 0.24),
            OCRObservationFixture(page: 4, text: "183,600.00", x: 0.70, y: 0.78, width: 0.12),
            OCRObservationFixture(page: 4, text: "TC:0.00562", x: 0.70, y: 0.74, width: 0.12),
            OCRObservationFixture(page: 4, text: "1,031.17", x: 0.86, y: 0.70, width: 0.10),
        ], fileName: "28_jul_2026_-_27_ago_2026.pdf")

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].amount, Decimal(string: "-1031.17")!)
        XCTAssertFalse(rows.contains { abs(NSDecimalNumber(decimal: $0.amount).doubleValue) > 2_000 })
    }

    func testAmexOCRDropsForeignRowWhenLocalMXNAmountIsMissing() {
        // A source-currency amount without its converted MXN value is not a
        // usable purchase. It must remain unresolved instead of becoming a
        // six-figure charge in the ledger.
        let rows = FinanceStore.amexOCRRowsForTesting([
            OCRObservationFixture(page: 1, text: "Fecha y Detalle de las operaciones", x: 0.05, y: 0.92, width: 0.40),
            OCRObservationFixture(page: 1, text: "6 de Agosto BOLD CO S A S MEDELLIN", x: 0.02, y: 0.82, width: 0.48),
            OCRObservationFixture(page: 1, text: "Peso Colombiano 183,600.00 TC:0.00562", x: 0.18, y: 0.78, width: 0.30),
        ], fileName: "28_jul_2026_-_27_ago_2026.pdf")

        XCTAssertTrue(rows.isEmpty)
    }

    func testSantanderOCRCalibratesShiftedColumnsFromHeader() {
        let rows = FinanceStore.santanderOCRRowsForTesting([
            OCRObservationFixture(text: "FECHA", x: 0.05, y: 0.90, width: 0.06),
            OCRObservationFixture(text: "FOLIO", x: 0.14, y: 0.90, width: 0.06),
            OCRObservationFixture(text: "DESCRIPCION", x: 0.23, y: 0.90, width: 0.12),
            OCRObservationFixture(text: "DEPOSITO", x: 0.50, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "RETIRO", x: 0.64, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "SALDO", x: 0.79, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "16-JUL-2026", x: 0.02, y: 0.80, width: 0.10),
            OCRObservationFixture(text: "PAGO TRANSFERENCIA SPEI", x: 0.10, y: 0.80, width: 0.34),
            OCRObservationFixture(text: "30.00", x: 0.66, y: 0.80, width: 0.08),
            OCRObservationFixture(text: "5,559.79", x: 0.81, y: 0.80, width: 0.08),
            OCRObservationFixture(text: "17-JUL-2026", x: 0.02, y: 0.70, width: 0.10),
            OCRObservationFixture(text: "NOMINA EMPRESA", x: 0.10, y: 0.70, width: 0.34),
            OCRObservationFixture(text: "500.00", x: 0.52, y: 0.70, width: 0.08),
            OCRObservationFixture(text: "56,097.93", x: 0.81, y: 0.70, width: 0.08),
        ], fileName: "sample-bank-period-3.pdf")

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].amount, -30)
        XCTAssertEqual(rows[1].amount, 500)
    }

    func testSantanderOCRRequiresACompleteColumnHeaderForAutomaticAcceptance() {
        let calibrated = [
            OCRObservationFixture(text: "FECHA", x: 0.05, y: 0.90, width: 0.06),
            OCRObservationFixture(text: "DESCRIPCION", x: 0.23, y: 0.90, width: 0.12),
            OCRObservationFixture(text: "DEPOSITO", x: 0.50, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "RETIRO", x: 0.64, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "SALDO", x: 0.79, y: 0.90, width: 0.08),
        ]
        XCTAssertTrue(FinanceStore.santanderOCRColumnsCalibratedForTesting(calibrated, fileName: "sample-bank-period-3.pdf"))

        let missingAnchor = [
            OCRObservationFixture(text: "FECHA", x: 0.05, y: 0.90, width: 0.06),
            OCRObservationFixture(text: "DESCRIPCION", x: 0.23, y: 0.90, width: 0.12),
            OCRObservationFixture(text: "DEPOSITO", x: 0.50, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "SALDO", x: 0.79, y: 0.90, width: 0.08),
        ]
        XCTAssertFalse(FinanceStore.santanderOCRColumnsCalibratedForTesting(missingAnchor, fileName: "sample-bank-period-3.pdf"))
    }

    func testSantanderOCRAcceptsEquivalentAbonosAndCargosColumnLabels() {
        let labels = [
            OCRObservationFixture(text: "FECHA", x: 0.05, y: 0.90, width: 0.06),
            OCRObservationFixture(text: "DESCRIPCION", x: 0.23, y: 0.90, width: 0.12),
            OCRObservationFixture(text: "ABONOS", x: 0.50, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "CARGOS", x: 0.64, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "BALANCE", x: 0.79, y: 0.90, width: 0.08),
        ]

        XCTAssertTrue(FinanceStore.santanderOCRColumnsCalibratedForTesting(
            labels,
            fileName: "sample-bank-period-3.pdf"
        ))
    }

    func testSantanderOCRDoesNotMixColumnAnchorsAcrossPagesOrRows() {
        let splitAcrossPages = [
            OCRObservationFixture(page: 0, text: "FECHA", x: 0.05, y: 0.90, width: 0.06),
            OCRObservationFixture(page: 0, text: "DESCRIPCION", x: 0.23, y: 0.90, width: 0.12),
            OCRObservationFixture(page: 0, text: "DEPOSITO", x: 0.50, y: 0.90, width: 0.08),
            OCRObservationFixture(page: 1, text: "RETIRO", x: 0.64, y: 0.90, width: 0.08),
            OCRObservationFixture(page: 0, text: "SALDO", x: 0.79, y: 0.90, width: 0.08),
        ]
        XCTAssertFalse(FinanceStore.santanderOCRColumnsCalibratedForTesting(
            splitAcrossPages,
            fileName: "sample-bank-period-3.pdf"
        ))

        let splitAcrossRows = [
            OCRObservationFixture(text: "FECHA", x: 0.05, y: 0.90, width: 0.06),
            OCRObservationFixture(text: "DESCRIPCION", x: 0.23, y: 0.90, width: 0.12),
            OCRObservationFixture(text: "DEPOSITO", x: 0.50, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "RETIRO", x: 0.64, y: 0.76, width: 0.08),
            OCRObservationFixture(text: "SALDO", x: 0.79, y: 0.90, width: 0.08),
        ]
        XCTAssertFalse(FinanceStore.santanderOCRColumnsCalibratedForTesting(
            splitAcrossRows,
            fileName: "sample-bank-period-3.pdf"
        ))

        let splitLabelTokens = [
            OCRObservationFixture(text: "FECHA", x: 0.05, y: 0.90, width: 0.06),
            OCRObservationFixture(text: "DESCRIPCION", x: 0.23, y: 0.90, width: 0.12),
            OCRObservationFixture(text: "DEPOSI TO", x: 0.50, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "RETI RO", x: 0.64, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "SAL DO", x: 0.79, y: 0.90, width: 0.08),
        ]
        XCTAssertTrue(FinanceStore.santanderOCRColumnsCalibratedForTesting(
            splitLabelTokens,
            fileName: "sample-bank-period-3.pdf"
        ))

        let glyphSubstitutions = [
            OCRObservationFixture(text: "FECHA", x: 0.05, y: 0.90, width: 0.06),
            OCRObservationFixture(text: "DESCRIPC10N", x: 0.23, y: 0.90, width: 0.12),
            OCRObservationFixture(text: "DEPOS1T0", x: 0.50, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "RET1R0", x: 0.64, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "SALD0", x: 0.79, y: 0.90, width: 0.08),
        ]
        XCTAssertTrue(FinanceStore.santanderOCRColumnsCalibratedForTesting(
            glyphSubstitutions,
            fileName: "sample-bank-period-3.pdf"
        ))
    }

    func testSantanderOCRIgnoresMultilineFolioTraceAndRunningBalance() {
        let rows = FinanceStore.santanderOCRRowsForTesting([
            OCRObservationFixture(text: "DEPOSITO", x: 0.50, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "RETIRO", x: 0.64, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "SALDO", x: 0.79, y: 0.90, width: 0.08),
            OCRObservationFixture(text: "16-JUL-2026", x: 0.02, y: 0.80, width: 0.10),
            OCRObservationFixture(text: "4309379 PAGO TRANSFERENCIA SPEI HORA 12:10:44", x: 0.10, y: 0.80, width: 0.45),
            OCRObservationFixture(text: "30.00", x: 0.66, y: 0.80, width: 0.08),
            OCRObservationFixture(text: "5,559.79", x: 0.81, y: 0.80, width: 0.08),
            OCRObservationFixture(text: "CLAVE DE RASTREO 203001020014TEST000001", x: 0.10, y: 0.795, width: 0.55),
            OCRObservationFixture(text: "REF 2603559 DATO NO VERIFICADO POR ESTA INSTITUCION", x: 0.10, y: 0.790, width: 0.55),
        ], fileName: "sample-bank-period-3.pdf")

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].amount, -30)
        XCTAssertFalse(rows[0].title.contains("5,559.79"))
    }

    func testSantanderOCRReconstructsSeveralRowsWithDepositsAndContinuationText() {
        let rows = FinanceStore.santanderOCRRowsForTesting([
            OCRObservationFixture(text: "DEPOSITO", x: 0.58, y: 0.94, width: 0.08),
            OCRObservationFixture(text: "RETIRO", x: 0.71, y: 0.94, width: 0.08),
            OCRObservationFixture(text: "SALDO", x: 0.84, y: 0.94, width: 0.08),

            OCRObservationFixture(text: "16-JUL-2026 4309379 PAGO TRANSFERENCIA SPEI HORA 12:10:44", x: 0.02, y: 0.82, width: 0.55),
            OCRObservationFixture(text: "30.00", x: 0.72, y: 0.82, width: 0.08),
            OCRObservationFixture(text: "5,559.79", x: 0.84, y: 0.82, width: 0.08),
            OCRObservationFixture(text: "CLAVE DE RASTREO 203001020014TEST000001", x: 0.10, y: 0.805, width: 0.55),
            OCRObservationFixture(text: "REF 2603559 DATO NO VERIFICADO POR ESTA INSTITUCION", x: 0.10, y: 0.79, width: 0.55),

            OCRObservationFixture(text: "17-JUL-2026 1162428 PAGO TRANSFERENCIA SPEI TRANSFERENCIA A VICTORIA", x: 0.02, y: 0.72, width: 0.55),
            OCRObservationFixture(text: "30.00", x: 0.72, y: 0.72, width: 0.08),
            OCRObservationFixture(text: "55,567.93", x: 0.84, y: 0.72, width: 0.08),

            OCRObservationFixture(text: "18-JUL-2026 000100 ABONO PAGO DE NOMINA", x: 0.02, y: 0.62, width: 0.55),
            OCRObservationFixture(text: "500.00", x: 0.58, y: 0.62, width: 0.08),
            OCRObservationFixture(text: "56,067.93", x: 0.84, y: 0.62, width: 0.08),
        ], fileName: "sample-bank-period-3.pdf")

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.amount), [-30, -30, 500])
        XCTAssertEqual(rows[2].flow, .income)
        XCTAssertTrue(rows[0].title.localizedCaseInsensitiveContains("transferencia"))
        XCTAssertFalse(rows.contains {
            $0.title.contains("5,559.79")
                || $0.title.contains("202607160014")
                || $0.title.localizedCaseInsensitiveContains("clave de rastreo")
                || $0.title.localizedCaseInsensitiveContains("a la cuenta")
                || $0.title.localizedCaseInsensitiveContains("dato no verificado")
        })
    }

    func testSantanderOCRSkipsDatedPeriodAndBalanceHeaders() {
        let rows = FinanceStore.santanderOCRRowsForTesting([
            OCRObservationFixture(text: "ESTADO DE CUENTA NOMINA", x: 0.04, y: 0.96, width: 0.40),
            OCRObservationFixture(text: "PERIODO 16-JUL-2026 AL 15-AGO-2026", x: 0.04, y: 0.94, width: 0.55),
            OCRObservationFixture(text: "SALDO FINAL DEL PERIODO ANTERIOR: $5562.79", x: 0.04, y: 0.90, width: 0.55),
            OCRObservationFixture(text: "FECHA FOLIO DESCRIPCION", x: 0.04, y: 0.86, width: 0.50),
            OCRObservationFixture(text: "16-JUL-2026 4309379 PAGO TRANSFERENCIA SPEI", x: 0.02, y: 0.80, width: 0.55),
            OCRObservationFixture(text: "30.00", x: 0.72, y: 0.80, width: 0.08),
            OCRObservationFixture(text: "5,559.79", x: 0.84, y: 0.80, width: 0.08),
        ], fileName: "sample-bank-period-3.pdf")

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].amount, -30)
        XCTAssertFalse(rows[0].title.localizedCaseInsensitiveContains("saldo final"))
        XCTAssertFalse(rows[0].title.localizedCaseInsensitiveContains("periodo 16"))
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

    func testWeakVerifiedIssuerEvidenceCannotFeedNativeDashboard() {
        let store = FinanceStore()
        defer { store.clearLocalData() }
        let statement = StatementRecord(
            id: UUID(),
            source: "BBVA",
            period: "agosto 2026",
            fileName: "estado-bbva.pdf",
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
                confidence: 0.98,
                status: .verified,
                evidence: [],
                ignoredBodyMentions: []
            ),
            readerVersion: FinanceStore.readerVersion
        )
        store.statements = [statement]
        XCTAssertTrue(store.dashboardIsBlocked)
        XCTAssertEqual(store.ledgerQuality.validatedStatementCount, 0)
    }

    func testVerifiedEvidenceFromAnotherIssuerCannotFeedNativeDashboard() {
        let store = FinanceStore()
        defer { store.clearLocalData() }
        let statement = StatementRecord(
            id: UUID(),
            source: "BBVA",
            period: "agosto 2026",
            fileName: "estado-bbva.pdf",
            importedAt: .now,
            transactionCount: 0,
            requiresReview: false,
            kind: .bank,
            reconciliation: StatementReconciliationRecord(
                status: .valid,
                tolerance: Decimal(string: "0.05") ?? Decimal(0.05)
            ),
            sourceDetection: SourceDetectionEvidence(
                source: "Santander",
                confidence: 1,
                status: .verified,
                evidence: ["encabezado institucional Santander"],
                ignoredBodyMentions: ["BBVA"]
            ),
            readerVersion: FinanceStore.readerVersion
        )
        store.statements = [statement]
        XCTAssertTrue(store.dashboardIsBlocked)
        XCTAssertEqual(store.ledgerQuality.validatedStatementCount, 0)
    }

    func testUnknownStatementKindCannotFeedNativeDashboard() {
        let store = FinanceStore()
        defer { store.clearLocalData() }
        let statement = StatementRecord(
            id: UUID(),
            source: "BBVA",
            period: "agosto 2026",
            fileName: "estado-bbva.pdf",
            importedAt: .now,
            transactionCount: 0,
            requiresReview: false,
            kind: .unknown,
            reconciliation: StatementReconciliationRecord(
                status: .valid,
                tolerance: Decimal(string: "0.05") ?? Decimal(0.05)
            ),
            sourceDetection: SourceDetectionEvidence(
                source: "BBVA",
                confidence: 1,
                status: .verified,
                evidence: ["encabezado institucional BBVA"],
                ignoredBodyMentions: []
            ),
            readerVersion: FinanceStore.readerVersion
        )
        store.statements = [statement]
        XCTAssertTrue(store.dashboardIsBlocked)
        XCTAssertEqual(store.ledgerQuality.validatedStatementCount, 0)
    }

    func testLatestNativeBalanceUsesMaskedAccountIdentity() {
        let store = FinanceStore()
        defer { store.clearLocalData() }
        func statement(id: UUID, period: String, accountKey: String, cash: String) -> StatementRecord {
            StatementRecord(
                id: id,
                source: "Santander",
                accountKey: accountKey,
                period: period,
                fileName: "estado-\(accountKey).pdf",
                importedAt: .now,
                transactionCount: 0,
                requiresReview: false,
                kind: .bank,
                summary: StatementSummaryRecord(cashBalance: Decimal(string: cash)),
                reconciliation: StatementReconciliationRecord(
                    status: .valid,
                    tolerance: Decimal(string: "0.05") ?? Decimal(0.05)
                ),
                sourceDetection: SourceDetectionEvidence(
                    source: "Santander",
                    confidence: 0.999,
                    status: .verified,
                    evidence: ["encabezado institucional Santander"],
                    ignoredBodyMentions: []
                ),
                readerVersion: FinanceStore.readerVersion
            )
        }
        store.statements = [
            statement(id: UUID(), period: "julio 2026", accountKey: "santander:1111", cash: "100"),
            statement(id: UUID(), period: "agosto 2026", accountKey: "santander:1111", cash: "150"),
            statement(id: UUID(), period: "julio 2026", accountKey: "santander:2222", cash: "300"),
        ]
        XCTAssertEqual(store.cashAvailable, Decimal(string: "450"))
    }

    func testLegacyStatementJSONDecodesWithoutNewOCRFields() throws {
        // A user may upgrade with statements persisted by a previous build.
        // Remove every field introduced by the OCR/source-confirmation work
        // and verify that the current Codable model still opens the record.
        let original = StatementRecord(
            id: UUID(),
            source: "Santander",
            period: "agosto 2026",
            fileName: "estado.pdf",
            importedAt: Date(timeIntervalSince1970: 1_725_000_000),
            transactionCount: 2,
            requiresReview: true,
            kind: .bank,
            summary: StatementSummaryRecord(cashBalance: Decimal(string: "27654.24")),
            reconciliation: StatementReconciliationRecord(
                status: .pending,
                tolerance: Decimal(string: "0.05") ?? Decimal(0.05)
            ),
            sourceDetection: SourceDetectionEvidence(
                source: "Santander",
                confidence: 0.90,
                status: .review,
                evidence: ["nombre de archivo"],
                ignoredBodyMentions: []
            ),
            issuerConfirmedByUser: true,
            ocrConfidence: 0.93,
            ocrPageConfidences: [0.91, 0.95],
            ocrColumnsCalibrated: false,
            sourceFingerprint: "sha256",
            readerVersion: FinanceStore.readerVersion
        )

        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for key in [
            "issuerConfirmedByUser", "ocrConfidence", "ocrPageConfidences",
            "ocrColumnsCalibrated", "sourceFingerprint", "readerVersion"
        ] {
            object.removeValue(forKey: key)
        }

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(StatementRecord.self, from: legacyData)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.source, "Santander")
        XCTAssertEqual(decoded.transactionCount, 2)
        XCTAssertNil(decoded.issuerConfirmedByUser)
        XCTAssertNil(decoded.ocrColumnsCalibrated)
        XCTAssertNil(decoded.readerVersion)
    }

    func testUncalibratedSantanderOCRCannotFeedNativeDashboard() {
        let store = FinanceStore()
        defer { store.clearLocalData() }
        let statement = StatementRecord(
            id: UUID(),
            source: "Santander",
            period: "agosto 2026",
            fileName: "estado-santander.pdf",
            importedAt: .now,
            transactionCount: 1,
            // Deliberately false: the independent OCR gate below must still
            // block even if a stale persisted record lost its review flag.
            requiresReview: false,
            kind: .bank,
            reconciliation: StatementReconciliationRecord(
                status: .valid,
                tolerance: Decimal(string: "0.05") ?? Decimal(0.05)
            ),
            sourceDetection: SourceDetectionEvidence(
                source: "Santander",
                confidence: 0.999,
                status: .verified,
                evidence: ["encabezado institucional Santander"],
                ignoredBodyMentions: []
            ),
            ocrColumnsCalibrated: false,
            readerVersion: FinanceStore.readerVersion
        )
        store.statements = [statement]
        store.movements = []

        XCTAssertTrue(store.dashboardIsBlocked)
        XCTAssertEqual(store.ledgerQuality.validatedStatementCount, 0)
        XCTAssertTrue(store.ledgerQuality.message?.contains("columnas de movimientos") == true)

        store.statements[0].ocrColumnsCalibrated = true
        XCTAssertFalse(store.dashboardIsBlocked)
        XCTAssertEqual(store.ledgerQuality.validatedStatementCount, 1)
    }

    func testWeakOCRCannotFeedNativeDashboardEvenWhenReviewFlagIsStale() {
        let store = FinanceStore()
        defer { store.clearLocalData() }
        let statement = StatementRecord(
            id: UUID(),
            source: "BBVA",
            period: "agosto 2026",
            fileName: "estado-bbva.pdf",
            importedAt: .now,
            transactionCount: 1,
            // Simulate a legacy/corrupt persisted record. OCR confidence is
            // an independent durable gate and must not rely on this flag.
            requiresReview: false,
            kind: .bank,
            reconciliation: StatementReconciliationRecord(
                status: .valid,
                tolerance: Decimal(string: "0.05") ?? Decimal(0.05)
            ),
            sourceDetection: SourceDetectionEvidence(
                source: "BBVA",
                confidence: 0.999,
                status: .verified,
                evidence: ["encabezado institucional BBVA"],
                ignoredBodyMentions: []
            ),
            ocrConfidence: 0.86,
            ocrPageConfidences: [0.86, 0.91],
            ocrColumnsCalibrated: true,
            readerVersion: FinanceStore.readerVersion
        )
        store.statements = [statement]
        store.movements = []

        XCTAssertTrue(store.dashboardIsBlocked)
        XCTAssertEqual(store.ledgerQuality.validatedStatementCount, 0)
        XCTAssertTrue(store.ledgerQuality.message?.contains("confianza insuficiente") == true)
    }

    func testStatementAuditUsesTheCanonicalRowsForPeriodBreakdown() {
        let store = FinanceStore()
        defer { store.clearLocalData() }
        let statementID = UUID()
        let statement = StatementRecord(
            id: statementID,
            source: "BBVA",
            period: "agosto 2026",
            fileName: "bbva.pdf",
            importedAt: .now,
            transactionCount: 2,
            requiresReview: false,
            kind: .bank,
            reconciliation: StatementReconciliationRecord(
                status: .valid,
                tolerance: Decimal(string: "0.05") ?? Decimal(0.05)
            ),
            sourceDetection: SourceDetectionEvidence(
                source: "BBVA",
                confidence: 0.999,
                status: .verified,
                evidence: ["encabezado institucional BBVA"],
                ignoredBodyMentions: []
            ),
            readerVersion: FinanceStore.readerVersion
        )
        store.statements = [statement]
        store.movements = [
            Movement(
                date: .now,
                title: "Nómina",
                account: "BBVA",
                category: "Ingresos",
                amount: 100,
                flow: .income,
                statementId: statementID,
                kind: .income
            ),
            Movement(
                date: .now,
                title: "Supermercado",
                account: "BBVA",
                category: "Alimentos",
                amount: -40,
                flow: .expense,
                statementId: statementID,
                kind: .purchase
            ),
        ]

        guard let audit = store.statementAudits.first else {
            return XCTFail("La auditoría debe crear una fila por estado")
        }
        XCTAssertEqual(audit.importedRows, 2)
        XCTAssertEqual(audit.canonicalRows, 2)
        XCTAssertEqual(audit.validRows, 2)
        XCTAssertEqual(audit.duplicateRows, 0)
        XCTAssertEqual(audit.incomeRows, 1)
        XCTAssertEqual(audit.expenseRows, 1)
        XCTAssertEqual(audit.incomeTotal, 100)
        XCTAssertEqual(audit.expenseTotal, 40)
        XCTAssertEqual(audit.statusLabel, "Conciliado")

        let exported = store.diagnosticExportText()
        XCTAssertTrue(exported.contains("BBVA · agosto 2026"))
        XCTAssertTrue(exported.contains("ingresos"))
        XCTAssertFalse(exported.contains("Supermercado"), "La exportación agregada no debe incluir descripciones individuales")
    }
}
