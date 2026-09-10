import SwiftUI

/// Live diagnostic projection; inspecting a problem never approves a row.
struct LedgerBlockerDetailsView: View {
    @Environment(FinanceStore.self) private var store
    var statementID: UUID? = nil

    private var statements: [StatementRecord] {
        store.blockingStatements.filter { statementID == nil || $0.id == statementID }
    }
    private var movements: [Movement] {
        store.blockingMovements.filter { statementID == nil || $0.statementId == statementID }
    }
    private var reviewMovements: [Movement] {
        store.canonicalMovements.filter {
            (statementID == nil || $0.statementId == statementID)
                && ["Por revisar", "Sin categoría", "Otros / Por revisar"].contains($0.category)
        }
    }

    var body: some View {
        List {
            Section("Qué está pasando") {
                Text(store.ledgerQuality.isBlocking ? "Hay controles que impiden validar los resultados." : "No hay bloqueos activos.")
                Text("\(statements.count) estados con bloqueo · \(movements.count) movimientos con problemas propios")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Una diferencia en los totales puede bloquear un estado completo. No significa que todos sus movimientos sean incorrectos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(statements) { statement in
                Section("\(statement.source) · \(conciseStatementPeriod(statement))") {
                    if let account = statement.accountKey { Text(account).font(.caption) }
                    ForEach(Array(store.statementBlockingReasons(statement).enumerated()), id: \.offset) { _, reason in
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .font(.subheadline).foregroundStyle(Color.marcelitoDanger)
                    }
                    let rejected = (statement.rowDiagnostics ?? []).filter { !$0.accepted }
                    if rejected.isEmpty {
                        Text("No hay filas concretas señaladas en el diagnóstico guardado. Revisa las cifras del estado o relee el PDF para obtener más detalle.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(rejected.count) filas rechazadas por el lector").font(.headline)
                        ForEach(Array(rejected.enumerated()), id: \.offset) { _, row in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(row.page.map { "Página \($0)" } ?? "Página no registrada").font(.caption.weight(.semibold))
                                if let ordinal = row.rowOrdinal { Text("Fila \(ordinal)").font(.caption) }
                                Text(row.rawText.isEmpty ? "Texto no recuperado" : row.rawText)
                                    .font(.subheadline).textSelection(.enabled)
                                if let amount = row.selectedAmount {
                                    Text("Importe leído: \(amount.formatted(.currency(code: "MXN")))").monospacedDigit()
                                }
                                Text(rowExplanation(row.reason)).font(.caption).foregroundStyle(.secondary)
                                DisclosureGroup("Detalle técnico") { Text(row.reason).font(.caption).textSelection(.enabled) }
                            }
                        }
                    }
                    NavigationLink("Revisar cifras y releer") { StatementSummaryEditor(statement: statement) }
                    if store.statementFileURL(for: statement) != nil {
                        NavigationLink("Abrir PDF de origen") { StatementDocumentView(statement: statement) }
                    } else {
                        Text("El PDF original no está disponible en este dispositivo.").font(.caption)
                    }
                }
            }
            if !movements.isEmpty {
                Section("Movimientos que bloquean") {
                    ForEach(movements) { movement in
                        VStack(alignment: .leading, spacing: 6) {
                            NavigationLink { MovementDetailView(movement: movement) } label: { movementLabel(movement) }
                            ForEach(store.movementBlockingReasons(movement), id: \.self) { reason in
                                Text(reason).font(.caption).foregroundStyle(Color.marcelitoDanger)
                            }
                            if let page = movement.extractionEvidence?.page {
                                Text(store.isProvisionalScreenshotMovement(movement) ? "Imagen \(page)" : "Página \(page)").font(.caption)
                            }
                            if let text = movement.extractionEvidence?.sourceText, !text.isEmpty {
                                Text(text).font(.caption).textSelection(.enabled)
                            }
                            if let statement = store.statements.first(where: { $0.id == movement.statementId }) {
                                NavigationLink("\(statement.source) · \(conciseStatementPeriod(statement))") {
                                    StatementSummaryEditor(statement: statement)
                                }
                            } else if store.isProvisionalScreenshotMovement(movement) {
                                Text("Origen: captura bancaria · provisional hasta conciliar con un estado oficial").font(.caption)
                                if let capture = store.screenshotCaptures.first(where: { $0.movements.contains(where: { $0.id == movement.id }) }) {
                                    Text("\(capture.source.rawValue) · \(capture.coverageLabel)").font(.caption)
                                }
                            } else {
                                Text(movement.statementId == nil ? "Origen: movimiento manual" : "El estado de origen ya no está disponible.").font(.caption)
                            }
                        }
                    }
                }
            }
            if statementID == nil {
                Section("Controles generales") {
                    ForEach(store.consistencyChecks.filter { !$0.passed }) { check in
                        Text(check.label)
                    }
                    if store.ledgerQuality.spendMismatch { Text("El gasto consolidado excede el calculado a partir de los movimientos. Requiere revisar el cálculo; no se ha identificado una fila responsable.") }
                    if store.ledgerQuality.missingRebuiltStatements { Text("La reconstrucción no recuperó todos los estados esperados. Revisa los PDF disponibles y vuelve a ejecutar la reconstrucción.") }
                    if !store.ledgerQuality.isBlocking { Text("Sin controles bloqueados").foregroundStyle(.secondary) }
                }
            }
            if !reviewMovements.isEmpty {
                Section("Sin categoría: no causan bloqueo por sí solos") {
                    ForEach(reviewMovements) { movement in
                        NavigationLink { MovementDetailView(movement: movement) } label: { movementLabel(movement) }
                    }
                }
            }
        }
        .navigationTitle("Detalle del bloqueo")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func movementLabel(_ movement: Movement) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(movement.title)
            Text("\(movement.account) · \(movement.date.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundStyle(.secondary)
            Text(movement.amount.formatted(.currency(code: "MXN"))).monospacedDigit()
        }
    }

    private func rowExplanation(_ reason: String) -> String {
        if reason.contains("balance-cell") { return "El saldo de esta fila falta o no se puede leer con seguridad." }
        if reason.contains("date-description-or-amount") { return "La fecha, el concepto o el importe de esta fila no pudieron validarse." }
        if reason.contains("ambiguous") || reason.contains("consensus") { return "Las lecturas de esta fila no coinciden; hay más de una interpretación posible." }
        if reason.contains("column") { return "No se pudo determinar con seguridad si el importe es un cargo, abono o saldo." }
        return "El lector no pudo validar esta fila. Consulta el texto original y el detalle técnico para revisar el motivo registrado."
    }
}

struct LedgerBlockerDetailsButton: View {
    @Environment(FinanceStore.self) private var store
    @State private var showingDetails = false
    var body: some View {
        Button("Ver detalle del bloqueo y pendientes") { showingDetails = true }
            .font(.subheadline.weight(.semibold))
            .sheet(isPresented: $showingDetails) {
                NavigationStack {
                    LedgerBlockerDetailsView()
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { showingDetails = false } } }
                }
                .environment(store)
            }
    }
}
