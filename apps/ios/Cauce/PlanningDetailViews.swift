import SwiftUI

struct SharedMonthlyPlanEditor: View {
    @Environment(FinancialPlanningStore.self) private var planning
    let month: Date
    @State private var limit = ""
    @State private var savings = ""
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Plan de " + FinancePeriod.month(month).label).font(.headline)
            if planning.plan(for: month).legacySpendingLimit != nil || planning.plan(for: month).legacySavingsTarget != nil {
                Text("Se conservó tu plan actual. También encontramos importes de un plan anterior.").font(.caption)
                Button("Cargar importes anteriores para revisarlos") {
                    let old = planning.plan(for: month)
                    if let value = old.legacySpendingLimit { limit = NSDecimalNumber(decimal: value).stringValue }
                    if let value = old.legacySavingsTarget { savings = NSDecimalNumber(decimal: value).stringValue }
                }.font(.caption)
            }
            TextField("Tope total de gastos · opcional", text: $limit).keyboardType(.decimalPad)
            TextField("Meta de ahorro MXN", text: $savings).keyboardType(.decimalPad)
            Text("El tope incluye fijos, variables, MSI y abonos previstos. Se usa el menor entre el tope y el ingreso disponible después de tu meta de ahorro.").font(.caption).foregroundStyle(.secondary)
            Button("Guardar plan del mes") {
                guard (limit.isEmpty || parsePlanningAmount(limit) != nil), let target = parsePlanningAmount(savings) else { message = "Escribe importes válidos."; return }
                var plan = planning.plan(for: month)
                plan.spendingLimit = limit.isEmpty ? nil : parsePlanningAmount(limit)
                plan.savingsTarget = target; plan.legacySpendingLimit = nil; plan.legacySavingsTarget = nil; planning.setPlan(plan, for: month)
                message = planning.loadError == nil ? "Plan compartido con Inicio y Presupuesto." : planning.loadError
            }
            if let message { Text(message).font(.caption) }
        }.disabled(planning.plan(for: month).closed)
            .onAppear(perform: load).onChange(of: month) { _, _ in load() }
            .onChange(of: planning.revision) { _, _ in load() }
    }
    private func load() {
        let plan = planning.plan(for: month)
        limit = plan.spendingLimit.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        savings = NSDecimalNumber(decimal: plan.savingsTarget).stringValue
    }
}
struct PlanningAccountCoverage: View {
    @Environment(FinanceStore.self) private var store
    let period: FinancePeriod
    var body: some View {
        DisclosureGroup("Cobertura por cuenta · " + period.label) {
            let groups = Dictionary(grouping: store.statements) { $0.accountKey ?? $0.source }
            ForEach(groups.keys.sorted(), id: \.self) { key in
                if let record = groups[key]?.max(by: { (store.statementCutoffDate(for: $0.id) ?? .distantPast) < (store.statementCutoffDate(for: $1.id) ?? .distantPast) }) {
                    let cutoff = store.statementCutoffDate(for: record.id)
                    let covered = store.spendingCoveredDays(account: key)
                    let through = min(period.end.addingTimeInterval(-1), Date.now)
                    let days = max(0, Calendar.current.dateComponents([.day], from: period.start, to: Calendar.current.startOfDay(for: through)).day ?? 0) + 1
                    let loaded = covered.filter { period.contains($0) && $0 <= through }.count
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.source + (record.accountKey.map { " · " + String($0.suffix(4)) } ?? "")).font(.subheadline.weight(.medium))
                        Text(cutoff.map { "Estado hasta " + planningDayLabel($0) } ?? "Sin corte confirmado").font(.caption)
                        Text(period.start > .now ? "Periodo futuro · plan" : loaded >= days ? "Periodo cubierto" : "Faltan estados para cubrir este periodo · \(loaded)/\(days) días").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                }
            }
            if groups.isEmpty { Text("Sube un estado para conocer la cobertura.").font(.caption) }
        }.font(.caption).foregroundStyle(Color.marcelitoNavy)
    }
}

struct SavingsGoalsView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(FinancialPlanningStore.self) private var planning
    @State private var editing: SavingsGoal?
    @State private var contributing: SavingsGoal?
    var body: some View {
        List {
            ForEach(planning.activeGoals) { goal in
                VStack(alignment: .leading, spacing: 8) {
                    Text(goal.name).font(.headline)
                    Text("\(planningMoney(goal.saved)) de \(planningMoney(goal.target))")
                    ProgressView(value: min(1, NSDecimalNumber(decimal: goal.saved / goal.target).doubleValue))
                    let totalContributions = planning.activeGoals.reduce(Decimal(0)) { $0 + $1.monthlyContribution }
                    let weight = totalContributions > 0 ? goal.monthlyContribution / totalContributions : 1 / Decimal(max(1, planning.activeGoals.count))
                    let observed = planning.observedOrdinarySavings(store, before: .now).map { $0 * weight }
                    if let rate = observed, rate > 0, let date = Calendar.current.date(byAdding: .month, value: Int(ceil(NSDecimalNumber(decimal: max(0, goal.target - goal.saved) / rate).doubleValue)), to: .now) {
                        Text("~\(FinancePeriod.month(date).label) al ritmo observado · \(planningMoney(rate))/mes para esta meta").font(.caption)
                    } else if observed != nil { Text("El ritmo registrado aún no genera ahorro para esta meta.").font(.caption) }
                    else if let months = goal.estimatedMonths, let date = Calendar.current.date(byAdding: .month, value: months, to: .now) { Text("~\(FinancePeriod.month(date).label) si apartas \(planningMoney(goal.monthlyContribution))/mes").font(.caption) }
                    CalculationHelp(explanation: "Fecha estimada con el ahorro observado en meses completos, repartido entre las aportaciones previstas de tus metas. Si falta historia se usa la aportación mensual configurada. No acredita dinero bancario ni supone rendimientos.")
                    HStack {
                        Button("Editar") { editing = goal }
                        Button("Aportación o retiro") { contributing = goal }
                    }.buttonStyle(.borderless)
                    DisclosureGroup("Historial") {
                        ForEach((goal.entries ?? []).sorted { $0.date > $1.date }) { entry in
                            VStack(alignment: .leading) { Text(entry.note); Text(planningDayLabel(entry.date) + " · " + planningMoney(entry.amount)).font(.caption).foregroundStyle(.secondary) }
                        }
                        if (goal.entries ?? []).isEmpty { Text("Saldo inicial: " + planningMoney(goal.saved)).font(.caption) }
                    }.font(.caption)
                }
            }
            Button("Agregar meta") { editing = SavingsGoal(name: "", target: 0, saved: 0, monthlyContribution: 0) }
            if planning.state.goals.contains(where: { $0.archived == true }) {
                Section("Archivadas") {
                    ForEach(planning.state.goals.filter { $0.archived == true }) { goal in
                        Button("Restaurar " + goal.name) { var updated = goal; updated.archived = false; _ = planning.saveGoal(updated) }
                    }
                }
            }
            Text("Los saldos son registros de tu ahorro; no crean transferencias bancarias. Cada cierre permite elegir la meta de destino.").font(.caption).foregroundStyle(.secondary)
        }.navigationTitle("Metas de ahorro").scrollContentBackground(.hidden).background(MarcelitoAmbientBackground()).foregroundStyle(Color.marcelitoNavy)
            .sheet(item: $editing) { SavingsGoalEditor(goal: $0) }
            .sheet(item: $contributing) { SavingsContributionEditor(goal: $0) }
    }
}
struct SavingsGoalEditor: View {
    @Environment(FinancialPlanningStore.self) private var planning
    @Environment(\.dismiss) private var dismiss
    let goal: SavingsGoal
    @State private var name = ""
    @State private var target = ""
    @State private var saved = ""
    @State private var monthly = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Nombre", text: $name)
                TextField("Objetivo MXN", text: $target).keyboardType(.decimalPad)
                TextField("Saldo registrado MXN", text: $saved).keyboardType(.decimalPad)
                TextField("Aportación mensual MXN", text: $monthly).keyboardType(.decimalPad)
                Button("Guardar meta") {
                    guard let target = parsePlanningAmount(target), let saved = parsePlanningAmount(saved), let monthly = parsePlanningAmount(monthly) else { error = "Completa los importes."; return }
                    var updated = goal; updated.name = name; updated.target = target; updated.saved = saved; updated.monthlyContribution = monthly
                    if planning.saveGoal(updated) { dismiss() } else { error = "Revisa el nombre y el objetivo. No se pudo guardar." }
                }
                if planning.state.goals.contains(where: { $0.id == goal.id }) {
                    Button("Archivar meta", role: .destructive) { var updated = goal; updated.archived = true; if planning.saveGoal(updated) { dismiss() } }
                    Text("Archivar conserva aportaciones y cierres anteriores.").font(.caption)
                }
                if let error { Text(error).foregroundStyle(Color.marcelitoDanger) }
            }.navigationTitle("Meta de ahorro").toolbar { Button("Cerrar") { dismiss() } }
        }.onAppear { name = goal.name; target = NSDecimalNumber(decimal: goal.target).stringValue; saved = NSDecimalNumber(decimal: goal.saved).stringValue; monthly = NSDecimalNumber(decimal: goal.monthlyContribution).stringValue }
    }
}
struct SavingsContributionEditor: View {
    @Environment(FinancialPlanningStore.self) private var planning
    @Environment(\.dismiss) private var dismiss
    let goal: SavingsGoal
    @State private var amount = ""
    @State private var note = ""
    @State private var withdrawal = false
    @State private var date = Date.now
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Text(goal.name).font(.headline)
                Toggle("Es un retiro", isOn: $withdrawal)
                TextField("Importe MXN", text: $amount).keyboardType(.decimalPad)
                DatePicker("Fecha", selection: $date, in: ...Date.now, displayedComponents: .date)
                TextField("Nota", text: $note)
                Button("Registrar") {
                    guard let value = parsePlanningAmount(amount), value > 0,
                          planning.contribute(to: goal.id, amount: withdrawal ? -value : value, date: date, note: note) else { error = "Revisa el importe; el saldo de la meta no puede ser negativo."; return }
                    dismiss()
                }
                if let error { Text(error).foregroundStyle(Color.marcelitoDanger) }
            }.navigationTitle("Movimiento de ahorro").toolbar { Button("Cerrar") { dismiss() } }
        }
    }
}
