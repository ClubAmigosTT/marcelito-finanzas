import Foundation
import PDFKit
import CryptoKit

/// Private, explicit export. Captures text before any row recognition and
/// never imports, caches or mutates the financial ledger.
enum PDFExtractionDiagnostic {
    struct Page: Codable {
        let number: Int
        let rotation: Int
        let characterCount: Int
        let truncated: Bool
        let text: String
    }

    struct Probe: Codable {
        let source: String
        let period: String
        let accountKey: String?
        let rows: Int
        let controls: StatementSummaryRecord?
        let missing: [String]
        let usedOCR: Bool?
        let ocrConfidence: Double?
        let ocrPageConfidences: [Double]?
        let ocrFallbackNeedsReview: Bool?
        let ocrColumnCalibrationNeedsReview: Bool?
        let ocrConfidenceNeedsReview: Bool?
        let reconciliation: StatementReconciliationRecord?
        let rowDiagnostics: [OCRRowDiagnostic]?

        init(_ snapshot: ReaderParseSnapshot) {
            self.init(snapshot, metadata: nil)
        }

        init(_ diagnostic: ReaderPDFDiagnosticSnapshot) {
            self.init(diagnostic.snapshot, metadata: diagnostic)
        }

        private init(_ snapshot: ReaderParseSnapshot, metadata: ReaderPDFDiagnosticSnapshot?) {
            source = snapshot.source
            period = snapshot.period
            accountKey = snapshot.accountKey
            rows = snapshot.movements.count
            controls = snapshot.summary
            usedOCR = metadata?.usedOCR
            ocrConfidence = metadata?.ocrConfidence
            ocrPageConfidences = metadata?.ocrPageConfidences
            ocrFallbackNeedsReview = metadata?.ocrFallbackNeedsReview
            ocrColumnCalibrationNeedsReview = metadata?.ocrColumnCalibrationNeedsReview
            ocrConfidenceNeedsReview = metadata?.ocrConfidenceNeedsReview
            reconciliation = metadata?.reconciliation
            rowDiagnostics = metadata?.rowDiagnostics
            var missing: [String] = []
            if snapshot.period == "Periodo no identificado" { missing.append("period") }
            if snapshot.accountKey == nil { missing.append("accountKey") }
            if snapshot.movements.isEmpty { missing.append("movements") }
            if snapshot.summary == nil { missing.append("financialControls") }
            self.missing = missing
        }
    }

    struct Report: Codable {
        let schemaVersion = 2
        let readerVersion: String
        let appVersion: String
        let build: String
        let operatingSystem: String
        let generatedAt: Date
        let fingerprint: String
        let pageCount: Int
        let encrypted: Bool
        let locked: Bool
        let pages: [Page]
        let orderedText: String
        let columnText: String
        let orderedTextTruncated: Bool
        let columnTextTruncated: Bool
        let nativeProbe: Probe
        let orderedProbe: Probe
        let columnProbe: Probe
        let productionProbe: Probe?
        let productionError: String?
    }

    static func capture(data: Data) throws -> Report {
        guard data.count <= 50 * 1024 * 1024 else { throw FinanceImportError.documentTooLarge }
        guard let document = PDFDocument(data: data) else { throw FinanceImportError.unreadableDocument }
        guard document.pageCount <= 80 else { throw FinanceImportError.documentTooManyPages }
        let pages = (0..<document.pageCount).map { index -> Page in
            let page = document.page(at: index)
            let text = page?.string ?? ""
            return Page(number: index + 1, rotation: page?.rotation ?? 0,
                characterCount: text.count, truncated: text.count > 100_000,
                text: String(text.prefix(100_000)))
        }
        let native = pages.map { "__PDF_PAGE_\($0.number)__\n\($0.text)" }.joined(separator: "\n")
        let ordered = SelectablePDFLayout.text(from: document)
        let columns = SelectablePDFLayout.text(from: document, rappiColumns: true)
        func probe(_ text: String) -> Probe {
            Probe(FinanceStore.readerParseSnapshotForTesting(text: text, fileName: "diagnostic.pdf"))
        }
        var production: Probe?
        var error: String?
        do {
            production = Probe(try FinanceStore.readerPDFDiagnosticSnapshotForTesting(
                data: data,
                fileName: "diagnostic.pdf"
            ))
        } catch let failure {
            error = failure.localizedDescription
        }
        return Report(readerVersion: FinanceStore.readerVersion,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            generatedAt: .now, fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            pageCount: document.pageCount, encrypted: document.isEncrypted, locked: document.isLocked,
            pages: pages, orderedText: String(ordered.prefix(1_000_000)), columnText: String(columns.prefix(1_000_000)),
            orderedTextTruncated: ordered.count > 1_000_000, columnTextTruncated: columns.count > 1_000_000,
            nativeProbe: probe(native), orderedProbe: probe(ordered), columnProbe: probe(columns),
            productionProbe: production, productionError: error)
    }

    static func export(from url: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            try Task.checkCancellation()
            let report = try capture(data: data)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("marcelito-pdf-extraction-\(UUID().uuidString).json")
            try encoder.encode(report).write(to: destination, options: [.atomic, .completeFileProtection])
            return destination
        }.value
    }
}
