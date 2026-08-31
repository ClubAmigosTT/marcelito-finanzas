import Foundation
import CryptoKit
import XCTest
@testable import Marcelito

/// Optional macOS/iOS corpus runner. The PDFs stay outside the repository and
/// are supplied through MARCELITO_PDF_CORPUS_DIR, so normal CI never receives
/// a user's financial documents. Running this test on a macOS host exercises
/// the same PDFDocument + Vision path used by the app, unlike the web corpus
/// evaluator which intentionally stops at `ocr-required` for scans.
final class NativeCorpusContractTests: XCTestCase {
    private struct Expectation {
        let sourceFingerprint: String
        let source: String
        let accountKey: String
        let kind: StatementKind
        let status: StatementReconciliationStatus
        let rows: Int
        let previousBalance: Decimal?
        let cashBalance: Decimal?
        let depositTotal: Decimal?
        let withdrawalTotal: Decimal?
        let chargeTotal: Decimal?
        let paymentTotal: Decimal?
        let creditLimit: Decimal?
        let creditAvailable: Decimal?
        let debtBalance: Decimal?
        let paymentForNoInterest: Decimal?
        let minimumPlusMsi: Decimal?
        let msiPending: Decimal?

        init(
            sourceFingerprint: String,
            source: String,
            accountKey: String = "",
            kind: StatementKind,
            status: StatementReconciliationStatus,
            rows: Int,
            previousBalance: Decimal? = nil,
            cashBalance: Decimal? = nil,
            depositTotal: Decimal? = nil,
            withdrawalTotal: Decimal? = nil,
            chargeTotal: Decimal? = nil,
            paymentTotal: Decimal? = nil,
            creditLimit: Decimal? = nil,
            creditAvailable: Decimal? = nil,
            debtBalance: Decimal? = nil,
            paymentForNoInterest: Decimal? = nil,
            minimumPlusMsi: Decimal? = nil,
            msiPending: Decimal? = nil
        ) {
            self.sourceFingerprint = sourceFingerprint
            self.source = source
            self.accountKey = accountKey
            self.kind = kind
            self.status = status
            self.rows = rows
            self.previousBalance = previousBalance
            self.cashBalance = cashBalance
            self.depositTotal = depositTotal
            self.withdrawalTotal = withdrawalTotal
            self.chargeTotal = chargeTotal
            self.paymentTotal = paymentTotal
            self.creditLimit = creditLimit
            self.creditAvailable = creditAvailable
            self.debtBalance = debtBalance
            self.paymentForNoInterest = paymentForNoInterest
            self.minimumPlusMsi = minimumPlusMsi
            self.msiPending = msiPending
        }
    }

    private let expectations: [String: Expectation] = [
        "1-28_may_2026_-_27_jun_2026.pdf": Expectation(sourceFingerprint: "e1a59460b86cab81f298cfa42e4cc1f738bf932bf5ccdb543cb49d623eb69abc", source: "Amex", accountKey: "amex:1003", kind: .card, status: .valid, rows: 92, chargeTotal: 28_034.19, creditLimit: 108_000, creditAvailable: 79_965.81, debtBalance: 28_034.19, paymentForNoInterest: 9_675.73, minimumPlusMsi: 10_529.23, msiPending: 18_358.46),
        "2-28_jun_2026_-_27_jul_2026.pdf": Expectation(sourceFingerprint: "83dc1e0b60c2edd56aa14330c7d001109cdc600af83a66e8e87243fdf86cfcc8", source: "Amex", accountKey: "amex:1003", kind: .card, status: .valid, rows: 145, chargeTotal: 46_711.63, paymentTotal: 34_405.21, creditLimit: 108_000, creditAvailable: 67_659.39, debtBalance: 40_340.61, paymentForNoInterest: 23_150.88, minimumPlusMsi: 15_036.56, msiPending: 17_189.73),
        "3-Estado-de-cuenta-mayo-2026.pdf": Expectation(sourceFingerprint: "f6940102b000539c733632727909dafbd8d97bca313d8c959ac5798d0611d6e4", source: "Santander", accountKey: "santander:7079", kind: .bank, status: .pending, rows: 0, previousBalance: 37_075.03, cashBalance: 24_621.48, depositTotal: 49_222.45, withdrawalTotal: 61_676.00),
        "4-Estado-de-cuenta-julio-2026.pdf": Expectation(sourceFingerprint: "747aba6d4453c0b7173c450a5a125d94cfb38a0940cb1776dd059f0d0e6e78a9", source: "Santander", accountKey: "santander:7079", kind: .bank, status: .pending, rows: 0, previousBalance: 87_801.76, cashBalance: 55_627.93, depositTotal: 40_833.38, withdrawalTotal: 73_007.21),
        "5-Estado-de-cuenta-agosto-2026.pdf": Expectation(sourceFingerprint: "30ccfc7fc31a128bbfd9f1d6c7c84e6840dbdc20c9cad9d90cac0807a845b8c0", source: "Santander", accountKey: "santander:7079", kind: .bank, status: .pending, rows: 0, previousBalance: 55_627.93, cashBalance: 27_654.24, depositTotal: 36_187.42, withdrawalTotal: 64_161.11),
        "6-28_jul_2026_-_27_ago_2026.pdf": Expectation(sourceFingerprint: "f2518086b1f4767c72c9e5d6d02ec27576576b8cfee5014d8b2eb0a635989b06", source: "Amex", accountKey: "amex:1003", kind: .card, status: .valid, rows: 105, chargeTotal: 33_177.48, paymentTotal: 23_150.88, creditLimit: 150_000, creditAvailable: 99_632.79, debtBalance: 50_367.21, paymentForNoInterest: 39_966.15, minimumPlusMsi: 19_579.69, msiPending: 10_401.06),
        "7-Estado-de-cuenta-junio-2026.pdf": Expectation(sourceFingerprint: "72b13daa0b9009017ce3d5d9c4951070a70da5f2888e8bbcb83ef4f1231455fb", source: "Santander", accountKey: "santander:7079", kind: .bank, status: .pending, rows: 0, previousBalance: 24_621.48, cashBalance: 87_801.76, depositTotal: 98_629.30, withdrawalTotal: 35_449.02),
        "8-BBVA-agosto-.pdf": Expectation(sourceFingerprint: "1c6c6e5a9aa96afa46bdfcd606c0c184f2ef0a964a9e51e4202be17b1ea4e558", source: "BBVA", accountKey: "bbva:4922", kind: .bank, status: .valid, rows: 11, depositTotal: 19_500.00, withdrawalTotal: 22_058.69),
    ]

    private func fingerprint(_ file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

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
        return String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
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
            let actualFingerprint = try fingerprint(file)
            let fileSizeBytes = file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            XCTAssertEqual(actualFingerprint, expected.sourceFingerprint, file.lastPathComponent + " no coincide con el PDF dorado")
            let result = try store.importPDF(
                from: file,
                allowOCR: true,
                preserveExistingOnEmpty: false,
                requireValidReconciliation: false
            )
            XCTAssertEqual(result.source, expected.source, file.lastPathComponent)
            if !expected.accountKey.isEmpty {
                XCTAssertNotNil(
                    expected.accountKey.range(of: #"^[a-z0-9]+:\d{4}$"#, options: .regularExpression),
                    file.lastPathComponent + " expectativa de identidad sin máscara válida"
                )
                XCTAssertEqual(result.accountKey, expected.accountKey, file.lastPathComponent + " identidad de cuenta")
            }
            XCTAssertEqual(result.kind, expected.kind, file.lastPathComponent)
            XCTAssertEqual(result.sourceDetection.status, .verified, file.lastPathComponent)
            XCTAssertLessThanOrEqual(result.imported, 1_000, file.lastPathComponent + " produjo un volumen de filas absurdo")
            XCTAssertEqual(result.fileSizeBytes, fileSizeBytes, file.lastPathComponent + " no conserva el tamaño original")
            XCTAssertGreaterThan(result.pageCount ?? 0, 0, file.lastPathComponent + " no conserva el número de páginas")

            // Summary controls are independent of row acceptance. Assert them
            // even while a scan remains pending so a plausible-looking OCR
            // header cannot silently move the golden forward with wrong
            // deposits/withdrawals. Row totals remain conditional below.
            if let previousBalance = expected.previousBalance {
                assertClose(result.summary?.previousBalance, previousBalance, file: file.lastPathComponent, field: "saldo inicial del resumen")
            }
            if let cashBalance = expected.cashBalance {
                assertClose(result.summary?.cashBalance, cashBalance, file: file.lastPathComponent, field: "saldo final del resumen")
            }
            if let depositTotal = expected.depositTotal {
                assertClose(result.summary?.depositTotal, depositTotal, file: file.lastPathComponent, field: "depósitos del resumen")
                if result.reconciliation?.status == .valid {
                    assertClose(result.reconciliation?.extractedDepositTotal, depositTotal, file: file.lastPathComponent, field: "depósitos")
                }
            }
            if let withdrawalTotal = expected.withdrawalTotal {
                assertClose(result.summary?.withdrawalTotal, withdrawalTotal, file: file.lastPathComponent, field: "retiros del resumen")
                if result.reconciliation?.status == .valid {
                    assertClose(result.reconciliation?.extractedWithdrawalTotal, withdrawalTotal, file: file.lastPathComponent, field: "retiros")
                }
            }
            if let chargeTotal = expected.chargeTotal {
                if result.reconciliation?.status == .valid {
                    assertClose(result.reconciliation?.extractedChargeTotal, chargeTotal, file: file.lastPathComponent, field: "cargos")
                }
            }
            if let paymentTotal = expected.paymentTotal {
                if result.reconciliation?.status == .valid {
                    assertClose(result.reconciliation?.extractedPaymentTotal, paymentTotal, file: file.lastPathComponent, field: "pagos")
                }
            }
            if let creditLimit = expected.creditLimit {
                assertClose(result.summary?.creditLimit, creditLimit, file: file.lastPathComponent, field: "límite de crédito")
            }
            if let creditAvailable = expected.creditAvailable {
                assertClose(result.summary?.creditAvailable, creditAvailable, file: file.lastPathComponent, field: "crédito disponible")
            }
            if let debtBalance = expected.debtBalance {
                let extractedDebt = result.summary.flatMap { summary -> Decimal? in
                    guard let limit = summary.creditLimit, let available = summary.creditAvailable else { return summary.debtBalance }
                    return max(Decimal(0), limit - available)
                }
                assertClose(extractedDebt, debtBalance, file: file.lastPathComponent, field: "deuda comprometida")
            }
            if let paymentForNoInterest = expected.paymentForNoInterest {
                assertClose(result.summary?.paymentForNoInterest, paymentForNoInterest, file: file.lastPathComponent, field: "pago para no generar intereses")
            }
            if let minimumPlusMsi = expected.minimumPlusMsi {
                assertClose(result.summary?.minimumPlusMsi, minimumPlusMsi, file: file.lastPathComponent, field: "mínimo más MSI")
            }
            if let msiPending = expected.msiPending {
                assertClose(result.summary?.msiPending, msiPending, file: file.lastPathComponent, field: "MSI pendiente")
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
                "sourceFingerprint": actualFingerprint,
                "expectedSourceFingerprint": expected.sourceFingerprint,
                "fileSizeBytes": String(result.fileSizeBytes ?? fileSizeBytes),
                "pageCount": String(result.pageCount ?? 0),
                "source": result.source,
                "accountKey": result.accountKey ?? "",
                "expectedAccountKey": expected.accountKey,
                "kind": result.kind.rawValue,
                "mode": result.usedOCR ? "vision-ocr" : "pdf-text",
                "sourceStatus": result.sourceDetection.status.rawValue,
                "sourceConfidence": percentText(result.sourceDetection.confidence),
                "status": result.reconciliation?.status.rawValue ?? "pending",
                "rows": String(result.imported),
                "requiresReview": String(result.requiresReview),
                "ocrConfidence": percentText(result.ocrConfidence),
                "weakestOCRPage": percentText(result.ocrPageConfidences?.min()),
                "ocrColumnsCalibrated": result.ocrColumnsCalibrated.map { $0 ? "true" : "false" } ?? "",
                "expectedPreviousBalance": decimalText(expected.previousBalance),
                "extractedPreviousBalance": decimalText(result.summary?.previousBalance),
                "expectedCashBalance": decimalText(expected.cashBalance),
                "extractedCashBalance": decimalText(result.summary?.cashBalance),
                "expectedDeposits": decimalText(expected.depositTotal),
                "extractedDeposits": decimalText(result.reconciliation?.extractedDepositTotal),
                "expectedWithdrawals": decimalText(expected.withdrawalTotal),
                "extractedWithdrawals": decimalText(result.reconciliation?.extractedWithdrawalTotal),
                "expectedCharges": decimalText(expected.chargeTotal),
                "extractedCharges": decimalText(result.reconciliation?.extractedChargeTotal),
                "expectedPayments": decimalText(expected.paymentTotal),
                "extractedPayments": decimalText(result.reconciliation?.extractedPaymentTotal),
                "expectedCreditLimit": decimalText(expected.creditLimit),
                "extractedCreditLimit": decimalText(result.summary?.creditLimit),
                "expectedCreditAvailable": decimalText(expected.creditAvailable),
                "extractedCreditAvailable": decimalText(result.summary?.creditAvailable),
                "expectedDebtBalance": decimalText(expected.debtBalance),
                "extractedDebtBalance": decimalText(result.summary.flatMap { summary in
                    guard let limit = summary.creditLimit, let available = summary.creditAvailable else { return summary.debtBalance }
                    return max(Decimal(0), limit - available)
                }),
                "expectedPaymentForNoInterest": decimalText(expected.paymentForNoInterest),
                "extractedPaymentForNoInterest": decimalText(result.summary?.paymentForNoInterest),
                "expectedMinimumPlusMsi": decimalText(expected.minimumPlusMsi),
                "extractedMinimumPlusMsi": decimalText(result.summary?.minimumPlusMsi),
                "expectedMsiPending": decimalText(expected.msiPending),
                "extractedMsiPending": decimalText(result.summary?.msiPending),
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
        let requireCertified = ["1", "true", "yes"].contains(
            ProcessInfo.processInfo.environment["MARCELITO_PDF_CORPUS_REQUIRE_CERTIFIED"]?.lowercased() ?? ""
        )
        if requireCertified {
            XCTAssertTrue(
                certified,
                "El corpus nativo no está certificado: promueve todos los goldens, corrige falsos positivos y resuelve OCR antes de publicar."
            )
        }
        let summary: [String: String] = [
            "readerVersion": FinanceStore.readerVersion,
            "files": String(files.count),
            "accepted": String(automaticAcceptances),
            "blocked": String(max(0, files.count - automaticAcceptances)),
            "expectedValid": String(expectedValidCount),
            "expectedPending": String(expectedPendingCount),
            "goldenAutoAccepted": String(goldenAutoAccepted),
            "goldenFalseAccepted": String(goldenFalseAccepted),
            "automaticAcceptancePrecision": String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), automaticAcceptancePrecision),
            "unresolvedOCR": String(unresolvedOCR),
            "requireCertified": String(requireCertified),
            "certified": String(certified)
        ]
        let summaryData = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        print("NATIVE_CORPUS_SUMMARY " + (String(data: summaryData, encoding: .utf8) ?? "{}"))
    }
}
