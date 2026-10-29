import SwiftUI

/// "Planear mes": builds the month's budget from the history in four short
/// steps (what comes in, the typical month, what is expected this month and
/// the goal) and saves it as the month's category limits.
struct PlanMonthWizard: View {
    @Environment(FinanceStore.self) private var store
    @Environment(FinancialPlanningStore.self) private var planning
    @Environment(\.dismiss) private var dismiss
    let month: Date

    private enum Goal: String, CaseIterable, Identifiable {
        case typical = "Como un mes típico", tight = "Apretado", savings = "Meta de ahorro"
        var id: String { rawValue }
    }

    @State private var step = 0
    @State private var prepared = false
    @State private var amounts: [String: Decimal] = [:]
    @State private var included: Set<String> = []
    @State private var travelling = false
    @State private var tripAmount: Decimal = 0
    @State private var repeats: Set<String> = []
    @State private var plannedName = ""
    @State private var plannedAmount: Decimal = 0
    @State private var plannedCategory = "Compras personales"
    @State private var goal: Goal = .typical
    @State private var savingsGoal: Decimal = 0

    private var advice: MonthPlanAdvice { planning.monthPlanAdvice(store, month: month) }
    private var monthLabel: String { FinancePeriod.month(month).label }
    private var income: Decimal? { planning.monthlyIncome(for: month) }
    private var fixedTotal: Decimal { planning.fixedLimits(store, month: month).values.reduce(0, +) }
    private var msi: Decimal { planning.commitments(store, month: month) }
    private var loans: Decimal { planning.snapshot(store, month: month).loans ?? 0 }
    /// What income leaves for variable spending and savings.
    private var available: Decimal? { income.map { $0 - fixedTotal - msi - loans } }

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case 0: incomeStep
                case 1: typicalStep
                case 2: questionsStep
                default: goalStep
                }
            }
            .navigationTitle("Planear \(monthLabel.lowercased())")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        if step > 0 { Button("Atrás") { step -= 1 } }
                        Spacer()
                        Text("Paso \(step + 1) de 4").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if step < 3 { Button("Siguiente") { step += 1 }.bold() }
                        else { Button("Guardar plan") { save() }.bold() }
                    }
                }
            }
            .onAppear(perform: prepare)
        }
    }

    // MARK: Steps

    private var incomeStep: some View {
        Group {
            Section {
                row("Ingreso esperado", income.map(planningMoney) ?? "Sin configurar")
                row("Gastos fijos", "−" + planningMoney(fixedTotal))
                if msi > 0 { row("Mensualidades MSI", "−" + planningMoney(msi)) }
                if loans > 0 { row("Préstamos", "−" + planningMoney(loans)) }
                if let available { row("Te quedan para gastar y ahorrar", planningMoney(available), bold: true) }
            } header: { Text("1 · Lo que entra y lo comprometido") } footer: {
                Text(income == nil
                     ? "Configura tus ingresos en Presupuesto → Ingresos para saber cuánto te queda. Puedes seguir sin ellos."
                     : "El ingreso y los fijos salen de lo que ya configuraste; los cambias en sus pestañas.")
            }
        }
    }

    private var typicalStep: some View {
        Section {
            ForEach(amounts.keys.sorted { (amounts[$0] ?? 0) > (amounts[$1] ?? 0) }, id: \.self) { category in
                HStack {
                    Toggle(isOn: Binding(get: { included.contains(category) }, set: { on in if on { included.insert(category) } else { included.remove(category) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category)
                            if let typical = advice.typical[category] {
                                Text("Normalmente \(planningMoney(typical))").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    amountField(Binding(get: { amounts[category] ?? 0 }, set: { amounts[category] = $0 }))
                }
            }
        } header: { Text("2 · Tu mes típico") } footer: {
            Text(typicalFootnote)
        }
    }

    private var typicalFootnote: String {
        let months = advice.sampleMonths.sorted().map { FinancePeriod.month($0).label }.joined(separator: ", ")
        var text = "Lo que normalmente gastas en el día a día (mediana de \(months.isEmpty ? "tus meses con datos" : months)), sin viajes, regalos ni gastos de una vez."
        if advice.partialHistory { text += " Aún hay pocos meses completos: tómalo como punto de partida." }
        if !planning.plan(for: previousMonth).limits.isEmpty { text += " Donde ya tenías límite, la sugerencia mezcla 70% tu límite y 30% lo que gastaste." }
        return text
    }

    private var questionsStep: some View {
        Group {
            Section {
                Toggle("¿Vas a viajar este mes?", isOn: $travelling)
                if travelling {
                    HStack { Text("Presupuesto del viaje"); Spacer(); amountField($tripAmount) }
                }
            } header: { Text("3 · Lo que viene este mes") } footer: {
                if let average = advice.tripAverage {
                    Text("Tus viajes y salidas suelen costar \(planningMoney(average)) en el mes (\(advice.tripMonths) de \(max(1, advice.sampleMonths.count)) meses).")
                }
            }
            if !advice.unusualLastMonth.isEmpty {
                Section {
                    ForEach(advice.unusualLastMonth) { item in
                        Toggle(isOn: Binding(get: { repeats.contains(item.id) }, set: { on in if on { repeats.insert(item.id) } else { repeats.remove(item.id) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(2)
                                Text("\(planningMoney(item.amount)) · \(item.category)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("El mes pasado no fue típico por esto. ¿Se repite?") } footer: {
                    Text("Lo que marques se suma a su categoría este mes.")
                }
            }
            Section {
                TextField("Ej. regalo, compra, cumpleaños", text: $plannedName)
                HStack { Text("Monto"); Spacer(); amountField($plannedAmount) }
                Picker("Categoría", selection: $plannedCategory) {
                    ForEach(personalExpenseCategories, id: \.self) { Text($0).tag($0) }
                }
            } header: { Text("¿Algún gasto grande planeado?") }
        }
    }

    private var goalStep: some View {
        Group {
            Section {
                Picker("Meta", selection: $goal) { ForEach(Goal.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                if goal == .savings {
                    HStack { Text("Quiero ahorrar"); Spacer(); amountField($savingsGoal) }
                    if available == nil { Text("Configura tus ingresos para repartir el resto.").font(.caption).foregroundStyle(Color.marcelitoAmber) }
                }
                Text(goalExplanation).font(.caption).foregroundStyle(.secondary)
            } header: { Text("4 · Tu meta") }
            Section {
                ForEach(finalLimits.sorted { $0.value > $1.value }, id: \.key) { item in
                    row(item.key, planningMoney(item.value))
                }
                row("Total para gastar", planningMoney(finalTotal), bold: true)
                if let available { row("Ahorro estimado", planningMoney(available - finalTotal), bold: true) }
            } header: { Text("Tu plan de \(monthLabel.lowercased())") } footer: {
                Text("Se guarda como el límite de cada categoría. Puedes cambiar cualquier monto después en Presupuesto.")
            }
        }
    }

    private var goalExplanation: String {
        switch goal {
        case .typical: "Tu mes típico más lo que esperas este mes."
        case .tight: "10% menos en lo flexible (restaurantes, entretenimiento, compras, tiendita, viajes). Nunca en fijos."
        case .savings: "Primero apartas tu ahorro; lo flexible se ajusta para que el resto alcance."
        }
    }

    // MARK: Plan math

    private var previousMonth: Date { Calendar.current.date(byAdding: .month, value: -1, to: FinancePeriod.month(month).start)! }

    /// Typical amounts plus this month's expected items, before the goal.
    private var baseLimits: [String: Decimal] {
        var result = amounts.filter { included.contains($0.key) && $0.value > 0 }
        if travelling, tripAmount > 0 { result["Viajes", default: 0] += tripAmount }
        for item in advice.unusualLastMonth where repeats.contains(item.id) {
            result[item.category, default: 0] += MonthPlanAdvice.round(item.amount)
        }
        if plannedAmount > 0 { result[plannedCategory, default: 0] += plannedAmount }
        return result
    }

    private var finalLimits: [String: Decimal] {
        var result = baseLimits
        let flexible = result.filter { MonthPlanAdvice.flexibleCategories.contains($0.key) }
        switch goal {
        case .typical: break
        case .tight:
            for (key, value) in flexible { result[key] = MonthPlanAdvice.round(value * Decimal(string: "0.9")!) }
        case .savings:
            guard let available, savingsGoal > 0 else { break }
            let rigid = result.filter { !MonthPlanAdvice.flexibleCategories.contains($0.key) }.values.reduce(0, +)
            let flexibleTotal = flexible.values.reduce(0, +)
            let room = max(0, available - savingsGoal - rigid)
            if flexibleTotal > room, flexibleTotal > 0 {
                let factor = room / flexibleTotal
                for (key, value) in flexible { result[key] = MonthPlanAdvice.round(value * factor) }
            }
        }
        return result.filter { $0.value > 0 }
    }

    private var finalTotal: Decimal { finalLimits.values.reduce(0, +) }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        let suggestion = advice.suggested(previousLimits: planning.plan(for: previousMonth).limits)
        amounts = suggestion
        included = Set(suggestion.keys)
        tripAmount = advice.tripAverage ?? 0
        savingsGoal = planning.plan(for: month).savingsTarget
    }

    private func save() {
        var plan = planning.plan(for: month)
        let limits = finalLimits
        // Every category the budget would otherwise propose gets an explicit
        // value, so the saved plan is exactly what was reviewed here.
        var saved: [String: Decimal] = [:]
        for category in Set(planning.limits(store, month: month).keys).union(limits.keys) {
            saved[category] = limits[category] ?? 0
        }
        plan.limits = saved
        if goal == .savings { plan.savingsTarget = savingsGoal }
        planning.setPlan(plan, for: month)
        dismiss()
    }

    // MARK: Small views

    private func row(_ title: String, _ value: String, bold: Bool = false) -> some View {
        HStack { Text(title); Spacer(); Text(value).monospacedDigit() }.font(bold ? .body.weight(.semibold) : .body)
    }

    private func amountField(_ value: Binding<Decimal>) -> some View {
        TextField("0", value: value, format: .currency(code: "MXN").precision(.fractionLength(0)))
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 120)
            .monospacedDigit()
    }
}

/// "¿Algo fue de una vez?": what stood out this month, so it does not shape
/// next month's typical budget. Marking a charge saves it as extraordinary.
struct OneOffReviewSection: View {
    @Environment(FinanceStore.self) private var store
    @Environment(FinancialPlanningStore.self) private var planning
    let month: Date

    private var items: [MonthPlanAdvice.Unusual] {
        let start = FinancePeriod.month(month).start
        guard start <= .now, let next = Calendar.current.date(byAdding: .month, value: 1, to: start) else { return [] }
        return planning.monthPlanAdvice(store, month: next).unusualLastMonth.filter { !$0.isTrip && $0.movementIDs.count == 1 }
    }

    var body: some View {
        let items = items
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("¿Algo fue de una vez?").font(.headline)
                Text("Lo que marques no cuenta para tu mes típico, así el siguiente plan no se infla.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(items) { item in
                    if let movement = store.movements.first(where: { $0.id == item.movementIDs[0] }) {
                        Toggle(isOn: Binding(
                            get: { planning.label(for: movement).extraordinary == true },
                            set: { value in
                                var label = planning.label(for: movement)
                                label.extraordinary = value ? true : nil
                                planning.setLabel(label, for: movement)
                            })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.subheadline).lineLimit(2)
                                Text("\(planningMoney(item.amount)) · \(MonthSpendingStory.day(movement.date))").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
