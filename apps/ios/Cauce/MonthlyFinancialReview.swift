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
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Confirmar excluye ambos lados de ingresos y gastos. Descartar sólo rechaza esta pareja; no cambia sus tipos ni categorías.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if store.pendingTransferReviewPairs.isEmpty {
                    ContentUnavailableView("Sin parejas pendientes", systemImage: "checkmark.circle",
                        description: Text("No hay coincidencias por revisar en las cuentas cargadas. Esto no garantiza que estén cargadas todas tus transferencias."))
                }
                ForEach(store.pendingTransferReviewPairs) { pair in
                    Section {
                        FinancialReviewRow(movement: pair.outgoing)
                        FinancialReviewRow(movement: pair.incoming)
                        HStack {
                            Button("Confirmar traspaso propio") { confirmation = pair }
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
            .navigationTitle("Revisar transferencias")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
            .alert("¿Son el mismo traspaso entre tus cuentas?", isPresented: Binding(
                get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
            )) {
                Button("Confirmar ambos movimientos") {
                    if let pair = confirmation { _ = store.confirmOwnTransfer(pair.outgoing, counterpart: pair.incoming) }
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
    @State private var month = Calendar(identifier: .gregorian).dateInterval(of: .month, for: .now)!.start
    @State private var budgetText = ""
    @State private var targetText = ""
    @State private var planMessage: String?
    @State private var copiedSummary = false
    private var audit: MonthlyFinancialAudit { store.monthlyFinancialAudit(for: month) }
    private var months: [Date] {
        let calendar = Calendar(identifier: .gregorian)
        return Array(Set(store.movements.compactMap { calendar.dateInterval(of: .month, for: $0.date)?.start } + [month])).sorted(by: >)
    }
    private func monthLabel(_ value: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "es_MX")
        formatter.dateFormat = "MMMM yyyy"; return formatter.string(from: value).capitalized
    }
    private var planKey: String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: month)
        return "marcelito.monthlyPlan.\(parts.year!).\(parts.month!)"
    }
    private func amount(_ value: String) -> Decimal? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.range(of: #"^\d+(?:[.,]\d{1,2})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: trimmed.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX"))
    }
    private func loadPlan() {
        budgetText = UserDefaults.standard.string(forKey: planKey + ".budget") ?? ""
        targetText = UserDefaults.standard.string(forKey: planKey + ".target") ?? ""
        planMessage = nil
    }
    private func savePlan() {
        guard (budgetText.isEmpty || amount(budgetText) != nil), (targetText.isEmpty || amount(targetText) != nil) else {
            planMessage = "Escribe importes positivos sin separadores de miles."; return
        }
        UserDefaults.standard.set(budgetText, forKey: planKey + ".budget")
        UserDefaults.standard.set(targetText, forKey: planKey + ".target")
        planMessage = "Plan guardado para este mes."
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
                    HStack {
                        Text("Presupuesto de gasto")
                        TextField("Importe MXN", text: $budgetText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Meta de ahorro")
                        TextField("Importe MXN", text: $targetText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    Button("Guardar plan del mes") { savePlan() }
                    if let planMessage { Text(planMessage).font(.caption).foregroundStyle(.secondary) }
                    if report.canUseForBudget {
                        if let budget = amount(budgetText) {
                            LabeledContent("Presupuesto restante", value: (budget - report.netSpending).formatted(.currency(code: "MXN")))
                            if report.netSpending > budget { Text("Superaste el presupuesto que definiste.").font(.caption).foregroundStyle(Color.marcelitoAmber) }
                        }
                        if let target = amount(targetText) {
                            LabeledContent("Excedente de ingresos", value: report.surplus.formatted(.currency(code: "MXN")))
                            LabeledContent("Falta para tu meta", value: max(0, target - report.surplus).formatted(.currency(code: "MXN")))
                            Text("El excedente no acredita una transferencia a una cuenta de ahorro.").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Puedes guardar tu plan. El avance se mostrará cuando haya cobertura suficiente y se resuelvan las posibles transferencias.").font(.caption).foregroundStyle(.secondary)
                    }
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
            .onAppear { loadPlan() }.onChange(of: month) { _, _ in loadPlan() }
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
