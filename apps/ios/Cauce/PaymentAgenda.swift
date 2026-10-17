import Foundation
import SwiftUI

struct CardCyclePayment {
    let target: Decimal
    let paid: Decimal
    let rows: [Movement]
    var remaining: Decimal { max(0, target - paid) }
    var label: String { remaining == 0 ? "Pago cubierto con movimientos registrados" : paid > 0 ? "Abono parcial confirmado" : "Sin pago posterior confirmado" }
}
extension FinanceStore {
    func cardCycleKey(_ statement: StatementRecord) -> String {
        (statement.accountKey ?? statement.source) + "|" + (statementCutoffDate(for: statement.id).map(LoanMath.dayKey) ?? statement.period)
    }
    func cyclePayment(_ statement: StatementRecord, planning: FinancialPlanningStore) -> CardCyclePayment? {
        guard let target = statement.summary?.paymentForNoInterest, target >= 0,
              let cutoff = statementCutoffDate(for: statement.id) else { return nil }
        let cardIDs = Set(statements.filter { ($0.accountKey ?? $0.source) == (statement.accountKey ?? statement.source) && $0.kind == .card }.map(\.id))
        let links = planning.state.cardPaymentLinks ?? []
        let candidates = canonicalMovements.filter { $0.date > cutoff && $0.date <= .now }
        var rows: [Movement] = []
        for row in candidates {
            let direct = row.amount > 0 && row.kind == .cardPayment && row.statementId.map { cardIDs.contains($0) } == true
            let linked = row.amount < 0 && row.kind == .cardPayment && links.contains { ($0.statementID == statement.id || $0.cycleKey == cardCycleKey(statement)) && ($0.movementID == row.id || $0.identity == FinanceStore.loanBankIdentity(row)) }
            if direct || linked { rows.append(row) }
        }
        let ids = Set(rows.map(\.id))
        rows.removeAll { row in row.amount < 0 && row.matchedMovementId.map(ids.contains) == true }
        return CardCyclePayment(target: target, paid: rows.reduce(0) { $0 + abs($1.amount) }, rows: rows)
    }
}
struct PaymentAgendaView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(FinancialPlanningStore.self) private var planning
    @State private var linking: StatementRecord?
    private var cards: [StatementRecord] {
        Dictionary(grouping: store.statements.filter { $0.kind == .card }) { $0.accountKey ?? $0.source }.values.compactMap { $0.max { (store.statementCutoffDate(for: $0.id) ?? .distantPast) < (store.statementCutoffDate(for: $1.id) ?? .distantPast) } }.sorted { ($0.summary?.paymentDueDate ?? .distantFuture) < ($1.summary?.paymentDueDate ?? .distantFuture) }
    }
    var body: some View {
        List {
            Section("Tarjetas · último ciclo registrado") {
                ForEach(cards) { statement in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(statement.source).font(.headline)
                        if let due = planning.state.cardTerms[statement.accountKey ?? statement.source].flatMap({ $0.statementID == statement.id ? $0.dueDate : nil }) ?? statement.summary?.paymentDueDate { Text("Fecha límite: " + planningDayLabel(due)).font(.subheadline) }
                        else { Text("Falta la fecha límite confirmada").font(.caption) }
                        if let payment = store.cyclePayment(statement, planning: planning) {
                            LabeledContent("Pago del estado", value: planningMoney(payment.target))
                            LabeledContent("Abonos registrados", value: planningMoney(payment.paid))
                            LabeledContent("Restante registrado", value: planningMoney(payment.remaining))
                            Text(payment.label).font(.caption)
                        } else { Text("Falta el pago para no generar intereses o el corte confirmado.").font(.caption) }
                        Text("Los pagos posteriores aún no cargados pueden cambiar el restante. Confirma el saldo en tu banco.").font(.caption).foregroundStyle(.secondary)
                        Button("Vincular un pago bancario") { linking = statement }
                    }
                }
                if cards.isEmpty { Text("Sube un estado de tarjeta para ver su vencimiento.") }
            }
            Section("Préstamos · próximos 90 días y cuotas vencidas") {
                ForEach(store.loanLedger.state.accounts) { account in
                    if let statement = account.latest {
                        Text(account.name + " · estado al " + planningDayLabel(statement.asOf)).font(.headline)
                        let horizon = Calendar.current.date(byAdding: .day, value: 90, to: .now)!
                        ForEach(statement.installments.filter { $0.dueDate <= horizon && statement.remaining($0) > Decimal(string: "0.05")! }, id: \.number) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Cuota \(item.number) · " + planningDayLabel(item.dueDate))
                                Text(statement.status(item)).font(.caption)
                                if let quote = store.loanLedger.quote() { Text("~" + planningMoney(statement.remaining(item) * quote.value)).font(.subheadline) }
                                else { Text("Falta valor UDI · \(statement.remaining(item)) UDIS").font(.caption) }
                            }
                        }
                    }
                }
                NavigationLink("Ver préstamos y abonos oficiales") { LoanAccountsView() }
            }
            PlanningReminderToggle()
        }.navigationTitle("Agenda de pagos").scrollContentBackground(.hidden).background(MarcelitoAmbientBackground()).foregroundStyle(Color.marcelitoNavy)
            .sheet(item: $linking) { CardPaymentLinkPicker(statement: $0) }
    }
}
struct CardPaymentLinkPicker: View {
    @Environment(FinanceStore.self) private var store
    @Environment(FinancialPlanningStore.self) private var planning
    @Environment(\.dismiss) private var dismiss
    let statement: StatementRecord
    @State private var message: String?
    var body: some View {
        NavigationStack {
            List {
                Text("Elige un pago de tarjeta que corresponda a este ciclo. No cambia el gasto ni reduce dos veces la deuda.").font(.caption)
                let cutoff = store.statementCutoffDate(for: statement.id) ?? .distantFuture
                ForEach(store.canonicalMovements.filter { $0.kind == .cardPayment && $0.amount < 0 && $0.date > cutoff && $0.date <= .now }) { row in
                    Button {
                        var links = planning.state.cardPaymentLinks ?? []
                        guard !links.contains(where: { $0.movementID == row.id || $0.identity == FinanceStore.loanBankIdentity(row) }) else { message = "Ese pago ya está vinculado a un ciclo."; return }
                        links.append(CardPaymentLink(statementID: statement.id, movementID: row.id, identity: FinanceStore.loanBankIdentity(row), cycleKey: store.cardCycleKey(statement)))
                        let previous = planning.state; planning.state.cardPaymentLinks = links
                        if planning.save() { dismiss() } else { planning.state = previous; message = "No se pudo guardar. Se conservaron los vínculos anteriores." }
                    } label: { VStack(alignment: .leading) { Text(row.summaryDisplayTitle); Text(row.account + " · " + planningDayLabel(row.date) + " · " + planningMoney(abs(row.amount))).font(.caption) } }
                }
                Section("Vínculos de este ciclo") {
                    ForEach((planning.state.cardPaymentLinks ?? []).filter { $0.statementID == statement.id || $0.cycleKey == store.cardCycleKey(statement) }, id: \.movementID) { link in
                        if let row = store.movements.first(where: { $0.id == link.movementID || FinanceStore.loanBankIdentity($0) == link.identity }) {
                            Button("Quitar vínculo · " + planningMoney(abs(row.amount)), role: .destructive) { planning.state.cardPaymentLinks?.removeAll { $0.movementID == link.movementID }; _ = planning.save() }
                        }
                    }
                }
                if let message { Text(message).font(.caption) }
            }.navigationTitle(statement.source + " · pago").toolbar { Button("Cerrar") { dismiss() } }
        }
    }
}
