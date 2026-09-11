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

    func testMissingCreditFailsEvenWhenChargesMatch() {
        let snapshot = FinanceStore.readerParseSnapshotForTesting(text: fixture, fileName: "example.pdf")
        let rows = snapshot.movements.filter { $0.kind != .refund }
        XCTAssertEqual(FinanceStore.reconcileStatementForTesting(kind: .card, summary: snapshot.summary, movements: rows).status, .invalid)
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
