import XCTest
@testable import Marcelito

/// Optional macOS/iOS corpus runner. The PDFs stay outside the repository and
/// are supplied through MARCELITO_PDF_CORPUS_DIR, so normal CI never receives
/// a user's financial documents. Running this test on a macOS host exercises
/// the same PDFDocument + Vision path used by the app, unlike the web corpus
/// evaluator which intentionally stops at `ocr-required` for scans.
final class NativeCorpusContractTests: XCTestCase {
    private struct Expectation {
        let source: String
        let kind: StatementKind
        let status: StatementReconciliationStatus
        let rows: Int
    }

    private let expectations: [String: Expectation] = [
        "1-28_may_2026_-_27_jun_2026.pdf": Expectation(source: "Amex", kind: .card, status: .valid, rows: 92),
        "2-28_jun_2026_-_27_jul_2026.pdf": Expectation(source: "Amex", kind: .card, status: .valid, rows: 145),
        "3-Estado-de-cuenta-mayo-2026.pdf": Expectation(source: "Santander", kind: .bank, status: .pending, rows: 0),
        "4-Estado-de-cuenta-julio-2026.pdf": Expectation(source: "Santander", kind: .bank, status: .pending, rows: 0),
        "5-Estado-de-cuenta-agosto-2026.pdf": Expectation(source: "Santander", kind: .bank, status: .pending, rows: 0),
        "6-28_jul_2026_-_27_ago_2026.pdf": Expectation(source: "Amex", kind: .card, status: .valid, rows: 105),
        "7-Estado-de-cuenta-junio-2026.pdf": Expectation(source: "Santander", kind: .bank, status: .pending, rows: 0),
        "8-BBVA-agosto-.pdf": Expectation(source: "BBVA", kind: .bank, status: .valid, rows: 11),
    ]

    func testValidatedCorpusThroughNativeReaderWhenProvided() throws {
        guard let rawDirectory = ProcessInfo.processInfo.environment["MARCELITO_PDF_CORPUS_DIR"],
              !rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Define MARCELITO_PDF_CORPUS_DIR para ejecutar el corpus nativo con Vision.")
        }

        let directory = URL(fileURLWithPath: rawDirectory, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertEqual(Set(files.map(\.lastPathComponent)), Set(expectations.keys), "El corpus nativo debe contener exactamente los PDFs del manifiesto.")

        let store = FinanceStore()
        defer { store.clearLocalData() }
        var report: [[String: String]] = []

        for file in files {
            guard let expected = expectations[file.lastPathComponent] else { continue }
            let result = try store.importPDF(
                from: file,
                allowOCR: true,
                preserveExistingOnEmpty: false,
                requireValidReconciliation: false
            )
            XCTAssertEqual(result.source, expected.source, file.lastPathComponent)
            XCTAssertLessThanOrEqual(result.imported, 1_000, file.lastPathComponent + " produjo un volumen de filas absurdo")

            // Text-layer goldens are the hard acceptance contract. Scanned
            // Santander rows remain pending in this manifest until Vision is
            // run and calibrated against the printed totals; once a scan is
            // promoted to valid, its exact row count is checked automatically.
            if expected.status == .valid {
                XCTAssertEqual(result.reconciliation?.status, .valid, file.lastPathComponent)
                XCTAssertEqual(result.kind, expected.kind, file.lastPathComponent)
                XCTAssertEqual(result.imported, expected.rows, file.lastPathComponent)
                XCTAssertFalse(result.requiresReview, file.lastPathComponent)
            } else if result.reconciliation?.status == .valid {
                // A scan may be promoted after Vision calibration. Until the
                // golden is updated, require that such an acceptance still
                // contains real rows and never silently accepts an empty PDF.
                XCTAssertGreaterThan(result.imported, 0, file.lastPathComponent)
            }

            report.append([
                "file": file.lastPathComponent,
                "source": result.source,
                "kind": result.kind.rawValue,
                "mode": result.usedOCR ? "vision-ocr" : "pdf-text",
                "status": result.reconciliation?.status.rawValue ?? "pending",
                "rows": String(result.imported),
                "requiresReview": String(result.requiresReview),
                "reason": result.reconciliation?.reason ?? "",
            ])
        }

        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("NATIVE_CORPUS_REPORT " + (String(data: data, encoding: .utf8) ?? "[]"))
    }
}
