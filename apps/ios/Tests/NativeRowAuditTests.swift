import CryptoKit
import Foundation
import XCTest
@testable import Marcelito

/// Independent expectations must be transcribed from the PDF, never generated
/// from the reader under test. This file contains no private financial data.
final class NativeRowAuditTests: XCTestCase {
    private struct Row: Decodable {
        let date: String
        let page: Int
        let signedAmount: String
        let titleContains: String
    }

    private struct File: Decodable {
        let file: String
        let sourceFingerprint: String
        let source: String
        let accountKey: String
        let period: String
        let rows: [Row]
        let controls: Controls?
    }

    private struct Controls: Decodable {
        let openingBalance: String
        let closingBalance: String
        let deposits: String
        let withdrawals: String
        let depositCount: Int
        let withdrawalCount: Int
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let referenceMethod: String
        let files: [File]
    }

    private func differences(expected: [Row], actual: [Movement]) -> [String] {
        var errors: [String] = []
        if expected.count != actual.count { errors.append("row-count") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        for (index, pair) in zip(expected, actual).enumerated() {
            let (wanted, received) = pair
            let prefix = "row-\(index + 1)"
            if formatter.string(from: received.date) != wanted.date { errors.append("\(prefix):date") }
            if received.extractionEvidence?.page != wanted.page { errors.append("\(prefix):page") }
            if Decimal(string: wanted.signedAmount, locale: Locale(identifier: "en_US_POSIX")) != received.amount {
                errors.append("\(prefix):signedAmount")
            }
            if wanted.titleContains.isEmpty || received.title.range(of: wanted.titleContains, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                errors.append("\(prefix):description")
            }
        }
        return errors
    }

    func testCompensatingErrorsCannotPassByMatchingOnlyTotals() {
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 1, day: 2))!
        let expected = [
            Row(date: "2026-01-02", page: 1, signedAmount: "100", titleContains: "sample"),
            Row(date: "2026-01-02", page: 1, signedAmount: "100", titleContains: "sample"),
        ]
        let wrong = [Decimal(90), Decimal(110)].map {
            Movement(date: date, title: "sample", account: "BBVA", category: "", amount: $0, flow: .income)
        }
        XCTAssertTrue(differences(expected: expected, actual: wrong).contains("row-1:signedAmount"))
        XCTAssertTrue(differences(expected: expected, actual: wrong).contains("row-2:signedAmount"))
        XCTAssertTrue(differences(expected: expected, actual: Array(wrong.prefix(1))).contains("row-count"))
    }

    func testRealPDFRowsAgainstIndependentReference() throws {
        let environment = ProcessInfo.processInfo.environment
        let required = ["1", "true", "yes"].contains(environment["MARCELITO_PDF_CORPUS_REQUIRE_CERTIFIED"]?.lowercased() ?? "")
        guard let corpusPath = environment["MARCELITO_PDF_CORPUS_DIR"],
              let manifestPath = environment["MARCELITO_PDF_ROW_MANIFEST"] else {
            if required { XCTFail("Certification requires the private row reference and PDF directory"); return }
            throw XCTSkip("Private row audit not supplied; this run does not verify real PDF rows")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.referenceMethod, "visual-independent")
        XCTAssertFalse(manifest.files.isEmpty)
        let directory = URL(fileURLWithPath: corpusPath, isDirectory: true)
        let available = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "pdf" }.map(\.lastPathComponent)
        let names = manifest.files.map(\.file)
        XCTAssertEqual(Set(names).count, names.count, "Duplicate document in reference")
        if required { XCTAssertEqual(Set(names), Set(available), "Reference does not cover the whole corpus") }
        for (index, file) in manifest.files.enumerated() {
            // Logs identify only ordinal/field; private amounts stay local.
            let label = "document-\(index + 1)"
            guard available.contains(file.file), !file.rows.isEmpty else {
                XCTFail("\(label): missing PDF or empty row reference"); continue
            }
            let data = try Data(contentsOf: directory.appendingPathComponent(file.file))
            let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard fingerprint == file.sourceFingerprint.lowercased() else {
                XCTFail("\(label): reference fingerprint mismatch"); continue
            }
            let snapshot = try FinanceStore.pdfRowSnapshotForTesting(data: data, fileName: file.file)
            XCTAssertTrue(snapshot.source == file.source, "\(label): source")
            XCTAssertTrue(snapshot.accountKey == file.accountKey, "\(label): account")
            XCTAssertTrue(snapshot.period == file.period, "\(label): period")
            let failures = differences(expected: file.rows, actual: snapshot.movements)
            XCTAssertTrue(failures.isEmpty, "\(label): \(failures.joined(separator: ", "))")
            if let controls = file.controls {
                func check(_ actual: Decimal?, _ expected: String, _ field: String) {
                    let value = Decimal(string: expected, locale: Locale(identifier: "en_US_POSIX"))
                    XCTAssertTrue(value != nil && actual == value, "\(label): \(field)")
                }
                check(snapshot.summary?.previousBalance, controls.openingBalance, "openingBalance")
                check(snapshot.summary?.cashBalance, controls.closingBalance, "closingBalance")
                check(snapshot.summary?.depositTotal, controls.deposits, "deposits")
                check(snapshot.summary?.withdrawalTotal, controls.withdrawals, "withdrawals")
                XCTAssertTrue(snapshot.movements.filter { $0.amount > 0 }.count == controls.depositCount, "\(label): depositCount")
                XCTAssertTrue(snapshot.movements.filter { $0.amount < 0 }.count == controls.withdrawalCount, "\(label): withdrawalCount")
            }
        }
        print("NATIVE_ROW_AUDIT_COVERAGE referenced=\(names.count) available=\(available.count)")
    }
}
