import Foundation
import SwiftUI

/// Ajustes de calidad del libro financiero. Los estados rechazados nunca
/// pueden desbloquearse manualmente ni alimentar resultados provisionales.
struct SettingsView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var ownerAliasesText = ""
    @State private var transferSaveMessage: String?

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
                    LabeledContent("Estados conciliados", value: "\(quality.validatedStatementCount)/\(quality.statementCount)")
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

                Section("Privacidad") {
                    Text("Los PDF y sus filas permanecen en este iPhone. Un archivo rechazado conserva su diagnóstico, pero no sus filas dentro del libro canónico.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .onAppear {
                ownerAliasesText = store.transferOwnerAliases.joined(separator: ", ")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }
}
