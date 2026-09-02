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
    /// A private corpus may carry its golden expectations in a file outside
    /// the repository.  The public fixture below stays synthetic, while a
    /// macOS/iPhone run can point at a local manifest containing hashes and
    /// issuer controls for real statements.  No PDF bytes or descriptions
    /// are read from the manifest.
    private struct ExternalManifest: Decodable {
        struct Summary: Decodable {
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

            private enum CodingKeys: String, CodingKey {
                case previousBalance, cashBalance, depositTotal, withdrawalTotal,
                     chargeTotal, paymentTotal, creditLimit, creditAvailable,
                     debtBalance, paymentForNoInterest, minimumPlusMsi, msiPending,
                     extractedPreviousBalance, extractedCashBalance,
                     extractedDepositTotal, extractedWithdrawalTotal,
                     extractedChargeTotal, extractedPaymentTotal,
                     extractedCreditLimit, extractedCreditAvailable,
                     extractedDebtBalance, extractedPaymentForNoInterest,
                     extractedMinimumPlusMsi, extractedMsiPending
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                func parseDecimal(_ raw: String) -> Decimal? {
                    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { return nil }
                    let comma = value.lastIndex(of: ",")
                    let dot = value.lastIndex(of: ".")
                    let normalized: String
                    if let comma, let dot {
                        normalized = comma > dot
                            ? value.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
                            : value.replacingOccurrences(of: ",", with: "")
                    } else if let comma {
                        let decimals = value.distance(from: comma, to: value.endIndex) - 1
                        normalized = (decimals == 1 || decimals == 2)
                            ? value.replacingOccurrences(of: ",", with: ".")
                            : value.replacingOccurrences(of: ",", with: "")
                    } else {
                        normalized = value
                    }
                    return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
                }
                func decodeDecimal(_ keys: [CodingKeys]) -> Decimal? {
                    for key in keys {
                        do {
                            if let value = try container.decodeIfPresent(Decimal.self, forKey: key) {
                                return value
                            }
                        } catch { }
                        do {
                            if let value = try container.decodeIfPresent(String.self, forKey: key),
                               let parsed = parseDecimal(value) {
                                return parsed
                            }
                        } catch { }
                    }
                    return nil
                }
                previousBalance = decodeDecimal([.previousBalance, .extractedPreviousBalance])
                cashBalance = decodeDecimal([.cashBalance, .extractedCashBalance])
                depositTotal = decodeDecimal([.depositTotal, .extractedDepositTotal])
                withdrawalTotal = decodeDecimal([.withdrawalTotal, .extractedWithdrawalTotal])
                chargeTotal = decodeDecimal([.chargeTotal, .extractedChargeTotal])
                paymentTotal = decodeDecimal([.paymentTotal, .extractedPaymentTotal])
                creditLimit = decodeDecimal([.creditLimit, .extractedCreditLimit])
                creditAvailable = decodeDecimal([.creditAvailable, .extractedCreditAvailable])
                debtBalance = decodeDecimal([.debtBalance, .extractedDebtBalance])
                paymentForNoInterest = decodeDecimal([.paymentForNoInterest, .extractedPaymentForNoInterest])
                minimumPlusMsi = decodeDecimal([.minimumPlusMsi, .extractedMinimumPlusMsi])
                msiPending = decodeDecimal([.msiPending, .extractedMsiPending])
            }
        }

        struct File: Decodable {
            let file: String
            let sourceFingerprint: String
            let source: String
            let accountKey: String?
            let kind: String
            let status: String
            let rows: Int?
            let summary: Summary?
        }

        let schemaVersion: Int?
        let readerVersion: String?
        let files: [File]
    }

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

    // The native corpus is supplied out-of-band. Keep only synthetic metadata
    // in the public repository; real statements and their fingerprints must
    // never be committed or used as test fixtures.
    private let expectations: [String: Expectation] = [
        "sample-card-period-1.pdf": Expectation(sourceFingerprint: String(repeating: "a", count: 64), source: "Amex", accountKey: "amex:1001", kind: .card, status: .valid, rows: 4, chargeTotal: 2_803.42, creditLimit: 10_000, creditAvailable: 7_196.58, debtBalance: 2_803.42, paymentForNoInterest: 967.57, minimumPlusMsi: 1_052.92, msiPending: 1_835.85),
        "sample-card-period-2.pdf": Expectation(sourceFingerprint: String(repeating: "b", count: 64), source: "Amex", accountKey: "amex:1001", kind: .card, status: .valid, rows: 5, chargeTotal: 4_671.16, paymentTotal: 3_440.52, creditLimit: 10_000, creditAvailable: 6_590.61, debtBalance: 3_409.39, paymentForNoInterest: 2_315.09, minimumPlusMsi: 1_503.66, msiPending: 1_718.97),
        "sample-bank-period-1.pdf": Expectation(sourceFingerprint: String(repeating: "c", count: 64), source: "Santander", accountKey: "santander:2001", kind: .bank, status: .pending, rows: 0, previousBalance: 3_700, cashBalance: 2_462, depositTotal: 4_922, withdrawalTotal: 6_160),
        "sample-bank-period-2.pdf": Expectation(sourceFingerprint: String(repeating: "d", count: 64), source: "Santander", accountKey: "santander:2001", kind: .bank, status: .pending, rows: 0, previousBalance: 2_462, cashBalance: 3_780, depositTotal: 5_160, withdrawalTotal: 3_842),
        "sample-bank-period-3.pdf": Expectation(sourceFingerprint: String(repeating: "e", count: 64), source: "Santander", accountKey: "santander:2001", kind: .bank, status: .pending, rows: 0, previousBalance: 3_780, cashBalance: 3_250, depositTotal: 3_618, withdrawalTotal: 4_148),
        "sample-card-period-3.pdf": Expectation(sourceFingerprint: String(repeating: "f", count: 64), source: "Amex", accountKey: "amex:1001", kind: .card, status: .valid, rows: 6, chargeTotal: 3_317.75, paymentTotal: 2_315.09, creditLimit: 20_000, creditAvailable: 16_682.25, debtBalance: 3_317.75, paymentForNoInterest: 3_996.62, minimumPlusMsi: 1_957.97, msiPending: 1_040.11),
        "sample-bank-period-4.pdf": Expectation(sourceFingerprint: String(repeating: "1", count: 64), source: "Santander", accountKey: "santander:2001", kind: .bank, status: .pending, rows: 0, previousBalance: 3_250, cashBalance: 2_950, depositTotal: 1_820, withdrawalTotal: 2_120),
        "sample-bank-bbva.pdf": Expectation(sourceFingerprint: String(repeating: "2", count: 64), source: "BBVA", accountKey: "bbva:3001", kind: .bank, status: .valid, rows: 11, depositTotal: 1_950, withdrawalTotal: 2_205.87),
    ]

    private func expectationsForRun() throws -> [String: Expectation] {
        guard let rawPath = ProcessInfo.processInfo.environment["MARCELITO_PDF_CORPUS_MANIFEST"],
              !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return expectations
        }

        let manifestURL = URL(fileURLWithPath: rawPath)
        let data = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
        let manifest = try JSONDecoder().decode(ExternalManifest.self, from: data)
        if let schemaVersion = manifest.schemaVersion, schemaVersion != 1 {
            throw NSError(
                domain: "NativeCorpusManifest",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "schemaVersion no compatible en el manifiesto privado."]
            )
        }
        if let readerVersion = manifest.readerVersion,
           readerVersion != FinanceStore.readerVersion {
            throw NSError(
                domain: "NativeCorpusManifest",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "El manifiesto usa \(readerVersion), pero el lector actual es \(FinanceStore.readerVersion)."]
            )
        }
        guard !manifest.files.isEmpty else {
            throw NSError(
                domain: "NativeCorpusManifest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "El manifiesto privado no contiene archivos."]
            )
        }

        var decoded: [String: Expectation] = [:]
        for entry in manifest.files {
            let file = entry.file.trimmingCharacters(in: .whitespacesAndNewlines)
            let fingerprint = entry.sourceFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !file.isEmpty,
                  fingerprint.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
                  decoded[file] == nil,
                  let kind = StatementKind(rawValue: entry.kind),
                  let status = StatementReconciliationStatus(rawValue: entry.status) else {
                throw NSError(
                    domain: "NativeCorpusManifest",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Entrada inválida en el manifiesto privado: \(entry.file)."]
                )
            }
            let normalizedSource = entry.source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedSource.isEmpty, normalizedSource != "Desconocido" else {
                throw NSError(
                    domain: "NativeCorpusManifest",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Falta el emisor de \(entry.file)."]
                )
            }
            if let accountKey = entry.accountKey,
               accountKey.range(of: #"^[a-z0-9]+:\d{4}$"#, options: [.regularExpression, .caseInsensitive]) == nil {
                throw NSError(
                    domain: "NativeCorpusManifest",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "La cuenta de \(entry.file) debe usar emisor:últimos4."]
                )
            }
            if status == .valid, (entry.rows == nil || (entry.rows ?? -1) < 0) {
                throw NSError(
                    domain: "NativeCorpusManifest",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Un golden válido necesita rows entero en \(entry.file)."]
                )
            }
            let summary = entry.summary
            decoded[file] = Expectation(
                sourceFingerprint: fingerprint,
                source: normalizedSource,
                accountKey: entry.accountKey ?? "",
                kind: kind,
                status: status,
                rows: entry.rows ?? 0,
                previousBalance: summary?.previousBalance,
                cashBalance: summary?.cashBalance,
                depositTotal: summary?.depositTotal,
                withdrawalTotal: summary?.withdrawalTotal,
                chargeTotal: summary?.chargeTotal,
                paymentTotal: summary?.paymentTotal,
                creditLimit: summary?.creditLimit,
                creditAvailable: summary?.creditAvailable,
                debtBalance: summary?.debtBalance,
                paymentForNoInterest: summary?.paymentForNoInterest,
                minimumPlusMsi: summary?.minimumPlusMsi,
                msiPending: summary?.msiPending
            )
        }
        return decoded
    }

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

    /// Lightweight real-file smoke test for the ten-state corpus supplied
    /// out-of-band on a development device/runner. It intentionally does not
    /// require a golden manifest: its job is to ensure the production reader
    /// never emits an absurd amount or an accepted OCR row without row-level
    /// provenance before someone attempts certification/publication.
    func testRealPDFCorpusHasSafeRowDiagnostics() async throws {
        guard let rawDirectory = ProcessInfo.processInfo.environment["MARCELITO_PDF_CORPUS_DIR"],
              !rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Define MARCELITO_PDF_CORPUS_DIR para ejecutar la prueba de seguridad sobre PDFs reales.")
        }

        let directory = URL(fileURLWithPath: rawDirectory, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            throw XCTSkip("MARCELITO_PDF_CORPUS_DIR no contiene PDFs.")
        }

        let store = FinanceStore()
        for file in files {
            let result = try await store.inspectPDFAsync(
                from: file,
                allowOCR: true,
                allowMultimodalFallback: false
            )
            XCTAssertNotEqual(result.source, "Desconocido", file.lastPathComponent + " no identificó el emisor")
            XCTAssertGreaterThan(result.pageCount ?? 0, 0, file.lastPathComponent + " no tiene páginas")
            XCTAssertLessThanOrEqual(result.rowDiagnostics.count, 2_000, file.lastPathComponent + " produjo diagnóstico de filas absurdo")
            for row in result.rowDiagnostics where row.accepted {
                XCTAssertFalse(row.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertFalse(row.selectedColumn?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                               file.lastPathComponent + " aceptó una fila sin columna")
                if let amount = row.selectedAmount {
                    XCTAssertLessThan(abs(NSDecimalNumber(decimal: amount).doubleValue), 10_000_000,
                                      file.lastPathComponent + " convirtió un identificador en importe")
                }
            }
            if result.reconciliation?.status == .invalid {
                XCTAssertEqual(result.imported, 0, file.lastPathComponent + " inválido alimentó el libro canónico")
            }
        }
    }

    func testRowDiagnosticsStayPrivateAndCanBeExported() throws {
        let diagnostic = NativeCorpusDiagnosticFile(
            file: "document-01.pdf",
            sourceFileName: "estado-privado.pdf",
            source: "BBVA",
            mode: "vision-ocr",
            status: StatementReconciliationStatus.pending.rawValue,
            reconciliationReason: "columnas pendientes",
            rows: [
                OCRRowDiagnostic(
                    page: 2,
                    rawText: "23/JUL FACEBK 120.00 3,469.63",
                    selectedColumn: "CARGOS",
                    selectedAmount: 120,
                    direction: "out",
                    reason: "CARGOS determina salida",
                    accepted: true
                )
            ]
        )
        let report = NativeCorpusCertificationReport(files: [], diagnostics: [diagnostic])
        let publicJSON = try XCTUnwrap(report.jsonData)
        let publicText = try XCTUnwrap(String(data: publicJSON, encoding: .utf8))
        XCTAssertFalse(publicText.contains("23/JUL FACEBK"), "el informe público no debe exponer texto OCR")
        XCTAssertFalse(publicText.contains("selectedColumn"), "el informe público no debe exponer decisiones de fila")

        let diagnosticURL = try report.writeDiagnosticsTemporaryFile()
        defer { try? FileManager.default.removeItem(at: diagnosticURL) }
        let privateJSON = try String(contentsOf: diagnosticURL, encoding: .utf8)
        let privateObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(privateJSON.utf8)) as? [String: Any]
        )
        let privateFiles = try XCTUnwrap(privateObject["files"] as? [[String: Any]])
        let privateRows = try XCTUnwrap(privateFiles.first?["rows"] as? [[String: Any]])
        let privateRow = try XCTUnwrap(privateRows.first)
        XCTAssertEqual(privateRow["rawText"] as? String, "23/JUL FACEBK 120.00 3,469.63")
        XCTAssertEqual(privateRow["selectedColumn"] as? String, "CARGOS")
        XCTAssertEqual(privateRow["selectedAmount"] as? String, "120")
    }

    func testValidatedCorpusThroughNativeReaderWhenProvided() throws {
        guard let rawDirectory = ProcessInfo.processInfo.environment["MARCELITO_PDF_CORPUS_DIR"],
              !rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Define MARCELITO_PDF_CORPUS_DIR para ejecutar el corpus nativo con Vision.")
        }

        let directory = URL(fileURLWithPath: rawDirectory, isDirectory: true)
        let runExpectations: [String: Expectation]
        do {
            runExpectations = try expectationsForRun()
        } catch {
            XCTFail("No se pudo leer MARCELITO_PDF_CORPUS_MANIFEST: \(error.localizedDescription)")
            return
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertEqual(Set(files.map(\.lastPathComponent)), Set(runExpectations.keys), "El corpus nativo debe contener exactamente los PDFs del manifiesto.")

        let store = FinanceStore()
        defer { store.clearLocalData() }
        var report: [[String: String]] = []
        var automaticAcceptances = 0
        var goldenAutoAccepted = 0
        var goldenFalseAccepted = 0
        var unresolvedOCR = 0

        for file in files {
            guard let expected = runExpectations[file.lastPathComponent] else { continue }
            let actualFingerprint = try fingerprint(file)
            let fileSizeBytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
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

            // Every real-corpus run also verifies the private row-level
            // provenance emitted by the reader. This catches a regression
            // where the totals look plausible but an OCR reference, balance
            // or certificate number was silently selected as the movement.
            let diagnostics = result.rowDiagnostics
            let extractedRows = result.reconciliation?.extractedMovementCount ?? result.imported
            XCTAssertGreaterThanOrEqual(
                diagnostics.count,
                extractedRows,
                file.lastPathComponent + " no conserva diagnóstico para cada fila extraída"
            )
            for diagnostic in diagnostics {
                XCTAssertFalse(
                    diagnostic.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    file.lastPathComponent + " contiene una fila de diagnóstico sin texto"
                )
                if diagnostic.accepted {
                    if let selectedAmount = diagnostic.selectedAmount {
                        XCTAssertLessThan(
                            abs(NSDecimalNumber(decimal: selectedAmount).doubleValue),
                            10_000_000,
                            file.lastPathComponent + " seleccionó un importe fuera de rango"
                        )
                    }
                    if result.usedOCR {
                        XCTAssertFalse(
                            diagnostic.selectedColumn?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                            file.lastPathComponent + " aceptó una fila OCR sin columna elegida"
                        )
                    }
                }
            }

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
                "diagnosticRows": String(result.rowDiagnostics.count),
                "acceptedDiagnosticRows": String(result.rowDiagnostics.filter(\.accepted).count),
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
        let expectedValidCount = runExpectations.values.filter { $0.status == .valid }.count
        let expectedPendingCount = runExpectations.values.filter { $0.status != .valid }.count
        let exactCorpus = Set(files.map(\.lastPathComponent)) == Set(runExpectations.keys)
        let certified = runExpectations.count >= 10
            && exactCorpus
            && expectedPendingCount == 0
            && goldenFalseAccepted == 0
            && goldenAutoAccepted == expectedValidCount
            && automaticAcceptancePrecision >= 0.97
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
