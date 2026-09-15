import XCTest
import PDFKit
import UIKit
@testable import Marcelito

final class RappiReaderTests: XCTestCase {
    // Synthetic account, merchant and amounts; no customer PDF committed.
    private let fixture = """
    __PDF_PAGE_1__
    Tarjeta de crédito RappiCard
    Banco Mercantil del Norte Grupo Financiero Banorte
    Número de cuenta 00190001000000001234
    Periodo 22-jul-2026 al 21-ago-2026
    Pago para no generar intereses2 $150.00
    Pago mínimo4 $20.00
    Adeudo del periodo anterior = $100.00
    Cargos regulares (no a meses) + $100.00
    Cargos compras a meses (capital)7 + $0.00
    Pagos y abonos - $50.00
    Saldo cargos a meses: $0.00
    Saldo deudor total11 $150.00
    Límite de crédito $1,000.00
    Crédito disponible $850.00
    __PDF_PAGE_3__
    DESGLOSE DE MOVIMIENTOS
    CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)
    2026-08-01 2026-08-02 COMERCIO EJEMPLO +$50.00
    2026-08-01 2026-08-02 COMERCIO EJEMPLO +$50.00
    2026-08-02 2026-08-02 PAGO POR SPEI -$40.00
    2026-08-03 2026-08-03 BONIFICACIÓN CON CASHBACK -$10.00
    Total de cargos +$100.00
    Total de abonos -$50.00
    CARGOS NO RECONOCIDOS
    2026-08-01 2026-08-02 COMERCIO EJEMPLO +$50.00
    """

    func testIdentityPeriodAndIndependentTotals() {
        let snapshot = FinanceStore.readerParseSnapshotForTesting(text: fixture, fileName: "example.pdf")
        XCTAssertEqual(snapshot.source, "Rappi")
        XCTAssertEqual(snapshot.kind, .card)
        XCTAssertEqual(snapshot.accountKey, "rappi:1234")
        XCTAssertEqual(snapshot.period, "22/07/2026 - 21/08/2026")
        XCTAssertEqual(snapshot.movements.count, 4)
        XCTAssertEqual(snapshot.movements.filter { $0.kind == .purchase }.count, 2)
        XCTAssertEqual(snapshot.summary?.paymentsAndCredits, 50)
        XCTAssertEqual(FinanceStore.reconcileStatementForTesting(kind: .card, summary: snapshot.summary, movements: snapshot.movements).status, .valid)
    }

    func testPeriodSurvivesPDFKitSpacingAndDashVariants() {
        let variants = [
            "Período\n22 - jun - 2026\nal\n21 - ago - 2026",
            "Periodo 22–jun–2026 al 21–ago–2026",
            "Periodo 22/jun/2026 al 21/ago/2026",
            "Periodo 22-junio-2026 al 21-agosto-2026"
        ]

        for period in variants {
            let text = fixture.replacingOccurrences(of: "Periodo 22-jul-2026 al 21-ago-2026", with: period)
            let snapshot = FinanceStore.readerParseSnapshotForTesting(text: text, fileName: "rappicard.pdf")
            XCTAssertEqual(snapshot.period, "22/06/2026 - 21/08/2026", period)
        }
    }

    func testPeriodRecoversWhenVisionDropsConnectorOrPeriodAnchor() {
        let variants = [
            "Periodo 22 jun 2026 21 jul 2026",
            "Periodo\n22-jun-2026\n21-jul-2026",
            "Resumen del estado 22 jun 2026 21 jul 2026"
        ]

        for period in variants {
            let text = fixture
                .replacingOccurrences(of: "Periodo 22-jul-2026 al 21-ago-2026", with: period)
                .replacingOccurrences(of: "21-jul-2026", with: "21-jul-2026\nFecha limite de pago 10-ago-2026")
            let snapshot = FinanceStore.readerParseSnapshotForTesting(text: text, fileName: "rappicard.pdf")
            XCTAssertEqual(snapshot.period, "22/06/2026 - 21/07/2026", period)
        }
    }

    func testPeriodRebuildsFromSplitVisionNumericComponents() {
        let fixtures: [OCRObservationFixture] = [
            .init(page: 0, text: "Tarjeta de crédito RappiCard", x: 0.05, y: 0.95, width: 0.45, confidence: 0.98),
            .init(page: 0, text: "Periodo", x: 0.05, y: 0.86, width: 0.12, confidence: 0.97),
            .init(page: 0, text: "22", x: 0.20, y: 0.86, width: 0.04, confidence: 0.96),
            .init(page: 0, text: "jun", x: 0.25, y: 0.86, width: 0.05, confidence: 0.96),
            .init(page: 0, text: "2026", x: 0.32, y: 0.86, width: 0.08, confidence: 0.96),
            .init(page: 0, text: "al", x: 0.43, y: 0.86, width: 0.04, confidence: 0.96),
            .init(page: 0, text: "21", x: 0.49, y: 0.86, width: 0.04, confidence: 0.96),
            .init(page: 0, text: "jul", x: 0.54, y: 0.86, width: 0.05, confidence: 0.96),
            .init(page: 0, text: "2026", x: 0.61, y: 0.86, width: 0.08, confidence: 0.96),
            .init(page: 0, text: "Resumen de cargos y abonos del periodo", x: 0.05, y: 0.74, width: 0.60, confidence: 0.97),
            .init(page: 2, text: "CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)", x: 0.05, y: 0.95, width: 0.75, confidence: 0.98)
        ]

        let snapshot = FinanceStore.rappiOCRSnapshotForTesting(fixtures)
        XCTAssertEqual(snapshot.source, "Rappi")
        XCTAssertEqual(snapshot.period, "22/06/2026 - 21/07/2026")
    }

    func testPeriodUsesVerifiedIssuerHintWhenVisionDropsRappiHeader() {
        let text = fixture
            .replacingOccurrences(of: "Tarjeta de crédito RappiCard", with: "Estado de cuenta")
            .replacingOccurrences(of: "Banco Mercantil del Norte Grupo Financiero Banorte", with: "Resumen de cargos")
        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "estado-importado.pdf",
            sourceHint: "Rappi"
        )
        XCTAssertEqual(snapshot.source, "Rappi")
        XCTAssertEqual(snapshot.period, "22/07/2026 - 21/08/2026")
    }

    func testMissingCreditFailsEvenWhenChargesMatch() {
        let snapshot = FinanceStore.readerParseSnapshotForTesting(text: fixture, fileName: "example.pdf")
        let rows = snapshot.movements.filter { $0.kind != .refund }
        XCTAssertEqual(FinanceStore.reconcileStatementForTesting(kind: .card, summary: snapshot.summary, movements: rows).status, .invalid)
    }

    func testRepeatedOCRAmountFragmentsDoNotConcatenateControls() {
        let text = fixture
            .replacingOccurrences(of: "Cargos regulares (no a meses) + $100.00", with: "Cargos regulares (no a meses) + $100.00 100.00")
            .replacingOccurrences(of: "Crédito disponible $850.00", with: "Crédito disponible $850.00 850.00")
            .replacingOccurrences(of: "COMERCIO EJEMPLO +$50.00", with: "COMERCIO EJEMPLO +$50.00 50.00")
        let snapshot = FinanceStore.readerParseSnapshotForTesting(text: text, fileName: "example.pdf")
        XCTAssertEqual(snapshot.summary?.newCharges, 100)
        XCTAssertEqual(snapshot.summary?.creditAvailable, 850)
        XCTAssertEqual(snapshot.movements.count, 4)
        XCTAssertEqual(FinanceStore.reconcileStatementForTesting(kind: .card, summary: snapshot.summary, movements: snapshot.movements).status, .valid)
    }

    func testMerchantRFCDoesNotRemovePurchasesFromReconciliation() {
        let text = fixture.replacingOccurrences(of: "COMERCIO EJEMPLO", with: "COMERCIO EJEMPLO; RFC: AAA010101AA1")
        let snapshot = FinanceStore.readerParseSnapshotForTesting(text: text, fileName: "example.pdf")
        XCTAssertEqual(snapshot.movements.filter { $0.title == "comercio ejemplo" }.count, 2)
        XCTAssertTrue(snapshot.movements.first?.extractionEvidence?.sourceText?.contains("RFC:") == true)
        let result = FinanceStore.reconcileStatementForTesting(kind: .card, summary: snapshot.summary, movements: snapshot.movements)
        XCTAssertEqual(result.extractedMovementCount, 4)
        XCTAssertEqual(result.extractedChargeTotal, 100)
        XCTAssertEqual(result.status, .valid)
    }

    func testSeparateOperationAndPostingDateLinesKeepEveryMovement() {
        let text = fixture.replacingOccurrences(
            of: #"(\d{4}-\d{2}-\d{2}) (\d{4}-\d{2}-\d{2}) "#,
            with: "$1\n$2\n", options: .regularExpression)
        let snapshot = FinanceStore.readerParseSnapshotForTesting(text: text, fileName: "example.pdf")
        XCTAssertEqual(snapshot.movements.count, 4)
        XCTAssertEqual(snapshot.movements.filter { $0.kind == .cardPayment }.count, 1)
        XCTAssertEqual(FinanceStore.reconcileStatementForTesting(kind: .card, summary: snapshot.summary, movements: snapshot.movements).status, .valid)
    }

    func testFlattenedContinuationTableRebuildsEveryRappiRow() {
        guard let tableRange = fixture.range(of: "DESGLOSE DE MOVIMIENTOS") else {
            XCTFail("fixture must include the Rappi movement section")
            return
        }
        let collapsed = String(fixture[tableRange.lowerBound...]).replacingOccurrences(of: "\n", with: " ")
        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: String(fixture[..<tableRange.lowerBound]) + collapsed,
            fileName: "rappi-continuation-pages.pdf"
        )

        // PDFKit may flatten all continuation pages into one stream. The
        // parser must recover the four date-anchored rows before reconciling
        // against the independent charge/credit controls.
        XCTAssertEqual(snapshot.movements.count, 4)
        XCTAssertEqual(snapshot.movements.filter { $0.kind == .cardPayment }.count, 1)
        XCTAssertEqual(
            FinanceStore.reconcileStatementForTesting(
                kind: .card, summary: snapshot.summary, movements: snapshot.movements
            ).status,
            .valid
        )
    }

    func testFooterNotesReferenceDoesNotSkipContinuationPages() {
        let pages = [
            "Tarjeta de crédito RappiCard",
            "Resumen del estado",
            "CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)\nMovimiento uno\nNotas: Ver notas en la sección NOTAS ACLARATORIAS en este estado de cuenta.",
            "Movimiento dos\nNotas: Ver notas en la sección NOTAS ACLARATORIAS en este estado de cuenta.",
            "Movimiento tres\nNotas: Ver notas en la sección NOTAS ACLARATORIAS en este estado de cuenta.",
            "CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)\nMovimiento cuatro\nTotal de cargos +$100.00\nTotal de abonos -$50.00",
            "NOTAS ACLARATORIAS\nContenido legal"
        ]

        XCTAssertEqual(FinanceStore.rappiOCRPageIndexesForTesting(pages), [0, 2, 3, 4, 5])
    }

    func testFooterNotesReferenceDoesNotCloseMovementParser() {
        let header = fixture.components(separatedBy: "__PDF_PAGE_3__")[0]
        let text = header + """
        __PDF_PAGE_3__
        CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)
        2026-08-01 2026-08-02 COMERCIO UNO +$50.00
        NOTAS ACLARATORIAS en este estado de cuenta.
        __PDF_PAGE_4__
        2026-08-01 2026-08-02 COMERCIO DOS +$50.00
        Notas: Ver notas en la sección NOTAS ACLARATORIAS en este estado de cuenta.
        __PDF_PAGE_5__
        2026-08-02 2026-08-02 PAGO POR SPEI -$40.00
        2026-08-03 2026-08-03 BONIFICACIÓN CON CASHBACK -$10.00
        Total de cargos +$100.00
        Total de abonos -$50.00
        """

        let snapshot = FinanceStore.readerParseSnapshotForTesting(text: text, fileName: "rappi-footer.pdf")
        XCTAssertEqual(snapshot.movements.count, 4)
        XCTAssertEqual(Set(snapshot.movements.compactMap { $0.extractionEvidence?.page }), Set([3, 4, 5]))
        XCTAssertEqual(
            FinanceStore.reconcileStatementForTesting(
                kind: .card, summary: snapshot.summary, movements: snapshot.movements
            ).status,
            .valid
        )
    }

    func testRowsAcceptLocalizedOCRDateFormats() {
        let text = fixture
            .replacingOccurrences(
                of: "2026-08-01 2026-08-02 COMERCIO EJEMPLO +$50.00",
                with: "01/08/2026 02/08/2026 COMERCIO EJEMPLO +$50.00"
            )
            .replacingOccurrences(
                of: "2026-08-02 2026-08-02 PAGO POR SPEI",
                with: "02-AGO-2026 02-AGO-2026 PAGO POR SPEI"
            )
        let snapshot = FinanceStore.readerParseSnapshotForTesting(text: text, fileName: "rappi-localized-dates.pdf")
        XCTAssertEqual(snapshot.movements.count, 4)
        XCTAssertEqual(snapshot.movements.filter { $0.kind == .cardPayment }.count, 1)
        XCTAssertEqual(FinanceStore.reconcileStatementForTesting(
            kind: .card, summary: snapshot.summary, movements: snapshot.movements
        ).status, .valid)
    }

    func testRowsSurviveMissingPostingDateAndConcatenatedOCRRows() {
        let text = fixture
            .replacingOccurrences(
                of: "2026-08-01 2026-08-02 COMERCIO EJEMPLO +$50.00\n    2026-08-01 2026-08-02 COMERCIO EJEMPLO +$50.00",
                with: "2026-08-01 COMERCIO EJEMPLO +$50.00 MERCHANT DOS +$50.00"
            )
        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: text,
            fileName: "rappi-concatenated-rows.pdf"
        )
        XCTAssertEqual(snapshot.movements.count, 4)
        XCTAssertEqual(snapshot.movements.filter { $0.kind == .purchase }.count, 2)
        XCTAssertEqual(snapshot.movements.filter { $0.kind == .cardPayment }.count, 1)
        XCTAssertEqual(
            FinanceStore.reconcileStatementForTesting(
                kind: .card, summary: snapshot.summary, movements: snapshot.movements
            ).status,
            .valid
        )
    }

    func testHybridRecoveryPrefersOrderedSelectableMerchantRows() {
        let collapsedOCR = fixture.replacingOccurrences(
            of: "2026-08-01 2026-08-02 COMERCIO EJEMPLO +$50.00\n2026-08-01 2026-08-02 COMERCIO EJEMPLO +$50.00",
            with: "2026-08-01 2026-08-02 50.00 +$50.00 50.00 +$50.00"
        )
        let snapshot = FinanceStore.rappiHybridSelectionForTesting(
            ocrText: collapsedOCR,
            selectableText: "",
            layoutText: fixture,
            summaryText: fixture
        )

        XCTAssertEqual(snapshot.movements.count, 4)
        XCTAssertEqual(snapshot.movements.filter { $0.title == "comercio ejemplo" }.count, 2)
        XCTAssertEqual(snapshot.movements.filter { $0.kind == .cardPayment }.count, 1)
        XCTAssertEqual(
            FinanceStore.reconcileStatementForTesting(
                kind: .card, summary: snapshot.summary, movements: snapshot.movements
            ).status,
            .valid
        )
    }

    func testEvidenceBackedFallbackKeepsNumericOnlyRowsWhenTotalsProveThem() {
        let collapsedOCR = fixture.replacingOccurrences(
            of: "2026-08-01 2026-08-02 COMERCIO EJEMPLO +$50.00\n2026-08-01 2026-08-02 COMERCIO EJEMPLO +$50.00",
            with: "2026-08-01 2026-08-02 50.00 +$50.00 50.00 +$50.00"
        )
        let snapshot = FinanceStore.rappiHybridSelectionForTesting(
            ocrText: collapsedOCR,
            selectableText: "",
            layoutText: "",
            summaryText: fixture
        )

        XCTAssertEqual(snapshot.movements.count, 4)
        XCTAssertEqual(
            snapshot.movements.filter { $0.title.hasPrefix("Movimiento Rappi sin concepto") }.count,
            2
        )
        let result = FinanceStore.reconcileStatementForTesting(
            kind: .card, summary: snapshot.summary, movements: snapshot.movements
        )
        XCTAssertEqual(result.extractedMovementCount, 4)
        XCTAssertEqual(result.extractedChargeTotal, 100)
        XCTAssertEqual(result.status, .valid)
    }

    func testProductionImportRecoversTwoColumnCoverAndMovementPages() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            func draw(_ text: String, _ x: CGFloat, _ y: CGFloat) {
                (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 9)])
            }
            context.beginPage()
            draw("Tarjeta de crédito RappiCard", 30, 30)
            let rows = [
                ("Adeudo del periodo anterior =", "$100.00", "Periodo", "22-jul-2026 al 21-ago-2026"),
                ("Cargos regulares (no a meses) +", "$100.00", "Saldo deudor total11", "$150.00"),
                ("Pagos y abonos -", "$50.00", "Saldo cargos a meses:", "$0.00"),
                ("Cargos compras a meses (capital)7 +", "$0.00", "Pago mínimo4", "$20.00")
            ]
            for (index, row) in rows.enumerated() {
                let y = CGFloat(100 + index * 25)
                // Deliberately interleave the two panels in content order.
                draw(row.0, 30, y); draw(row.2, 320, y)
                draw(row.1, 245, y); draw(row.3, 460, y)
            }
            context.beginPage()
            let lines = ["CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)",
                         "2026-08-01 2026-08-02 COMERCIO EJEMPLO +$50.00",
                         "2026-08-01 2026-08-02 COMERCIO EJEMPLO +$50.00",
                         "2026-08-02 2026-08-02 PAGO POR SPEI -$40.00",
                         "2026-08-03 2026-08-03 BONIFICACIÓN CON CASHBACK -$10.00",
                         "Total de cargos +$100.00", "Total de abonos -$50.00"]
            for (index, line) in lines.enumerated() { draw(line, 30, CGFloat(40 + index * 25)) }
        }
        let snapshot = try FinanceStore.readerPDFSnapshotForTesting(data: data)
        XCTAssertEqual(snapshot.source, "Rappi")
        XCTAssertEqual(snapshot.period, "22/07/2026 - 21/08/2026")
        XCTAssertEqual(snapshot.movements.count, 4)
        XCTAssertEqual(snapshot.movements.first?.extractionEvidence?.page, 2)
        XCTAssertEqual(FinanceStore.reconcileStatementForTesting(kind: .card, summary: snapshot.summary, movements: snapshot.movements).status, .valid)
    }

    func testVisualRowBandsKeepOneCandidatePerPrintedTransaction() throws {
        let width = 612
        let height = 792
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        let rows = [
            ("2026-08-01", "2026-08-02", "COMERCIO UNO", "+$50.00"),
            ("2026-08-01", "2026-08-02", "COMERCIO DOS", "+$50.00"),
            ("2026-08-02", "2026-08-02", "PAGO POR SPEI", "-$40.00"),
            ("2026-08-03", "2026-08-03", "BONIFICACION CASHBACK", "-$10.00"),
        ]
        for separatorY in stride(from: 150, through: 150 + rows.count * 46, by: 46) {
            for y in separatorY..<(separatorY + 2) {
                for x in 30..<582 {
                    let pixel = (y * bytesPerRow) + (x * bytesPerPixel)
                    pixels[pixel] = 205
                    pixels[pixel + 1] = 205
                    pixels[pixel + 2] = 205
                    pixels[pixel + 3] = 255
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let cgImage = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        XCTAssertEqual(FinanceStore.rappiTableRowRegionsForTesting(cgImage).count, rows.count)

        let isolatedRowTexts = rows.map { row in
            "\(row.0) \(row.1) \(row.2) \(row.3)"
        }
        let recognizedRows = FinanceStore.rappiIsolatedRowLinesForTesting(isolatedRowTexts)
        XCTAssertEqual(recognizedRows.count, rows.count)
        let cover = fixture.components(separatedBy: "__PDF_PAGE_3__")[0]
        let snapshot = FinanceStore.readerParseSnapshotForTesting(
            text: cover + "__PDF_PAGE_3__\nCARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)\n"
                + recognizedRows.joined(separator: "\n"),
            fileName: "rappi-visual-rows.pdf"
        )
        XCTAssertEqual(snapshot.movements.count, rows.count)
        XCTAssertEqual(
            FinanceStore.reconcileStatementForTesting(
                kind: .card,
                summary: snapshot.summary,
                movements: snapshot.movements
            ).status,
            .valid
        )
    }

    func testVisualRowBandsIncludeTallForeignPurchase() throws {
        let width = 612
        let height = 792
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        // The second band is 80 px tall (10.1% of the page), matching a
        // purchase that includes Rappi's multi-line USD conversion detail.
        for separatorY in [150, 196, 276] {
            for y in separatorY..<(separatorY + 2) {
                for x in 30..<582 {
                    let pixel = (y * bytesPerRow) + (x * bytesPerPixel)
                    pixels[pixel] = 205
                    pixels[pixel + 1] = 205
                    pixels[pixel + 2] = 205
                    pixels[pixel + 3] = 255
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))

        XCTAssertEqual(FinanceStore.rappiTableRowRegionsForTesting(image).count, 2)
    }

    func testIsolatedRowRejectsMergedTransactionsInsteadOfSelectingLastAmount() {
        let merged = "2026-08-01 2026-08-01 PAGO POR SPEI -$500.00 2026-08-02 2026-08-02 COMERCIO +$50.00"
        XCTAssertTrue(FinanceStore.rappiIsolatedRowLinesForTesting([merged]).isEmpty)
        let ambiguous = "2026-08-01 2026-08-01 PAGO POR SPEI -$500.00 COMERCIO +$50.00"
        XCTAssertTrue(FinanceStore.rappiIsolatedRowLinesForTesting([ambiguous]).isEmpty)
    }

    func testIsolatedRowRecoversUnsignedIssuerCreditsOnly() {
        let lines = FinanceStore.rappiIsolatedRowLinesForTesting([
            "2026-05-14 2026-05-14 IVA BONIFICACION CON CASHBACK $5.17",
            "2026-06-13 2026-06-13 BONIFICACION CON CASHBACK 10.54",
            "2026-03-05 2026-03-05 PAGO POR SPEI $537.00",
            "2026-03-20 2026-03-21 AVIANCA SA B8N7NM $5,618.56"
        ])

        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.contains { $0.contains("-$5.17") })
        XCTAssertTrue(lines.contains { $0.contains("-$10.54") })
        XCTAssertTrue(lines.contains { $0.contains("-$537.00") })
        XCTAssertFalse(lines.contains { $0.contains("AVIANCA") })
    }

    func testDenseIsolatedRowsKeepTheirOwnDatesAndIdenticalAmounts() {
        let lines = FinanceStore.rappiIsolatedRowLinesForTesting([
            "2026-08-01 2026-08-02 COMERCIO UNO +$50.00",
            "2026-08-03 2026-08-04 COMERCIO DOS +$50.00"
        ], spacing: 0.009)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.first?.hasPrefix("2026-08-01 2026-08-02") == true)
        XCTAssertTrue(lines.last?.hasPrefix("2026-08-03 2026-08-04") == true)
        XCTAssertTrue(lines.last?.contains("COMERCIO DOS") == true)
    }

    func testVisualRowOCRReadsPixelsAndKeepsPaymentSeparateFromPurchase() throws {
        let size = CGSize(width: 1224, height: 1584)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let lines = [
                "2026-08-01  2026-08-01  PAGO POR SPEI  -$500.00",
                "2026-08-02  2026-08-02  GOOGLE CLOUD  +$389.76",
                "2026-08-03  2026-08-03  COMERCIO  +$50.00"
            ]
            for index in 0...lines.count {
                UIColor.gray.setFill()
                context.fill(CGRect(x: 60, y: 300 + index * 70, width: 1104, height: 2))
                if index < lines.count {
                    (lines[index] as NSString).draw(
                        at: CGPoint(x: 80, y: 315 + index * 70),
                        withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 23, weight: .regular),
                                         .foregroundColor: UIColor.black]
                    )
                }
            }
        }
        let image = try XCTUnwrap(rendered.cgImage)
        let regions = FinanceStore.rappiTableRowRegionsForTesting(image)
        XCTAssertEqual(regions.count, 3)
        XCTAssertEqual(try XCTUnwrap(regions.first).midY, 1 - 336.0 / 1584.0, accuracy: 0.01)
        let rows = FinanceStore.rappiVisualRowTextsForTesting(image)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.contains { $0.contains("500.00") && !$0.contains("389.76") })
        XCTAssertTrue(rows.contains { $0.contains("389.76") && !$0.contains("500.00") })
    }

    func testSPEIPaymentSpacingAndCaseDoNotBecomeIncome() throws {
        for label in ["PAGO POR SPEI", "Pago por Spei", "PAGO   POR\nSPEI"] {
            let text = fixture.replacingOccurrences(of: "PAGO POR SPEI", with: label)
            let snapshot = FinanceStore.readerParseSnapshotForTesting(text: text, fileName: "example.pdf")
            let payment = try XCTUnwrap(snapshot.movements.first { $0.amount == 40 })
            XCTAssertEqual(payment.kind, .cardPayment, label)
            XCTAssertEqual(payment.flow, .transfer, label)
            XCTAssertEqual(snapshot.movements.first { $0.amount == 10 }?.kind, .refund)
        }
    }

    func testRappiCorrectsPlusMisreadOnExplicitCreditLabels() throws {
        let text = fixture
            .replacingOccurrences(of: "PAGO POR SPEI -$40.00", with: "PAGO POR SPEI +$40.00")
            .replacingOccurrences(of: "BONIFICACIÓN CON CASHBACK -$10.00", with: "BONIFICACIÓN CON CASHBACK +$10.00")
        let snapshot = FinanceStore.readerParseSnapshotForTesting(text: text, fileName: "rappi-credit-sign-ocr.pdf")

        XCTAssertEqual(snapshot.movements.first { $0.kind == .cardPayment }?.amount, 40)
        XCTAssertEqual(snapshot.movements.first { $0.kind == .refund }?.amount, 10)
        XCTAssertTrue(snapshot.movements.filter { $0.amount > 0 }.allSatisfy {
            $0.extractionEvidence?.selectionReason?.contains("signo OCR corregido") == true
        })
        XCTAssertEqual(FinanceStore.reconcileStatementForTesting(
            kind: .card, summary: snapshot.summary, movements: snapshot.movements
        ).status, .valid)
    }

    func testRappiOCRRepairsCollapsedLabelsAndMissingSPEISign() throws {
        let text = fixture
            .replacingOccurrences(of: "Número de cuenta", with: "Numerodecuenta")
            .replacingOccurrences(of: "Adeudo del periodo anterior", with: "Adeudodelperiodoanterior")
            .replacingOccurrences(of: "Cargos regulares (no a meses)", with: "Cargosregulares(noameses)")
            .replacingOccurrences(of: "Pagos y abonos", with: "Pagosyabonos")
            .replacingOccurrences(of: "Saldo deudor total", with: "Saldodeudortotal")
            .replacingOccurrences(of: "PAGO POR SPEI -$40.00", with: "PAGOPORSPEI $40.00")
        let snapshot = FinanceStore.readerParseSnapshotForTesting(text: text, fileName: "example.pdf")
        XCTAssertEqual(snapshot.accountKey, "rappi:1234")
        XCTAssertEqual(snapshot.movements.count, 4)
        let payment = try XCTUnwrap(snapshot.movements.first { $0.kind == .cardPayment })
        XCTAssertEqual(payment.amount, 40)
        XCTAssertTrue(payment.extractionEvidence?.selectionReason?.contains("signo ausente") == true)
        XCTAssertEqual(FinanceStore.reconcileStatementForTesting(
            kind: .card, summary: snapshot.summary, movements: snapshot.movements
        ).status, .valid)
    }

    func testRappiOCRNormalizesRepeatedThousandsSeparatorsInControls() throws {
        let text = fixture
            .replacingOccurrences(of: "COMERCIO EJEMPLO +$50.00", with: "COMERCIO EJEMPLO +$500.00")
            .replacingOccurrences(of: "Cargos regulares (no a meses) + $100.00", with: "Cargos regulares (no a meses) + $1.000.00")
            .replacingOccurrences(of: "Saldo deudor total11 $150.00", with: "Saldo deudor total11 $1.050.00")
            .replacingOccurrences(of: "Total de cargos +$100.00", with: "Total de cargos +$1.000.00")
        let snapshot = FinanceStore.readerParseSnapshotForTesting(text: text, fileName: "rappi-ocr.pdf")
        XCTAssertEqual(snapshot.movements.filter { $0.kind == .purchase }.map(\.amount), [-500, -500])
        XCTAssertEqual(snapshot.summary?.newCharges, 1_000)
        XCTAssertEqual(snapshot.summary?.statementBalance, 1_050)
        XCTAssertEqual(FinanceStore.reconcileStatementForTesting(
            kind: .card, summary: snapshot.summary, movements: snapshot.movements
        ).status, .valid)
    }

    func testVisionFallbackRecoversDigitsRowsAndIndependentControls() throws {
        let fixtures: [OCRObservationFixture] = [
            .init(page: 0, text: "Tarjeta de crédito RappiCard", x: 0.05, y: 0.95, width: 0.40, confidence: 0.98),
            .init(page: 0, text: "Número de cuenta 0019 0001 0000 0000 1234", x: 0.05, y: 0.91, width: 0.55, confidence: 0.97),
            .init(page: 0, text: "Periodo 22-jul-2026 al 21-ago-2026", x: 0.50, y: 0.87, width: 0.42, confidence: 0.98),
            .init(page: 0, text: "Adeudo del periodo anterior = $100.00", x: 0.05, y: 0.75, width: 0.42, confidence: 0.97),
            .init(page: 0, text: "Cargos regulares (no a meses) + $100.00", x: 0.05, y: 0.71, width: 0.46, confidence: 0.97),
            .init(page: 0, text: "Cargos compras a meses (capital)7 + $0.00", x: 0.05, y: 0.67, width: 0.48, confidence: 0.97),
            .init(page: 0, text: "Pagos y abonos - $50.00", x: 0.05, y: 0.63, width: 0.35, confidence: 0.97),
            .init(page: 0, text: "Saldo cargos a meses: $0.00", x: 0.52, y: 0.59, width: 0.36, confidence: 0.97),
            .init(page: 0, text: "Saldo deudor total11 $150.00", x: 0.52, y: 0.55, width: 0.36, confidence: 0.97),
            .init(page: 2, text: "CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)", x: 0.05, y: 0.95, width: 0.75, confidence: 0.98),
            .init(page: 2, text: "2026-08-01 2026-08-02 COMERCIO EJEMPLO +$50.00", x: 0.05, y: 0.85, width: 0.80, confidence: 0.96),
            .init(page: 2, text: "2026-08-01 2026-08-02 COMERCIO EJEMPLO +$50.00", x: 0.05, y: 0.80, width: 0.80, confidence: 0.96),
            .init(page: 2, text: "2026-08-02 2026-08-02 PAGO POR SPEI -$40.00", x: 0.05, y: 0.75, width: 0.75, confidence: 0.96),
            .init(page: 2, text: "2026-08-03 2026-08-03 BONIFICACIÓN CON CASHBACK -$10.00", x: 0.05, y: 0.70, width: 0.85, confidence: 0.96),
            .init(page: 2, text: "Total de cargos +$100.00", x: 0.05, y: 0.60, width: 0.32, confidence: 0.98),
            .init(page: 2, text: "Total de abonos -$50.00", x: 0.05, y: 0.56, width: 0.32, confidence: 0.98),
            .init(page: 3, text: "CARGOS NO RECONOCIDOS", x: 0.05, y: 0.95, width: 0.35, confidence: 0.98),
            .init(page: 3, text: "2026-08-01 2026-08-02 CARGO EN REVISIÓN +$50.00", x: 0.05, y: 0.85, width: 0.75, confidence: 0.96)
        ]
        let snapshot = FinanceStore.rappiOCRSnapshotForTesting(fixtures)
        XCTAssertEqual(snapshot.source, "Rappi")
        XCTAssertEqual(snapshot.accountKey, "rappi:1234")
        XCTAssertEqual(snapshot.period, "22/07/2026 - 21/08/2026")
        XCTAssertEqual(snapshot.movements.count, 4)
        XCTAssertTrue(snapshot.movements.allSatisfy { $0.extractionEvidence?.method == "vision-ocr" })
        XCTAssertEqual(snapshot.movements.filter { $0.kind == .cardPayment }.count, 1)
        XCTAssertEqual(snapshot.movements.filter { $0.kind == .refund }.count, 1)
        XCTAssertEqual(FinanceStore.reconcileStatementForTesting(
            kind: .card, summary: snapshot.summary, movements: snapshot.movements
        ).status, .valid)
    }

    func testPDFKitRoundTripKeepsPeriodRowsAndReconciliation() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage()
            var y: CGFloat = 30
            for line in fixture.components(separatedBy: .newlines) {
                if line.hasPrefix("__PDF_PAGE_") { continue }
                (line as NSString).draw(at: CGPoint(x: 25, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 10)])
                y += 20
            }
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = SelectablePDFLayout.text(from: document)
        let snapshot = FinanceStore.readerParseSnapshotForTesting(text: text, fileName: "example.pdf")
        XCTAssertEqual(snapshot.period, "22/07/2026 - 21/08/2026")
        XCTAssertEqual(snapshot.movements.count, 4)
        XCTAssertEqual(snapshot.movements.filter { $0.kind == .cardPayment }.count, 1)
        XCTAssertEqual(FinanceStore.reconcileStatementForTesting(kind: .card, summary: snapshot.summary, movements: snapshot.movements).status, .valid)
    }

    func testUnsupportedInstallmentLayoutDoesNotCertify() {
        let text = fixture.replacingOccurrences(of: "Saldo cargos a meses: $0.00", with: "Saldo cargos a meses: $500.00")
        let snapshot = FinanceStore.readerParseSnapshotForTesting(text: text, fileName: "example.pdf")
        XCTAssertNil(snapshot.summary)
    }

    func testForeignAnnotationUsesMXNNotUSD() {
        let text = fixture.replacingOccurrences(of: "COMERCIO EJEMPLO +$50.00", with: "COMERCIO EJEMPLO\nCompra en el extranjero\nTasa de conversión $10.00\nUSD $5\n+$50.00")
        let snapshot = FinanceStore.readerParseSnapshotForTesting(text: text, fileName: "example.pdf")
        XCTAssertEqual(snapshot.movements.filter { $0.kind == .purchase }.map(\.amount), [-50, -50])
        XCTAssertEqual(snapshot.movements.first?.extractionEvidence?.page, 3)
    }

    func testScreenshotRewardsRejectedAndIncompleteRows() throws {
        let result = try BankScreenshotReader.parseTextForTesting([
            "RappiCard", "Transacciones", "Comercio ejemplo $100.00", "1 Ago 2026 10:30 + $3.00", "Titular",
            "Abono Con Cashback -$10.00", "2 Ago 2026 05:00", "Titular",
            "Pago Por Spei -$40.00", "2 Ago 2026 06:00", "Titular",
            "Playstation $300.00", "3 Ago 2026 10:00 Rechazada", "Titular",
            "Comercio tapado 34.00", "4 Ago 2026 11:00", "Titular",
            "Fila cortada $25.00"
        ], source: .rappi, capturedAt: .now)
        XCTAssertEqual(result.movements.map(\.normalizedAmount), [-100, 10, 40])
    }
}
