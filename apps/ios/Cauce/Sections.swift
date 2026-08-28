import SwiftUI

struct MovementsView: View {
    @Environment(FinanceStore.self) private var store
    @State private var query = ""
    @State private var isAddPresented = false

    private var filtered: [Movement] {
        query.isEmpty ? store.movements : store.movements.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { movement in
                NavigationLink {
                    MovementDetailView(movement: movement)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: movement.flow.symbol)
                            .foregroundStyle(movement.flow.color)
                        VStack(alignment: .leading) {
                            Text(movement.title)
                            Text("\(movement.account) · \(movement.category)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(movement.amount, format: .currency(code: "MXN"))
                            .monospacedDigit()
                    }
                }
            }
            .searchable(text: $query, prompt: "Comercio o categoría")
            .navigationTitle("Movimientos")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAddPresented = true
                    } label: {
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
    private let categories = ["Ingresos", "Transferencia", "Alimentos", "Viajes", "Comidas", "Servicios", "Transporte", "Salud", "Compras", "Sin categoría"]

    init(movement: Movement) {
        self.movement = movement
        _selectedCategory = State(initialValue: movement.category)
    }

    var body: some View {
        Form {
            LabeledContent("Importe") { Text(movement.amount, format: .currency(code: "MXN")).monospacedDigit() }
            LabeledContent("Cuenta", value: movement.account)
            Picker("Categoría", selection: Binding(
                get: { selectedCategory },
                set: {
                    selectedCategory = $0
                    store.updateCategory(for: movement, to: $0)
                }
            )) {
                ForEach(categories, id: \.self) { Text($0) }
            }
        }
        .navigationTitle(movement.title)
        .navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(.marcelitoNavy)
        .scrollContentBackground(.hidden)
        .background(Color.marcelitoCream)
    }
}

struct ExpensesView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Agosto") {
                    ExpenseRow(name: "Viajes", amount: 6_270, share: "61%", color: .marcelitoNavy)
                    ExpenseRow(name: "Alimentos", amount: 1_843, share: "18%", color: .marcelitoNavyMid)
                    ExpenseRow(name: "Comidas", amount: 920, share: "9%", color: .marcelitoNavySoft)
                    ExpenseRow(name: "Servicios", amount: 648, share: "6%", color: .marcelitoNavyMid.opacity(0.72))
                }
                Section("Historia financiera") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Fin de semana en Mérida").font(.headline)
                        Text("Hospedaje y transporte ya están pagados. Quedan $1,800 reservados para consumo.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
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
    var body: some View {
        NavigationStack {
            List {
                AccountRow(name: "Santander", purpose: "Cuenta principal", balance: 27_654, symbol: "building.columns.fill", color: .marcelitoNavy)
                AccountRow(name: "BBVA", purpose: "Ahorro y reservas", balance: 80_266, symbol: "building.columns.fill", color: .marcelitoNavyMid)
                AccountRow(name: "American Express", purpose: "Crédito · corte 27 ago", balance: 23_151, symbol: "creditcard.fill", color: .marcelitoNavySoft)
            }
            .navigationTitle("Cuentas")
            .listRowBackground(Color.marcelitoCreamSoft)
            .foregroundStyle(.marcelitoNavy)
            .scrollContentBackground(.hidden)
            .background(Color.marcelitoCream)
        }
    }
}

private struct AccountRow: View {
    let name: String
    let purpose: String
    let balance: Decimal
    let symbol: String
    let color: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading) { Text(name); Text(purpose).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Text(balance, format: .currency(code: "MXN").precision(.fractionLength(0))).monospacedDigit()
        }
    }
}

struct NetWorthView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Patrimonio neto estimado").foregroundStyle(.secondary)
                        Text(84_769, format: .currency(code: "MXN").precision(.fractionLength(0)))
                            .font(.largeTitle.bold()).monospacedDigit()
                        Text("+$18,430 en seis meses").foregroundStyle(.marcelitoNavyMid)
                    }.padding(.vertical, 10)
                }
                Section("Evolución") {
                    LabeledContent("Agosto", value: "$84,769")
                    LabeledContent("Julio", value: "$77,929")
                    LabeledContent("Junio", value: "$75,310")
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
