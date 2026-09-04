import Foundation
import OSLog
import SwiftUI
import UIKit

/// A small, local diagnostic trail for TestFlight builds.
///
/// The trail deliberately stores only app state and counts. It never uploads
/// data and it is capped so a failed import cannot fill the device's storage.
struct DiagnosticEvent: Codable, Identifiable {
    let id: UUID
    let date: Date
    let level: String
    let stage: String
    let message: String

    init(level: String = "info", stage: String, message: String) {
        self.id = UUID()
        self.date = .now
        self.level = level
        self.stage = stage
        self.message = message
    }
}

enum DiagnosticsRecorder {
    private static let eventsKey = "marcelito.diagnostics.events.v1"
    private static let cleanExitKey = "marcelito.diagnostics.cleanExit.v1"
    private static let unexpectedSessionKey = "marcelito.diagnostics.unexpectedSession.v1"
    private static let maxEvents = 120
    private static let logger = Logger(subsystem: "mx.marcelito.personal", category: "finance")

    static var events: [DiagnosticEvent] {
        guard let data = UserDefaults.standard.data(forKey: eventsKey),
              let decoded = try? JSONDecoder().decode([DiagnosticEvent].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.date > $1.date }
    }

    static var lastSessionEndedUnexpectedly: Bool {
        UserDefaults.standard.bool(forKey: unexpectedSessionKey)
    }

    static func markLaunch() {
        let defaults = UserDefaults.standard
        let hadPreviousSession = defaults.object(forKey: cleanExitKey) != nil
        let previousSessionWasUnexpected = hadPreviousSession && !defaults.bool(forKey: cleanExitKey)
        defaults.set(previousSessionWasUnexpected, forKey: unexpectedSessionKey)
        defaults.set(false, forKey: cleanExitKey)

        if previousSessionWasUnexpected {
            record(
                level: "error",
                stage: "lifecycle",
                message: "La sesión anterior terminó inesperadamente; revisa los eventos de esta sesión."
            )
        }
        record(stage: "lifecycle", message: "Aplicación iniciada.")
    }

    static func markBackground() {
        UserDefaults.standard.set(true, forKey: cleanExitKey)
        record(stage: "lifecycle", message: "Aplicación enviada a segundo plano.")
    }

    static func record(level: String = "info", stage: String, message: String) {
        let event = DiagnosticEvent(level: level, stage: stage, message: message)
        var stored = events
        stored.insert(event, at: 0)
        stored = Array(stored.prefix(maxEvents))
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: eventsKey)
        }

        switch level {
        case "error": logger.error("[\(stage, privacy: .public)] \(message, privacy: .public)")
        case "debug": logger.debug("[\(stage, privacy: .public)] \(message, privacy: .public)")
        default: logger.info("[\(stage, privacy: .public)] \(message, privacy: .public)")
        }
    }

    static func exportText() -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Marcelito · diagnóstico local",
            "Sesión anterior inesperada: \(lastSessionEndedUnexpectedly ? "sí" : "no")",
            ""
        ]
        lines.append(contentsOf: events.prefix(80).map { event in
            "\(formatter.string(from: event.date)) [\(event.level)] \(event.stage): \(event.message)"
        })
        return lines.joined(separator: "\n")
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: eventsKey)
    }
}

struct DiagnosticsView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var events = DiagnosticsRecorder.events
    @State private var isNativeCorpusPresented = false
    @State private var isSettingsPresented = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(
                        DiagnosticsRecorder.lastSessionEndedUnexpectedly
                            ? "La sesión anterior terminó inesperadamente"
                            : "No se detectó un cierre inesperado",
                        systemImage: DiagnosticsRecorder.lastSessionEndedUnexpectedly
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .foregroundStyle(
                        DiagnosticsRecorder.lastSessionEndedUnexpectedly
                            ? Color.marcelitoDanger
                            : Color.marcelitoSuccess
                    )

                    Text("Este registro es local. Sirve para identificar si el fallo ocurrió al abrir la app, reparar estados o importar un PDF.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Estado de la sesión")
                }

                Section("Libro canónico") {
                    if let audit = store.lastAuditRun {
                        let auditStatus: String = switch audit.status {
                        case .passed: "Verificado"
                        case .warning: "Advertencias"
                        case .blocked: "Bloqueado"
                        }
                        LabeledContent("Última auditoría", value: auditStatus)
                        LabeledContent("Disparador", value: audit.trigger)
                        LabeledContent("Versión del libro", value: String(audit.ledgerVersion.uuidString.prefix(8)))
                        if let readerVersion = audit.readerVersion {
                            LabeledContent("Versión del lector", value: readerVersion)
                        }
                        Text("Ejecutada \(audit.completedAt, style: .relative) · \(String(audit.id.uuidString.prefix(8)))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Estados", value: "\(store.ledgerQuality.validatedStatementCount)/\(store.ledgerQuality.statementCount) conciliados")
                    LabeledContent("Movimientos canónicos", value: "\(store.ledgerQuality.movementCount)")
                    LabeledContent("Por revisar (canónicos)", value: "\(Int(store.ledgerQuality.reviewPercent.rounded()))% · \(store.ledgerQuality.reviewMovementCount) · \(money(store.ledgerQuality.reviewAmount))")
                    LabeledContent("Movimientos en cuarentena", value: "\(store.ledgerQuality.quarantinedMovementCount) · \(money(store.ledgerQuality.quarantinedAmount))")
                    LabeledContent("Estados en cuarentena", value: "\(store.ledgerQuality.quarantinedStatementCount)")
                    LabeledContent("Importes fuera de rango", value: "\(store.ledgerQuality.absurdMovementCount)")
                    LabeledContent("Filas con evidencia", value: "\(Int(store.ledgerQuality.evidencePercent.rounded()))%")
                    if store.dashboardIsProvisional {
                        Label("Desbloqueo manual activo: los KPI son provisionales.", systemImage: "lock.open.trianglebadge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(Color.marcelitoAmber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if store.ledgerQuality.missingEvidenceCount > 0 {
                        Text("\(store.ledgerQuality.missingEvidenceCount) movimiento(s) importado(s) sin página, confianza o fragmento de origen completo.")
                            .font(.caption)
                            .foregroundStyle(Color.marcelitoDanger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let message = store.ledgerQuality.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(Color.marcelitoDanger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(store.statements) { statement in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("\(statement.source) · \(conciseStatementPeriod(statement))")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(reconciliationLabel(statement))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(reconciliationColor(statement))
                            }
                            Text("Filas reconstruidas: \(statement.transactionCount)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if statement.issuerConfirmedByUser == true {
                                Label("Emisor confirmado manualmente", systemImage: "person.crop.circle.badge.checkmark")
                                    .font(.caption2)
                                    .foregroundStyle(Color.marcelitoNavyMid)
                            }
                            if let reason = statement.reconciliation?.reason {
                                Text(reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let detection = statement.sourceDetection,
                               !detection.evidence.isEmpty {
                                Text("Señales del emisor: \(detection.evidence.joined(separator: " · "))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let detection = statement.sourceDetection,
                               !detection.ignoredBodyMentions.isEmpty {
                                Text("Menciones ignoradas en movimientos: \(detection.ignoredBodyMentions.joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let summary = statement.summary {
                                let statementKind = statement.kind
                                    ?? (statement.source.localizedCaseInsensitiveContains("Amex") ? .card : .bank)
                                VStack(alignment: .leading, spacing: 2) {
                                    if statementKind == .card {
                                        if let limit = summary.creditLimit,
                                           let available = summary.creditAvailable {
                                            Text("Deuda comprometida: \(money(max(Decimal(0), limit - available)))")
                                        }
                                        if summary.paymentForNoInterest != nil {
                                            Text("Pago para no generar intereses: \(money(summary.paymentForNoInterest))")
                                        }
                                        if summary.msiPending != nil {
                                            Text("MSI pendientes: \(money(summary.msiPending))")
                                        }
                                    } else {
                                        if summary.previousBalance != nil {
                                            Text("Saldo inicial: \(money(summary.previousBalance))")
                                        }
                                        if summary.depositTotal != nil {
                                            Text("Depósitos: \(money(summary.depositTotal))")
                                        }
                                        if summary.withdrawalTotal != nil {
                                            Text("Retiros: \(money(summary.withdrawalTotal))")
                                        }
                                        if summary.cashBalance != nil {
                                            Text("Saldo final: \(money(summary.cashBalance))")
                                        }
                                    }
                                }
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Color.marcelitoNavyMid)
                            }
                            if let confidence = statement.ocrConfidence {
                                Text("Confianza OCR: \(Int((confidence * 100).rounded()))%")
                                    .font(.caption2)
                                    .foregroundStyle(confidence >= 0.88 ? Color.marcelitoSuccess : Color.marcelitoAmber)
                            }
                            if let weakestPage = statement.ocrPageConfidences?.min() {
                                Text("Página más débil: \(Int((weakestPage * 100).rounded()))%")
                                    .font(.caption2)
                                    .foregroundStyle(weakestPage >= 0.78 ? Color.marcelitoSuccess : Color.marcelitoAmber)
                            }
                            if let columnsCalibrated = statement.ocrColumnsCalibrated {
                                Label(
                                    columnsCalibrated
                                        ? "Columnas OCR calibradas con encabezado visual"
                                        : "Columnas OCR provisionales; requiere revisión",
                                    systemImage: columnsCalibrated ? "checkmark.ruler" : "ruler"
                                )
                                .font(.caption2)
                                .foregroundStyle(columnsCalibrated ? Color.marcelitoSuccess : Color.marcelitoAmber)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            if let reconciliation = statement.reconciliation,
                               let extracted = reconciliation.extractedMovementCount,
                               let expected = reconciliation.expectedMovementCount {
                                Text("Cobertura de filas: \(extracted)/\(expected)")
                                    .font(.caption2)
                                    .foregroundStyle(extracted == expected ? Color.marcelitoSuccess : Color.marcelitoDanger)
                            }
                        }
                    }
                    ForEach(store.consistencyChecks) { check in
                        let mark = check.passed ? "✓" : "!"
                        Text("\(mark) \(check.label)")
                            .font(.caption)
                            .foregroundStyle(check.passed ? Color.marcelitoSuccess : Color.marcelitoDanger)
                    }
                }

                Section("Certificación del lector") {
                    Button {
                        isNativeCorpusPresented = true
                    } label: {
                        Label("Certificar estados con Vision", systemImage: "viewfinder")
                    }
                    Text("Ejecuta el mismo lector PDFKit/Vision en el iPhone sobre tus estados privados y genera un informe sanitizado para la publicación.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Resumen por periodo") {
                    if store.statementAudits.isEmpty {
                        Text("Aún no hay estados para auditar.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.statementAudits) { audit in
                            let duplicateSuffix = audit.duplicateRows.map { " · \($0) duplicadas" } ?? ""
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(audit.source) · \(audit.period)")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(audit.statusLabel)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(audit.reconciliation == .invalid ? Color.marcelitoDanger : (audit.requiresReview ? Color.marcelitoAmber : Color.marcelitoSuccess))
                                }
                                Text("Filas: \(audit.validRows)/\(audit.importedRows) válidas · \(audit.canonicalRows) canónicas · \(audit.quarantinedRows) en cuarentena\(duplicateSuffix)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text("Por revisar \(audit.reviewRows) · \(money(audit.reviewTotal))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(audit.reviewRows > 0 ? Color.marcelitoAmber : .secondary)
                                Text("Ingresos \(money(audit.incomeTotal)) · Gasto \(money(audit.expenseTotal)) · Reembolsos \(money(audit.refundTotal))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Color.marcelitoNavyMid)
                                Text("Transferencias \(money(audit.transferTotal)) · Pagos de tarjeta \(money(audit.cardPaymentTotal))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Color.marcelitoNavyMid)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                Section("Eventos recientes") {
                    if events.isEmpty {
                        Text("Aún no hay eventos registrados.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(events) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(event.stage)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(event.date, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(event.message)
                                    .font(.caption)
                                    .foregroundStyle(event.level == "error" ? Color.marcelitoDanger : .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .navigationTitle("Diagnóstico")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = DiagnosticsRecorder.exportText()
                                + "\n\n"
                                + store.diagnosticExportText()
                            copied = true
                        } label: {
                            Label("Copiar registro", systemImage: "doc.on.doc")
                        }
                        Button {
                            isSettingsPresented = true
                        } label: {
                            Label("Ajustes", systemImage: "gearshape")
                        }
                        Button("Limpiar registro", role: .destructive) {
                            DiagnosticsRecorder.clear()
                            events = []
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Opciones de diagnóstico")
                }
            }
            .alert("Registro copiado", isPresented: $copied) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Puedes pegarlo en el reporte de TestFlight sin adjuntar tus estados de cuenta.")
            }
            .sheet(isPresented: $isNativeCorpusPresented) {
                NativeCorpusCertificationView()
            }
            .sheet(isPresented: $isSettingsPresented) {
                SettingsView()
            }
        }
    }

    private func reconciliationLabel(_ statement: StatementRecord) -> String {
        switch statement.reconciliation?.status {
        case .valid: return "Conciliado"
        case .invalid: return "Inválido"
        case .pending, .none: return "Pendiente"
        }
    }

    private func reconciliationColor(_ statement: StatementRecord) -> Color {
        switch statement.reconciliation?.status {
        case .valid: return Color.marcelitoSuccess
        case .invalid: return Color.marcelitoDanger
        case .pending, .none: return Color.marcelitoAmber
        }
    }

    private func money(_ value: Decimal?) -> String {
        value?.formatted(.currency(code: "MXN").precision(.fractionLength(2))) ?? "Pendiente"
    }
}
