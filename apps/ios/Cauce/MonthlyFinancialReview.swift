import Foundation
import SwiftUI

enum MonthlyAuditBucket: String, CaseIterable, Identifiable {
    case income = "Ingresos externos"
    case spending = "Compras y gastos"
    case refunds = "Reembolsos"
    case transferOut = "Traspasos propios: salidas"
    case transferIn = "Traspasos propios: entradas"
    case cardPayment = "Pagos de tarjeta desde bancos"
    var id: String { rawValue }
}

struct MonthlyFinancialAudit {
    let month: Date
    let rows: [MonthlyAuditBucket: [Movement]]
    let hasCompleteCoverage: Bool
    let unresolvedPairCount: Int
    let excludedStatementCount: Int
    let bridge: MonthlyFundingBridge?
    func total(_ bucket: MonthlyAuditBucket) -> Decimal {
        rows[bucket, default: []].reduce(0) { $0 + abs($1.amount) }
    }
    var netSpending: Decimal { total(.spending) - total(.refunds) }
    var surplus: Decimal { total(.income) - netSpending }
    var canUseForBudget: Bool { hasCompleteCoverage && unresolvedPairCount == 0 && excludedStatementCount == 0 }
}

struct MonthlyFundingBridge {
    let cashChange: Decimal
    let debtChange: Decimal
    let incomeLessSpending: Decimal
    var positionChange: Decimal { cashChange - debtChange }
    var difference: Decimal { positionChange - incomeLessSpending }
    var reconciles: Bool { abs(difference) <= Decimal(string: "0.01")! }
}

struct TransferReviewPair: Identifiable {
    let outgoing: Movement
    let incoming: Movement
    var isCardPayment: Bool = false
    var id: String { "\(outgoing.id)|\(incoming.id)" }
}

struct FinancialReviewRow: View {
    let movement: Movement
    var body: some View {
        NavigationLink {
            MovementDetailView(movement: movement)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(movement.summaryDisplayTitle).lineLimit(2)
                    Spacer()
                    Text(movement.amount, format: .currency(code: "MXN")).monospacedDigit()
                }
                Text("\(movement.account) · \(movement.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct TransferReviewView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation: TransferReviewPair?
    @State private var repairMessage: String?
    @State private var ownershipAnswer: OwnershipAnswer?
    private struct OwnershipAnswer { let movement: Movement; let ownAccount: Bool }
    var body: some View {
        NavigationStack {
            List {
                let ownership = store.pendingOwnershipReviews
                if !ownership.isEmpty {
                    Section {
                        ForEach(ownership.prefix(30)) { movement in
                            VStack(alignment: .leading, spacing: 8) {
                                FinancialReviewRow(movement: movement)
                                HStack {
                                    Button("Sí, es mía") { ownershipAnswer = OwnershipAnswer(movement: movement, ownAccount: true) }
                                        .buttonStyle(.bordered)
                                    Button(movement.amount < 0 ? "No, fue un gasto" : "No, fue un ingreso") { ownershipAnswer = OwnershipAnswer(movement: movement, ownAccount: false) }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    } header: {
                        Text("¿Fue a una cuenta tuya? (\(ownership.count))")
                    } footer: {
                        Text("El estado no dice a quién fue la transferencia. Si fue a otra cuenta tuya no cuenta como gasto ni ingreso.")
                    }
                }
                let rules = store.transferOwnershipRules
                if !rules.isEmpty {
                    Section("Tus reglas de transferencias") {
                        ForEach(rules.keys.sorted(), id: \.self) { key in
                            LabeledContent(key.split(separator: "|").dropFirst().joined().uppercased(), value: rules[key] == "own" ? "Cuenta tuya" : "Gasto o ingreso")
                                .swipeActions { Button("Olvidar", role: .destructive) { store.removeTransferOwnershipRule(key) } }
                        }
                    }
                }
                Section {
                    Text("Confirmar excluye ambos lados de ingresos y gastos. Descartar sólo rechaza esta pareja; no cambia sus tipos ni categorías.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        Task {
                            let result = await store.recoverPaymentDescriptions()
                            repairMessage = "\(result.updated) descripciones recuperadas."
                                + (result.skipped > 0 ? " \(result.skipped) estados no pudieron comprobarse; se conservaron sus datos." : "")
                        }
                    } label: {
                        if store.isRepairingPaymentDescriptions {
                            HStack { ProgressView(); Text(store.paymentDescriptionRepairProgress ?? "Recuperando descripciones…") }
                        } else { Label("Recuperar descripciones de los PDF", systemImage: "doc.text.magnifyingglass") }
                    }
                    .disabled(store.isRepairingPaymentDescriptions)
                    if let repairMessage { Text(repairMessage).font(.caption).foregroundStyle(.secondary) }
                }
                if store.pendingTransferReviewPairs.isEmpty {
                    ContentUnavailableView("Sin parejas pendientes", systemImage: "checkmark.circle",
                        description: Text("No hay coincidencias por revisar en las cuentas cargadas. Esto no garantiza que estén cargadas todas tus transferencias."))
                }
                ForEach(store.pendingTransferReviewPairs) { pair in
                    Section(pair.isCardPayment ? "Pago a tarjeta" : "Traspaso entre cuentas") {
                        FinancialReviewRow(movement: pair.outgoing)
                        FinancialReviewRow(movement: pair.incoming)
                        HStack {
                            Button(pair.isCardPayment ? "Confirmar pago a tarjeta" : "Confirmar traspaso propio") { confirmation = pair }
                                .buttonStyle(.bordered)
                            Button("Descartar pareja") { store.rejectTransferPair(pair) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                Section {
                    Button("Volver a mostrar parejas descartadas") { store.resetRejectedTransferPairs() }
                        .font(.caption)
                }
            }
            .confirmationDialog(ownershipAnswer.map { $0.ownAccount ? "Marcar como traspaso entre tus cuentas" : "Marcar como movimiento con otra persona" } ?? "",
                isPresented: Binding(get: { ownershipAnswer != nil }, set: { if !$0 { ownershipAnswer = nil } }), titleVisibility: .visible) {
                if let answer = ownershipAnswer {
                    Button("Solo este movimiento") {
                        store.resolveTransferOwnership(answer.movement, ownAccount: answer.ownAccount, applyToConcept: false); ownershipAnswer = nil
                    }
                    Button("Todos los «\(answer.movement.title)»") {
                        store.resolveTransferOwnership(answer.movement, ownAccount: answer.ownAccount, applyToConcept: true); ownershipAnswer = nil
                    }
                    Button("Cancelar", role: .cancel) { ownershipAnswer = nil }
                }
            } message: {
                Text("Con «Todos» la respuesta queda como regla para este concepto, incluso en estados que importes después. Puedes olvidarla abajo.")
            }
            .navigationTitle("Revisar transferencias")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
            .alert(confirmation?.isCardPayment == true ? "¿Es el mismo pago a tu tarjeta?" : "¿Son el mismo traspaso entre tus cuentas?", isPresented: Binding(
                get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
            )) {
                Button("Confirmar ambos movimientos") {
                    if let pair = confirmation {
                        if pair.isCardPayment { _ = store.confirmPaymentPair(pair) }
                        else { _ = store.confirmOwnTransfer(pair.outgoing, counterpart: pair.incoming) }
                    }
                    confirmation = nil
                }
                Button("Cancelar", role: .cancel) { confirmation = nil }
            } message: { Text("El importe se excluirá de ingresos y gastos. Tus categorías se conservarán.") }
            .foregroundStyle(Color.marcelitoNavy)
            .scrollContentBackground(.hidden)
            .background(MarcelitoAmbientBackground())
        }
    }
}

struct MonthlyFinancialReviewView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(FinancialPlanningStore.self) private var planning
    @State private var month = Calendar(identifier: .gregorian).dateInterval(of: .month, for: .now)!.start
    @State private var copiedSummary = false
    private var audit: MonthlyFinancialAudit { store.monthlyFinancialAudit(for: month) }
    private var months: [Date] {
        let calendar = Calendar(identifier: .gregorian)
        let current = calendar.dateInterval(of: .month, for: .now)!.start
        return Array(Set(store.movements.compactMap { calendar.dateInterval(of: .month, for: $0.date)?.start } + [month, current])).sorted(by: >)
    }
    private func monthLabel(_ value: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "es_MX")
        formatter.dateFormat = "MMMM yyyy"; return formatter.string(from: value).capitalized
    }
    private func copySummary(_ report: MonthlyFinancialAudit) {
        var lines = ["Marcelito · resumen mensual · \(monthLabel(month))",
            "Cobertura: \(report.hasCompleteCoverage ? "completa" : "parcial")",
            "Parejas pendientes: \(report.unresolvedPairCount)",
            "Estados excluidos: \(report.excludedStatementCount)",
            "Gasto neto: \(report.netSpending.formatted(.currency(code: "MXN")))"]
        for bucket in MonthlyAuditBucket.allCases {
            lines.append("\n\(bucket.rawValue): \(report.total(bucket).formatted(.currency(code: "MXN")))")
            for row in report.rows[bucket, default: []].sorted(by: { $0.date < $1.date }) {
                let title = row.summaryDisplayTitle.replacingOccurrences(of: #"\d{10,}"#, with: "••••", options: .regularExpression)
                lines.append("\(row.date.formatted(date: .abbreviated, time: .omitted)) · \(row.account) · \(title) · \(row.amount.formatted(.currency(code: "MXN")))")
            }
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        copiedSummary = true
    }

    var body: some View {
        let report = audit
        return NavigationStack {
            List {
                Section {
                    Picker("Mes", selection: $month) {
                        ForEach(months, id: \.self) { Text(monthLabel($0)).tag($0) }
                    }
                    LabeledContent("Gasto neto", value: report.netSpending.formatted(.currency(code: "MXN")))
                    Text("Compras y gastos menos reembolsos. Los traspasos propios y pagos de tarjeta se muestran por separado.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !report.hasCompleteCoverage { Text("Cobertura parcial: estos importes corresponden a los datos cargados.").font(.caption).foregroundStyle(Color.marcelitoAmber) }
                    if report.unresolvedPairCount > 0 { Text("\(report.unresolvedPairCount) parejas de transferencias pendientes pueden cambiar estos totales.").font(.caption).foregroundStyle(Color.marcelitoAmber) }
                    if report.excludedStatementCount > 0 { Text("\(report.excludedStatementCount) estados del mes están fuera de los totales por revisión.").font(.caption).foregroundStyle(Color.marcelitoAmber) }
                }
                Section("De dónde sale cada cifra") {
                    ForEach(MonthlyAuditBucket.allCases) { bucket in
                        NavigationLink {
                            MonthlyAuditMovementsView(month: month, bucket: bucket)
                        } label: {
                            LabeledContent(bucket.rawValue, value: report.total(bucket).formatted(.currency(code: "MXN")))
                        }
                    }
                    LabeledContent("Ingresos − gasto neto", value: report.surplus.formatted(.currency(code: "MXN")))
                }
                Section("Cómo se financió el gasto") {
                    if let bridge = report.bridge {
                        LabeledContent("Cambio de efectivo", value: bridge.cashChange.formatted(.currency(code: "MXN")))
                        LabeledContent("Cambio de deuda", value: bridge.debtChange.formatted(.currency(code: "MXN")))
                        LabeledContent("Cambio de posición", value: bridge.positionChange.formatted(.currency(code: "MXN")))
                        LabeledContent("Diferencia por explicar", value: bridge.difference.formatted(.currency(code: "MXN")))
                        Text(bridge.reconciles ? "Los ingresos y gastos cuadran con el cambio de efectivo menos deuda." : "Las cifras no cierran todavía. Revisa transferencias, créditos contables y cobertura antes de interpretar el resultado.")
                            .font(.caption).foregroundStyle(.secondary)
                        if bridge.reconciles {
                            LabeledContent("Efectivo utilizado", value: max(0, -bridge.cashChange).formatted(.currency(code: "MXN")))
                            LabeledContent("Aumento de deuda", value: max(0, bridge.debtChange).formatted(.currency(code: "MXN")))
                        }
                    } else {
                        Text("Faltan saldos oficiales de todas las cuentas al inicio y al final del mismo mes, o quedan transferencias por revisar. Los cortes de fechas distintas no permiten comprobar esta comparación.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Tu presupuesto y ahorro") {
                    SharedMonthlyPlanEditor(month: month)
                    let snapshot = planning.snapshot(store, month: month)
                    LabeledContent("Disponible del mismo plan", value: snapshot.remaining.map(planningMoney) ?? "Completa ingreso y compromisos")
                    Text("Comparte el plan de Inicio y Presupuesto. Incluye todos los gastos; MSI y préstamos se descuentan una sola vez.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Resumen mensual")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { copySummary(report) } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("Copiar resumen del mes")
                }
            }
            .alert("Resumen copiado", isPresented: $copiedSummary) {
                Button("Aceptar", role: .cancel) { }
            } message: { Text("Puedes pegar aquí el desglose del mes. No incluye PDFs ni números completos de cuenta.") }
            .scrollDismissesKeyboard(.interactively)

            .foregroundStyle(Color.marcelitoNavy)
            .scrollContentBackground(.hidden)
            .background(MarcelitoAmbientBackground())
        }
    }
}

struct MonthlyAuditMovementsView: View {
    @Environment(FinanceStore.self) private var store
    let month: Date
    let bucket: MonthlyAuditBucket
    private var rows: [Movement] { store.monthlyFinancialAudit(for: month).rows[bucket, default: []] }
    var body: some View {
        List {
            if rows.isEmpty { ContentUnavailableView("Sin movimientos", systemImage: "doc.text.magnifyingglass") }
            ForEach(rows.sorted { $0.date > $1.date }) { FinancialReviewRow(movement: $0) }
        }
        .navigationTitle(bucket.rawValue)
        .foregroundStyle(Color.marcelitoNavy)
    }
}

/// Inicio entry point for transfers whose destination the statement omits.
struct OwnershipReviewBanner: View {
    let store: FinanceStore
    @State private var showReview = false
    var body: some View {
        let pending = store.pendingOwnershipReviews
        if !pending.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right.circle").foregroundStyle(Color.marcelitoAmber)
                Text("\(pending.count) transferencias sin destinatario · ¿fueron a cuentas tuyas?")
                    .font(.caption)
                Spacer(minLength: 4)
                Button("Responder") { showReview = true }.font(.caption.weight(.semibold))
            }
            .padding(10)
            .foregroundStyle(Color.marcelitoNavy)
            .sheet(isPresented: $showReview) { TransferReviewView() }
        }
    }
}

/// "Ya cortó tu Amex · sube el PDF": shown in Inicio for every account whose
/// next statement should already be published, with or without notifications.
struct NewStatementBanner: View {
    let store: FinanceStore
    let upload: () -> Void
    var body: some View {
        let waiting = store.accountsAwaitingNewStatement
        if !waiting.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "doc.badge.arrow.up").foregroundStyle(Color.marcelitoAmber)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(waiting.enumerated()), id: \.offset) { _, item in
                        let label = item.accountKey.flatMap { $0.split(separator: ":").last.map { " ••" + $0 } } ?? ""
                        Text("Ya cortó tu \(item.source)\(label) · \(planningDayLabel(item.cutoff))")
                    }
                    Text("Sube el PDF para completar tus gastos.").foregroundStyle(.secondary)
                }
                .font(.caption)
                Spacer(minLength: 4)
                Button("Subir", action: upload).font(.caption.weight(.semibold))
            }
            .padding(10)
            .foregroundStyle(Color.marcelitoNavy)
        }
    }
}
