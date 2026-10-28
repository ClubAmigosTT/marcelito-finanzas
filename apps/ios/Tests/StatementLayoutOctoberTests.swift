import XCTest
@testable import Marcelito

/// Layouts first seen in late-2026 statements, with synthetic data.
final class StatementLayoutOctoberTests: XCTestCase {
    func testAmexPageWithAmountColumnListedSeparatelyAndAnAdditionalCardholder() {
        let text = """
        __PDF_PAGE_6__
        TITULAR EJEMPLO UNO 27-Oct-2026 27-Nov-2026
        Fecha y Detalle de las operaciones 16 de Octubre TIENDA UNO 17 de Octubre TIENDA DOS Total de las transacciones en $ de TITULAR EJEMPLO UNO 18 de Octubre SUPER EJEMPLO NORTE
        RFCABC1234567X1 /REF12345678
        Total de las transacciones en $ de ADICIONAL EJEMPLO DOS 1 de Octubre SERVICIO WEB
        Dólar U.S.A. 4.33 TC:18.86374
        Total de Transacciones en Moneda Extranjera de TITULAR EJEMPLO UNO Transacciones de Meses sin Intereses
        Total de Meses sin Intereses Este no es un documento con validez fiscal
        Importe en MN.
        100.00
        50.00
        150.00
        300.00
        300.00
        81.68
        81.68
        0.00
        """
        let rows = FinanceStore.amexTextRowsForTesting(text, fileName: "2026.pdf")
        XCTAssertEqual(rows.map(\.title), ["TIENDA UNO", "TIENDA DOS", "SUPER EJEMPLO NORTE", "SERVICIO WEB"])
        XCTAssertEqual(rows.map(\.amount), [-100, -50, -300, Decimal(string: "-81.68")!])
        XCTAssertEqual(rows.map(\.foreignCurrency), [false, false, false, true])
        // Only the additional card's purchase carries a cardholder.
        XCTAssertEqual(rows.map(\.statementCardholder), [nil, nil, "ADICIONAL EJEMPLO DOS", nil])
    }

    func testAmexPagoRecibidoIsACardPayment() {
        let text = """
        Fecha y Detalle de las operaciones Importe en MN.
        23 de Octubre PAGO RECIBIDO, GRACIAS 20.00 CR
        24 de Octubre TIENDA EJEMPLO 75.00
        Total de las transacciones en $ 75.00
        """
        let rows = FinanceStore.amexTextRowsForTesting(text, fileName: "2026.pdf")
        XCTAssertEqual(rows.map(\.kind), [.cardPayment, .purchase])
    }

    func testRappiOCRGluedDatesAreSeparated() {
        XCTAssertEqual(FinanceStore.spacedRappiRowDates("2026-10-032026-10-04TIENDA EJEMPLO +$45.00"),
                       "2026-10-03 2026-10-04 TIENDA EJEMPLO +$45.00")
        XCTAssertEqual(FinanceStore.spacedRappiRowDates("2026-10-03 2026-10-04 TIENDA +$1.00"),
                       "2026-10-03 2026-10-04 TIENDA +$1.00")
    }

    func testOCRLookalikeLettersBecomeLatinWithoutShiftingRanges() {
        // "OCТ" with a Cyrillic Т hid a Santander row's date from the reader.
        let read = "06-OC\u{0422}-2026 1234567 ABONO TRANSFERENCIA SPEI"
        let latin = FinanceStore.latinizedOCRText(read)
        XCTAssertEqual(latin, "06-OCT-2026 1234567 ABONO TRANSFERENCIA SPEI")
        XCTAssertEqual(latin.utf16.count, read.utf16.count)
        XCTAssertEqual(FinanceStore.latinizedOCRText("15-SEP-2026 Pago"), "15-SEP-2026 Pago")
    }

    func testRappiCutBalanceFollowsTheStatementsOwnArithmetic() throws {
        let text = """
        Pago para no generar intereses $2,100.00
        RESUMEN DE CARGOS Y ABONOS DEL PERIODO
        Adeudo del periodo anterior = $2,000.00
        Cargos regulares (no a meses) + $500.00
        Cargos compras a meses (capital) + $0.00
        Monto de intereses + $0.00
        Monto de comisiones + $0.00
        Pagos y abonos - $400.00
        Saldo cargos a meses: $0.00
        Saldo deudor total $700.00
        """
        let summary = try XCTUnwrap(FinanceStore.rappiSummaryForTesting(text))
        // 2,000 + 500 − 400 = 2,100: the printed 700 is not the cut balance.
        XCTAssertEqual(summary.statementBalance, 2_100)
        XCTAssertEqual(summary.debtBalance, 2_100)
    }
}
