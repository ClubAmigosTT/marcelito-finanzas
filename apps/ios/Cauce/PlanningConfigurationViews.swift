import SwiftUI

struct IncomeDepositEvidenceView: View {
    let rows: [Movement]
    var body: some View {
        List(rows.sorted { $0.date > $1.date }) { row in
            NavigationLink { MovementDetailView(movement: row) } label: { IncomeDepositRow(movement: row) }
        }.navigationTitle("Depósitos de la sugerencia")
    }
}

private struct IncomeDepositRow: View {
    let movement: Movement
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(movement.summaryDisplayTitle).lineLimit(2)
                Spacer()
                Text(planningMoney(movement.amount)).monospacedDigit()
            }
            Text(movement.account + " · " + planningDayLabel(movement.date)).font(.caption).foregroundStyle(.secondary)
            if let text = movement.rawDescription, text != movement.title {
                Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }.padding(.vertical, 3)
    }
}

struct IncomeDepositPicker: View {
    @Environment(FinanceStore.self) private var store
    @Environment(FinancialPlanningStore.self) private var planning
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var account = "Todas"
    let choose: (Movement) -> Void
    var body: some View {
        let all = planning.receivedIncomeOptions(store)
        let rows = all.filter { row in
            (account == "Todas" || row.account == account) && (search.isEmpty || [row.title, row.rawDescription ?? "", row.account, row.transferRecipient ?? ""].joined(separator: " ").localizedStandardContains(search))
        }
        NavigationStack {
            List {
                Section {
                    Picker("Cuenta", selection: $account) {
                        Text("Todas").tag("Todas")
                        ForEach(Array(Set(all.map(\.account))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                } footer: { Text("Elige un depósito y confirma su importe y frecuencia. Se excluyen transferencias propias, devoluciones y pagos de tarjetas.") }
                if rows.isEmpty {
                    Text(all.isEmpty ? "Aún no hay depósitos de ingreso cargados. Agrega la fuente manualmente o sube un estado de débito." : "No hay depósitos que coincidan con la búsqueda.").foregroundStyle(.secondary)
                }
                ForEach(rows) { row in Button { choose(row) } label: { IncomeDepositRow(movement: row) }.buttonStyle(.plain) }
            }.navigationTitle("Elegir depósito").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "Banco, nombre o descripción")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
    }
}

// These tabs live inside Presupuesto so all five primary destinations stay visible.
enum BudgetWorkspaceSection: String, CaseIterable, Identifiable {
    case plan = "Plan", income = "Ingresos", fixed = "Gastos fijos"
    var id: String { rawValue }
    var title: String { self == .plan ? "Presupuesto" : rawValue }
}

struct RecurringChargesView: View {
    @Environment(FinancialPlanningStore.self) private var planning
    @Environment(FinanceStore.self) private var store
    var month: Date = .now
    @State private var editing: PlanningFixedExpense?
    @State private var deleting: PlanningFixedExpense?
    @State private var showAll = false
    @State private var error: String?
    var body: some View {
        let saved = planning.fixedExpenses.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let candidates = planning.recurringExpenseSuggestions(store)
        let total = saved.filter { $0.includes(month) }.reduce(Decimal(0)) { $0 + $1.monthlyAmount }
        List {
            Section {
                LabeledContent("Fijos configurados", value: planningMoney(total)).font(.headline)
                Text(FinancePeriod.month(month).label).font(.caption).foregroundStyle(.secondary)
                Button { editing = PlanningFixedExpense(name: "", amount: 0, category: "Otros / Por revisar", startMonth: FinancePeriod.month(month).start) } label: {
                    Label("Agregar gasto fijo", systemImage: "plus.circle")
                }.accessibilityIdentifier("fixedExpenses.add")
            } footer: { Text("Se incluyen en tu presupuesto desde el mes que elijas. Los ajustes que hayas guardado por categoría para un mes tienen prioridad.") }
            Section("Tus gastos fijos") {
                if saved.isEmpty { Text("Aún no tienes gastos fijos configurados. Agrega uno o confirma una sugerencia.").foregroundStyle(.secondary) }
                ForEach(saved) { item in
                    HStack {
                        Button { editing = item } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).fontWeight(.semibold).foregroundStyle(Color.marcelitoNavy)
                                Text("\(planningMoney(item.amount)) · \(item.cadence.rawValue) · \(item.category)").font(.caption).foregroundStyle(.secondary)
                                Text("\(planningMoney(item.monthlyAmount)) al mes · \(item.includes(month) ? "Incluido" : "Fuera de vigencia")").font(.caption).foregroundStyle(Color.marcelitoNavyMid)
                                if !item.account.isEmpty { Text(item.account).font(.caption2).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Button { deleting = item } label: { Image(systemName: "trash").foregroundStyle(.secondary) }.buttonStyle(.borderless).accessibilityLabel("Quitar \(item.name)")
                    }
                }
            }
            Section {
                if candidates.isEmpty {
                    Text("Aún no encontramos nuevos cargos con fechas e importes periódicos. Puedes configurar renta, internet, entrenamiento u otro gasto manualmente.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(showAll ? candidates : Array(candidates.prefix(10))) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name).font(.headline)
                        Text("Patrón periódico · confirma si es un gasto fijo").font(.caption).foregroundStyle(Color.marcelitoNavyMid)
                        Text("\(planningMoney(item.amount)) · \(item.cadence.rawValue) · \(item.account)").font(.subheadline)
                        Text("\(item.count) cargos en \(item.observedMonths) meses · último: \(planningDayLabel(item.lastDate))").font(.caption).foregroundStyle(.secondary)
                        if let first = item.movements.first, let last = item.movements.last {
                            NavigationLink("Ver los \(item.count) cargos") {
                                PersonalMovementList(title: item.name, rows: item.movements, period: FinancePeriod(start: Calendar.current.startOfDay(for: first.date), end: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: last.date))!))
                            }.font(.caption)
                        }
                        Button("Configurar y guardar") {
                            editing = PlanningFixedExpense(name: item.name, amount: item.amount, cadence: item.cadence, category: item.category, matchKey: item.id, account: item.account, startMonth: FinancePeriod.month(month).start)
                        }
                        Button("No es un gasto fijo") {
                            if !planning.setDismissedRecurringExpenses((planning.state.dismissedRecurringExpenseKeys ?? []) + [item.id]) { error = "No se pudo guardar tu elección. Intenta de nuevo." }
                        }.font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                if candidates.count > 10 { Button(showAll ? "Ver menos" : "Ver las \(candidates.count) sugerencias") { showAll.toggle() } }
            } header: { Text("Cargos periódicos detectados") } footer: {
                Text("Las compras frecuentes sin un patrón no se proponen como fijas. Revisa los cargos y confirma solo los compromisos que quieras reservar en tu presupuesto.")
            }
            Section {
                if !(planning.state.dismissedRecurringExpenseKeys ?? []).isEmpty {
                    Button("Restablecer sugerencias descartadas") {
                        if !planning.setDismissedRecurringExpenses([]) { error = "No se pudieron restablecer las sugerencias." }
                    }
                }
                CalculationHelp(explanation: "Buscamos al menos tres cargos mensuales o cuatro semanales o quincenales, en dos meses distintos. Al menos 75% debe tener importes similares e intervalos compatibles. Se muestran los cargos que respaldan cada propuesta. Excluye transferencias propias, pagos de tarjeta, MSI y gastos extraordinarios. Una compra frecuente sin periodicidad no es un gasto fijo. Las propuestas se guardan únicamente cuando las confirmas.")
            }
            if let error { Text(error).foregroundStyle(Color.marcelitoDanger) }
        }.navigationTitle("Gastos fijos").scrollContentBackground(.hidden).background(MarcelitoAmbientBackground())
            .sheet(item: $editing) { item in PlanningFixedExpenseEditor(expense: item) }
            .confirmationDialog("¿Quitar este gasto del presupuesto?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { item in
                Button("Quitar gasto fijo", role: .destructive) {
                    if !planning.setFixedExpenses(planning.fixedExpenses.filter { $0.id != item.id }) { error = "No se pudo guardar. Tu configuración se conserva." }
                    deleting = nil
                }
                Button("Cancelar", role: .cancel) { deleting = nil }
            } message: { _ in Text("Tus movimientos y categorías se conservan. También puedes editar su último mes para conservar los presupuestos anteriores.") }
    }
}

private struct FixedExpenseMerchantOption: Identifiable {
    let id: String, name: String, account: String, category: String
}
private struct FixedExpenseMerchantPicker: View {
    @Environment(\.dismiss) private var dismiss
    let merchants: [FixedExpenseMerchantOption]
    let choose: (String) -> Void
    @State private var search = ""
    @State private var account = "Todas"
    var body: some View {
        NavigationStack {
            List {
                Button("Sin comercio asociado") { choose("") }
                Picker("Cuenta", selection: $account) {
                    Text("Todas").tag("Todas")
                    ForEach(Array(Set(merchants.map(\.account))).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) }
                }
                let rows = merchants.filter { item in
                    (account == "Todas" || item.account == account) && (search.isEmpty || (item.name + " " + item.account + " " + item.category).localizedStandardContains(search))
                }
                if rows.isEmpty { Text("Sin comercios coincidentes. Puedes guardar el gasto sin asociarlo a un comercio.").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(rows) { item in
                    Button { choose(item.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                            Text(item.account + " · " + item.category).font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }.navigationTitle("Buscar comercio").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "Nombre, categoría o banco")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
    }
}
struct PlanningFixedExpenseEditor: View {
    @Environment(FinancialPlanningStore.self) private var planning
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let expense: PlanningFixedExpense
    @State private var name = ""
    @State private var amount = ""
    @State private var cadence: FixedExpenseCadence = .monthly
    @State private var category = "Otros / Por revisar"
    @State private var matchKey = ""
    @State private var startMonth = Date.now
    @State private var endMonth = Date.now
    @State private var hasEndMonth = false
    @State private var merchants: [FixedExpenseMerchantOption] = []
    @State private var choosingEnd = false
    @State private var showMonthPicker = false
    @State private var showMerchantPicker = false
    @State private var error: String?
    private var categories: [String] { Array(Set(personalExpenseCategories + [expense.category])).filter { !["Ingresos", "Transferencia", "Transferencias", "ITAM"].contains($0) }.sorted() }
    var body: some View {
        NavigationStack {
            Form {
                Section("Gasto fijo") {
                    TextField("Nombre · renta, internet…", text: $name)
                    TextField("Importe del pago · MXN", text: $amount).keyboardType(.decimalPad)
                    Picker("Frecuencia", selection: $cadence) { ForEach(FixedExpenseCadence.allCases) { Text($0.rawValue).tag($0) } }
                    Picker("Categoría de presupuesto", selection: $category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }
                    if let amount = parsePlanningAmount(amount), amount > 0 {
                        let item = PlanningFixedExpense(name: name, amount: amount, cadence: cadence, category: category, startMonth: startMonth)
                        LabeledContent("Reserva mensual", value: planningMoney(item.monthlyAmount))
                    }
                }
                Section {
                    Button { showMerchantPicker = true } label: {
                        LabeledContent("Comercio asociado", value: merchants.first(where: { $0.id == matchKey }).map { $0.name + " · " + $0.account } ?? "Buscar o elegir")
                    }
                } footer: {
                    Text(matchKey.isEmpty ? "Asocia un comercio si ya existe en tus movimientos para separarlo del gasto variable." : "Sus cargos ordinarios de esta cuenta se tratarán como fijos durante la vigencia. Se respetan las excepciones que hayas marcado manualmente y tus categorías no cambian.")
                }
                Section("Vigencia") {
                    Button { choosingEnd = false; showMonthPicker = true } label: { LabeledContent("Desde", value: FinancePeriod.month(startMonth).label) }
                    Toggle("Definir último mes", isOn: $hasEndMonth)
                    if hasEndMonth {
                        Button { choosingEnd = true; showMonthPicker = true } label: { LabeledContent("Hasta", value: FinancePeriod.month(endMonth).label) }
                    }
                }
                Section {
                    Button("Guardar para presupuestos", action: save).buttonStyle(.marcelitoPrimary).accessibilityIdentifier("fixedExpenses.save")
                } footer: {
                    Text("Se guarda una previsión, sin crear movimientos. Semanal y anual se convierten en una reserva mensual promedio. No incluyas aquí pagos de tarjetas ni mensualidades MSI ya registradas.")
                }
                if let error { Text(error).foregroundStyle(Color.marcelitoDanger) }
            }.navigationTitle("Configurar gasto fijo").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancelar") { dismiss() } } }
                .sheet(isPresented: $showMonthPicker) { PeriodSelectionSheet(mode: .month, date: choosingEnd ? endMonth : startMonth) { date in
                    if choosingEnd { endMonth = FinancePeriod.month(date).start } else { startMonth = FinancePeriod.month(date).start; if endMonth < startMonth { endMonth = startMonth } }
                } }
                .sheet(isPresented: $showMerchantPicker) { FixedExpenseMerchantPicker(merchants: merchants) { key in matchKey = key; showMerchantPicker = false } }
        }.onAppear(perform: load)
            .onChange(of: matchKey) { _, value in
                guard let item = merchants.first(where: { $0.id == value }) else { return }
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = item.name }
                if category == "Otros / Por revisar" { category = item.category }
            }
    }
    private func load() {
        name = expense.name; amount = expense.amount > 0 ? NSDecimalNumber(decimal: expense.amount).stringValue : ""
        cadence = expense.cadence; category = expense.category == "ITAM" ? "Educación" : expense.category; matchKey = expense.matchKey
        startMonth = expense.startMonth; endMonth = expense.endMonth ?? expense.startMonth; hasEndMonth = expense.endMonth != nil
        var indexed: [String: FixedExpenseMerchantOption] = [:]
        for row in store.netExpenseMovements where row.expenseContribution > 0 && planning.canLinkFixedExpense(row) && !planning.isInstallmentRow(row, store: store) {
            let key = planning.fixedExpenseKey(row)
            if indexed[key] == nil { indexed[key] = FixedExpenseMerchantOption(id: key, name: planning.merchantLabel(row), account: row.account, category: planning.category(row)) }
        }
        if !expense.matchKey.isEmpty, indexed[expense.matchKey] == nil { indexed[expense.matchKey] = FixedExpenseMerchantOption(id: expense.matchKey, name: expense.name, account: expense.account, category: expense.category) }
        merchants = indexed.values.sorted { ($0.name + $0.account).localizedStandardCompare($1.name + $1.account) == .orderedAscending }
    }
    private func save() {
        guard let amount = parsePlanningAmount(amount), amount > 0, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Escribe un nombre y un importe mayor a cero."; return }
        if hasEndMonth && FinancePeriod.month(endMonth).start < FinancePeriod.month(startMonth).start { error = "El último mes debe ser igual o posterior al primero."; return }
        if !matchKey.isEmpty && planning.fixedExpenses.contains(where: { $0.id != expense.id && $0.matchKey == matchKey }) { error = "Este comercio ya está guardado. Edita el gasto fijo existente."; return }
        var updated = expense
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines); updated.amount = amount; updated.cadence = cadence; updated.category = category
        updated.matchKey = matchKey; updated.account = merchants.first(where: { $0.id == matchKey })?.account ?? ""
        updated.startMonth = FinancePeriod.month(startMonth).start; updated.endMonth = hasEndMonth ? FinancePeriod.month(endMonth).start : nil
        var items = planning.fixedExpenses
        if let index = items.firstIndex(where: { $0.id == updated.id }) { items[index] = updated } else { items.append(updated) }
        if planning.setFixedExpenses(items) { dismiss() } else { error = "No se pudo guardar. Tu configuración anterior se conserva." }
    }
}
