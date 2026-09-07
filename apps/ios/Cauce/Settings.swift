import SwiftUI

/// Ajustes de calidad del libro financiero. Los estados rechazados nunca
/// pueden desbloquearse manualmente ni alimentar resultados provisionales.
struct SettingsView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss

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
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }
}
