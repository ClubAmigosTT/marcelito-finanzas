import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Redacted, device-generated evidence for the Vision reader. The report
/// contains hashes, quality signals and reconciliation status, never PDF
/// bytes, descriptions, balances or transaction amounts.
struct NativeCorpusFileReport: Codable, Identifiable {
    let file: String
    let sourceFingerprint: String
    let source: String
    let accountKey: String
    let kind: String
    let mode: String
    let sourceStatus: String
    let sourceConfidence: Double
    let status: String
    let requiresReview: Bool
    let rows: Int
    /// Number of rows reconstructed before reconciliation quarantined them.
    /// Keeping this visible makes an invalid statement diagnosable instead of
    /// looking like an empty PDF.
    let extractedRows: Int
    let ocrConfidence: Double?
    let weakestOCRPage: Double?
    let ocrColumnsCalibrated: Bool?
    let reconciliationValid: Bool
    let duplicate: Bool
    let errorCode: String?
    let reconciliationReason: String?

    /// Kept only in memory for the local result list. It is deliberately not
    /// part of the Codable payload exported to GitHub.
    var sourceFileName: String = ""

    private enum CodingKeys: String, CodingKey {
        case file, sourceFingerprint, source, accountKey, kind, mode,
             sourceStatus, sourceConfidence, status, requiresReview, rows,
             extractedRows,
             ocrConfidence, weakestOCRPage, ocrColumnsCalibrated,
             reconciliationValid, duplicate, errorCode, reconciliationReason
    }

    var id: String { file }

    var accepted: Bool {
        guard status == StatementReconciliationStatus.valid.rawValue,
              sourceStatus == SourceDetectionStatus.verified.rawValue,
              !requiresReview,
              reconciliationValid,
              !duplicate else { return false }
        if mode == "vision-ocr" {
            guard let ocrConfidence,
                  let weakestOCRPage,
                  ocrConfidence >= 0.88,
                  weakestOCRPage >= 0.78 else { return false }
            if source == "Santander" && ocrColumnsCalibrated != true { return false }
        }
        return true
    }

    init(index: Int, sourceFileName: String, summary: ImportSummary) {
        file = "document-\(String(format: "%02d", index + 1)).pdf"
        sourceFingerprint = summary.sourceFingerprint
        source = summary.source
        accountKey = summary.accountKey ?? ""
        kind = summary.kind.rawValue
        mode = summary.usedOCR ? "vision-ocr" : "pdf-text"
        sourceStatus = summary.sourceDetection.status.rawValue
        sourceConfidence = summary.sourceDetection.confidence
        status = summary.reconciliation?.status.rawValue ?? StatementReconciliationStatus.pending.rawValue
        requiresReview = summary.requiresReview
        rows = summary.imported
        extractedRows = summary.reconciliation?.extractedMovementCount ?? summary.imported
        ocrConfidence = summary.ocrConfidence
        weakestOCRPage = summary.ocrPageConfidences?.min()
        ocrColumnsCalibrated = summary.ocrColumnsCalibrated
        reconciliationValid = summary.reconciliation?.status == .valid
        duplicate = false
        errorCode = nil
        reconciliationReason = summary.reconciliation?.reason
        self.sourceFileName = sourceFileName
    }

    init(index: Int, sourceFileName: String, fingerprint: String, errorCode: String) {
        file = "document-\(String(format: "%02d", index + 1)).pdf"
        sourceFingerprint = fingerprint
        source = "Desconocido"
        accountKey = "desconocido:0000"
        kind = StatementKind.unknown.rawValue
        mode = "pdf-text"
        sourceStatus = SourceDetectionStatus.unknown.rawValue
        sourceConfidence = 0
        status = StatementReconciliationStatus.invalid.rawValue
        requiresReview = true
        rows = 0
        extractedRows = 0
        ocrConfidence = nil
        weakestOCRPage = nil
        ocrColumnsCalibrated = nil
        reconciliationValid = false
        duplicate = false
        self.errorCode = errorCode
        reconciliationReason = nil
        self.sourceFileName = sourceFileName
    }

    init(index: Int, sourceFileName: String, duplicateOf summary: ImportSummary) {
        file = "document-\(String(format: "%02d", index + 1)).pdf"
        sourceFingerprint = summary.sourceFingerprint
        source = summary.source
        accountKey = summary.accountKey ?? ""
        kind = summary.kind.rawValue
        mode = summary.usedOCR ? "vision-ocr" : "pdf-text"
        sourceStatus = summary.sourceDetection.status.rawValue
        sourceConfidence = summary.sourceDetection.confidence
        status = StatementReconciliationStatus.invalid.rawValue
        requiresReview = true
        rows = 0
        extractedRows = 0
        ocrConfidence = summary.ocrConfidence
        weakestOCRPage = summary.ocrPageConfidences?.min()
        ocrColumnsCalibrated = summary.ocrColumnsCalibrated
        reconciliationValid = false
        duplicate = true
        errorCode = "duplicate-pdf"
        reconciliationReason = "Este PDF ya fue seleccionado anteriormente."
        self.sourceFileName = sourceFileName
    }
}

struct NativeCorpusCertificationReport: Codable, Identifiable {
    static let schemaVersion = 1
    static let minimumFileCount = 10

    let schemaVersion: Int
    let generatedAt: Date
    let readerVersion: String
    let files: [NativeCorpusFileReport]
    let accepted: Int
    let blocked: Int
    let expectedValid: Int
    let expectedPending: Int
    let goldenAutoAccepted: Int
    let goldenFalseAccepted: Int
    let automaticAcceptancePrecision: Double
    let unresolvedOCR: Int
    let certified: Bool
    /// A machine-readable promise consumed by the GitHub verifier.
    let financialDataRedacted: Bool
    let generatedBy: String

    var id: String { "native-corpus-\(generatedAt.timeIntervalSince1970)" }

    init(files: [NativeCorpusFileReport], readerVersion: String = FinanceStore.readerVersion) {
        self.schemaVersion = Self.schemaVersion
        generatedAt = .now
        self.readerVersion = readerVersion
        self.files = files
        accepted = files.filter(\.accepted).count
        blocked = files.count - accepted
        expectedValid = files.count
        expectedPending = 0
        goldenAutoAccepted = accepted
        goldenFalseAccepted = 0
        automaticAcceptancePrecision = files.isEmpty ? 0 : Double(accepted) / Double(files.count)
        unresolvedOCR = files.filter { $0.mode == "vision-ocr" && !$0.accepted }.count
        certified = files.count >= Self.minimumFileCount
            && blocked == 0
            && automaticAcceptancePrecision >= 0.99
            && unresolvedOCR == 0
        financialDataRedacted = true
        generatedBy = "ios-vision-device"
    }

    var jsonData: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }

    func writeTemporaryFile() throws -> URL {
        guard let jsonData else { throw NSError(domain: "NativeCorpus", code: 1) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("marcelito-native-corpus-certification.json")
        try jsonData.write(to: url, options: [.atomic])
        return url
    }
}

extension FinanceStore {
    /// Runs the production PDFKit/Vision reader over a user-selected corpus
    /// without touching movements, statements or the canonical ledger.
    func certifyNativeCorpus(
        from urls: [URL],
        progress: ((Int, Int, String) -> Void)? = nil
    ) async -> NativeCorpusCertificationReport {
        let sortedURLs = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var reports: [NativeCorpusFileReport] = []
        var seenFingerprints = Set<String>()

        for (index, url) in sortedURLs.enumerated() {
            if Task.isCancelled { break }
            progress?(index, sortedURLs.count, url.lastPathComponent)
            let fingerprint = Self.fingerprintForCertification(url) ?? String(repeating: "0", count: 64)
            do {
                let summary = try await inspectPDFAsync(from: url, allowOCR: true)
                if !seenFingerprints.insert(summary.sourceFingerprint).inserted {
                    reports.append(NativeCorpusFileReport(index: index, sourceFileName: url.lastPathComponent, duplicateOf: summary))
                } else {
                    reports.append(NativeCorpusFileReport(index: index, sourceFileName: url.lastPathComponent, summary: summary))
                }
            } catch is CancellationError {
                break
            } catch {
                reports.append(
                    NativeCorpusFileReport(
                        index: index,
                        sourceFileName: url.lastPathComponent,
                        fingerprint: fingerprint,
                        errorCode: "reader-error"
                    )
                )
            }
            progress?(index + 1, sortedURLs.count, url.lastPathComponent)
        }

        return NativeCorpusCertificationReport(files: reports)
    }

    private static func fingerprintForCertification(_ url: URL) -> String? {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct NativeCorpusCertificationView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var isImporterPresented = false
    @State private var selectedFiles: [URL] = []
    @State private var isRunning = false
    @State private var progress = 0.0
    @State private var status = "Selecciona los 10 estados validados para ejecutar Vision en este iPhone."
    @State private var report: NativeCorpusCertificationReport?
    @State private var exportURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    introCard
                    selectionCard
                    if isRunning {
                        ProgressView(value: progress) {
                            Text(status)
                        }
                        .tint(Color.marcelitoNavy)
                    }
                    if let report {
                        resultCard(report)
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .background(Color.marcelitoCream.ignoresSafeArea())
            .navigationTitle("Certificar lector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: true,
                onCompletion: handleSelection
            )
            .alert("No se pudo ejecutar la certificación", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Revisa los archivos seleccionados e inténtalo de nuevo.")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.marcelitoCream)
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Certificación privada en el dispositivo", systemImage: "checkmark.shield.fill")
                .font(.headline)
            Text("El lector ejecuta PDFKit y Vision sobre tus estados. Los PDFs nunca salen del iPhone; el informe solo contiene hashes, emisor, calidad OCR y resultado de conciliación.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Se requieren al menos \(NativeCorpusCertificationReport.minimumFileCount) archivos únicos para habilitar la compuerta de publicación.")
                .font(.caption)
                .foregroundStyle(Color.marcelitoNavyMid)
        }
        .foregroundStyle(Color.marcelitoNavy)
        .marcelitoCard(fill: Color.marcelitoNavy.opacity(0.10), radius: 16, padding: 16)
    }

    private var selectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Estados seleccionados", systemImage: "doc.on.doc")
                    .font(.headline)
                Spacer()
                Text("\(selectedFiles.count)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(selectedFiles.count >= NativeCorpusCertificationReport.minimumFileCount ? Color.marcelitoSuccess : Color.marcelitoAmber)
            }
            if !selectedFiles.isEmpty {
                Text(selectedFiles.map(\.lastPathComponent).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 10) {
                Button {
                    isImporterPresented = true
                } label: {
                    Label("Elegir PDFs", systemImage: "folder")
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.bordered)
                .tint(Color.marcelitoNavy)

                Button {
                    runCertification()
                } label: {
                    Label("Ejecutar Vision", systemImage: "viewfinder")
                        .frame(maxWidth: .infinity, minHeight: 42)
                        // The parent card sets a navy foreground style. Keep
                        // the prominent action legible on its navy fill on
                        // iOS versions that do not derive a contrasting
                        // label color from `.tint` automatically.
                        .foregroundStyle(Color.marcelitoCream)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.marcelitoNavy)
                .disabled(selectedFiles.isEmpty || isRunning)
            }
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(Color.marcelitoNavy)
        .marcelitoCard(fill: Color.marcelitoCreamSoft, radius: 16, padding: 16)
    }

    private func resultCard(_ report: NativeCorpusCertificationReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                report.certified ? "Corpus certificado" : "Corpus bloqueado",
                systemImage: report.certified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
            )
            .font(.headline)
            .foregroundStyle(report.certified ? Color.marcelitoSuccess : Color.marcelitoAmber)

            HStack(spacing: 16) {
                NativeCorpusMetric(title: "Aceptados", value: "\(report.accepted)/\(report.files.count)")
                NativeCorpusMetric(title: "Precisión", value: "\(Int((report.automaticAcceptancePrecision * 100).rounded()))%")
                NativeCorpusMetric(title: "OCR pendiente", value: "\(report.unresolvedOCR)")
            }

            Text(report.certified
                ? "Comparte este informe JSON y guárdalo como docs/native-corpus-certification.json en GitHub. La siguiente build podrá usarlo sin una Mac."
                : "Corrige los archivos bloqueados y vuelve a ejecutar Vision. El informe no habilita publicación hasta alcanzar 99% y cubrir los 10 estados.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(report.files) { file in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: file.accepted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(file.accepted ? Color.marcelitoSuccess : Color.marcelitoAmber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.sourceFileName)
                            .font(.subheadline.weight(.semibold))
                        Text("\(file.source) · \(file.status) · \(file.rows) válidas · \(file.extractedRows) extraídas")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let reason = file.errorCode {
                            Text(reason)
                                .font(.caption2)
                                .foregroundStyle(Color.marcelitoAmber)
                        }
                        if let reason = file.reconciliationReason,
                           !reason.isEmpty {
                            Text(reason)
                                .font(.caption2)
                                .foregroundStyle(Color.marcelitoAmber)
                                .lineLimit(3)
                        }
                    }
                    Spacer()
                }
            }

            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Compartir informe JSON", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.marcelitoNavy)
            }
        }
        .foregroundStyle(Color.marcelitoNavy)
        .marcelitoCard(fill: Color.marcelitoCreamSoft, radius: 16, padding: 16)
    }

    private func handleSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            selectedFiles = urls
            report = nil
            exportURL = nil
            status = urls.isEmpty ? "No seleccionaste archivos." : "Listo para ejecutar Vision sobre \(urls.count) PDF(s)."
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func runCertification() {
        guard !selectedFiles.isEmpty, !isRunning else { return }
        isRunning = true
        report = nil
        exportURL = nil
        progress = 0
        status = "Preparando el corpus…"
        Task { @MainActor in
            let result = await store.certifyNativeCorpus(from: selectedFiles) { completed, total, fileName in
                progress = total == 0 ? 0 : Double(completed) / Double(total)
                status = "Leyendo \(fileName)…"
            }
            report = result
            progress = 1
            status = result.certified ? "Certificación lista." : "Hay archivos que requieren revisión."
            exportURL = try? result.writeTemporaryFile()
            isRunning = false
            DiagnosticsRecorder.record(
                level: result.certified ? "info" : "error",
                stage: "native.corpus",
                message: "Certificación en dispositivo: \(result.accepted)/\(result.files.count) aceptados; precisión \(Int((result.automaticAcceptancePrecision * 100).rounded()))%."
            )
        }
    }
}

private struct NativeCorpusMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
