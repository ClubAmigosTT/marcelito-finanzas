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
    let multimodalFallbackAttempted: Bool
    let multimodalFallbackError: String?

    /// Kept only in memory for the local result list. It is deliberately not
    /// part of the Codable payload exported to GitHub.
    var sourceFileName: String = ""

    private enum CodingKeys: String, CodingKey {
        case file, sourceFingerprint, source, accountKey, kind, mode,
             sourceStatus, sourceConfidence, status, requiresReview, rows,
             extractedRows,
             ocrConfidence, weakestOCRPage, ocrColumnsCalibrated,
             reconciliationValid, duplicate, errorCode, reconciliationReason,
             multimodalFallbackAttempted, multimodalFallbackError
    }

    var id: String { file }

    var accepted: Bool {
        guard status == StatementReconciliationStatus.valid.rawValue,
              sourceStatus == SourceDetectionStatus.verified.rawValue,
              !requiresReview,
              reconciliationValid,
              !duplicate else { return false }
        guard mode != "multimodal-error" else { return false }
        if mode == "vision-ocr" || mode == "multimodal-ai" {
            guard let ocrConfidence,
                  let weakestOCRPage,
                  ocrConfidence >= 0.88,
                  weakestOCRPage >= 0.78 else { return false }
            if mode == "vision-ocr", ["Santander", "BBVA"].contains(source), ocrColumnsCalibrated != true { return false }
        }
        return true
    }

    init(index: Int, sourceFileName: String, summary: ImportSummary) {
        file = "document-\(String(format: "%02d", index + 1)).pdf"
        sourceFingerprint = summary.sourceFingerprint
        source = summary.source
        accountKey = summary.accountKey ?? ""
        kind = summary.kind.rawValue
        mode = summary.extractionProvider == "multimodal"
            ? "multimodal-ai"
            : (summary.multimodalFallbackAttempted
                ? "multimodal-error"
                : (summary.usedOCR ? "vision-ocr" : "pdf-text"))
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
        multimodalFallbackAttempted = summary.multimodalFallbackAttempted
        multimodalFallbackError = summary.multimodalFallbackError
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
        multimodalFallbackAttempted = false
        multimodalFallbackError = nil
        self.sourceFileName = sourceFileName
    }

    init(index: Int, sourceFileName: String, duplicateOf summary: ImportSummary) {
        file = "document-\(String(format: "%02d", index + 1)).pdf"
        sourceFingerprint = summary.sourceFingerprint
        source = summary.source
        accountKey = summary.accountKey ?? ""
        kind = summary.kind.rawValue
        mode = summary.extractionProvider == "multimodal"
            ? "multimodal-ai"
            : (summary.multimodalFallbackAttempted
                ? "multimodal-error"
                : (summary.usedOCR ? "vision-ocr" : "pdf-text"))
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
        multimodalFallbackAttempted = summary.multimodalFallbackAttempted
        multimodalFallbackError = summary.multimodalFallbackError
        self.sourceFileName = sourceFileName
    }
}

/// Private, row-level companion to the redacted corpus report. It is intended
/// for local debugging only and is never included in the publication JSON.
struct NativeCorpusDiagnosticFile: Codable, Identifiable {
    let file: String
    let sourceFileName: String
    let source: String
    let mode: String
    let status: String
    let reconciliationReason: String?
    let multimodalFallbackAttempted: Bool
    let multimodalFallbackError: String?
    let rows: [OCRRowDiagnostic]

    private enum CodingKeys: String, CodingKey {
        case file, sourceFileName, source, mode, status, reconciliationReason,
             multimodalFallbackAttempted, multimodalFallbackError, rows
    }

    init(
        file: String,
        sourceFileName: String,
        source: String,
        mode: String,
        status: String,
        reconciliationReason: String?,
        multimodalFallbackAttempted: Bool = false,
        multimodalFallbackError: String? = nil,
        rows: [OCRRowDiagnostic]
    ) {
        self.file = file
        self.sourceFileName = sourceFileName
        self.source = source
        self.mode = mode
        self.status = status
        self.reconciliationReason = reconciliationReason
        self.multimodalFallbackAttempted = multimodalFallbackAttempted
        self.multimodalFallbackError = multimodalFallbackError
        self.rows = rows
    }

    var id: String { file }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(file, forKey: .file)
        try container.encode(sourceFileName, forKey: .sourceFileName)
        try container.encode(source, forKey: .source)
        try container.encode(mode, forKey: .mode)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(reconciliationReason, forKey: .reconciliationReason)
        try container.encode(multimodalFallbackAttempted, forKey: .multimodalFallbackAttempted)
        try container.encodeIfPresent(multimodalFallbackError, forKey: .multimodalFallbackError)
        try container.encode(rows, forKey: .rows)
    }
}

struct NativeCorpusDiagnosticReport: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let readerVersion: String
    let files: [NativeCorpusDiagnosticFile]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, readerVersion, files
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(readerVersion, forKey: .readerVersion)
        // Keep row evidence in the private export explicitly. The public
        // certification report uses a different encoder and intentionally
        // omits this field.
        try container.encode(files, forKey: .files)
    }

    func writeTemporaryFile() throws -> URL {
        let dateFormatter = ISO8601DateFormatter()
        let filePayload: [[String: Any]] = files.map { file in
            let rows: [[String: Any]] = file.rows.map { row in
                var payload: [String: Any] = [
                    "id": row.id,
                    "rawText": row.rawText,
                    "reason": row.reason,
                    "accepted": row.accepted
                ]
                if let page = row.page { payload["page"] = page }
                if let selectedColumn = row.selectedColumn { payload["selectedColumn"] = selectedColumn }
                if let selectedAmount = row.selectedAmount {
                    payload["selectedAmount"] = NSDecimalNumber(decimal: selectedAmount).stringValue
                }
                if let direction = row.direction { payload["direction"] = direction }
                return payload
            }
            var payload: [String: Any] = [
                "file": file.file,
                "sourceFileName": file.sourceFileName,
                "source": file.source,
                "mode": file.mode,
                "status": file.status,
                "rows": rows
            ]
            if let reconciliationReason = file.reconciliationReason {
                payload["reconciliationReason"] = reconciliationReason
            }
            return payload
        }
        let object: [String: Any] = [
            "schemaVersion": schemaVersion,
            "generatedAt": dateFormatter.string(from: generatedAt),
            "readerVersion": readerVersion,
            "files": filePayload
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("marcelito-native-corpus-row-diagnostics-\(UUID().uuidString).json")
        try data.write(to: url, options: [.atomic])
        return url
    }
}

struct NativeCorpusCertificationReport: Codable, Identifiable {
    static let schemaVersion = 1
    static let minimumFileCount = 10
    static let targetPrecision = 0.97

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
    /// Kept in memory for the explicit private diagnostics export. This is
    /// intentionally excluded from `jsonData`, which remains safe to share
    /// with the publication verifier.
    var diagnostics: [NativeCorpusDiagnosticFile] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, readerVersion, files, accepted,
             blocked, expectedValid, expectedPending, goldenAutoAccepted,
             goldenFalseAccepted, automaticAcceptancePrecision, unresolvedOCR,
             certified, financialDataRedacted, generatedBy
    }

    var id: String { "native-corpus-\(generatedAt.timeIntervalSince1970)" }

    init(
        files: [NativeCorpusFileReport],
        readerVersion: String = FinanceStore.readerVersion,
        diagnostics: [NativeCorpusDiagnosticFile] = []
    ) {
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
        unresolvedOCR = files.filter { ["vision-ocr", "multimodal-ai", "multimodal-error"].contains($0.mode) && !$0.accepted }.count
        certified = files.count >= Self.minimumFileCount
            && blocked == 0
            && automaticAcceptancePrecision >= Self.targetPrecision
            && unresolvedOCR == 0
        financialDataRedacted = true
        generatedBy = files.contains { $0.mode == "multimodal-ai" }
            ? "ios-hybrid-device"
            : "ios-vision-device"
        self.diagnostics = diagnostics
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

    func writeDiagnosticsTemporaryFile() throws -> URL {
        try NativeCorpusDiagnosticReport(
            schemaVersion: 1,
            generatedAt: generatedAt,
            readerVersion: readerVersion,
            files: diagnostics
        ).writeTemporaryFile()
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
        var diagnostics: [NativeCorpusDiagnosticFile] = []
        var seenFingerprints = Set<String>()

        for (index, url) in sortedURLs.enumerated() {
            if Task.isCancelled { break }
            progress?(index, sortedURLs.count, url.lastPathComponent)
            let fingerprint = Self.fingerprintForCertification(url) ?? String(repeating: "0", count: 64)
            do {
                let summary = try await inspectPDFAsync(
                    from: url,
                    allowOCR: true,
                    stage: { stage in
                        progress?(index, sortedURLs.count, "\(url.lastPathComponent): \(stage)")
                    }
                )
                if !seenFingerprints.insert(summary.sourceFingerprint).inserted {
                    reports.append(NativeCorpusFileReport(index: index, sourceFileName: url.lastPathComponent, duplicateOf: summary))
                } else {
                    reports.append(NativeCorpusFileReport(index: index, sourceFileName: url.lastPathComponent, summary: summary))
                }
                diagnostics.append(
                    NativeCorpusDiagnosticFile(
                        file: "document-\(String(format: "%02d", index + 1)).pdf",
                        sourceFileName: url.lastPathComponent,
                        source: summary.source,
                        mode: summary.extractionProvider == "multimodal"
                            ? "multimodal-ai"
                            : (summary.multimodalFallbackAttempted
                                ? "multimodal-error"
                                : (summary.usedOCR ? "vision-ocr" : "pdf-text")),
                        status: summary.reconciliation?.status.rawValue ?? StatementReconciliationStatus.pending.rawValue,
                        reconciliationReason: summary.reconciliation?.reason,
                        multimodalFallbackAttempted: summary.multimodalFallbackAttempted,
                        multimodalFallbackError: summary.multimodalFallbackError,
                        rows: summary.rowDiagnostics
                    )
                )
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
                diagnostics.append(
                    NativeCorpusDiagnosticFile(
                        file: "document-\(String(format: "%02d", index + 1)).pdf",
                        sourceFileName: url.lastPathComponent,
                        source: "Desconocido",
                        mode: "reader-error",
                        status: StatementReconciliationStatus.invalid.rawValue,
                        reconciliationReason: "El lector no pudo producir una extracción.",
                        rows: []
                    )
                )
            }
            progress?(index + 1, sortedURLs.count, url.lastPathComponent)
        }

        return NativeCorpusCertificationReport(files: reports, diagnostics: diagnostics)
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
    @State private var isAISettingsPresented = false
    @State private var selectedFiles: [URL] = []
    @State private var isRunning = false
    @State private var progress = 0.0
    @State private var status = "Selecciona los 10 estados validados para ejecutar Vision en este iPhone."
    @State private var report: NativeCorpusCertificationReport?
    @State private var exportURL: URL?
    @State private var diagnosticExportURL: URL?
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
            .sheet(isPresented: $isAISettingsPresented) {
                AISettingsView()
            }
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
            Text("El lector usa PDFKit y Vision dentro del iPhone. OpenCode Zen no recibe PDFs: se usa opcionalmente después para clasificar gastos ya conciliados. El informe exportado contiene únicamente hashes y resultados de calidad.")
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
                .buttonStyle(.marcelitoSecondary)

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
                .buttonStyle(.marcelitoPrimary)
                .disabled(selectedFiles.isEmpty || isRunning)
            }
            if ZenAPIKeyStore.apiKey == nil {
                Button("Configurar OpenCode Zen") {
                    isAISettingsPresented = true
                }
                .buttonStyle(.borderless)
            } else {
                HStack(spacing: 12) {
                    Text("Zen disponible solo para clasificar gastos")
                        .font(.subheadline)
                    Button {
                        isAISettingsPresented = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .accessibilityLabel("Editar configuración de OpenCode Zen")
                    }
                    .buttonStyle(.borderless)
                }
                Text("La lectura y conciliación de PDFs siempre se ejecutan localmente. Zen recibe únicamente descripciones, fechas e importes de gastos ya validados; nunca recibe el PDF ni puede cambiar cifras contables.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                NativeCorpusMetric(title: "Por resolver", value: "\(report.unresolvedOCR)")
            }

            Text(report.certified
                ? "Comparte este informe JSON y guárdalo como docs/native-corpus-certification.json en GitHub. La siguiente build podrá usarlo sin una Mac."
                : "Corrige los archivos bloqueados y vuelve a ejecutar el lector. El informe no habilita publicación hasta alcanzar 97% y cubrir los 10 estados; cada archivo aceptado debe conciliar al 100%.")
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
                        Text(file.qualityDetail)
                            .font(.caption2)
                            .foregroundStyle(file.accepted ? Color.marcelitoSuccess : Color.marcelitoAmber)
                            .lineLimit(2)
                        if let reason = file.errorCode {
                            Text(reason)
                                .font(.caption2)
                                .foregroundStyle(Color.marcelitoAmber)
                        }
                        if let reason = file.multimodalFallbackError,
                           !reason.isEmpty {
                            Text("Respaldo IA: \(reason)")
                                .font(.caption2)
                                .foregroundStyle(Color.marcelitoDanger)
                                .lineLimit(4)
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
                .buttonStyle(.marcelitoPrimary)
            }
            if let diagnosticExportURL {
                Text("El diagnóstico por fila contiene el texto OCR, la columna y el importe seleccionados para cada fila. Compártelo solo para depurar tus propios estados.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ShareLink(item: diagnosticExportURL) {
                    Label("Compartir diagnóstico por fila", systemImage: "list.bullet.rectangle.portrait")
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.marcelitoSecondary)
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
            diagnosticExportURL = nil
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
        diagnosticExportURL = nil
        progress = 0
        status = "Preparando el corpus…"
        Task { @MainActor in
            let result = await store.certifyNativeCorpus(
                from: selectedFiles
            ) { completed, total, fileName in
                progress = total == 0 ? 0 : Double(completed) / Double(total)
                status = "Leyendo \(fileName) con Vision…"
            }
            report = result
            progress = 1
            status = result.certified ? "Certificación lista." : "Hay archivos que requieren revisión."
            exportURL = try? result.writeTemporaryFile()
            diagnosticExportURL = try? result.writeDiagnosticsTemporaryFile()
            isRunning = false
            DiagnosticsRecorder.record(
                level: result.certified ? "info" : "error",
                stage: "native.corpus",
                message: "Certificación en dispositivo: \(result.accepted)/\(result.files.count) aceptados; precisión \(Int((result.automaticAcceptancePrecision * 100).rounded()))%."
            )
        }
    }
}

private extension NativeCorpusFileReport {
    /// Compact, actionable diagnostics for the on-device result list. The
    /// exported JSON keeps the individual numeric fields for automation; the
    /// UI combines them into one line so a blocked PDF explains whether the
    /// issue is OCR quality, Santander column calibration or text
    /// reconciliation without exposing transaction content.
    var qualityDetail: String {
        let method: String = switch mode {
        case "multimodal-ai": "IA multimodal"
        case "multimodal-error": "IA multimodal falló · se conservó Vision"
        case "vision-ocr": "Vision"
        default: "PDF de texto"
        }
        var parts: [String] = [method]
        if let ocrConfidence {
            parts.append("OCR media \(Int((ocrConfidence * 100).rounded()))%")
        }
        if let weakestOCRPage {
            parts.append("mín. página \(Int((weakestOCRPage * 100).rounded()))%")
        }
        if sourceStatus != SourceDetectionStatus.verified.rawValue {
            parts.append("emisor \(sourceStatus)")
        }
        if ["Santander", "BBVA"].contains(source), let ocrColumnsCalibrated {
            parts.append(ocrColumnsCalibrated ? "columnas calibradas" : "columnas sin calibrar")
        }
        return parts.joined(separator: " · ")
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
