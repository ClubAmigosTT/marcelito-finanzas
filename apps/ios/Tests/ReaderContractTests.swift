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
}
