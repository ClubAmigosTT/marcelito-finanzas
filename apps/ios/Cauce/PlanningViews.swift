import SwiftUI
import Charts

func planningMoney(_ amount: Decimal) -> String {
    amount.formatted(.currency(code: "MXN").locale(Locale(identifier: "es_MX")).precision(.fractionLength(0)))
}
let personalExpenseCategories = ["Restaurantes y bares", "Tiendita", "Despensa / supermercado", "Entretenimiento", "Viajes", "Transporte", "Deporte", "Compras personales", "Software y suscripciones", "Salud", "Educación", "Entrenamiento", "Binance (salarios)", "Club Amigos / Proyectos", "Comisiones y finanzas", "Otros / Por revisar"]

struct CalculationHelp: View {
    let explanation: String
    @State private var show = false
    var body: some View {
        Button { show = true } label: { Image(systemName: "info.circle").font(.caption) }
            .buttonStyle(.plain).accessibilityLabel("Cómo se calcula")
            .alert("Cómo se calcula", isPresented: $show) { Button("Entendido", role: .cancel) {} } message: { Text(explanation) }
    }
}
struct PlanningMetric: View {
    let title: String, value: String, period: String, explanation: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(title).font(.caption); CalculationHelp(explanation: explanation) }
            Text(value).font(.title3.bold()).monospacedDigit()
            if !period.isEmpty { Text(period).font(.caption2).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct PlanningIncomeView: View {
    var month = Date.now
    var body: some View { NavigationStack { PlanningIncomeContent(month: month, allowsDismiss: true) } }
}
struct PlanningIncomeContent: View {
    var month: Date = .now
    var allowsDismiss = false
    @Environment(FinancialPlanningStore.self) private var planning
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var editing: PlanningIncomeSource?
    @State private var showReceivedDeposits = false
    @State private var selectedDepositSource: PlanningIncomeSource?
    @State private var deleting: PlanningIncomeSource?
    @State private var incomeMonth = Date.now
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                DatePicker("Ingreso vigente desde el mes de", selection: $incomeMonth, displayedComponents: .date)
                Text(FinancePeriod.month(incomeMonth).label).font(.caption).foregroundStyle(.secondary)
                LabeledContent("Total habitual al mes", value: planning.monthlyIncome(for: incomeMonth).map(planningMoney) ?? "Sin configurar")
                    .font(.headline)
            } footer: { Text("Se usa para planear tu presupuesto. Los depósitos realmente recibidos se muestran por separado. Los cambios aplican desde el mes elegido; los cierres guardados se conservan.") }
            Section {
                ForEach(planning.incomeSources(for: incomeMonth)) { source in
                    HStack {
                        Button { editing = source } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name).foregroundStyle(Color.marcelitoNavy)
                                Text(sourceSummary(source)).font(.caption).foregroundStyle(.secondary)
                                Text("\(planningMoney(source.monthlyAmount)) al mes").font(.caption).foregroundStyle(Color.marcelitoNavyMid)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Button { deleting = source } label: { Image(systemName: "trash").foregroundStyle(.secondary) }.buttonStyle(.borderless).accessibilityLabel("Eliminar \(source.name)")
                    }
                }
                Button { editing = PlanningIncomeSource(name: "", amount: 0, cadence: "Mensual") } label: { Label("Agregar fuente manualmente", systemImage: "plus.circle") }
                Button { showReceivedDeposits = true } label: { Label("Elegir un depósito recibido", systemImage: "tray.and.arrow.down") }
            } header: { Text("Tus fuentes de ingreso") } footer: {
                if planning.state.incomeSources == nil, planning.state.incomeAmount != nil {
                    Text("Conservamos tu total anterior como Ingreso habitual. Si incluía varias fuentes, edítalo antes de agregarlas por separado para no sumarlas dos veces.")
                }
            }
            let recurring = planning.incomeSuggestions(store)
            Section("Ingresos con patrón periódico") {
                if recurring.isEmpty {
                    Text(store.realIncomeMovements.isEmpty ? "Aún no hay depósitos de ingreso cargados. Puedes agregar tus fuentes manualmente y subir después el estado de débito." : "Sin nuevas sugerencias automáticas. Puedes elegir un depósito recibido o agregar otra fuente manualmente.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(recurring) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            editing = PlanningIncomeSource(name: item.name, amount: item.amount, cadence: item.cadence, account: item.movement.account, detectedKey: item.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                Text("\(item.movement.account) · \(planningMoney(item.amount)) · \(item.cadence)").font(.caption)
                                Text("\(item.movements.count) depósitos con importe y fechas similares").font(.caption).foregroundStyle(.secondary)
                                Text("Agregar como fuente").font(.caption.weight(.semibold))
                            }
                        }
                        NavigationLink("Ver depósitos que respaldan la sugerencia") { IncomeDepositEvidenceView(rows: item.movements) }.font(.caption)
                    }
                }
                Text("No se agregan automáticamente ni incluyen transferencias propias. Si falta una fuente, puedes agregarla manualmente.").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(Color.marcelitoDanger) }
            Section("Depósitos recibidos") {
                NavigationLink("Ver ingresos recibidos por mes") { IncomeOverviewView(month: month) }
            }
            if allowsDismiss && !planning.state.incomeOnboardingCompleted {
                Button("Configurar después") { planning.state.incomeOnboardingCompleted = true; if planning.save() { dismiss() } }
            }
        }.navigationTitle("Ingresos").onAppear { incomeMonth = FinancePeriod.month(month).start }.toolbar {
            if allowsDismiss { ToolbarItem(placement: .topBarTrailing) { Button("Listo") { dismiss() } } }
        }.scrollContentBackground(.hidden).background(MarcelitoAmbientBackground())
            .sheet(item: $editing) { source in PlanningIncomeSourceEditor(source: source, effectiveFrom: incomeMonth) }
            .sheet(isPresented: $showReceivedDeposits, onDismiss: {
                if let source = selectedDepositSource { selectedDepositSource = nil; editing = source }
            }) {
                IncomeDepositPicker { movement in
                    selectedDepositSource = planning.incomeDraft(from: movement, store: store)
                    showReceivedDeposits = false
                }
            }
            .confirmationDialog("¿Eliminar esta fuente de ingreso?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { source in
                Button("Eliminar fuente", role: .destructive) {
                    if !planning.setIncomeSources(planning.incomeSources(for: incomeMonth).filter { $0.id != source.id }, effectiveFrom: incomeMonth) { error = "No se pudo guardar el cambio. Tu información se conserva." }
                    deleting = nil
                }
                Button("Cancelar", role: .cancel) { deleting = nil }
            } message: { _ in Text("Solo cambia tu ingreso habitual para presupuestar. Los depósitos y movimientos se conservan.") }
    }
    private func sourceSummary(_ source: PlanningIncomeSource) -> String {
        [planningMoney(source.amount), source.cadence, source.account].filter { !$0.isEmpty }.joined(separator: " · ")
    }

}
struct PlanningIncomeSourceEditor: View {
    @Environment(FinancialPlanningStore.self) private var planning
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let source: PlanningIncomeSource
    var effectiveFrom = Date.now
    @State private var appliesFrom = Date.now
    @State private var name = ""
    @State private var amount = ""
    @State private var cadence = "Mensual"
    @State private var account = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Aplicar desde el mes de", selection: $appliesFrom, displayedComponents: .date)
                    TextField("Nombre, por ejemplo Nómina Santander", text: $name)
                    TextField("Importe MXN", text: $amount).keyboardType(.decimalPad)
                    Picker("Frecuencia", selection: $cadence) { ForEach(RecurringCadence.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } }
                    Picker("Cuenta", selection: $account) {
                        Text("Sin asociar").tag("")
                        ForEach(Array(Set(store.movements.map(\.account) + store.statements.map(\.source) + [source.account])).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    if let value = parsePlanningAmount(amount) { LabeledContent("Equivalente mensual", value: planningMoney(RecurringCadence(rawValue: cadence)?.monthlyAmount(value) ?? value)) }
                } header: { Text("Fuente de ingreso") } footer: { Text("Confirma el importe por pago y su frecuencia. Quincenal equivale a dos pagos al mes; semanal y anual usan un promedio mensual. Guardar una fuente no crea depósitos.") }
                if let error { Text(error).foregroundStyle(Color.marcelitoDanger) }
                Button("Guardar fuente") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, let number = parsePlanningAmount(amount) else { error = "Escribe un nombre y un importe válido."; return }
                    var updated = source; updated.name = trimmed; updated.amount = number; updated.cadence = cadence; updated.account = account
                    if account != source.account { updated.detectedKey = nil }
                    var sources = planning.incomeSources(for: appliesFrom)
                    if let key = updated.detectedKey, sources.contains(where: { $0.id != updated.id && $0.detectedKey == key }) { error = "Esta fuente ya está configurada. Edítala desde Tus fuentes de ingreso."; return }
                    if let index = sources.firstIndex(where: { $0.id == source.id }) { sources[index] = updated } else { sources.append(updated) }
                    if planning.setIncomeSources(sources, effectiveFrom: appliesFrom) { dismiss() } else { error = "No se pudo guardar. Tu información anterior se conserva." }
                }.buttonStyle(.marcelitoPrimary)
            }.navigationTitle("Fuente de ingreso").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancelar") { dismiss() } } }
        }.onAppear { appliesFrom = effectiveFrom; name = source.name; amount = source.name.isEmpty && source.amount == 0 ? "" : NSDecimalNumber(decimal: source.amount).stringValue; cadence = source.cadence; account = source.account }
    }
}
func parsePlanningAmount(_ text: String, precision: Int = 2) -> Decimal? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
    let pattern = #"^[0-9]+(?:\.[0-9]{1,"# + String(precision) + #"})?$"#
    guard trimmed.range(of: pattern, options: .regularExpression) != nil, let number = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")), number >= 0 else { return nil }
    return number
}

struct HomeMonthlyPlanCard: View {
    @Environment(FinanceStore.self) private var store
    @Environment(FinancialPlanningStore.self) private var planning
    @State private var incomeSheet = false
    let upload: () -> Void
    let showLatest: (Date) -> Void
    var body: some View {
        let month = FinancePeriod.month(.now)
        let snapshot = planning.snapshot(store, month: .now)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(snapshot.hasData ? "Te queda este mes" : "\(month.label) · Presupuesto del mes")
                Spacer()
                CalculationHelp(explanation: "Ingreso confirmado − gastos fijos presupuestados − exceso gastado en fijos − meta de ahorro − mensualidades MSI − reserva de préstamos − todo el gasto variable registrado, incluidos viajes, extraordinarios y montos por cobrar. Sin movimientos del mes todavía no se conoce el restante real. Las cifras son provisionales cuando faltan estados o capturas.")
            }
            if store.operationalMetricsBlocked {
                Text("Revisa tus estados para calcular el disponible").font(.headline)
            } else if !snapshot.hasData {
                Text(planning.monthlyIncome == nil ? "Prepara tu presupuesto del mes" : "Tu presupuesto está preparado").font(.title3.bold())
                if let income = planning.monthlyIncome { Text("Ingreso habitual: \(planningMoney(income)) al mes").font(.subheadline) }
                if let latest = planning.latestMovementDate(store), !month.contains(latest) {
                    Button("Ver último mes con datos: \(monthName(latest)) →") { showLatest(latest) }.font(.subheadline.weight(.semibold)).tint(.white)
                }
                if planning.monthlyIncome == nil { Button("Configurar ingresos") { incomeSheet = true }.buttonStyle(.bordered).tint(.white) }
            } else if let remaining = snapshot.remaining {
                Text("\(planningMoney(remaining)) este mes · \(snapshot.daily.map(planningMoney) ?? "—") por día").font(.title2.bold()).monospacedDigit()
                if !monthIsCovered(store, period: month, through: .now) { Text("Disponible provisional · faltan movimientos por actualizar").font(.caption) }
            } else if snapshot.hasUnknownLoans {
                Text("Completa el valor de UDI de tu préstamo para calcular el disponible").font(.headline)
                NavigationLink("Revisar préstamos") { LoanAccountsView() }
            } else if snapshot.hasUnknownCommitments {
                Text("Completa el detalle de tus mensualidades MSI para calcular el disponible").font(.headline)
            } else {
                Text("Define tus ingresos para planear el mes").font(.headline)
                Button("Configurar ingresos") { incomeSheet = true }.buttonStyle(.bordered).tint(.white)
            }
            if snapshot.hasData { Text(month.label).font(.caption) }
            let observed = planning.observedIncome(store, period: month)
            if observed > 0, snapshot.hasData {
                let rate = (observed - planning.total(store, period: month)) / observed
                HStack { Text("Tasa de ahorro observada: \(Int((NSDecimalNumber(decimal: rate * 100).doubleValue).rounded()))%").font(.caption); CalculationHelp(explanation: "(Ingreso real recibido − consumo total registrado) / ingreso real recibido. MSI registra la compra completa. Historial parcial puede cambiar esta tasa.") }
            }
        }.foregroundStyle(.white).marcelitoCard(fill: Color.marcelitoNavyMid, radius: 20, padding: 18)
            .sheet(isPresented: $incomeSheet) { PlanningIncomeView() }
    }
}
struct PlanningDataFreshness: View {
    @Environment(FinanceStore.self) private var store
    @Environment(FinancialPlanningStore.self) private var planning
    let update: () -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                if let latest = planning.latestDataDate(store) { Text("Último dato: " + planningDayLabel(latest)) }
                else { Text("Sin fecha de actualización confirmada") }
            }.font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Actualizar", action: update).font(.caption.weight(.semibold))
        }
    }
}
func planningDayLabel(_ date: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "es_MX"); f.dateFormat = "d MMM yyyy"; return f.string(from: date)
}
func monthName(_ date: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "es_MX"); f.dateFormat = "MMMM"; return f.string(from: date) }
func monthIsCovered(_ store: FinanceStore, period: FinancePeriod, through date: Date, account: String? = nil) -> Bool {
    let c = Calendar.current; let covered = store.spendingCoveredDays(account: account); var day = period.start
    let last = min(period.end, c.date(byAdding: .day, value: 1, to: c.startOfDay(for: date))!)
    guard day < last else { return false }
    while day < last { if !covered.contains(day) { return false }; day = c.date(byAdding: .day, value: 1, to: day)! }
    return true
}

struct ExpensesView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(FinancialPlanningStore.self) private var planning
    var initialDate: Date? = nil
    var initialMode: FinancePeriodMode = .month
    var isPresentedAsSheet = false
    @Environment(\.dismiss) private var dismiss
    @State private var showPeriodPicker = false
    @State private var initializedPeriod = false
    @State private var userSelectedPeriod = false
    @State private var mode: FinancePeriodMode = .month
    @State private var selectedDate = Date.now
    @State private var from = FinancePeriod.month(.now).start
    @State private var through = Date.now
    @State private var account = "Todas"
    @State private var showPending = false
    @State private var showAll = false
    @State private var selectedCategory: String?
    @State private var showCategories = false
    @State private var showImport = false
    private var period: FinancePeriod { .selected(mode, date: selectedDate, from: from, through: through) }
    private var rows: [Movement] { planning.expenseRows(store, period: period).filter { account == "Todas" || $0.account == account } }
    private var total: Decimal { rows.reduce(0) { $0 + $1.expenseContribution } }
    private var categories: [(String, Decimal)] {
        Dictionary(grouping: rows, by: { planning.category($0) }).map { ($0.key, $0.value.reduce(0) { $0 + $1.expenseContribution }) }.filter { $0.1 != 0 }.sorted { $0.1 > $1.1 }
    }
    private var selectedRows: [Movement] { rows.filter { selectedCategory == nil || planning.category($0) == selectedCategory } }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    CategoryUndoButton()
                    if store.operationalMetricsBlocked { HistoricalDashboardBlockedCard(store: store) }
                    else if rows.isEmpty {
                        emptyPeriodSection
                    } else {
                        totalsSection
                        comparisonSection
                        categoriesSection
                        accumulatedChart
                        merchantsSection
                        dailySection
                        breakdown
                    }
                    let pending = store.pendingExpenseCategoryMovements.filter { period.contains($0.date) && (account == "Todas" || $0.account == account) }
                    if !pending.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pendientes de clasificar").font(.headline)
                            Text("\(pending.count) movimientos · \(planningMoney(pending.reduce(0) { $0 + $1.expenseContribution })) · \(period.label)").font(.caption).foregroundStyle(Color.marcelitoAmber)
                            Button("Clasificar pendientes") { showPending = true }.buttonStyle(.marcelitoPrimary)
                        }
                    }
                }.padding(18)
            }
            .modifier(PeriodSwipeNavigation(move: movePeriod))
            .navigationTitle("Gastos").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) { periodSelector.padding(.horizontal, 18).padding(.vertical, 8).background(.regularMaterial) }
            .background(MarcelitoAmbientBackground()).foregroundStyle(Color.marcelitoNavy)
            .sheet(isPresented: $showPending) { PendingClassificationView(period: period, accountFilter: account) }
            .sheet(isPresented: $showCategories) { NavigationStack { PersonalMovementList(title: selectedCategory ?? "Movimientos", rows: selectedRows, period: period) } }
            .sheet(isPresented: $showImport) { AccountsView() }
            .sheet(isPresented: $showPeriodPicker) {
                PeriodSelectionSheet(mode: mode == .range ? .day : mode, date: mode == .range ? from : selectedDate, choose: choosePeriodDate)
            }
            .toolbar { if isPresentedAsSheet { ToolbarItem(placement: .topBarTrailing) { Button("Cerrar") { dismiss() } } } }
            .onAppear { initializePeriod() }
            .onChange(of: store.ledgerVersion) { _, _ in
                // Imports may finish after the view first opens. Follow the
                // newest data only until the user explicitly picks a period.
                if !userSelectedPeriod, initialDate == nil {
                    selectedDate = planning.initialExpenseDate(store)
                    from = FinancePeriod.month(selectedDate).start
                    through = min(.now, FinancePeriod.month(selectedDate).end.addingTimeInterval(-1))
                }
            }
        }
    }
    private func initializePeriod() {
        guard !initializedPeriod else { return }
        mode = initialMode
        selectedDate = initialDate ?? planning.initialExpenseDate(store)
        from = FinancePeriod.month(selectedDate).start
        through = min(.now, FinancePeriod.month(selectedDate).end.addingTimeInterval(-1))
        initializedPeriod = true
    }
    private func selectLatest(_ date: Date) {
        userSelectedPeriod = true; mode = .month; selectedDate = date; selectedCategory = nil
        from = FinancePeriod.month(date).start
        through = min(.now, FinancePeriod.month(date).end.addingTimeInterval(-1))
    }
    private var emptyPeriodSection: some View {
        let latest = planning.latestMovementDate(store, account: account == "Todas" ? nil : account)
        let currentMonth = mode == .month && Calendar.current.isDate(selectedDate, equalTo: .now, toGranularity: .month)
        return VStack(alignment: .leading, spacing: 14) {
            Label(currentMonth ? "\(period.label) aún no tiene gastos cargados" : "Sin gastos cargados en este periodo", systemImage: "calendar").font(.title3.bold())
            if let latest, !period.contains(latest) {
                Text("El último mes con movimientos es \(FinancePeriod.month(latest).label.lowercased()).").foregroundStyle(.secondary)
                Button("Ver \(FinancePeriod.month(latest).label.lowercased())") { selectLatest(latest) }.buttonStyle(.marcelitoPrimary)
            } else if latest != nil {
                Text("Hay movimientos de cuenta, pero no cargos de consumo en este periodo.").font(.subheadline).foregroundStyle(.secondary)
            } else { Text("Los gastos aparecerán al subir un estado o capturas.").foregroundStyle(.secondary) }
            Text("La app se actualiza con tus estados y capturas, sin conexión en tiempo real.").font(.caption).foregroundStyle(.secondary)
            Button("Subir estado o capturas") { showImport = true }.buttonStyle(.bordered)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
    }
    private func choosePeriodDate(_ date: Date) {
        if mode == .range {
            let count = Calendar.current.dateComponents([.day], from: period.start, to: period.end).day ?? 1
            from = date; through = Calendar.current.date(byAdding: .day, value: max(0, count - 1), to: date)!
        } else { selectedDate = date }
        userSelectedPeriod = true; selectedCategory = nil
    }
    private func movePeriod(_ direction: Int) {
        let next = period.shifted(by: direction, mode: mode)
        userSelectedPeriod = true; selectedCategory = nil
        if mode == .range { from = next.start; through = Calendar.current.date(byAdding: .day, value: -1, to: next.end)! }
        else { selectedDate = next.start }
    }
    private var periodSelector: some View {
        VStack(spacing: 4) {
            Picker("Periodo", selection: Binding(get: { mode }, set: { mode = $0; userSelectedPeriod = true; selectedCategory = nil })) { ForEach(FinancePeriodMode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            if mode == .range {
                HStack {
                    DatePicker("Desde", selection: Binding(get: { from }, set: { from = $0; userSelectedPeriod = true }), displayedComponents: .date).labelsHidden()
                    DatePicker("Hasta", selection: Binding(get: { through }, set: { through = $0; userSelectedPeriod = true }), displayedComponents: .date).labelsHidden()
                }
            }
            PeriodNavigationBar(label: period.label, move: movePeriod) { showPeriodPicker = true }
            HStack {
                Spacer()
                Menu {
                    Button("Todas") { account = "Todas" }
                    ForEach(Array(Set(store.movements.map(\.account))).sorted(), id: \.self) { name in Button(name) { account = name } }
                } label: { Text(account).font(.caption).lineLimit(1) }
                Menu {
                    Button("Hoy / este periodo") { choosePeriodDate(.now) }
                    if let latest = planning.latestMovementDate(store, account: account == "Todas" ? nil : account) { Button("Último mes con datos") { selectLatest(latest) } }
                } label: { Image(systemName: "calendar.badge.clock") }.accessibilityLabel("Ir al periodo actual o último mes con datos")
            }
            if let latest = planning.latestDataDate(store, account: account == "Todas" ? nil : account) {
                HStack {
                    Text("Último dato: " + planningDayLabel(latest)).font(.caption2).foregroundStyle(.secondary)
                    if !rows.isEmpty, !monthIsCovered(store, period: period, through: min(.now, period.end.addingTimeInterval(-1)), account: account == "Todas" ? nil : account) {
                        Text("Cobertura parcial").font(.caption2).foregroundStyle(Color.marcelitoAmber)
                    }
                }
            }
        }
    }
    private var totalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlanningMetric(title: "Gasto registrado", value: planningMoney(total), period: "", explanation: "Todo el gasto por fecha del cargo, incluidos viajes, extraordinarios y gastos compartidos, menos devoluciones. Excluye traspasos propios y pagos de tarjeta. Las compras MSI confirmadas se registran completas una vez; sus mensualidades son compromisos.")
            let c = Calendar.current
            let observedEnd = min(period.end, c.date(byAdding: .day, value: 1, to: c.startOfDay(for: .now))!)
            let days = max(0, c.dateComponents([.day], from: period.start, to: observedEnd).day ?? 0)
            let purchases = rows.filter { $0.expenseContribution > 0 }
            HStack(alignment: .top, spacing: 10) {
                PlanningMetric(title: "Promedio diario", value: days > 0 && monthIsCovered(store, period: period, through: observedEnd.addingTimeInterval(-1), account: account == "Todas" ? nil : account) ? planningMoney(total / Decimal(days)) : "Faltan días", period: "", explanation: "Gasto registrado del periodo / días transcurridos cubiertos. No convierte días sin estado en gasto cero.")
                PlanningMetric(title: "Movimientos", value: String(rows.count), period: "", explanation: "Movimientos de consumo y devoluciones del periodo seleccionado, incluyendo compras MSI confirmadas una vez.")
                PlanningMetric(title: "Ticket promedio", value: purchases.isEmpty ? "Sin cargos" : planningMoney(purchases.reduce(0) { $0 + $1.expenseContribution } / Decimal(purchases.count)), period: "", explanation: "Suma de cargos positivos / número de esos cargos. No utiliza devoluciones como cargos ni divide entre cero.")
            }
        }
    }
    private var comparisonSection: some View {
        Group {
            if mode == .month, let previous = Calendar.current.date(byAdding: .month, value: -1, to: period.start) {
                let c = Calendar.current
                let dayCount = c.isDate(selectedDate, equalTo: .now, toGranularity: .month) ? c.component(.day, from: .now) : c.range(of: .day, in: .month, for: selectedDate)!.count
                let previousPeriod = FinancePeriod.month(previous)
                let count = min(dayCount, c.range(of: .day, in: .month, for: previous)!.count)
                let range = FinancePeriod(start: previous, end: c.date(byAdding: .day, value: count, to: previous)!)
                let currentRange = FinancePeriod(start: period.start, end: c.date(byAdding: .day, value: count, to: period.start)!)
                let previousRows = planning.expenseRows(store, period: range).filter { account == "Todas" || $0.account == account }
                if !previousRows.isEmpty {
                    let old = previousRows.reduce(0) { $0 + $1.expenseContribution }
                    let current = rows.filter { currentRange.contains($0.date) }.reduce(0) { $0 + $1.expenseContribution }
                    let partial = !monthIsCovered(store, period: range, through: range.end.addingTimeInterval(-1), account: account == "Todas" ? nil : account)
                        || !monthIsCovered(store, period: currentRange, through: currentRange.end.addingTimeInterval(-1), account: account == "Todas" ? nil : account)
                    (Text("\(current >= old ? "+" : "−")\(planningMoney(abs(current - old))) vs \(range.label)")
                        + Text(partial ? " · parcial" : "").foregroundStyle(Color.marcelitoAmber)).font(.subheadline)
                } else { Text("Sin movimientos comparables de \(previousPeriod.label)").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Categorías").font(.headline)
            ForEach(Array((showAll ? categories : Array(categories.prefix(5))).enumerated()), id: \.element.0) { _, item in
                Button { selectedCategory = item.0; showCategories = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(item.0); Spacer(); Text(planningMoney(item.1)).monospacedDigit(); Text(total > 0 ? "\(Int((NSDecimalNumber(decimal: item.1 / total * 100).doubleValue).rounded()))%" : "—").font(.caption).foregroundStyle(.secondary) }
                        ProgressView(value: total > 0 ? min(1, max(0, NSDecimalNumber(decimal: item.1 / total).doubleValue)) : 0).tint(Color.marcelitoNavyMid)
                        Text(categoryComparison(item.0, actual: item.1)).font(.caption2).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
            if categories.count > 5 {
                if !showAll { LabeledContent("Otras categorías", value: planningMoney(categories.dropFirst(5).reduce(0) { $0 + $1.1 })).font(.subheadline) }
                Button(showAll ? "Ver menos" : "Ver todas las categorías") { showAll.toggle() }
            }
            Text(period.label).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func categoryComparison(_ category: String, actual: Decimal) -> String {
        guard mode == .month else { return "Toca para recategorizar movimientos" }
        let c = Calendar.current
        let sampleMonths = (1...3).compactMap { c.date(byAdding: .month, value: -$0, to: period.start) }
        let days = c.isDate(selectedDate, equalTo: .now, toGranularity: .month) ? c.component(.day, from: .now) : c.range(of: .day, in: .month, for: selectedDate)!.count
        let comparableDays = min(days, sampleMonths.map { c.range(of: .day, in: .month, for: $0)!.count }.min() ?? days)
        let comparableEnd = c.date(byAdding: .day, value: comparableDays, to: period.start)!
        let actualComparable = rows.filter { $0.date < comparableEnd && planning.category($0) == category }.reduce(0) { $0 + $1.expenseContribution }
        let samples: [Decimal] = sampleMonths.compactMap { date in
            let range = FinancePeriod(start: date, end: c.date(byAdding: .day, value: comparableDays, to: date)!)
            let r = planning.expenseRows(store, period: range).filter { account == "Todas" || $0.account == account }
            guard !r.isEmpty else { return nil }
            return r.filter { planning.category($0) == category }.reduce(0) { $0 + $1.expenseContribution }
        }
        guard !samples.isEmpty else { return "Sin promedio comparable" }
        let avg = samples.reduce(0, +) / Decimal(samples.count)
        guard avg > 0 else { return "Sin promedio comparable" }
        let change = (actualComparable - avg) / avg * 100
        return "\(change >= 0 ? "↑" : "↓") \(Int(NSDecimalNumber(decimal: abs(change)).doubleValue.rounded()))% vs tu promedio"
    }
    private var merchantsSection: some View {
        let merchants = Dictionary(grouping: rows, by: { planning.merchantLabel($0) }).map { ($0.key, $0.value.reduce(0) { $0 + $1.expenseContribution }) }.sorted { $0.1 > $1.1 }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Tus 10 comercios principales").font(.headline)
            ForEach(Array(merchants.prefix(10).enumerated()), id: \.offset) { _, merchant in HStack { Text(merchant.0).lineLimit(1); Spacer(); Text(planningMoney(merchant.1)).monospacedDigit() }.font(.subheadline) }
            Text(period.label).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var dailySection: some View {
        let c = Calendar.current
        let byDay = Dictionary(grouping: rows) { c.startOfDay(for: $0.date) }
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(mode == .year ? "Meses" : "Días") · \(period.label)").font(.headline)
            if mode == .year {
                ForEach(period.months(), id: \.self) { month in
                    let range = FinancePeriod.month(month)
                    let monthlyRows = rows.filter { range.contains($0.date) }
                    if monthlyRows.isEmpty {
                        HStack { Text(monthName(month).capitalized); Spacer(); Text(month > .now ? "Aún no inicia" : "Sin gastos cargados").foregroundStyle(.secondary) }.font(.subheadline)
                    } else {
                        NavigationLink { PersonalMovementList(title: range.label, rows: monthlyRows, period: range) } label: {
                            HStack { Text(monthName(month).capitalized); Spacer(); Text(planningMoney(monthlyRows.reduce(0) { $0 + $1.expenseContribution })).monospacedDigit() }
                        }.buttonStyle(.plain)
                    }
                    Divider()
                }
            } else if mode == .day { PersonalMovementRows(rows: rows, period: period) }
            else {
                ForEach(byDay.keys.sorted(by: >), id: \.self) { day in
                    let dailyRows = byDay[day, default: []]
                    let range = FinancePeriod(start: day, end: c.date(byAdding: .day, value: 1, to: day)!)
                    NavigationLink {
                        PersonalMovementList(title: range.label, rows: dailyRows, period: range)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(day, format: .dateTime.locale(Locale(identifier: "es_MX")).weekday(.wide).day().month(.abbreviated))
                                Text("\(dailyRows.count) movimientos").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(planningMoney(dailyRows.reduce(0) { $0 + $1.expenseContribution })).monospacedDigit()
                            Image(systemName: "chevron.right").font(.caption)
                        }
                    }.buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }
    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Desglose · \(period.label)").font(.headline)
            LabeledContent("Fijos", value: planningMoney(rows.filter { planning.isFixed($0) }.reduce(0) { $0 + $1.expenseContribution }))
            LabeledContent("Variables", value: planningMoney(rows.filter { !planning.isFixed($0) }.reduce(0) { $0 + $1.expenseContribution }))
            NavigationLink("Quién debe qué") { SharedReceivablesView() }
        }.font(.subheadline)
    }
    private var accumulatedChart: some View {
        let points = chartPoints()
        return VStack(alignment: .leading, spacing: 8) {
            HStack { Text(mode == .year ? "Gasto por mes" : "Gasto acumulado").font(.headline); CalculationHelp(explanation: "Todo el gasto por fecha del cargo, menos devoluciones. La línea discontinua es tu presupuesto ordinario y puede excluir gastos etiquetados; incluye el principal completo de MSI en el mes de compra. Presupuesto muestra por separado sus mensualidades. Los puntos indican fines de semana.") }
            Chart(points) { point in
                if mode == .year { BarMark(x: .value("Mes", point.date, unit: .month), y: .value("Gasto", point.spend)).foregroundStyle(Color.marcelitoNavy) }
                else { LineMark(x: .value("Fecha", point.date), y: .value("Gasto acumulado", point.spend)).foregroundStyle(Color.marcelitoNavy) }
                if let budget = point.budget { LineMark(x: .value("Fecha", point.date), y: .value("Presupuesto", budget), series: .value("Serie", "Presupuesto")).foregroundStyle(Color.marcelitoNavySoft).lineStyle(StrokeStyle(dash: [4, 4])) }
                if mode != .year && Calendar.current.isDateInWeekend(point.date) { PointMark(x: .value("Fin de semana", point.date), y: .value("Gasto", point.spend)).foregroundStyle(Color.marcelitoAmber).symbolSize(12) }
            }.chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in if mode == .year { AxisValueLabel(format: .dateTime.locale(Locale(identifier: "es_MX")).month(.abbreviated)) }
                else { AxisValueLabel(format: .dateTime.locale(Locale(identifier: "es_MX")).day().month(.abbreviated)) } } }.frame(height: 155)
            Text(period.label + (mode == .year ? " · solo meses con gastos cargados" : " · puntos ámbar: fines de semana")).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func chartPoints() -> [PlanningChartPoint] {
        let c = Calendar.current
        let selectedRows = rows // evaluate the period/account projection once
        if mode == .year {
            let byMonth = Dictionary(grouping: selectedRows) { FinancePeriod.month($0.date).start }
            return period.months().compactMap { month in
                guard let monthlyRows = byMonth[month], !monthlyRows.isEmpty else { return nil }
                return PlanningChartPoint(date: month, spend: NSDecimalNumber(decimal: monthlyRows.reduce(0) { $0 + $1.expenseContribution }).doubleValue, budget: nil)
            }
        }
        let limit = min(period.end, c.date(byAdding: .day, value: 1, to: c.startOfDay(for: .now))!)
        guard period.start < limit else { return [] }
        let daily = selectedRows.reduce(into: [Date: Decimal]()) { values, row in values[c.startOfDay(for: row.date), default: 0] += row.expenseContribution }
        let observedPeriod = FinancePeriod(start: period.start, end: limit)
        let monthlyBudgets: [Date: Decimal] = account == "Todas" ? Dictionary(uniqueKeysWithValues: observedPeriod.months().map { ($0, planning.consumptionBudget(store, month: $0)) }) : [:]
        var day = period.start; var accumulated: Decimal = 0; var budget: Decimal = 0; var result: [PlanningChartPoint] = []
        while day < limit {
            accumulated += daily[c.startOfDay(for: day), default: 0]
            let totalBudget = monthlyBudgets[FinancePeriod.month(day).start, default: 0]
            budget += totalBudget / Decimal(c.range(of: .day, in: .month, for: day)!.count)
            result.append(PlanningChartPoint(date: day, spend: NSDecimalNumber(decimal: accumulated).doubleValue, budget: account == "Todas" && totalBudget > 0 ? NSDecimalNumber(decimal: budget).doubleValue : nil))
            day = c.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }

}
struct PlanningChartPoint: Identifiable { let date: Date; let spend: Double; let budget: Double?; var id: Date { date } }
struct PersonalMovementList: View {
    let title: String, rows: [Movement], period: FinancePeriod
    var body: some View { ScrollView { PersonalMovementRows(rows: rows, period: period).padding(18) }.navigationTitle(title) }
}
struct PersonalMovementRows: View {
    @Environment(FinanceStore.self) private var store
    @Environment(FinancialPlanningStore.self) private var planning
    let rows: [Movement], period: FinancePeriod
    var body: some View {
        LazyVStack(spacing: 10) {
            ForEach(rows) { movement in
                let loanInterest = store.loanSpendingProjection.interestLinks[movement.id]
                VStack(alignment: .leading, spacing: 4) {
                    NavigationLink {
                        if loanInterest != nil || store.movements.contains(where: { $0.id == movement.id }) { MovementDetailView(movement: movement) }
                        else { Text("Compra MSI registrada: \(movement.title)").padding() }
                    } label: {
                        HStack { Text(planning.merchantLabel(movement)).lineLimit(1); Spacer(); Text(planningMoney(movement.expenseContribution)).monospacedDigit() }
                    }.buttonStyle(.plain)
                    Text(movement.date, format: .dateTime.locale(Locale(identifier: "es_MX")).day().month(.abbreviated).year()).font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        if loanInterest != nil {
                            Text(planning.category(movement)).font(.caption)
                        } else {
                        Menu {
                            Section("Solo este movimiento") {
                                ForEach(personalExpenseCategories, id: \.self) { category in
                                    Button(category) {
                                        if store.movements.contains(where: { $0.id == movement.id }) { _ = store.updateCategory(for: movement, to: category, applyToMerchant: false) }
                                        else if let index = planning.state.installments.firstIndex(where: { $0.id == movement.id }) { planning.state.installments[index].category = category; planning.save() }
                                    }
                                }
                            }
                            if store.movements.contains(where: { $0.id == movement.id }) {
                                Section("Regla para este comercio") {
                                    ForEach(personalExpenseCategories, id: \.self) { category in
                                        Button(category) { _ = store.updateCategory(for: movement, to: category, applyToMerchant: true) }
                                            .disabled(!store.canApplyCategoryRule(for: movement, to: category))
                                    }
                                }
                            }
                        } label: { Label(planning.category(movement), systemImage: "pencil").font(.caption) }
                        }
                        Spacer()
                        Text(loanInterest != nil ? "Interés" : planning.isFixed(movement) ? "Fijo" : "Variable").font(.caption2).foregroundStyle(.secondary)
                    }
                    Divider()
                }
            }
        }
    }
}

struct BudgetView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(FinancialPlanningStore.self) private var planning
    @State private var section: BudgetWorkspaceSection = .plan
    @State private var month = Date.now
    @State private var periodMode: FinancePeriodMode = .month
    @State private var showPeriodPicker = false
    @State private var showIncome = false
    @State private var showDecision = false
    @State private var closeMessage: String?
    @State private var selectedGoalID: UUID?
    @State private var reopenConfirmation = false
    private var snapshot: BudgetSnapshot { planning.snapshot(store, month: month) }
    private var limits: [String: Decimal] { planning.limits(store, month: month) }
    private var fixed: [String: Decimal] { planning.fixedLimits(store, month: month) }
    private var actual: [String: Decimal] { planning.plan(for: month).closing?.categorySpent ?? planning.budgetCategoryTotals(store, period: .month(month)) }
    private var categories: [String] { Array(Set(personalExpenseCategories.filter { $0 != "Otros / Por revisar" }).union(limits.keys).union(fixed.keys)).sorted() }
    var body: some View {
        NavigationStack {
            Group {
                switch section {
                case .income: PlanningIncomeContent(month: month)
                case .fixed: RecurringChargesView(month: month)
                case .plan:
                    planContent
                }
            }.navigationTitle(section.title).background(MarcelitoAmbientBackground()).foregroundStyle(Color.marcelitoNavy)
                .safeAreaInset(edge: .top) {
                    VStack(spacing: 8) {
                        Picker("Sección de presupuesto", selection: $section) {
                            ForEach(BudgetWorkspaceSection.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("budget.configuration.tabs")
                        if section == .plan {
                            Picker("Periodo de presupuesto", selection: $periodMode) { Text("Mes").tag(FinancePeriodMode.month); Text("Año").tag(FinancePeriodMode.year) }.pickerStyle(.segmented)
                            PeriodNavigationBar(label: budgetPeriod.label, move: moveBudgetPeriod) { showPeriodPicker = true }
                            Text("Desliza aquí para cambiar de periodo").font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(.horizontal, 18).padding(.vertical, 6).background(.regularMaterial)
                }
                .sheet(isPresented: $showPeriodPicker) { PeriodSelectionSheet(mode: periodMode, date: month) { month = $0 } }
                .sheet(isPresented: $showIncome) { PlanningIncomeView(month: month) }
                .sheet(isPresented: $showDecision) { AffordabilityView(month: month) }
                .onDisappear { planning.savePendingPlanChanges() }
                .onChange(of: section) { _, _ in planning.savePendingPlanChanges() }
                .onChange(of: month) { _, _ in planning.savePendingPlanChanges() }
                .alert("Cierre mensual", isPresented: Binding(get: { closeMessage != nil }, set: { if !$0 { closeMessage = nil } })) { Button("Aceptar") { closeMessage = nil } } message: { Text(closeMessage ?? "") }
        }
    }
    private var planContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if periodMode == .year { annualBudgetSummary }
                else {
                    Text(snapshot.period.label + " · mes natural").font(.caption).foregroundStyle(.secondary)
                    budgetSummary
                    Button("Configurar ingresos y depósitos") { section = .income }
                    if !snapshot.hasData { Text("Sin movimientos de este mes. Define tu plan; el gasto se actualizará al subir estados o capturas.").font(.caption).foregroundStyle(.secondary) }
                    SharedMonthlyPlanEditor(month: month)
                    PlanningAccountCoverage(period: .month(month))
                    if !planning.proposals(store, month: month).isEmpty { Text("Propuesta: mediana de " + planning.proposalMonths(store, before: month).reversed().map { FinancePeriod.month($0).label }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                    if planning.proposals(store, month: month).isEmpty {
                        Text("Necesitamos tres meses naturales completos para proponer la mediana variable. Puedes definir tus montos ahora.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Fijos").font(.headline)
                    if fixed.isEmpty { Text("Agrega o confirma tus gastos fijos en la pestaña Gastos fijos.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(categories.filter { fixed[$0] != nil }, id: \.self) { budgetRow($0, fixed: true) }
                    Text("Variables").font(.headline)
                    ForEach(categories, id: \.self) { budgetRow($0, fixed: false) }
                    if planning.plan(for: month).closed { Text("Mes cerrado. Los importes guardados se conservan; reabre el cierre para hacer cambios.").font(.caption) }
                    let planned = limits.values.reduce(0, +) + fixed.values.reduce(0, +)
                    if let income = snapshot.income, let loans = snapshot.loans {
                        PlanningMetric(title: "Ahorro con este plan", value: planningMoney(income - planned - snapshot.msi - loans), period: snapshot.period.label, explanation: "Ingreso mensual confirmado menos límites de categorías, mensualidades MSI y reserva para préstamos. Cambia en vivo con los sliders. La meta de ahorro es un objetivo y no un gasto adicional en esta cifra.")
                    }
                    installmentSection
                    if !store.loanLedger.state.accounts.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Préstamos").font(.headline)
                            LabeledContent("Cuotas y abonos previstos", value: snapshot.loans.map { "~" + planningMoney($0) } ?? "Falta valor UDI")
                            LabeledContent("Abonos bancarios vinculados", value: planningMoney(store.loanPaid(in: snapshot.period)))
                            Text("La reserva usa la cuota del mes más el extra que configures, o el total pagado si es mayor. Los intereses vinculados no se descuentan otra vez como variables.").font(.caption).foregroundStyle(.secondary)
                            NavigationLink("Ver préstamos y configurar abono extra") { LoanAccountsView() }
                        }
                    }
                    closingSection
                    Button("¿Me alcanza?") { showDecision = true }.buttonStyle(.marcelitoPrimary)
                    Button("Configurar gastos fijos y recurrentes") { section = .fixed }
                    NavigationLink("Metas de ahorro") { SavingsGoalsView() }
                    PlanningReminderToggle()
                }
            }.padding(18)
        }
    }
    private var budgetPeriod: FinancePeriod { .selected(periodMode, date: month, from: month, through: month) }
    private func moveBudgetPeriod(_ direction: Int) { month = budgetPeriod.shifted(by: direction, mode: periodMode).start }
    private var annualBudgetSummary: some View {
        let range = budgetPeriod
        let hasCharges = !planning.expenseRows(store, period: range).isEmpty
        return VStack(alignment: .leading, spacing: 16) {
            Text("Resumen anual · \(range.label)").font(.title3.bold())
            PlanningMetric(title: "Gasto registrado", value: hasCharges ? planningMoney(planning.total(store, period: range)) : "Sin gastos cargados", period: range.label, explanation: "Todo el gasto registrado por fecha del cargo durante el año, incluidos viajes, extraordinarios y gastos compartidos, menos devoluciones. Excluye transferencias propias y pagos de tarjeta. Los meses sin datos no se suponen en cero.")
            Text("El presupuesto se guarda por mes. Toca un mes para editarlo.").font(.caption).foregroundStyle(.secondary)
            ForEach(range.months(), id: \.self) { value in
                let monthlyRange = FinancePeriod.month(value)
                let observed = !planning.expenseRows(store, period: monthlyRange).isEmpty
                let plan = planning.state.budgets[planning.monthKey(value)]
                Button { month = value; periodMode = .month } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(monthName(value).capitalized).fontWeight(.semibold); Spacer(); Text(observed ? planningMoney(planning.total(store, period: monthlyRange)) : "Sin datos"); Image(systemName: "chevron.right").font(.caption) }
                        if let plan {
                            Text("Meta de ahorro: \(planningMoney(plan.savingsTarget)) · límites guardados: \(planningMoney(plan.limits.values.reduce(0, +) + plan.fixedLimits.values.reduce(0, +)))").font(.caption).foregroundStyle(.secondary)
                        } else { Text("Sin plan mensual guardado").font(.caption).foregroundStyle(.secondary) }
                    }
                }.buttonStyle(.plain)
                Divider()
            }
        }
    }
    private var budgetSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let remaining = snapshot.remaining {
                PlanningMetric(title: "Disponible variable", value: planningMoney(remaining), period: snapshot.period.label, explanation: "Ingreso − fijos − exceso gastado en fijos − meta de ahorro − mensualidades MSI − reserva de préstamos − variable gastado + sobrante trasladado. Incluye viajes, extraordinarios y montos compartidos pendientes de cobro. Disponible provisional si faltan movimientos.")
                PlanningMetric(title: "Disponible por día", value: snapshot.daily.map(planningMoney) ?? "Mes terminado", period: snapshot.period.label, explanation: "Disponible variable restante / días restantes del mes, incluyendo hoy. Nunca divide entre cero.")
            } else if snapshot.hasUnknownLoans {
                Text("Completa el valor de UDI de tu préstamo para calcular el disponible").font(.headline)
                NavigationLink("Revisar préstamos") { LoanAccountsView() }
            } else if snapshot.hasUnknownCommitments {
                Text("Faltan las mensualidades de tus MSI para calcular el disponible").font(.headline)
            } else {
                Text("Configura tu ingreso para calcular el disponible").font(.headline)
                Button("Definir ingreso") { showIncome = true }
            }
            HStack { Text("Ingreso mensual"); Spacer(); Button(snapshot.income.map(planningMoney) ?? "Configurar") { showIncome = true } }
            LabeledContent("Fijos previstos", value: planningMoney(snapshot.fixed))
            if snapshot.fixedOverrun > 0 { LabeledContent("Exceso en gastos fijos", value: planningMoney(snapshot.fixedOverrun)) }

            if !store.loanLedger.state.accounts.isEmpty { LabeledContent("Reserva de préstamos", value: snapshot.loans.map { "~" + planningMoney($0) } ?? "Falta valor UDI") }
            LabeledContent("Mensualidades MSI", value: snapshot.hasUnknownCommitments ? "Falta detalle MSI" : planningMoney(snapshot.msi))
            if !monthIsCovered(store, period: snapshot.period, through: min(.now, snapshot.period.end.addingTimeInterval(-1))) { Text("Plan provisional · faltan movimientos por actualizar").font(.caption).foregroundStyle(Color.marcelitoAmber) }
            Text("Consumo y presupuesto por fecha del cargo. MSI: compra completa en Gastos; mensualidades como compromisos aquí.").font(.caption).foregroundStyle(.secondary)
        }.marcelitoCard(fill: Color.marcelitoCreamSoft, radius: 16, padding: 14)
    }
    private func budgetRow(_ category: String, fixed: Bool) -> some View {
        // Split into typed steps: the one-line form exceeded the CI
        // compiler's type-checking time limit.
        let limit: Decimal = fixed ? (self.fixed[category] ?? 0) : (limits[category] ?? 0)
        let spent: Decimal
        if let closing = planning.plan(for: month).closing {
            let fixedSpent: Decimal = closing.fixedSpent?[category] ?? 0
            let categorySpent: Decimal = closing.categorySpent?[category] ?? 0
            spent = fixed ? fixedSpent : categorySpent - fixedSpent
        } else {
            let totals: [String: Decimal] = planning.budgetCategoryTotals(store, period: .month(month), fixed: fixed)
            spent = totals[category] ?? 0
        }
        let ratio: Double
        if limit > 0 {
            ratio = NSDecimalNumber(decimal: spent / limit).doubleValue
        } else {
            ratio = spent > 0 ? 1 : 0
        }
        let c = Calendar.current
        let daysInMonth: Int = c.range(of: .day, in: .month, for: month)!.count
        let elapsed: Int = c.isDate(month, equalTo: .now, toGranularity: .month) ? c.component(.day, from: .now) : daysInMonth
        let expected: Double = Double(elapsed) / Double(daysInMonth)
        let color: Color
        if ratio > 1 || (ratio > expected * 1.25 && ratio > 0.8) {
            color = .marcelitoDanger
        } else if ratio > expected * 1.1 {
            color = .marcelitoAmber
        } else {
            color = .marcelitoSuccess
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack { Text(category).font(.subheadline.weight(.semibold)); Spacer(); Text(planningMoney(limit)).monospacedDigit() }
            Slider(value: Binding(get: { NSDecimalNumber(decimal: fixed ? self.fixed[category] ?? 0 : limits[category] ?? 0).doubleValue }, set: { value in
                var plan = planning.plan(for: month); if fixed { plan.fixedLimits[category] = Decimal(Int(value)) } else { plan.limits[category] = Decimal(Int(value)) }; planning.setPlan(plan, for: month, persist: false)
            }), in: 0...max(5000, NSDecimalNumber(decimal: max(limit, planning.monthlyIncome(for: month) ?? 0)).doubleValue), step: 50, onEditingChanged: { editing in if !editing { planning.savePendingPlanChanges() } }).tint(Color.marcelitoNavy).disabled(planning.plan(for: month).closed)
            ProgressView(value: min(1, max(0, ratio))).tint(color)
            Text("\(snapshot.hasData && actual[category] != nil ? planningMoney(spent) + " usados" : "Sin cargos registrados") · \(snapshot.period.label) · \(fixed ? "fijo" : "variable")").font(.caption2).foregroundStyle(.secondary)
            if ratio >= 0.8, elapsed < 20, c.isDate(month, equalTo: .now, toGranularity: .month), limit > 0 { Text("Ya usaste al menos 80% antes del día 20").font(.caption).foregroundStyle(Color.marcelitoAmber) }
        }
    }
    private var installmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compromisos MSI").font(.headline)
            ForEach(planning.state.installments.filter { $0.due(in: month) > 0 }) { plan in
                HStack { Text(plan.merchant); Spacer(); Text(planningMoney(plan.due(in: month))) }.font(.subheadline)
            }
            if planning.state.installments.isEmpty { Text("Registra una compra MSI desde su movimiento con el importe completo y el plazo real.").font(.caption).foregroundStyle(.secondary) }
            Text(snapshot.period.label).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var closingSection: some View {
        let range = FinancePeriod.month(month)
        let plan = planning.plan(for: month)
        let surplus = planning.cashSurplus(store, month: month)
        return VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Cierre mensual").font(.headline); CalculationHelp(explanation: "Se guarda una instantánea del ingreso, presupuesto y disponible. Las asignaciones a metas son registros del plan; no mueven dinero bancario. Reabrir revierte la asignación para evitar duplicarla.") }
            if let closing = plan.closing {
                Text("Cierre guardado el " + planningDayLabel(closing.recordedAt)).font(.caption)
                LabeledContent("Resultado de caja guardado", value: planningMoney(closing.surplus))
                Button("Reabrir y recalcular") { reopenConfirmation = true }
                    .confirmationDialog("¿Reabrir este cierre?", isPresented: $reopenConfirmation, titleVisibility: .visible) {
                        Button("Revertir asignación y reabrir", role: .destructive) { closeMessage = planning.reopenMonth(month) ? "Cierre reabierto. La asignación anterior se revirtió." : "No se pudo reabrir: revisa el saldo de la meta o el cierre del mes siguiente." }
                    } message: { Text("Se revierte el sobrante asignado. Podrás revisar los datos actuales y cerrar de nuevo.") }
            } else if plan.closed {
                Text("Cierre de una versión anterior, sin instantánea. Conservamos la asignación original; no se volverá a acreditar.").font(.caption)
            } else {
                Picker("Sobrante", selection: Binding(get: { plan.surplusDestination }, set: { destination in var updated = planning.plan(for: month); updated.surplusDestination = destination; planning.setPlan(updated, for: month) })) {
                    ForEach(SurplusDestination.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                if plan.surplusDestination == .savings {
                    Picker("Meta de destino", selection: $selectedGoalID) {
                        Text("Selecciona una meta").tag(nil as UUID?)
                        ForEach(planning.activeGoals) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if range.end > .now { Text("Disponible al terminar el mes y completar los movimientos.").font(.caption) }
                else if snapshot.hasUnknownLoans || snapshot.hasUnknownCommitments { Text("Completa tus préstamos y MSI antes de cerrar.").font(.caption) }
                else if !monthIsCovered(store, period: range, through: range.end.addingTimeInterval(-1)) { Text("Completa los estados del mes para confirmar el sobrante.").font(.caption) }
                else {
                    Text("Resultado de caja observado: " + planningMoney(surplus)).font(.subheadline)
                    Button("Confirmar destino y guardar cierre") {
                        closeMessage = planning.closeMonth(month, store: store, goalID: selectedGoalID) ? "Cierre y destino guardados. No se mueve dinero bancario." : "Revisa las transferencias pendientes y selecciona una meta de destino."
                    }
                }
            }
        }
    }
}

struct IncomeOverviewView: View {
    @Environment(FinancialPlanningStore.self) private var planning
    @Environment(FinanceStore.self) private var store
    @State private var edit = false
    let month: Date
    var body: some View {
        let range = FinancePeriod.month(month)
        let rows = store.realIncomeMovements.filter { range.contains($0.date) }
        List {
            Section(range.label) {
                LabeledContent("Ingreso habitual mensual", value: planning.monthlyIncome(for: month).map(planningMoney) ?? "Sin configurar")
                ForEach(planning.incomeSources(for: month)) { source in
                    LabeledContent(source.name, value: "\(planningMoney(source.amount)) · \(source.cadence)")
                }
                Button("Editar fuentes de ingreso") { edit = true }
                if rows.isEmpty { Text("No hay depósitos de este periodo.") }
                else { LabeledContent("Recibido", value: planningMoney(planning.observedIncome(store, period: range))) }
            }
            Section("Depósitos · excluye transferencias propias") {
                ForEach(rows) { row in NavigationLink { MovementDetailView(movement: row) } label: { VStack(alignment: .leading) { Text(row.title); Text("\(planningMoney(abs(row.amount))) · \(row.account)").font(.caption) } } }
            }
        }.navigationTitle("Ingresos").sheet(isPresented: $edit) { PlanningIncomeView(month: month) }
    }
}

struct MovementPlanningLabels: View {
    @Environment(FinancialPlanningStore.self) private var planning
    let movement: Movement
    @State private var person = ""
    @State private var share = ""
    @State private var showMSI = false
    @State private var message: String?
    var body: some View {
        Section("Etiquetas para presupuesto") {
            Toggle("Extraordinario", isOn: Binding(get: { planning.isExtraordinary(movement) }, set: { value in var l = planning.label(for: movement); l.extraordinary = value; planning.setLabel(l, for: movement) }))
            Toggle("Gasto fijo", isOn: Binding(get: { planning.isFixed(movement) }, set: { value in var l = planning.label(for: movement); l.fixed = value; planning.setLabel(l, for: movement) }))
            TextField("Por cobrar / compartido · persona", text: $person)
            TextField("Parte que debe · MXN", text: $share).keyboardType(.decimalPad)
            Button("Guardar parte compartida") {
                guard let amount = parsePlanningAmount(share), amount <= max(0, movement.expenseContribution), amount == 0 || !person.trimmingCharacters(in: .whitespaces).isEmpty else { message = "Indica la persona y un importe no mayor al gasto."; return }
                var l = planning.label(for: movement); l.sharedPerson = person; l.sharedAmount = amount; planning.setLabel(l, for: movement)
                message = "Parte compartida guardada en Por cobrar. El gasto completo sigue visible en Gastos."
            }
            Button(planning.isInstallmentRow(movement) ? "Ver compra MSI registrada" : "Registrar compra a MSI") { showMSI = true }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            CalculationHelp(explanation: "En Gastos siempre se muestra el importe completo, incluidos viajes, extraordinarios y gastos compartidos. Las etiquetas se conservan para planear el presupuesto y llevar lo que te deben. Por cobrar conserva quién te debe y cuánto; marcarlo como cobrado reduce esa cuenta pendiente.")
        }.onAppear { let l = planning.label(for: movement); person = l.sharedPerson; share = NSDecimalNumber(decimal: l.sharedAmount).stringValue }
            .sheet(isPresented: $showMSI) { InstallmentEditor(movement: movement) }
    }
}
struct SharedReceivablesView: View {
    @Environment(FinancialPlanningStore.self) private var planning
    @Environment(FinanceStore.self) private var store
    var body: some View {
        let rows = store.movements.filter { planning.label(for: $0).sharedAmount > 0 }
        List {
            if rows.isEmpty { Text("Marca la parte compartida y la persona desde un movimiento.") }
            ForEach(rows) { row in
                let label = planning.label(for: row)
                VStack(alignment: .leading, spacing: 6) {
                    Text(label.sharedPerson).font(.headline)
                    Text("Debe \(planningMoney(label.outstanding)) · \(row.title)").font(.subheadline)
                    Text(row.date, format: .dateTime.locale(Locale(identifier: "es_MX")).day().month().year()).font(.caption)
                    Button(label.outstanding > 0 ? "Marcar como cobrado" : "Cobrado") {
                        var l = planning.label(for: row); l.collectedAmount = l.sharedAmount; planning.setLabel(l, for: row)
                    }.disabled(label.outstanding == 0)
                }
            }
        }.navigationTitle("Por cobrar / compartido")
    }
}
struct InstallmentEditor: View {
    @Environment(FinancialPlanningStore.self) private var planning
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let movement: Movement
    @State private var total = ""
    @State private var monthly = ""
    @State private var count = 3
    @State private var purchase = Date.now
    @State private var firstDue = Date.now
    @State private var linked = Set<UUID>()
    @State private var allPlansConfirmed = false
    @State private var purchaseDateConfirmed = false
    @State private var error: String?
    private var existing: InstallmentCommitment? { planning.state.installments.first { $0.linkedMovementIDs.contains(movement.id) } }
    var body: some View {
        NavigationStack {
            Form {
                Section("Compra completa · datos confirmados") {
                    Text(movement.displayMerchant ?? movement.title)
                    TextField("Importe original completo MXN", text: $total).keyboardType(.decimalPad)
                    TextField("Mensualidad real MXN", text: $monthly).keyboardType(.decimalPad)
                    Stepper("\(count) mensualidades", value: $count, in: 2...60)
                    DatePicker("Fecha de compra", selection: $purchase, in: ...Date.now, displayedComponents: .date)
                    Toggle("Confirmo la fecha original de compra", isOn: $purchaseDateConfirmed)
                    DatePicker("Mes de primera mensualidad", selection: $firstDue, displayedComponents: .date)
                    Text("La compra se registra completa en esa fecha. Los cargos vinculados se sustituyen por compromisos; no se suman otra vez al consumo.").font(.caption)
                }
                Toggle("Ya registré todas las compras MSI de esta cuenta", isOn: $allPlansConfirmed)
                Section("Vincula únicamente cargos de esta misma compra") {
                    ForEach(store.netExpenseMovements.filter { $0.account == movement.account && ($0.id == movement.id || $0.kind == .msi) }) { row in
                        Toggle(isOn: Binding(get: { linked.contains(row.id) }, set: { on in if on { linked.insert(row.id) } else { linked.remove(row.id) } })) {
                            Text("\(row.title) · \(planningMoney(abs(row.amount)))").font(.caption)
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(Color.marcelitoDanger) }
                Button("Guardar MSI") {
                    guard let original = parsePlanningAmount(total), let payment = parsePlanningAmount(monthly), original > 0, payment > 0,
                          payment * Decimal(count - 1) < original, payment * Decimal(count) >= original, !linked.isEmpty, purchaseDateConfirmed, purchase <= .now, FinancePeriod.month(firstDue).start >= FinancePeriod.month(purchase).start else { error = "Confirma la fecha original, importe, mensualidad, plazo y sus cargos. El total debe corresponder al plazo indicado."; return }
                    guard !planning.state.installments.contains(where: { other in other.id != existing?.id && !Set(other.linkedMovementIDs).isDisjoint(with: linked) }) else { error = "Uno de estos cargos ya pertenece a otra compra MSI."; return }
                    let rows = store.movements.filter { linked.contains($0.id) }
                    let account = movement.statementId.flatMap { id in store.statements.first { $0.id == id }?.accountKey } ?? movement.account
                    if allPlansConfirmed { if !planning.state.completeMSIAccounts.contains(account) { planning.state.completeMSIAccounts.append(account) } }
                    else { planning.state.completeMSIAccounts.removeAll { $0 == account } }
                    let plan = InstallmentCommitment(id: existing?.id ?? UUID(), merchant: movement.displayMerchant ?? movement.title, account: account, purchaseDate: purchase, total: original, monthly: payment, count: count, firstDueMonth: firstDue, linkedMovementIDs: Array(linked), linkedIdentities: rows.map { planning.identity($0) }, category: planning.category(movement))
                    if let index = planning.state.installments.firstIndex(where: { $0.id == plan.id }) { planning.state.installments[index] = plan } else { planning.state.installments.append(plan) }
                    planning.state.labels[plan.id.uuidString] = planning.label(for: movement)
                    if planning.save() { dismiss() }
                }.buttonStyle(.marcelitoPrimary)
            }.navigationTitle("Compra a MSI").toolbar { Button("Cerrar") { dismiss() } }
        }.onAppear {
            let account = movement.statementId.flatMap { id in store.statements.first { $0.id == id }?.accountKey } ?? movement.account
            allPlansConfirmed = planning.state.completeMSIAccounts.contains(account)
            if let existing { purchaseDateConfirmed = true; total = NSDecimalNumber(decimal: existing.total).stringValue; monthly = NSDecimalNumber(decimal: existing.monthly).stringValue; count = existing.count; purchase = existing.purchaseDate; firstDue = existing.firstDueMonth; linked = Set(existing.linkedMovementIDs) }
            else { purchase = movement.date; firstDue = movement.date; linked = [movement.id] }
        }
    }
}

struct AffordabilityView: View {
    @Environment(FinancialPlanningStore.self) private var planning
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let month: Date
    @State private var amount = ""
    @State private var installments = false
    @State private var count = 3
    @State private var fundingID: UUID?
    private var fundingAccounts: [StatementMetric] {
        Dictionary(grouping: store.periodMetrics) { $0.accountKey ?? $0.source }.values.compactMap { records in
            records.max { (store.statementCutoffDate(for: $0.id) ?? .distantPast) < (store.statementCutoffDate(for: $1.id) ?? .distantPast) }
        }.sorted { $0.source < $1.source }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("¿Me alcanza?") {
                    TextField("Importe MXN", text: $amount).keyboardType(.decimalPad)
                    Picker("Cuenta o tarjeta de pago", selection: $fundingID) {
                        Text("Selecciona una cuenta").tag(nil as UUID?)
                        ForEach(fundingAccounts) { metric in Text(metric.source + " · " + metric.period).tag(Optional(metric.id)) }
                    }
                    Toggle("Pagar a MSI", isOn: $installments)
                    if installments { Stepper("\(count) meses", value: $count, in: 2...36) }
                    Text("Simulación basada en tu ingreso y plan. No registra una compra ni considera comisiones de financiamiento.").font(.caption).foregroundStyle(.secondary)
                }
                if let value = parsePlanningAmount(amount), value > 0 {
                    if planning.monthlyIncome(for: month) == nil { Text("Configura tu ingreso para saber cómo queda tu disponible.") }
                    else {
                        if let metric = fundingAccounts.first(where: { $0.id == fundingID }) {
                            let balance = metric.kind == .card ? metric.creditAvailable : metric.cashBalance
                            if let balance {
                                LabeledContent(metric.kind == .card ? "Crédito al último corte" : "Efectivo al último corte", value: planningMoney(balance))
                                Text(balance >= value ? "El importe cabe en ese saldo registrado." : "El importe supera el saldo registrado.").font(.subheadline)
                                if installments && metric.kind != .card { Text("Selecciona una tarjeta para evaluar MSI.").font(.caption) }
                            } else { Text("Falta el saldo o crédito disponible de esta cuenta para evaluar la liquidez.").font(.caption) }
                            Text("Saldo al corte: " + (store.statementCutoffDate(for: metric.id).map(planningDayLabel) ?? "sin fecha confirmada") + ". Los movimientos posteriores pueden cambiarlo.").font(.caption).foregroundStyle(.secondary)
                        } else { Text("Selecciona la cuenta de pago para contrastar el presupuesto con su saldo registrado.").font(.caption) }
                        let monthly = installments ? value / Decimal(count) : value
                        Section("Después de esta compra") {
                            ForEach(0..<(installments ? count : 1), id: \.self) { offset in
                                let date = Calendar.current.date(byAdding: .month, value: offset, to: FinancePeriod.month(month).start)!
                                let snapshot = planning.snapshot(store, month: date)
                                let limit = planning.limits(store, month: date)
                                let plannedVariable = limit.values.reduce(0, +)
                                let baseline = offset == 0 ? snapshot.remaining : snapshot.available.map { $0 - plannedVariable }
                                HStack {
                                    Text(FinancePeriod.month(date).label)
                                    Spacer()
                                    Text(baseline.map { planningMoney($0 - monthly) } ?? (snapshot.hasUnknownLoans ? "Falta información del préstamo o UDI" : snapshot.hasUnknownCommitments ? "Falta detalle MSI" : "Sin ingreso para este mes")).foregroundStyle((baseline ?? 0) < monthly ? Color.marcelitoDanger : Color.marcelitoNavy)
                                }
                            }
                            Text("Estimación; el siguiente mes usa los límites definidos. Si no existe un plan de ese mes, el resultado aún no contempla todos sus gastos.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.navigationTitle("¿Me alcanza?").toolbar { Button("Cerrar") { dismiss() } }
        }
    }
}
struct AccountPlanningStatus: View {
    @Environment(FinancialPlanningStore.self) private var planning
    @Environment(FinanceStore.self) private var store
    let source: String, kind: StatementKind, accountKey: String?
    @State private var showTerms = false
    private var key: String { accountKey ?? source }
    private var latest: StatementRecord? { store.latestStatement(for: source, kind: kind, accountKey: accountKey) }
    var body: some View {
        let status = store.accountStatementStatus(for: source, kind: kind, accountKey: accountKey)
        VStack(alignment: .leading, spacing: 10) {
            if let cutoff = status.latestCutoff {
                let age = max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: cutoff), to: Calendar.current.startOfDay(for: .now)).day ?? 0)
                Text("Actualizado hace \(age) días · datos al \(cutoff.formatted(.dateTime.locale(Locale(identifier: "es_MX")).day().month().year()))").font(.caption).foregroundStyle(.secondary)
            } else { Text("Sin fecha de actualización disponible").font(.caption).foregroundStyle(.secondary) }
            if kind == .card {
                let terms = planning.state.cardTerms[key].flatMap { $0.statementID == latest?.id ? $0 : nil }
                let due = terms?.dueDate ?? latest?.summary?.paymentDueDate
                if let amount = latest?.summary?.paymentForNoInterest, let due {
                    let payment = latest.flatMap { store.cyclePayment($0, planning: planning) }
                    Text(payment?.remaining == 0 ? "Pago cubierto con movimientos registrados" : "Restante registrado: \(planningMoney(payment?.remaining ?? amount)) · vence el \(due.formatted(.dateTime.locale(Locale(identifier: "es_MX")).day().month()))").font(.headline)
                    NavigationLink("Ver pagos y vencimientos") { PaymentAgendaView() }
                    Text("\(latest.map(conciseStatementPeriod) ?? "Ciclo de corte") · confirma pagos recientes en el banco").font(.caption).foregroundStyle(.secondary)
                } else { Text("Confirma la fecha límite y el pago para no generar intereses en tu estado.").font(.caption) }
                Button("Fecha límite y tasa") { showTerms = true }
                let annual = terms?.annualRate ?? latest?.summary?.annualInterestRate
                if let rate = annual, let debt = latest?.summary?.revolvingBalance, let minimum = latest?.summary?.minimumPayment {
                    let estimate = max(0, debt - minimum) * rate / 12
                    Text("Solo el mínimo: ~\(planningMoney(estimate)) de intereses en un mes").font(.subheadline)
                    CalculationHelp(explanation: "Estimación simple: saldo revolvente pendiente después del mínimo × tasa anual confirmada / 12. No incluye IVA ni comisiones ni el cálculo diario del banco. No aplica a principal MSI.")
                } else { Text("Intereses del mínimo: falta tasa, saldo revolvente o pago mínimo confirmado.").font(.caption).foregroundStyle(.secondary) }
                let plans = planning.state.installments.filter { $0.account == key || $0.account == source }
                if !plans.isEmpty {
                    Text("MSI activos").font(.headline)
                    ForEach(plans.filter { $0.remaining(after: FinancePeriod.month(.now).start.addingTimeInterval(-1)) > 0 }) { item in
                        VStack(alignment: .leading) {
                            Text(item.merchant).font(.subheadline)
                            Text("\(planningMoney(item.due(in: .now))) este mes · \(item.remaining(after: FinancePeriod.month(.now).start.addingTimeInterval(-1))) mensualidades restantes").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if let pending = latest?.summary?.msiPending, pending > 0 {
                    Text("MSI pendientes: \(planningMoney(pending)) · falta el detalle por compra").font(.caption)
                }
                PlanningReminderToggle()
            }
        }.sheet(isPresented: $showTerms) { CardTermsEditor(accountKey: key, statement: latest) }
            .task(id: latest?.id) {
                guard kind == .card, let statement = latest, planning.state.cardTerms[key]?.statementID != statement.id,
                      let url = store.statementFileURL(for: statement) else { return }
                let metadata = await Task.detached(priority: .utility) { CardDocumentMetadata.read(url) }.value
                guard latest?.id == statement.id, planning.state.cardTerms[key]?.statementID != statement.id,
                      metadata.dueDate != nil || metadata.annualRate != nil else { return }
                planning.state.cardTerms[key] = CardPaymentTerms(statementID: statement.id, dueDate: metadata.dueDate, annualRate: metadata.annualRate)
                planning.save()
                await PlanningNotifications.refresh(store: store, planning: planning)
            }
    }
}
struct CardTermsEditor: View {
    @Environment(FinancialPlanningStore.self) private var planning
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let accountKey: String
    let statement: StatementRecord?
    @State private var due = Date.now
    @State private var rate = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Fecha límite de este estado", selection: $due, displayedComponents: .date)
                TextField("Tasa anual ordinaria % · opcional", text: $rate).keyboardType(.decimalPad)
                Text("Copia la tasa anual ordinaria de tu estado, no el CAT. No se estima desde el porcentaje de utilización.").font(.caption)
                if let error { Text(error).foregroundStyle(Color.marcelitoDanger) }
                Button("Guardar datos confirmados") {
                    let annual = rate.isEmpty ? nil : parsePlanningAmount(rate, precision: 4).map { $0 / 100 }
                    guard rate.isEmpty || annual != nil else { error = "La tasa debe ser un porcentaje válido."; return }
                    planning.state.cardTerms[accountKey] = CardPaymentTerms(statementID: statement?.id, dueDate: due, annualRate: annual)
                    planning.save()
                    Task { await PlanningNotifications.refresh(store: store, planning: planning) }
                    dismiss()
                }
            }.navigationTitle("Datos de pago").toolbar { Button("Cerrar") { dismiss() } }
        }.onAppear {
            let terms = planning.state.cardTerms[accountKey].flatMap { $0.statementID == statement?.id ? $0 : nil }
            due = terms?.dueDate ?? statement?.summary?.paymentDueDate ?? .now
            rate = (terms?.annualRate ?? statement?.summary?.annualInterestRate).map { NSDecimalNumber(decimal: $0 * 100).stringValue } ?? ""
        }
    }
}

struct LastRecordedMonthSummary: View {
    @Environment(FinanceStore.self) private var store
    @Environment(FinancialPlanningStore.self) private var planning
    let date: Date
    let showMovements: (Date, FinancePeriodMode) -> Void
    @State private var selectedDate: Date?
    @State private var mode: FinancePeriodMode = .month
    @State private var showPeriodPicker = false
    private var anchor: Date { selectedDate ?? date }
    private var period: FinancePeriod { .selected(mode, date: anchor, from: anchor, through: anchor) }
    private func movePeriod(_ direction: Int) { selectedDate = period.shifted(by: direction, mode: mode).start }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Actividad registrada").font(.headline)
            Picker("Periodo de actividad", selection: $mode) { Text("Mes").tag(FinancePeriodMode.month); Text("Año").tag(FinancePeriodMode.year) }.pickerStyle(.segmented)
            PeriodNavigationBar(label: period.label, move: movePeriod) { showPeriodPicker = true }
            if planning.hasData(store, period: period) {
                HStack(alignment: .top, spacing: 12) {
                    PlanningMetric(title: "Gasto registrado", value: planning.expenseRows(store, period: period).isEmpty ? "Sin cargos" : planningMoney(planning.total(store, period: period)), period: "", explanation: "Todo el gasto registrado por fecha del cargo, incluidos viajes, extraordinarios y gastos compartidos, menos devoluciones. Excluye transferencias propias y pagos de tarjeta; no representa actividad en tiempo real.")
                    PlanningMetric(title: "Ingreso recibido", value: store.realIncomeMovements.contains(where: { period.contains($0.date) }) ? planningMoney(planning.observedIncome(store, period: period)) : "Sin depósitos", period: "", explanation: "Depósitos reales del periodo seleccionado. El ingreso habitual de tus fuentes se utiliza por separado para planear.")
                }
                if !monthIsCovered(store, period: period, through: min(.now, period.end.addingTimeInterval(-1))) {
                    Text("Cobertura parcial").font(.caption).foregroundStyle(.secondary)
                }
                Button("Ver movimientos") { showMovements(anchor, mode) }.font(.subheadline.weight(.semibold))
            } else { Text("Sin movimientos cargados en \(period.label.lowercased()).").font(.subheadline).foregroundStyle(.secondary) }
        }.padding(.vertical, 6)
            .sheet(isPresented: $showPeriodPicker) { PeriodSelectionSheet(mode: mode, date: anchor) { selectedDate = $0 } }
    }
}

struct HomePersonalMetrics: View {
    var showActivity = true
    @Environment(FinanceStore.self) private var store
    @Environment(FinancialPlanningStore.self) private var planning
    @State private var showIncome = false
    @State private var showAccounts = false
    var body: some View {
        let period = FinancePeriod.month(.now)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                PlanningMetric(title: "Efectivo", value: store.dashboardIsBlocked ? "Por revisar" : store.cashAvailable.map(planningMoney) ?? "Falta estado", period: balancePeriodLabel(store, kind: .bank), explanation: "Suma de saldos de cuentas de débito en sus últimos cortes conciliados. No incluye crédito disponible.")
                PlanningMetric(title: "Deuda", value: store.dashboardIsBlocked ? "Por revisar" : store.debtTotal.map(planningMoney) ?? store.loanDebtUnavailableLabel, period: balancePeriodLabel(store, kind: .card), explanation: "Deuda de tarjetas más capital e intereses vencidos confirmados de préstamos. UDIS se convierte con el último valor fechado y confirmado; no agrega intereses futuros. Si falta el valor UDI, la deuda total queda pendiente. El principal MSI forma parte del saldo de tarjetas.")
            }
            if showActivity, planning.hasData(store, period: period), !store.operationalMetricsBlocked {
                HStack(alignment: .top, spacing: 12) {
                    PlanningMetric(title: "Gasto registrado", value: planning.expenseRows(store, period: period).isEmpty ? "Sin cargos" : planningMoney(planning.total(store, period: period)), period: period.label, explanation: "Todo el gasto por fecha del cargo, incluidos viajes, extraordinarios y gastos compartidos, menos devoluciones. Excluye transferencias propias y pagos de tarjeta. MSI se registra completo el día de compra.")
                    PlanningMetric(title: "Ingreso recibido", value: store.realIncomeMovements.contains(where: { period.contains($0.date) }) ? planningMoney(planning.observedIncome(store, period: period)) : "Sin depósitos", period: period.label, explanation: "Depósitos de ingreso real en débito, excluyendo traspasos propios, devoluciones y pagos de tarjetas. Puede ser parcial si falta actualizar cuentas.")
                }
                Button("Ver ingresos") { showIncome = true }.font(.caption)
            }
        }.sheet(isPresented: $showIncome) { NavigationStack { IncomeOverviewView(month: .now) } }
            .sheet(isPresented: $showAccounts) { AccountsView() }
    }
}

func balancePeriodLabel(_ store: FinanceStore, kind: StatementKind) -> String {
    let grouped = Dictionary(grouping: store.periodMetrics.filter { $0.kind == kind }, by: { $0.accountKey ?? $0.source })
    let dates = grouped.values.compactMap { $0.first.flatMap { store.statementCutoffDate(for: $0.id) } }.sorted()
    guard let last = dates.last else { return "Sin corte confirmado" }
    return "Corte al " + planningDayLabel(last)
}
