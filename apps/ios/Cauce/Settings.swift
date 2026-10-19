import Foundation
import SwiftUI

/// Ajustes de calidad del libro financiero. Los estados rechazados nunca
/// pueden desbloquearse manualmente ni alimentar resultados provisionales.
struct SettingsView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var ownerAliasesText = ""
    @State private var transferSaveMessage: String?
    @State private var rereading = false
    @State private var rereadProgress = 0.0
    @State private var rereadStatus: String?
    @State private var confirmReread = false

    private var quality: LedgerQuality { store.ledgerQuality }

    var body: some View {
        NavigationStack {
            Form {
                Section("Resultados") {
                    Label(
                        quality.isBlocking ? "KPI bloqueados por conciliación" : "KPI respaldados por estados conciliados",
                        systemImage: quality.isBlocking ? "lock.fill" : "checkmark.seal.fill"
                    )
                    .foregroundStyle(quality.isBlocking ? Color.marcelitoDanger : Color.marcelitoSuccess)

                    Text("Solo los estados cuyo parser específico concilia exactamente contra los totales oficiales pueden entrar al libro canónico. No existe desbloqueo manual de resultados.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Calidad actual") {
                    NavigationLink("Ver detalle del bloqueo y pendientes") { LedgerBlockerDetailsView() }
                    LabeledContent("Estados con conciliación válida", value: "\(quality.reconciledStatementCount)/\(quality.statementCount)")
                    LabeledContent("Estados elegibles para KPI", value: "\(quality.validatedStatementCount)/\(quality.statementCount)")
                    LabeledContent("Calidad de conciliación", value: "\(Int(quality.reconciledPercent.rounded()))%")
                    LabeledContent("Evidencia de filas", value: "\(Int(quality.evidencePercent.rounded()))%")
                    if quality.isBlocking {
                        Label(quality.message ?? "Hay controles pendientes.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.marcelitoDanger)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label("Todos los controles permiten usar los KPI.", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(Color.marcelitoSuccess)
                    }
                }

                Section("Transferencias entre mis cuentas") {
                    TextField("Nombres del titular", text: $ownerAliasesText, axis: .vertical)
                        .textInputAutocapitalization(.words)
                        .lineLimit(2...5)
                    Text("Separa las variantes con comas. El nombre sólo se usa junto con importe, fecha, dirección y señales de transferencia; nunca se envía fuera del iPhone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Guardar y volver a comparar") {
                        let aliases = ownerAliasesText
                            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
                        let added = store.updateTransferOwnerAliases(aliases)
                        ownerAliasesText = store.transferOwnerAliases.joined(separator: ", ")
                        transferSaveMessage = added == 0
                            ? "Perfil guardado. No aparecieron coincidencias nuevas."
                            : "Perfil guardado. Se identificaron \(added) lados nuevos de transferencias."
                    }
                    if let transferSaveMessage {
                        Label(transferSaveMessage, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.marcelitoSuccess)
                    }
                }

                Section {
                    Button("Releer todos mis PDFs") { confirmReread = true }
                        .disabled(rereading)
                    if rereading {
                        ProgressView(value: rereadProgress) { Text(rereadStatus ?? "Leyendo…").font(.caption) }
                    } else if let rereadStatus {
                        Text(rereadStatus).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Lectura de estados")
                } footer: {
                    Text("Vuelve a leer cada PDF guardado con la versión actual de la app, sin usar lecturas anteriores. Tus clasificaciones y movimientos manuales se conservan, y si algún estado deja de cuadrar se queda el libro que ya tenías.")
                }

                Section("Tu información") {
                    NavigationLink("Respaldo y restauración") { FinanceBackupView() }
                    CategoryUndoButton()
                }
                Section("Privacidad") {
                    Text("Los PDF y sus filas permanecen en este iPhone. Un archivo rechazado conserva su diagnóstico, pero no sus filas dentro del libro canónico.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .confirmationDialog("¿Releer todos tus PDFs?", isPresented: $confirmReread, titleVisibility: .visible) {
                Button("Releer ahora") { rereadAll() }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Puede tardar varios minutos si hay estados escaneados. Mantén la app abierta.")
            }
            .interactiveDismissDisabled(rereading)
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }.disabled(rereading)
                }
            }
            .onAppear {
                ownerAliasesText = store.transferOwnerAliases.joined(separator: ", ")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(rereading ? .hidden : .visible)
        .presentationBackground(.regularMaterial)
    }

    private func rereadAll() {
        rereading = true
        rereadProgress = 0
        rereadStatus = "Preparando la relectura…"
        Task { @MainActor in
            let result = await store.rereadAllStoredPDFsAsync { completed, total, fileName in
                rereadProgress = Double(completed) / Double(max(total, 1))
                rereadStatus = "Leyendo \(fileName) · \(completed)/\(total)"
            }
            if result.candidateCount == 0 {
                rereadStatus = "No hay PDFs guardados en este iPhone para releer."
            } else if result.keptPrevious {
                rereadStatus = "Se conservó tu libro anterior: con la relectura cuadraban menos estados. Revisa Diagnóstico para ver cuáles."
            } else if result.invalidCount > 0 {
                rereadStatus = "\(result.importedCount) estados releídos · \(result.invalidCount) requieren revisión."
            } else {
                rereadStatus = "\(result.importedCount) estados releídos con la versión actual."
            }
            rereading = false
            store.runAutomaticAuditIfNeeded(trigger: "manual-reread")
        }
    }
}
