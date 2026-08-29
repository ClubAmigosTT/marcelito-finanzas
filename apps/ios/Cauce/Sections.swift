import SwiftUI

struct MovementsView: View {
    @Environment(FinanceStore.self) private var store
    @State private var query = ""
    @State private var isAddPresented = false

    private var filtered: [Movement] {
        guard !query.isEmpty else { return store.movements }
        return store.movements.filter {
            let statement = $0.statementId.flatMap { id in store.statements.first(where: { $0.id == id }) }
            return $0.title.localizedCaseInsensitiveContains(query)
                || $0.category.localizedCaseInsensitiveContains(query)
                || $0.account.localizedCaseInsensitiveContains(query)
                || statement?.source.localizedCaseInsensitiveContains(query) == true
                || statement?.period.localizedCaseInsensitiveContains(query) == true
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    ContentUnavailableView("Sin movimientos", systemImage: "doc.text.magnifyingglass", description: Text("Importa un estado de cuenta o agrega un movimiento manual."))
                } else {
                    ForEach(filtered) { movement in
                        NavigationLink {
                            MovementDetailView(movement: movement)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: movement.flow.symbol)
                                    .foregroundStyle(movement.flow.color)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(movement.title)
                                    Text("\(movement.account) · \(statementLabel(for: movement))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(movement.date, format: .dateTime.day().month(.abbreviated).year())
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(movement.amount, format: .currency(code: "MXN"))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Comercio, banco o periodo")
            .navigationTitle("Movimientos")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isAddPresented = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Agregar movimiento")
                }
            }
            .listRowBackground(Color.marcelitoCreamSoft)
            .foregroundStyle(.marcelitoNavy)
            .scrollContentBackground(.hidden)
            .background(Color.marcelitoCream)
            .sheet(isPresented: $isAddPresented) {
                AddMovementView()
            }
        }
    }

    private func statementLabel(for movement: Movement) -> String {
        guard let statementId = movement.statementId,
              let statement = store.statements.first(where: { $0.id == statementId }) else {
            return "Manual"
        }
        return "\(statement.source) · \(statement.period)"
    }
}

private struct AddMovementView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var account = "Importado"
    @State private var category = "Por revisar"
    @State private var amount = ""
    @State private var flow: FlowKind = .expense
    @State private var date = Date.now

    private let categoryOptions = [
        "Por revisar", "Ingresos", "Transferencia", "Alimentos", "Viajes", "Comidas",
        "Servicios", "Transporte", "Salud", "Compras"
    ]

    private var numericAmount: Decimal? {
        let clean = amount
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: clean, locale: Locale(identifier: "en_US_POSIX"))
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (numericAmount ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Movimiento") {
                    TextField("Descripción", text: $title)
                    TextField("Cuenta", text: $account)
                    TextField("Importe en MXN", text: $amount)
                        .keyboardType(.decimalPad)
                    Picker("Tipo", selection: $flow) {
                        ForEach(FlowKind.allCases) { item in
                            Label(item.rawValue, systemImage: item.symbol).tag(item)
                        }
                    }
                    Picker("Categoría", selection: $category) {
                        ForEach(categoryOptions, id: \.self) { Text($0) }
                    }
                    DatePicker("Fecha", selection: $date, displayedComponents: .date)
                }

                Section {
                    Button("Guardar movimiento") {
                        guard let numericAmount, numericAmount > 0 else { return }
                        store.addMovement(
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            account: account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Importado" : account,
                            category: category,
                            amount: numericAmount,
                            flow: flow,
                            date: date
                        )
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(!canSave)
                }
            }
            .navigationTitle("Agregar movimiento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.marcelitoCream)
            .foregroundStyle(.marcelitoNavy)
        }
    }
}

private struct MovementDetailView: View {
    @Environment(FinanceStore.self) private var store
    let movement: Movement
    @State private var selectedCategory: String
    @State private var selectedKind: MovementKind
    @State private var isTravel: Bool
    private let categories = ["Ingresos", "Transferencia", "Alimentos", "Viajes", "Comidas", "Servicios", "Transporte", "Salud", "Compras", "Sin categoría"]

    init(movement: Movement) {
        self.movement = movement
        _selectedCategory = State(initialValue: movement.category)
        _selectedKind = State(initialValue: movement.kind ?? .purchase)
        _isTravel = State(initialValue: movement.travelRelated)
    }

    var body: some View {
        Form {
            LabeledContent("Importe") { Text(movement.amount, format: .currency(code: "MXN")).monospacedDigit() }
            LabeledContent("Cuenta", value: movement.account)
            if let statement = movement.statementId.flatMap({ id in store.statements.first(where: { $0.id == id }) }) {
                LabeledContent("Estado", value: "\(statement.source) · \(statement.period)")
                LabeledContent("Archivo", value: statement.fileName)
            } else {
                LabeledContent("Estado", value: "Movimiento manual")
            }
            Picker("Categoría", selection: Binding(
                get: { selectedCategory },
                set: {
                    selectedCategory = $0
                    store.updateCategory(for: movement, to: $0)
                }
            )) {
                ForEach(categories, id: \.self) { Text($0) }
            }
            Picker("Tipo de movimiento", selection: Binding(
                get: { selectedKind },
                set: {
                    selectedKind = $0
                    store.updateClassification(for: movement, kind: $0, travelRelated: isTravel)
                }
            )) {
                ForEach(MovementKind.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Relacionado con viaje", isOn: Binding(
                get: { isTravel },
                set: {
                    isTravel = $0
                    store.updateClassification(for: movement, kind: selectedKind, travelRelated: $0)
                }
            ))
        }
        .navigationTitle(movement.title)
        .navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(.marcelitoNavy)
        .scrollContentBackground(.hidden)
        .background(Color.marcelitoCream)
    }
}

struct ExpensesView: View {
    @Environment(FinanceStore.self) private var store

    private var groups: [(category: String, amount: Decimal)] {
        Dictionary(grouping: store.realExpenseMovements, by: { $0.category })
            .map { (category: $0.key, amount: $0.value.reduce(0) { $0 + abs($1.amount) }) }
            .sorted { $0.amount > $1.amount }
    }

    private var total: Decimal { groups.reduce(0) { $0 + $1.amount } }

    var body: some View {
        NavigationStack {
            List {
                if groups.isEmpty {
                    ContentUnavailableView("Sin gastos", systemImage: "chart.pie", description: Text("Importa un estado de cuenta para construir tus categorías reales."))
                } else {
                    Section("Gasto identificado") {
                        ForEach(Array(groups.enumerated()), id: \.element.category) { index, item in
                            ExpenseRow(name: item.category, amount: item.amount, share: total > 0 ? "\(Int((item.amount / total * 100).rounded()))%" : "0%", color: [.marcelitoNavy, .marcelitoNavyMid, .marcelitoNavySoft][min(index, 2)])
                        }
                    }
                    Section("Lectura") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(groups.count) categorías explican")
                            Text(total, format: .currency(code: "MXN").precision(.fractionLength(0)))
                                .font(.headline)
                            Text("Puedes corregir el origen o la categoría desde Movimientos.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section("Conciliación") {
                        LabeledContent("Gasto de viaje", value: store.travelSpend.formatted(.currency(code: "MXN").precision(.fractionLength(0))))
                        LabeledContent("Gasto ordinario", value: store.ordinarySpend.formatted(.currency(code: "MXN").precision(.fractionLength(0))))
                        LabeledContent("Gasto consolidado", value: store.consolidatedRealSpend.formatted(.currency(code: "MXN").precision(.fractionLength(0))))
                        LabeledContent("Tasa de ahorro", value: store.savingsRate.map { "\(Int((NSDecimalNumber(decimal: $0).doubleValue * 100).rounded()))%" } ?? "Pendiente")
                    }
                }
            }
            .navigationTitle("Gastos")
            .listRowBackground(Color.marcelitoCreamSoft)
            .foregroundStyle(.marcelitoNavy)
            .scrollContentBackground(.hidden)
            .background(Color.marcelitoCream)
        }
    }
}

private struct ExpenseRow: View {
    let name: String
    let amount: Decimal
    let share: String
    let color: Color

    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(name)
            Spacer()
            Text(share).foregroundStyle(.secondary)
            Text(amount, format: .currency(code: "MXN").precision(.fractionLength(0))).monospacedDigit()
        }
    }
}

struct AccountsView: View {
    @Environment(FinanceStore.self) private var store
    private let knownSources = ["Santander", "BBVA", "Amex"]

    var body: some View {
        NavigationStack {
            List {
                Section("Estados de cuenta") {
                    if store.statements.isEmpty {
                        Text("Aún no hay estados importados. Usa el botón de carga en Inicio.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.statements) { statement in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: statement.requiresReview ? "exclamationmark.triangle" : "checkmark.circle.fill")
                                        .foregroundStyle(statement.requiresReview ? .orange : .marcelitoNavyMid)
                                    Text("\(statement.source) · \(statement.period)")
                                    Spacer()
                                    Text("\(statement.transactionCount) mov.")
                                        .font(.caption)
                                        .monospacedDigit()
                                }
                                Text(statement.fileName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Editar cifras del corte") {
                    if store.statements.isEmpty {
                        Text("Importa un estado para capturar saldos, pagos, crédito y MSI.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.statements) { statement in
                            NavigationLink {
                                StatementSummaryEditor(statement: statement)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(statement.source) · \(statement.period)")
                                    Text("Saldos, pagos, crédito y MSI")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section("Bancos") {
                    ForEach(knownSources, id: \.self) { source in
                        let statements = store.statements.filter { $0.source == source }
                        let movementCount = store.movements.filter { movement in
                            guard let statementId = movement.statementId else { return false }
                            return statements.contains(where: { $0.id == statementId })
                        }.count
                        HStack(spacing: 12) {
                            Image(systemName: source == "Amex" ? "creditcard.fill" : "building.columns.fill")
                                .foregroundStyle(.marcelitoNavyMid)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source)
                                Text(statements.isEmpty ? "Sin estados importados" : "\(statements.count) estado(s) · \(movementCount) movimientos")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Cuentas")
            .listRowBackground(Color.marcelitoCreamSoft)
            .foregroundStyle(.marcelitoNavy)
            .scrollContentBackground(.hidden)
            .background(Color.marcelitoCream)
        }
    }
}

private struct StatementSummaryEditor: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let statement: StatementRecord
    @State private var summary: StatementSummaryRecord

    init(statement: StatementRecord) {
        self.statement = statement
        _summary = State(initialValue: statement.summary ?? StatementSummaryRecord())
    }

    private func decimalBinding(_ keyPath: WritableKeyPath<StatementSummaryRecord, Decimal?>) -> Binding<String> {
        Binding(
            get: { summary[keyPath: keyPath].map { String(describing: $0) } ?? "" },
            set: { value in
                let cleaned = value.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
                summary[keyPath: keyPath] = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
            }
        )
    }

    private var installmentBinding: Binding<String> {
        Binding(
            get: { summary.msiInstallments.map { String($0) } ?? "" },
            set: { summary.msiInstallments = Int($0) }
        )
    }

    private func decimalField(_ title: String, _ keyPath: WritableKeyPath<StatementSummaryRecord, Decimal?>) -> some View {
        TextField(title, text: decimalBinding(keyPath))
            .keyboardType(.decimalPad)
    }

    var body: some View {
        Form {
            Section("Resumen del corte") {
                decimalField("Saldo anterior", \.previousBalance)
                decimalField("Nuevas transacciones", \.newTransactions)
                decimalField("Pagos realizados", \.payments)
                decimalField("Créditos / abonos contables", \.credits)
                decimalField("Nuevos cargos", \.newCharges)
                decimalField("Intereses", \.interest)
                decimalField("Comisiones", \.fees)
                decimalField("Saldo al corte", \.statementBalance)
                decimalField("Pago mínimo", \.minimumPayment)
                decimalField("Pago para no generar intereses", \.paymentForNoInterest)
            }
            if statement.source.localizedCaseInsensitiveContains("Amex") {
                Section("Crédito y MSI") {
                    decimalField("Límite de crédito", \.creditLimit)
                    decimalField("Crédito disponible", \.creditAvailable)
                    decimalField("Deuda al corte", \.debtBalance)
                    decimalField("MSI original diferido", \.msiOriginalDeferred)
                    TextField("Mensualidades MSI activas", text: installmentBinding)
                        .keyboardType(.numberPad)
                    decimalField("Carga mensual MSI", \.msiMonthlyLoad)
                }
            } else {
                Section("Banco") {
                    decimalField("Efectivo disponible", \.cashBalance)
                }
            }
            Section {
                Button("Guardar cifras del corte") {
                    store.updateStatementSummary(for: statement, summary: summary)
                    dismiss()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Cifras del corte")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Color.marcelitoCream)
        .foregroundStyle(.marcelitoNavy)
    }
}

struct NetWorthView: View {
    @Environment(FinanceStore.self) private var store

    private var patrimonyText: String {
        store.liquidPatrimony?.formatted(.currency(code: "MXN").precision(.fractionLength(0))) ?? "—"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Patrimonio líquido").foregroundStyle(.secondary)
                        Text(patrimonyText)
                            .font(.largeTitle.bold())
                            .monospacedDigit()
                        Text(store.liquidPatrimony == nil ? "Pendiente de saldos al corte" : "Efectivo disponible menos deuda")
                            .foregroundStyle(.marcelitoNavyMid)
                    }
                    .padding(.vertical, 10)
                }
                Section("Saldos calculados") {
                    LabeledContent("Efectivo disponible", value: store.cashAvailable?.formatted(.currency(code: "MXN").precision(.fractionLength(0))) ?? "Pendiente")
                    LabeledContent("Deuda total", value: store.debtTotal?.formatted(.currency(code: "MXN").precision(.fractionLength(0))) ?? "Pendiente")
                    LabeledContent("Utilización de crédito", value: store.creditUtilizationRate.map { "\(Int((NSDecimalNumber(decimal: $0).doubleValue * 100).rounded()))%" } ?? "Pendiente")
                }
                Section("Estados que alimentan la historia") {
                    if store.statements.isEmpty {
                        Text("Importa tus PDFs para construir la línea de tiempo por banco y periodo.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.statements) { statement in
                            LabeledContent("\(statement.period) · \(statement.source)", value: "\(statement.transactionCount) mov.")
                        }
                    }
                }
            }
            .navigationTitle("Patrimonio")
            .listRowBackground(Color.marcelitoCreamSoft)
            .foregroundStyle(.marcelitoNavy)
            .scrollContentBackground(.hidden)
            .background(Color.marcelitoCream)
        }
    }
}
