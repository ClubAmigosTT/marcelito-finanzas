import XCTest
import UIKit
@testable import Marcelito

final class PDFExtractionDiagnosticTests: XCTestCase {
    func testUnrecognizedTextSurvivesZeroRowsAndJSONExport() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage()
            ("Tarjeta de crédito RappiCard" as NSString).draw(at: CGPoint(x: 30, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
            ("EVIDENCIA SIN MOVIMIENTOS 123" as NSString).draw(at: CGPoint(x: 30, y: 80), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
            context.beginPage() // Empty pages must also be represented.
        }
        let report = try PDFExtractionDiagnostic.capture(data: data)
        XCTAssertEqual(report.pages.count, 2)
        XCTAssertTrue(report.pages[0].text.contains("EVIDENCIA SIN MOVIMIENTOS"))
        XCTAssertEqual(report.pages[1].characterCount, 0)
        XCTAssertEqual(report.nativeProbe.rows, 0)
        XCTAssertTrue(report.nativeProbe.missing.contains("financialControls"))
        XCTAssertTrue(report.orderedText.contains("EVIDENCIA"))
        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(PDFExtractionDiagnostic.Report.self, from: encoded)
        XCTAssertEqual(decoded.pages[0].text, report.pages[0].text)
        XCTAssertEqual(decoded.fingerprint.count, 64)
    }
}
