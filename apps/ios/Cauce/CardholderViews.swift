import SwiftUI

/// "¿Quién lo gastó?" on a charge: you or an additional cardholder.
struct SpenderPickerSection: View {
    @Environment(FinanceStore.self) private var store
    let movement: Movement
    @State private var addingPerson = false
    @State private var newName = ""

    private var current: Movement { store.movements.first { $0.id == movement.id } ?? movement }

    var body: some View {
        Section {
            Picker("Lo gastó", selection: Binding(
                get: { current.spender ?? "" },
                set: { store.setSpender(for: current, to: $0.isEmpty ? nil : $0) }
            )) {
                Text("Yo").tag("")
                ForEach(store.cardholderProfiles) { profile in Text(profile.name).tag(profile.id) }
            }
            Button("Otra persona…") { newName = ""; addingPerson = true }
            if let profile = store.cardholderProfile(current.spender) {
                Text("No cuenta en tu gasto ni en tu presupuesto. Se suma a lo que gastó \(profile.shortName)\(profile.reimburses ? " y a lo que te debe" : "").")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("¿Quién lo gastó?")
        }
        .alert("¿Quién hizo este cargo?", isPresented: $addingPerson) {
            TextField("Nombre", text: $newName)
            Button("Guardar") {
                if let profile = store.addCardholder(named: newName) { store.setSpender(for: current, to: profile.id) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Por ejemplo, quien usa tu tarjeta adicional.")
        }
    }
}

/// Inicio: what each additional cardholder spent this month and owes you.
struct CardholderSummaryCard: View {
    @Environment(FinanceStore.self) private var store
    @State private var selected: CardholderProfile?

    var body: some View {
        let month = FinancePeriod.month(.now)
        let rows = store.cardholderProfiles.map { profile in
            (profile: profile, month: store.cardholderSpend(profile.id, period: month), owed: store.cardholderReceivable(profile.id))
        }.filter { $0.month != 0 || $0.owed != 0 }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows, id: \.profile.id) { row in
                    Button { selected = row.profile } label: {
                        HStack(alignment: .top) {
                            Image(systemName: "person.crop.rectangle.stack").foregroundStyle(Color.marcelitoNavyMid)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(row.profile.shortName) · tarjeta adicional").font(.headline)
                                Text("Gastó \(planningMoney(row.month)) este mes · fuera de tu gasto").font(.caption).foregroundStyle(.secondary)
                                if row.profile.reimburses {
                                    Text(row.owed >= 0 ? "Te debe \(planningMoney(row.owed))" : "Te pagó \(planningMoney(-row.owed)) de más")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(row.owed > 0 ? Color.marcelitoAmber : Color.marcelitoSuccess)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .marcelitoCard(radius: 20, padding: 16)
            .sheet(item: $selected) { profile in NavigationStack { CardholderDetailView(profileID: profile.id) } }
        }
    }
}

/// Patrimonio: money owed to you by additional cardholders.
struct CardholderReceivableRows: View {
    @Environment(FinanceStore.self) private var store
    var body: some View {
        let owed = store.cardholderProfiles.filter(\.reimburses).map { ($0, store.cardholderReceivable($0.id)) }.filter { $0.1 > 0 }
        if !owed.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(owed, id: \.0.id) { profile, amount in
                    LabeledContent("Por cobrar a \(profile.shortName)", value: planningMoney(amount))
                }
                let total = owed.reduce(Decimal(0)) { $0 + $1.1 }
                if let base = store.liquidPatrimony {
                    LabeledContent("Posición neta contando lo que te deben", value: planningMoney(base + total))
                        .font(.subheadline.weight(.semibold))
                }
                Text("Sus cargos siguen en la deuda de tu tarjeta porque el banco te los cobra a ti.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .marcelitoCard(radius: 18, padding: 16)
        }
    }
}

struct CardholderDetailView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let profileID: String
    @State private var cashAmount = ""
    @State private var cashDate = Date.now

    var body: some View {
        if let profile = store.cardholderProfile(profileID) {
            let charges = store.cardholderSpendMovements(profileID)
            let transfers = store.cardholderPaymentMovements(profileID)
            let charged = charges.reduce(Decimal(0)) { $0 + $1.expenseContribution }
            Form {
                Section {
                    LabeledContent("Este mes", value: planningMoney(store.cardholderSpend(profileID, period: .month(.now))))
                    LabeledContent("Total de sus cargos", value: planningMoney(charged))
                    if profile.reimburses {
                        LabeledContent("Te ha pagado", value: planningMoney(transfers.reduce(Decimal(0)) { $0 + $1.amount } + profile.cashPayments.reduce(Decimal(0)) { $0 + $1.amount }))
                        let owed = store.cardholderReceivable(profileID)
                        LabeledContent(owed >= 0 ? "Te debe" : "A su favor", value: planningMoney(abs(owed))).fontWeight(.semibold)
                    }
                    Toggle("Me paga lo que gasta", isOn: Binding(
                        get: { profile.reimburses },
                        set: { var updated = profile; updated.reimburses = $0; store.updateCardholder(updated) }
                    ))
                } footer: {
                    Text("Sus cargos no cuentan en tu gasto, presupuesto ni proyección. Las transferencias que recibas con su nombre se toman como pagos suyos, no como ingreso tuyo.")
                }
                if profile.reimburses {
                    Section("Registrar pago en efectivo") {
                        TextField("Importe", text: $cashAmount).keyboardType(.decimalPad)
                        DatePicker("Fecha", selection: $cashDate, displayedComponents: .date)
                        Button("Guardar pago") {
                            let clean = cashAmount.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
                            guard let amount = Decimal(string: clean, locale: Locale(identifier: "en_US_POSIX")), amount > 0 else { return }
                            var updated = profile
                            updated.cashPayments.append(CardholderCashPayment(date: cashDate, amount: amount))
                            store.updateCardholder(updated)
                            cashAmount = ""
                        }
                        .disabled(cashAmount.isEmpty)
                    }
                    if !transfers.isEmpty || !profile.cashPayments.isEmpty {
                        Section("Pagos recibidos") {
                            ForEach(transfers) { row in
                                LabeledContent("\(planningDayLabel(row.date)) · \(row.account)", value: planningMoney(row.amount))
                            }
                            ForEach(profile.cashPayments.sorted { $0.date > $1.date }) { payment in
                                LabeledContent("\(planningDayLabel(payment.date)) · efectivo", value: planningMoney(payment.amount))
                            }
                            .onDelete { offsets in
                                let sorted = profile.cashPayments.sorted { $0.date > $1.date }
                                let removed = Set(offsets.map { sorted[$0].id })
                                var updated = profile
                                updated.cashPayments.removeAll { removed.contains($0.id) }
                                store.updateCardholder(updated)
                            }
                        }
                    }
                }
                let months = Dictionary(grouping: charges) { FinancePeriod.month($0.date).start }.sorted { $0.key > $1.key }
                ForEach(months, id: \.key) { month, rows in
                    Section("\(FinancePeriod.month(month).label) · \(planningMoney(rows.reduce(Decimal(0)) { $0 + $1.expenseContribution }))") {
                        ForEach(rows) { row in
                            NavigationLink { MovementDetailView(movement: row) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.displayMerchant ?? row.title).lineLimit(1)
                                        Text(planningDayLabel(row.date)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(planningMoney(row.expenseContribution)).monospacedDigit()
                                }
                            }
                        }
                    }
                }
                if charges.isEmpty {
                    Text("Aún no hay cargos suyos. Se detectan solos en las capturas de Amex, o márcalos en el detalle de un movimiento con «¿Quién lo gastó?».")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Listo") { dismiss() } } }
        } else {
            ContentUnavailableView("Sin datos", systemImage: "person.crop.rectangle")
        }
    }
}

/// Ajustes: additional cardholders.
struct CardholdersSettingsView: View {
    @Environment(FinanceStore.self) private var store
    @State private var newName = ""
    var body: some View {
        Form {
            Section {
                ForEach(store.cardholderProfiles) { profile in
                    NavigationLink(profile.name) { CardholderDetailView(profileID: profile.id) }
                }
                HStack {
                    TextField("Agregar persona", text: $newName)
                    Button("Agregar") { store.addCardholder(named: newName); newName = "" }.disabled(newName.count < 3)
                }
            } footer: {
                Text("Quien usa una tarjeta adicional tuya. La app de Amex muestra su nombre bajo sus cargos y Marcelito los separa solo al leer tus capturas.")
            }
        }
        .navigationTitle("Tarjetas adicionales")
    }
}
