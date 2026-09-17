import XCTest
import PDFKit
import UIKit
@testable import Marcelito

final class SelectablePDFLayoutTests: XCTestCase {
    func testContentStreamOrderDoesNotChangePrintedRowsOrRepeatedAmounts() {
        typealias Fragment = SelectablePDFLayout.Fragment
        let input = [
            Fragment(text: "72.00", bounds: CGRect(x: 200, y: 100, width: 30, height: 10)),
            Fragment(text: "72.00", bounds: CGRect(x: 200, y: 80, width: 30, height: 10)),
            Fragment(text: "02/ENE", bounds: CGRect(x: 10, y: 80, width: 30, height: 10)),
            Fragment(text: "01/ENE", bounds: CGRect(x: 10, y: 100, width: 30, height: 10)),
            Fragment(text: "ABONO", bounds: CGRect(x: 60, y: 100.5, width: 45, height: 10)),
            Fragment(text: "ABONO", bounds: CGRect(x: 60, y: 80.5, width: 45, height: 10)),
        ]
        XCTAssertEqual(SelectablePDFLayout.orderedText(input), "01/ENE ABONO 72.00\n02/ENE ABONO 72.00")
    }

    func testRealPDFKitSelectionsKeepPageMarkers() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            for _ in 0..<2 {
                context.beginPage()
                // Deliberately draw amount first; it still belongs on the right.
                ("72.00" as NSString).draw(at: CGPoint(x: 300, y: 50), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
                ("01/ENE ABONO" as NSString).draw(at: CGPoint(x: 30, y: 50), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
            }
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = SelectablePDFLayout.text(from: document)
        XCTAssertTrue(text.contains("__PDF_PAGE_1__"))
        XCTAssertTrue(text.contains("__PDF_PAGE_2__"))
        XCTAssertEqual(text.components(separatedBy: "01/ENE ABONO 72.00").count - 1, 2)
    }

    func testRappiGeometryReaderKeepsRowsAfterARepeatedTableTotal() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10)]
        let data = renderer.pdfData { context in
            context.beginPage()
            ("RappiCard  Periodo 22/07/2026 - 21/08/2026" as NSString)
                .draw(at: CGPoint(x: 30, y: 730), withAttributes: attributes)

            context.beginPage()
            func draw(_ value: String, x: CGFloat, y: CGFloat) {
                (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
            }
            draw("CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)", x: 30, y: 730)
            draw("22/07/2026", x: 42, y: 680)
            draw("23/07/2026", x: 109, y: 680)
            draw("COMERCIO UNO", x: 175, y: 680)
            draw("+$50.00", x: 510, y: 680)
            draw("Total de cargos", x: 30, y: 630)
            draw("+$50.00", x: 510, y: 630)
            draw("CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)", x: 30, y: 580)
            draw("24/07/2026", x: 42, y: 530)
            draw("25/07/2026", x: 109, y: 530)
            draw("PAGO POR SPEI", x: 175, y: 530)
            draw("-$40.00", x: 510, y: 530)
            draw("Total de cargos", x: 30, y: 480)
            draw("+$10.00", x: 510, y: 480)
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = SelectablePDFLayout.rappiText(from: document)

        XCTAssertEqual(text.components(separatedBy: "__RAPPI_ROW_BOUNDS__").count - 1, 2)
        XCTAssertTrue(text.contains("22/07/2026 23/07/2026 COMERCIO UNO +$50.00"))
        XCTAssertTrue(text.contains("24/07/2026 25/07/2026 PAGO POR SPEI -$40.00"))
    }
}
