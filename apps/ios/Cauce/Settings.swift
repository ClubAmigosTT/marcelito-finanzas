import SwiftUI

/// Ajustes locales del libro financiero. El desbloqueo manual es únicamente
/// una salida controlada para inspección: no cambia la conciliación del emisor
/// ni convierte filas provisionales en datos certificados.
struct SettingsView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showUnlockConfirmation = false
    @State private var showUnlockError = false

    private var quality: LedgerQuality { store.ledgerQuality }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if store.manualDashboardUnlockEnabled {
                        Label("Resultados provisionales desbloqueados", systemImage: "lock.open.trianglebadge.exclamationmark")
                            .foregroundStyle(Color.marcelitoAmber)

                        Button {
                            _ = store.setManualDashboardUnlock(false)
                        } label: {
                            Label("Volver a bloquear KPI", systemImage: "lock.fill")
                        }
                        .foregroundStyle(Color.marcelitoNavy)
                    } else {
                        Button {
                            showUnlockConfirmation = true
                        } label: {
                            Label("Desbloquear resultados provisionales", systemImage: "lock.open.trianglebadge.exclamationmark")
                        }
                        .foregroundStyle(Color.marcelitoNavy)
                    }

                    Text("Permite mostrar Resumen, Gastos, Patrimonio y gráficas aunque existan estados no conciliados. No corrige ni certifica los datos: los valores se muestran como provisionales y la acción queda registrada en Diagnóstico.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Resultados")
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
                    Text("La preferencia se guarda solo en este iPhone. Los PDF, filas y credenciales no se envían al activar esta opción.")
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
            .confirmationDialog(
                "Desbloquear resultados provisionales",
                isPresented: $showUnlockConfirmation,
                titleVisibility: .visible
            ) {
                Button("Desbloquear", role: .destructive) {
                    if !store.setManualDashboardUnlock(true) {
                        showUnlockError = true
                    }
                }
                Button("Cancelar", role: .cancel) { }
            } message: {
                Text("Los KPI podrán mostrar cifras de estados pendientes o inválidos. Verás una advertencia de provisionalidad; revisa Diagnóstico antes de tomar decisiones.")
            }
            .alert("No se pudo desbloquear", isPresented: $showUnlockError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Importa al menos un estado de cuenta y ejecuta la auditoría local antes de habilitar resultados provisionales.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }
}
