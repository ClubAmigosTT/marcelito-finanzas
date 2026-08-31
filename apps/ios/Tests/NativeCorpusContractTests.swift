import Foundation
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
        let depositTotal: Decimal?
        let withdrawalTotal: Decimal?
        let chargeTotal: Decimal?
        let paymentTotal: Decimal?

        init(
            source: String,
            kind: StatementKind,
            status: StatementReconciliationStatus,
            rows: Int,
            depositTotal: Decimal? = nil,
            withdrawalTotal: Decimal? = nil,
            chargeTotal: Decimal? = nil,
            paymentTotal: Decimal? = nil
        ) {
            self.source = source
            self.kind = kind
            self.status = status
            self.rows = rows
            self.depositTotal = depositTotal
            self.withdrawalTotal = withdrawalTotal
            self.chargeTotal = chargeTotal
            self.paymentTotal = paymentTotal
        }
    }

    private let expectations: [String: Expectation] = [
        "1-28_may_2026_-_27_jun_2026.pdf": Expectation(source: "Amex", kind: .card, status: .valid, rows: 92, chargeTotal: 28_034.19),
        "2-28_jun_2026_-_27_jul_2026.pdf": Expectation(source: "Amex", kind: .card, status: .valid, rows: 145, chargeTotal: 46_711.63, paymentTotal: 34_405.21),
        "3-Estado-de-cuenta-mayo-2026.pdf": Expectation(source: "Santander", kind: .bank, status: .pending, rows: 0, depositTotal: 49_222.45, withdrawalTotal: 61_676.00),
        "4-Estado-de-cuenta-julio-2026.pdf": Expectation(source: "Santander", kind: .bank, status: .pending, rows: 0, depositTotal: 40_833.38, withdrawalTotal: 73_007.21),
        "5-Estado-de-cuenta-agosto-2026.pdf": Expectation(source: "Santander", kind: .bank, status: .pending, rows: 0, depositTotal: 36_187.42, withdrawalTotal: 64_161.11),
        "6-28_jul_2026_-_27_ago_2026.pdf": Expectation(source: "Amex", kind: .card, status: .valid, rows: 105, chargeTotal: 33_177.48, paymentTotal: 23_150.88),
        "7-Estado-de-cuenta-junio-2026.pdf": Expectation(source: "Santander", kind: .bank, status: .pending, rows: 0, depositTotal: 98_629.30, withdrawalTotal: 35_449.02),
        "8-BBVA-agosto-.pdf": Expectation(source: "BBVA", kind: .bank, status: .valid, rows: 11, depositTotal: 19_500.00, withdrawalTotal: 22_058.69),
    ]

    private func assertClose(_ actual: Decimal?, _ expected: Decimal, file: String, field: String) {
        guard let actual else {
            XCTFail("\(file): falta \(field), esperado \(expected)")
            return
        }
        let difference = abs(NSDecimalNumber(decimal: actual - expected).doubleValue)
        XCTAssertLessThanOrEqual(difference, 0.05, "\(file): \(field) extraído \(actual), esperado \(expected)")
    }

    private func decimalText(_ value: Decimal?) -> String {
        value.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
    }

    private func percentText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.4f", value)
    }

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
        var automaticAcceptances = 0
        var goldenAutoAccepted = 0
        var goldenFalseAccepted = 0
        var unresolvedOCR = 0

        for file in files {
            guard let expected = expectations[file.lastPathComponent] else { continue }
            let result = try store.importPDF(
                from: file,
                allowOCR: true,
                preserveExistingOnEmpty: false,
                requireValidReconciliation: false
            )
            XCTAssertEqual(result.source, expected.source, file.lastPathComponent)
            XCTAssertEqual(result.kind, expected.kind, file.lastPathComponent)
            XCTAssertEqual(result.sourceDetection.status, .verified, file.lastPathComponent)
            XCTAssertLessThanOrEqual(result.imported, 1_000, file.lastPathComponent + " produjo un volumen de filas absurdo")

            // A pending scan is a diagnostic candidate, not a failed build:
            // its extracted controls are printed in the report for calibration
            // and become hard assertions once the golden is promoted to valid.
            let controlsReady = expected.status == .valid || result.reconciliation?.status == .valid
            if controlsReady, let depositTotal = expected.depositTotal {
                assertClose(result.reconciliation?.extractedDepositTotal, depositTotal, file: file.lastPathComponent, field: "depósitos")
            }
            if controlsReady, let withdrawalTotal = expected.withdrawalTotal {
                assertClose(result.reconciliation?.extractedWithdrawalTotal, withdrawalTotal, file: file.lastPathComponent, field: "retiros")
            }
            if controlsReady, let chargeTotal = expected.chargeTotal {
                assertClose(result.reconciliation?.extractedChargeTotal, chargeTotal, file: file.lastPathComponent, field: "cargos")
            }
            if controlsReady, let paymentTotal = expected.paymentTotal {
                assertClose(result.reconciliation?.extractedPaymentTotal, paymentTotal, file: file.lastPathComponent, field: "pagos")
            }

            // Text-layer goldens are the hard acceptance contract. Scanned
            // Santander rows remain pending in this manifest until Vision is
            // run and calibrated against the printed totals; once a scan is
            // promoted to valid, its exact row count is checked automatically.
            if expected.status == .valid {
                XCTAssertEqual(result.reconciliation?.status, .valid, file.lastPathComponent)
                XCTAssertEqual(result.imported, expected.rows, file.lastPathComponent)
                XCTAssertFalse(result.requiresReview, file.lastPathComponent)
            } else if result.reconciliation?.status == .valid {
                // A scan may be promoted after Vision calibration. Until the
                // golden is updated, require that such an acceptance still
                // contains real rows and never silently accepts an empty PDF.
                XCTAssertGreaterThan(result.imported, 0, file.lastPathComponent)
                XCTAssertTrue(result.requiresReview, file.lastPathComponent + " quedó válido sin estar promovido en el golden")
            }

            let autoAccepted = result.reconciliation?.status == .valid
                && result.sourceDetection.status == .verified
                && !result.requiresReview
            if autoAccepted {
                automaticAcceptances += 1
                if expected.status == .valid {
                    goldenAutoAccepted += 1
                } else {
                    // A scan that becomes valid before its golden is promoted
                    // must remain provisional; count it as a false automatic
                    // acceptance even though the XCTest assertion above also
                    // reports the contract violation.
                    goldenFalseAccepted += 1
                }
            }
            if result.usedOCR && !autoAccepted {
                unresolvedOCR += 1
            }

            report.append([
                "file": file.lastPathComponent,
                "source": result.source,
                "kind": result.kind.rawValue,
                "mode": result.usedOCR ? "vision-ocr" : "pdf-text",
                "sourceStatus": result.sourceDetection.status.rawValue,
                "sourceConfidence": percentText(result.sourceDetection.confidence),
                "status": result.reconciliation?.status.rawValue ?? "pending",
                "rows": String(result.imported),
                "requiresReview": String(result.requiresReview),
                "ocrConfidence": percentText(result.ocrConfidence),
                "weakestOCRPage": percentText(result.ocrPageConfidences?.min()),
                "expectedDeposits": decimalText(expected.depositTotal),
                "extractedDeposits": decimalText(result.reconciliation?.extractedDepositTotal),
                "expectedWithdrawals": decimalText(expected.withdrawalTotal),
                "extractedWithdrawals": decimalText(result.reconciliation?.extractedWithdrawalTotal),
                "expectedCharges": decimalText(expected.chargeTotal),
                "extractedCharges": decimalText(result.reconciliation?.extractedChargeTotal),
                "expectedPayments": decimalText(expected.paymentTotal),
                "extractedPayments": decimalText(result.reconciliation?.extractedPaymentTotal),
                "reason": result.reconciliation?.reason ?? "",
            ])
        }

        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("NATIVE_CORPUS_REPORT " + (String(data: data, encoding: .utf8) ?? "[]"))

        let precisionDenominator = goldenAutoAccepted + goldenFalseAccepted
        let automaticAcceptancePrecision = precisionDenominator > 0
            ? Double(goldenAutoAccepted) / Double(precisionDenominator)
            : 0
        let expectedValidCount = expectations.values.filter { $0.status == .valid }.count
        let expectedPendingCount = expectations.values.filter { $0.status != .valid }.count
        let exactCorpus = Set(files.map(\.lastPathComponent)) == Set(expectations.keys)
        let certified = exactCorpus
            && expectedPendingCount == 0
            && goldenFalseAccepted == 0
            && goldenAutoAccepted == expectedValidCount
            && automaticAcceptancePrecision >= 0.99
            && unresolvedOCR == 0
        let summary: [String: String] = [
            "files": String(files.count),
            "accepted": String(automaticAcceptances),
            "blocked": String(max(0, files.count - automaticAcceptances)),
            "expectedValid": String(expectedValidCount),
            "expectedPending": String(expectedPendingCount),
            "goldenAutoAccepted": String(goldenAutoAccepted),
            "goldenFalseAccepted": String(goldenFalseAccepted),
            "automaticAcceptancePrecision": String(format: "%.4f", automaticAcceptancePrecision),
            "unresolvedOCR": String(unresolvedOCR),
            "certified": String(certified)
        ]
        let summaryData = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        print("NATIVE_CORPUS_SUMMARY " + (String(data: summaryData, encoding: .utf8) ?? "{}"))
    }
}
