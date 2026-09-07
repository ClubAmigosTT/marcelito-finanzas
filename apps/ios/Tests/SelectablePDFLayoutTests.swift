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
}
