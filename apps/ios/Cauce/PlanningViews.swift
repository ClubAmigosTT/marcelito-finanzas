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
            Text(period).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct PlanningIncomeView: View {
    @Environment(FinancialPlanningStore.self) private var planning
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var editing: PlanningIncomeSource?
    @State private var deleting: PlanningIncomeSource?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Total habitual al mes", value: planning.monthlyIncome.map(planningMoney) ?? "Sin configurar")
                        .font(.headline)
                } footer: { Text("Se usa para planear tu presupuesto. Los depósitos realmente recibidos se muestran por separado.") }
                Section("Tus fuentes de ingreso") {
                    ForEach(planning.incomeSources) { source in
                        HStack {
                            Button { editing = source } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.name).foregroundStyle(Color.marcelitoNavy)
                                    Text("\(planningMoney(source.amount)) · \(source.cadence)" + (source.account.isEmpty ? "" : " · " + source.account)).font(.caption).foregroundStyle(.secondary)
                                    Text("\(planningMoney(source.monthlyAmount)) al mes").font(.caption).foregroundStyle(Color.marcelitoNavyMid)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Button { deleting = source } label: { Image(systemName: "trash").foregroundStyle(.secondary) }.buttonStyle(.borderless).accessibilityLabel("Eliminar \(source.name)")
                        }
                    }
                    Button { editing = PlanningIncomeSource(name: "", amount: 0, cadence: "Mensual") } label: { Label("Agregar ingreso", systemImage: "plus.circle") }
                } footer: {
                    if planning.state.incomeSources == nil, planning.state.incomeAmount != nil {
                        Text("Conservamos tu total anterior como Ingreso habitual. Si incluía varias fuentes, edítalo antes de agregarlas por separado para no sumarlas dos veces.")
                    }
                }
                let recurring = planning.incomeSuggestions(store)
                if !recurring.isEmpty {
                    Section("Sugerencias · confirma cada fuente") {
                        ForEach(recurring) { item in
                            Button {
                                editing = PlanningIncomeSource(name: item.name, amount: item.amount, cadence: item.cadence, account: item.movement.account, detectedKey: item.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name)
                                    Text("\(item.movement.account) · \(planningMoney(item.amount)) · \(item.cadence)").font(.caption)
                                    Text("Agregar como fuente").font(.caption.weight(.semibold))
                                }
                            }
                        }
                        Text("No se agregan automáticamente ni incluyen transferencias propias. Si falta una fuente, puedes agregarla manualmente.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Text(error).foregroundStyle(Color.marcelitoDanger) }
                if !planning.state.incomeOnboardingCompleted {
                    Button("Configurar después") { planning.state.incomeOnboardingCompleted = true; if planning.save() { dismiss() } }
                }
            }.navigationTitle("Ingresos").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Listo") { dismiss() } } }
                .sheet(item: $editing) { source in PlanningIncomeSourceEditor(source: source) }
                .confirmationDialog("¿Eliminar esta fuente de ingreso?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { source in
                    Button("Eliminar fuente", role: .destructive) {
                        if !planning.setIncomeSources(planning.incomeSources.filter { $0.id != source.id }) { error = "No se pudo guardar el cambio. Tu información se conserva." }
                        deleting = nil
                    }
                    Button("Cancelar", role: .cancel) { deleting = nil }
                } message: { _ in Text("Solo cambia tu ingreso habitual para presupuestar. Los depósitos y movimientos se conservan.") }
        }
    }
}
struct PlanningIncomeSourceEditor: View {
    @Environment(FinancialPlanningStore.self) private var planning
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let source: PlanningIncomeSource
    @State private var name = ""
    @State private var amount = ""
    @State private var cadence = "Mensual"
    @State private var account = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Fuente de ingreso") {
                    TextField("Nombre, por ejemplo Nómina Santander", text: $name)
                    TextField("Importe MXN", text: $amount).keyboardType(.decimalPad)
                    Picker("Frecuencia", selection: $cadence) { Text("Mensual").tag("Mensual"); Text("Quincenal").tag("Quincenal") }
                    Picker("Cuenta", selection: $account) {
                        Text("Sin asociar").tag("")
                        ForEach(Array(Set(store.movements.map(\.account) + store.statements.map(\.source) + [source.account])).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    if let value = parsePlanningAmount(amount) { LabeledContent("Equivalente mensual", value: planningMoney(cadence == "Quincenal" ? value * 2 : value)) }
                } footer: { Text("Quincenal equivale a dos pagos al mes. Registrar una fuente no crea depósitos ni cambia tus movimientos.") }
                if let error { Text(error).foregroundStyle(Color.marcelitoDanger) }
                Button("Guardar fuente") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, let number = parsePlanningAmount(amount) else { error = "Escribe un nombre y un importe válido."; return }
                    var updated = source; updated.name = trimmed; updated.amount = number; updated.cadence = cadence; updated.account = account
                    var sources = planning.incomeSources
                    if let index = sources.firstIndex(where: { $0.id == source.id }) { sources[index] = updated } else { sources.append(updated) }
                    if planning.setIncomeSources(sources) { dismiss() } else { error = "No se pudo guardar. Tu información anterior se conserva." }
                }.buttonStyle(.marcelitoPrimary)
            }.navigationTitle("Fuente de ingreso").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancelar") { dismiss() } } }
        }.onAppear { name = source.name; amount = source.name.isEmpty && source.amount == 0 ? "" : NSDecimalNumber(decimal: source.amount).stringValue; cadence = source.cadence; account = source.account }
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
                CalculationHelp(explanation: "Ingreso confirmado − gastos fijos presupuestados − meta de ahorro − mensualidades MSI − gasto variable personal. Sin movimientos del mes todavía no se conoce el restante real. Las cifras son provisionales cuando faltan estados o capturas.")
            }
            if store.operationalMetricsBlocked {
                Text("Revisa tus estados para calcular el disponible").font(.headline)
            } else if !snapshot.hasData {
                Text(planning.monthlyIncome == nil ? "Prepara tu presupuesto del mes" : "Tu presupuesto está preparado").font(.title3.bold())
                if let income = planning.monthlyIncome { Text("Ingreso habitual: \(planningMoney(income)) al mes").font(.subheadline) }
                Text("Los gastos de \(monthName(.now)) aparecerán al cargar movimientos.").font(.subheadline)
                if let latest = planning.latestMovementDate(store), !month.contains(latest) {
                    Button("Ver último mes con datos: \(monthName(latest)) →") { showLatest(latest) }.font(.subheadline.weight(.semibold)).tint(.white)
                }
                if planning.monthlyIncome == nil { Button("Configurar ingresos") { incomeSheet = true }.buttonStyle(.bordered).tint(.white) }
            } else if let remaining = snapshot.remaining {
                Text("\(planningMoney(remaining)) este mes · \(snapshot.daily.map(planningMoney) ?? "—") por día").font(.title2.bold()).monospacedDigit()
                if !monthIsCovered(store, period: month, through: .now) { Text("Disponible provisional · faltan movimientos por actualizar").font(.caption) }
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
                Text("Por estados y capturas · sin conexión en tiempo real").font(.caption2)
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
    private var personal: Decimal { rows.reduce(0) { $0 + planning.personalContribution($1) } }
    private var categories: [(String, Decimal)] {
        Dictionary(grouping: rows, by: { planning.category($0) }).map { ($0.key, $0.value.reduce(0) { $0 + planning.personalContribution($1) }) }.filter { $0.1 != 0 }.sorted { $0.1 > $1.1 }
    }
    private var selectedRows: [Movement] { rows.filter { selectedCategory == nil || planning.category($0) == selectedCategory } }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
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
                Text("Por fecha del cargo").font(.caption2).foregroundStyle(.secondary)
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
            PlanningMetric(title: "Consumo registrado", value: planningMoney(total), period: period.label, explanation: "Compras por fecha del cargo, menos devoluciones. Excluye traspasos propios y pagos de tarjeta. Las compras MSI confirmadas se registran completas una vez; sus mensualidades son compromisos.")
            PlanningMetric(title: "Gasto personal ordinario", value: planningMoney(personal), period: period.label, explanation: "Consumo menos viajes/extraordinarios y la parte compartida. El registro de quién debe qué conserva el importe pendiente por cobrar.")
            let c = Calendar.current
            let observedEnd = min(period.end, c.date(byAdding: .day, value: 1, to: c.startOfDay(for: .now))!)
            let days = max(0, c.dateComponents([.day], from: period.start, to: observedEnd).day ?? 0)
            let purchases = rows.filter { planning.personalContribution($0) > 0 }
            HStack(alignment: .top, spacing: 10) {
                PlanningMetric(title: "Promedio diario", value: days > 0 && monthIsCovered(store, period: period, through: observedEnd.addingTimeInterval(-1), account: account == "Todas" ? nil : account) ? planningMoney(personal / Decimal(days)) : "Faltan días", period: period.label, explanation: "Gasto personal del periodo / días transcurridos cubiertos. No convierte días sin estado en gasto cero.")
                PlanningMetric(title: "Movimientos", value: String(rows.count), period: period.label, explanation: "Movimientos de consumo y devoluciones del periodo seleccionado, incluyendo compras MSI confirmadas una vez.")
                PlanningMetric(title: "Ticket promedio", value: purchases.isEmpty ? "Sin cargos" : planningMoney(purchases.reduce(0) { $0 + planning.personalContribution($1) } / Decimal(purchases.count)), period: period.label, explanation: "Suma de cargos personales positivos / número de esos cargos. No utiliza devoluciones como cargos ni divide entre cero.")
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
                    let old = previousRows.reduce(0) { $0 + planning.personalContribution($1) }
                    let current = rows.filter { currentRange.contains($0.date) }.reduce(0) { $0 + planning.personalContribution($1) }
                    Text("\(current >= old ? "+" : "−")\(planningMoney(abs(current - old))) vs \(range.label)").font(.subheadline)
                    if !monthIsCovered(store, period: range, through: range.end.addingTimeInterval(-1), account: account == "Todas" ? nil : account) || !monthIsCovered(store, period: currentRange, through: currentRange.end.addingTimeInterval(-1), account: account == "Todas" ? nil : account) {
                        Text("Comparación parcial · faltan datos en uno o ambos periodos").font(.caption).foregroundStyle(Color.marcelitoAmber)
                    }
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
                        HStack { Text(item.0); Spacer(); Text(planningMoney(item.1)).monospacedDigit(); Text(personal > 0 ? "\(Int((NSDecimalNumber(decimal: item.1 / personal * 100).doubleValue).rounded()))%" : "—").font(.caption).foregroundStyle(.secondary) }
                        ProgressView(value: personal > 0 ? min(1, max(0, NSDecimalNumber(decimal: item.1 / personal).doubleValue)) : 0).tint(Color.marcelitoNavyMid)
                        Text(categoryComparison(item.0, actual: item.1)).font(.caption2).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
            if categories.count > 5 { Button(showAll ? "Ver menos" : "Ver todas las categorías") { showAll.toggle() } }
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
        let actualComparable = rows.filter { $0.date < comparableEnd && planning.category($0) == category }.reduce(0) { $0 + planning.personalContribution($1) }
        let samples: [Decimal] = sampleMonths.compactMap { date in
            let range = FinancePeriod(start: date, end: c.date(byAdding: .day, value: comparableDays, to: date)!)
            let r = planning.expenseRows(store, period: range).filter { account == "Todas" || $0.account == account }
            guard !r.isEmpty else { return nil }
            return r.filter { planning.category($0) == category }.reduce(0) { $0 + planning.personalContribution($1) }
        }
        guard !samples.isEmpty else { return "Sin promedio comparable" }
        let avg = samples.reduce(0, +) / Decimal(samples.count)
        guard avg > 0 else { return "Sin promedio comparable" }
        let change = (actualComparable - avg) / avg * 100
        return "\(change >= 0 ? "↑" : "↓") \(Int(NSDecimalNumber(decimal: abs(change)).doubleValue.rounded()))% vs tu promedio · días 1–\(comparableDays) · historial observado"
    }
    private var merchantsSection: some View {
        let merchants = Dictionary(grouping: rows, by: { planning.merchantLabel($0) }).map { ($0.key, $0.value.reduce(0) { $0 + planning.personalContribution($1) }) }.sorted { $0.1 > $1.1 }
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
                            HStack { Text(monthName(month).capitalized); Spacer(); Text(planningMoney(monthlyRows.reduce(0) { $0 + planning.personalContribution($1) })).monospacedDigit() }
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
                            Text(planningMoney(dailyRows.reduce(0) { $0 + planning.personalContribution($1) })).monospacedDigit()
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
            LabeledContent("Fijos", value: planningMoney(rows.filter { planning.isFixed($0) }.reduce(0) { $0 + planning.personalContribution($1) }))
            LabeledContent("Variables", value: planningMoney(rows.filter { !planning.isFixed($0) }.reduce(0) { $0 + planning.personalContribution($1) }))
            LabeledContent("Extraordinario / viajes / compartido", value: planningMoney(total - personal))
            NavigationLink("Quién debe qué") { SharedReceivablesView() }
        }.font(.subheadline)
    }
    private var accumulatedChart: some View {
        let points = chartPoints()
        return VStack(alignment: .leading, spacing: 8) {
            HStack { Text(mode == .year ? "Gasto personal por mes" : "Gasto personal acumulado").font(.headline); CalculationHelp(explanation: "Suma del consumo personal por fecha del cargo. La línea de presupuesto incluye el principal completo de MSI en el mes de compra; Presupuesto muestra por separado sus mensualidades. Los puntos indican fines de semana.") }
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
        if mode == .year {
            return period.months().compactMap { month in
                let monthlyRows = rows.filter { FinancePeriod.month(month).contains($0.date) }
                guard !monthlyRows.isEmpty else { return nil }
                return PlanningChartPoint(date: month, spend: NSDecimalNumber(decimal: monthlyRows.reduce(0) { $0 + planning.personalContribution($1) }).doubleValue, budget: nil)
            }
        }
        let c = Calendar.current; let limit = min(period.end, c.date(byAdding: .day, value: 1, to: c.startOfDay(for: .now))!)
        guard period.start < limit else { return [] }
        var day = period.start; var accumulated: Decimal = 0; var budget: Decimal = 0; var result: [PlanningChartPoint] = []
        while day < limit {
            accumulated += rows.filter { c.isDate($0.date, inSameDayAs: day) }.reduce(0) { $0 + planning.personalContribution($1) }
            let totalBudget = planning.consumptionBudget(store, month: day)
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
                VStack(alignment: .leading, spacing: 4) {
                    NavigationLink {
                        if store.movements.contains(where: { $0.id == movement.id }) { MovementDetailView(movement: movement) }
                        else { Text("Compra MSI registrada: \(movement.title)").padding() }
                    } label: {
                        HStack { Text(planning.merchantLabel(movement)).lineLimit(1); Spacer(); Text(planningMoney(movement.expenseContribution)).monospacedDigit() }
                    }.buttonStyle(.plain)
                    Text(movement.date, format: .dateTime.locale(Locale(identifier: "es_MX")).day().month(.abbreviated).year()).font(.caption2).foregroundStyle(.secondary)
                    HStack {
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
                        Spacer()
                        Text(planning.isFixed(movement) ? "Fijo" : "Variable").font(.caption2).foregroundStyle(.secondary)
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
    @State private var month = Date.now
    @State private var periodMode: FinancePeriodMode = .month
    @State private var showPeriodPicker = false
    @State private var showIncome = false
    @State private var savingsText = ""
    @State private var showDecision = false
    @State private var closeMessage: String?
    private var snapshot: BudgetSnapshot { planning.snapshot(store, month: month) }
    private var limits: [String: Decimal] { planning.limits(store, month: month) }
    private var fixed: [String: Decimal] { planning.fixedLimits(store, month: month) }
    private var actual: [String: Decimal] { planning.budgetCategoryTotals(store, period: .month(month)) }
    private var categories: [String] { Array(Set(personalExpenseCategories.filter { $0 != "Otros / Por revisar" }).union(limits.keys)).sorted() }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if periodMode == .year { annualBudgetSummary }
                    else {
                    Text(snapshot.period.label + " · mes natural").font(.caption).foregroundStyle(.secondary)
                    budgetSummary
                    NavigationLink("Ingresos y depósitos") { IncomeOverviewView(month: month) }
                    if !snapshot.hasData { Text("Sin movimientos de este mes. Define tu plan; el gasto se actualizará al subir estados o capturas.").font(.caption).foregroundStyle(.secondary) }
                    targetSection
                    if !planning.proposals(store, month: month).isEmpty { Text("Propuesta: mediana de " + planning.proposalMonths(store, before: month).reversed().map { FinancePeriod.month($0).label }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                    if planning.proposals(store, month: month).isEmpty {
                        Text("Necesitamos tres meses naturales completos para proponer la mediana variable. Puedes definir tus montos ahora.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Fijos").font(.headline)
                    if fixed.isEmpty { Text("Marca tus cargos fijos desde el detalle de un movimiento. Los importes del último mes observado se propondrán aquí.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(categories.filter { fixed[$0] != nil }, id: \.self) { budgetRow($0, fixed: true) }
                    Text("Variables").font(.headline)
                    ForEach(categories, id: \.self) { budgetRow($0, fixed: false) }
                    let planned = limits.values.reduce(0, +) + fixed.values.reduce(0, +)
                    if let income = planning.monthlyIncome {
                        PlanningMetric(title: "Ahorro con este plan", value: planningMoney(income - planned - snapshot.msi), period: snapshot.period.label, explanation: "Ingreso mensual confirmado menos límites de categorías y mensualidades MSI. Cambia en vivo con los sliders. La meta de ahorro es un objetivo y no un gasto adicional en esta cifra.")
                    }
                    installmentSection
                    closingSection
                    Button("¿Me alcanza?") { showDecision = true }.buttonStyle(.marcelitoPrimary)
                    NavigationLink("Suscripciones y recurrentes") { RecurringChargesView() }
                    NavigationLink("Metas de ahorro") { SavingsGoalsView() }
                    PlanningReminderToggle()
                    }
                }.padding(18)
            }.navigationTitle("Presupuesto").background(MarcelitoAmbientBackground()).foregroundStyle(Color.marcelitoNavy)
                .safeAreaInset(edge: .top) {
                    VStack(spacing: 4) {
                        Picker("Periodo de presupuesto", selection: $periodMode) { Text("Mes").tag(FinancePeriodMode.month); Text("Año").tag(FinancePeriodMode.year) }.pickerStyle(.segmented)
                        PeriodNavigationBar(label: budgetPeriod.label, move: moveBudgetPeriod) { showPeriodPicker = true }
                        Text("Desliza aquí para cambiar de periodo").font(.caption2).foregroundStyle(.secondary)
                    }.padding(.horizontal, 18).padding(.vertical, 6).background(.regularMaterial)
                }
                .sheet(isPresented: $showPeriodPicker) { PeriodSelectionSheet(mode: periodMode, date: month) { month = $0 } }
                .sheet(isPresented: $showIncome) { PlanningIncomeView() }
                .sheet(isPresented: $showDecision) { AffordabilityView(month: month) }
                .onAppear { loadTarget() }
                .onChange(of: month) { _, _ in loadTarget() }
                .alert("Cierre mensual", isPresented: Binding(get: { closeMessage != nil }, set: { if !$0 { closeMessage = nil } })) { Button("Aceptar") { closeMessage = nil } } message: { Text(closeMessage ?? "") }
        }
    }
    private var budgetPeriod: FinancePeriod { .selected(periodMode, date: month, from: month, through: month) }
    private func moveBudgetPeriod(_ direction: Int) { month = budgetPeriod.shifted(by: direction, mode: periodMode).start }
    private var annualBudgetSummary: some View {
        let range = budgetPeriod
        let hasCharges = !planning.expenseRows(store, period: range).isEmpty
        return VStack(alignment: .leading, spacing: 16) {
            Text("Resumen anual · \(range.label)").font(.title3.bold())
            PlanningMetric(title: "Gasto personal registrado", value: hasCharges ? planningMoney(planning.personalTotal(store, period: range)) : "Sin gastos cargados", period: range.label, explanation: "Consumo personal registrado por fecha del cargo durante el año. Los meses sin datos no se suponen en cero.")
            Text("El presupuesto se guarda por mes. Toca un mes para editarlo.").font(.caption).foregroundStyle(.secondary)
            ForEach(range.months(), id: \.self) { value in
                let monthlyRange = FinancePeriod.month(value)
                let observed = !planning.expenseRows(store, period: monthlyRange).isEmpty
                let plan = planning.state.budgets[planning.monthKey(value)]
                Button { month = value; periodMode = .month } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(monthName(value).capitalized).fontWeight(.semibold); Spacer(); Text(observed ? planningMoney(planning.personalTotal(store, period: monthlyRange)) : "Sin datos"); Image(systemName: "chevron.right").font(.caption) }
                        if let plan {
                            Text("Meta de ahorro: \(planningMoney(plan.savingsTarget)) · límites guardados: \(planningMoney(plan.limits.values.reduce(0, +) + plan.fixedLimits.values.reduce(0, +)))").font(.caption).foregroundStyle(.secondary)
                        } else { Text("Sin plan mensual guardado").font(.caption).foregroundStyle(.secondary) }
                    }
                }.buttonStyle(.plain)
                Divider()
            }
        }
    }
    private func loadTarget() { savingsText = NSDecimalNumber(decimal: planning.plan(for: month).savingsTarget).stringValue }
    private var budgetSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let remaining = snapshot.remaining {
                PlanningMetric(title: "Disponible variable", value: planningMoney(remaining), period: snapshot.period.label, explanation: "Ingreso − fijos − meta de ahorro − mensualidades MSI − variable gastado + sobrante trasladado. Los viajes, extraordinarios y la parte compartida se muestran aparte. Disponible provisional si faltan movimientos.")
                PlanningMetric(title: "Disponible por día", value: snapshot.daily.map(planningMoney) ?? "Mes terminado", period: snapshot.period.label, explanation: "Disponible variable restante / días restantes del mes, incluyendo hoy. Nunca divide entre cero.")
            } else if snapshot.hasUnknownCommitments {
                Text("Faltan las mensualidades de tus MSI para calcular el disponible").font(.headline)
            } else {
                Text("Configura tu ingreso para calcular el disponible").font(.headline)
                Button("Definir ingreso") { showIncome = true }
            }
            HStack { Text("Ingreso mensual"); Spacer(); Button(planning.monthlyIncome.map(planningMoney) ?? "Configurar") { showIncome = true } }
            LabeledContent("Fijos previstos", value: planningMoney(snapshot.fixed))
            if snapshot.hasData { LabeledContent("Fuera del presupuesto personal", value: planningMoney(planning.total(store, period: snapshot.period) - planning.personalTotal(store, period: snapshot.period))) }
            LabeledContent("Mensualidades MSI", value: snapshot.hasUnknownCommitments ? "Falta detalle MSI" : planningMoney(snapshot.msi))
            if !monthIsCovered(store, period: snapshot.period, through: min(.now, snapshot.period.end.addingTimeInterval(-1))) { Text("Plan provisional · faltan movimientos por actualizar").font(.caption).foregroundStyle(Color.marcelitoAmber) }
            Text("Consumo y presupuesto por fecha del cargo. MSI: compra completa en Gastos; mensualidades como compromisos aquí.").font(.caption).foregroundStyle(.secondary)
        }.marcelitoCard(fill: Color.marcelitoCreamSoft, radius: 16, padding: 14)
    }
    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Meta de ahorro del mes").font(.headline)
            HStack {
                TextField("Importe MXN", text: $savingsText).keyboardType(.decimalPad)
                Button("Guardar") { guard let number = parsePlanningAmount(savingsText) else { return }; var plan = planning.plan(for: month); plan.savingsTarget = number; planning.setPlan(plan, for: month) }
            }
        }
    }
    private func budgetRow(_ category: String, fixed: Bool) -> some View {
        let limit = fixed ? self.fixed[category] ?? 0 : limits[category] ?? 0
        let spent = planning.budgetCategoryTotals(store, period: .month(month), fixed: fixed)[category] ?? 0
        let ratio = limit > 0 ? NSDecimalNumber(decimal: spent / limit).doubleValue : (spent > 0 ? 1 : 0)
        let c = Calendar.current
        let elapsed = c.isDate(month, equalTo: .now, toGranularity: .month) ? c.component(.day, from: .now) : c.range(of: .day, in: .month, for: month)!.count
        let expected = Double(elapsed) / Double(c.range(of: .day, in: .month, for: month)!.count)
        let color: Color = ratio > 1 || (ratio > expected * 1.25 && ratio > 0.8) ? .marcelitoDanger : ratio > expected * 1.1 ? .marcelitoAmber : .marcelitoSuccess
        return VStack(alignment: .leading, spacing: 6) {
            HStack { Text(category).font(.subheadline.weight(.semibold)); Spacer(); Text(planningMoney(limit)).monospacedDigit() }
            Slider(value: Binding(get: { NSDecimalNumber(decimal: fixed ? self.fixed[category] ?? 0 : limits[category] ?? 0).doubleValue }, set: { value in
                var plan = planning.plan(for: month); if fixed { plan.fixedLimits[category] = Decimal(Int(value)) } else { plan.limits[category] = Decimal(Int(value)) }; planning.setPlan(plan, for: month)
            }), in: 0...max(5000, NSDecimalNumber(decimal: max(limit, planning.monthlyIncome ?? 0)).doubleValue), step: 50).tint(Color.marcelitoNavy)
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
        let income = planning.observedIncome(store, period: range)
        let spent = store.netExpenseMovements.filter { range.contains($0.date) && !planning.isInstallmentRow($0, store: store) }.reduce(0) { $0 + $1.expenseContribution }
        let surplus = income - spent - snapshot.msi
        return VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Cierre mensual").font(.headline); CalculationHelp(explanation: "Ingreso real recibido menos consumo de caja y mensualidades MSI. Para proponer ahorro aquí también se descuentan extraordinarios y partes compartidas que ya pagaste; marcar un cobro no crea dinero bancario. Es una asignación en el plan, no una transferencia ni prueba del saldo bancario.") }
            Picker("Sobrante", selection: Binding(get: { planning.plan(for: month).surplusDestination }, set: { destination in var plan = planning.plan(for: month); plan.surplusDestination = destination; planning.setPlan(plan, for: month) })) {
                ForEach(SurplusDestination.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if range.end > .now { Text("Disponible al terminar el mes y completar los movimientos.").font(.caption).foregroundStyle(.secondary) }
            else if snapshot.hasUnknownCommitments { Text("Completa las mensualidades MSI antes de cerrar el mes.").font(.caption).foregroundStyle(.secondary) }
            else if !monthIsCovered(store, period: range, through: range.end.addingTimeInterval(-1)) { Text("Completa los estados del mes para confirmar el sobrante.").font(.caption).foregroundStyle(.secondary) }
            else if surplus > 0 {
                Text("Podrías destinar \(planningMoney(surplus)) a \(planning.plan(for: month).surplusDestination == .savings ? (planning.state.goals.first?.name ?? "una meta de ahorro") : "tu próximo mes").").font(.subheadline)
                Button(planning.plan(for: month).closed ? "Cierre guardado" : "Confirmar destino del sobrante") {
                    closeMessage = planning.closeMonth(month, surplus: surplus) ? "Destino registrado. Es una asignación en tu plan; no mueve dinero del banco." : "Crea una meta de ahorro antes de confirmar."
                }.disabled(planning.plan(for: month).closed)
            } else { Text("No hay sobrante observado para asignar.").font(.caption) }
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
                LabeledContent("Ingreso habitual mensual", value: planning.monthlyIncome.map(planningMoney) ?? "Sin configurar")
                ForEach(planning.incomeSources) { source in
                    LabeledContent(source.name, value: "\(planningMoney(source.amount)) · \(source.cadence)")
                }
                Button("Editar fuentes de ingreso") { edit = true }
                if rows.isEmpty { Text("No hay depósitos de este periodo.") }
                else { LabeledContent("Recibido", value: planningMoney(planning.observedIncome(store, period: range))) }
            }
            Section("Depósitos · excluye transferencias propias") {
                ForEach(rows) { row in NavigationLink { MovementDetailView(movement: row) } label: { VStack(alignment: .leading) { Text(row.title); Text("\(planningMoney(abs(row.amount))) · \(row.account)").font(.caption) } } }
            }
        }.navigationTitle("Ingresos").sheet(isPresented: $edit) { PlanningIncomeView() }
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
        Section("Gasto personal y presupuesto") {
            Toggle("Extraordinario", isOn: Binding(get: { planning.isExtraordinary(movement) }, set: { value in var l = planning.label(for: movement); l.extraordinary = value; planning.setLabel(l, for: movement) }))
            Toggle("Gasto fijo", isOn: Binding(get: { planning.isFixed(movement) }, set: { value in var l = planning.label(for: movement); l.fixed = value; planning.setLabel(l, for: movement) }))
            TextField("Por cobrar / compartido · persona", text: $person)
            TextField("Parte que debe · MXN", text: $share).keyboardType(.decimalPad)
            Button("Guardar parte compartida") {
                guard let amount = parsePlanningAmount(share), amount <= max(0, movement.expenseContribution), amount == 0 || !person.trimmingCharacters(in: .whitespaces).isEmpty else { message = "Indica la persona y un importe no mayor al gasto."; return }
                var l = planning.label(for: movement); l.sharedPerson = person; l.sharedAmount = amount; planning.setLabel(l, for: movement)
                message = "Parte compartida guardada. Se excluye del gasto personal."
            }
            Button(planning.isInstallmentRow(movement) ? "Ver compra MSI registrada" : "Registrar compra a MSI") { showMSI = true }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            CalculationHelp(explanation: "Extraordinario y viaje se muestran en consumo total y se excluyen del presupuesto ordinario. Por cobrar excluye solo el importe asignado a la otra persona; cobrarlo reduce la cuenta pendiente y no convierte ese importe en consumo personal.")
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
    var body: some View {
        NavigationStack {
            Form {
                Section("¿Me alcanza?") {
                    TextField("Importe MXN", text: $amount).keyboardType(.decimalPad)
                    Toggle("Pagar a MSI", isOn: $installments)
                    if installments { Stepper("\(count) meses", value: $count, in: 2...36) }
                    Text("Simulación basada en tu ingreso y plan. No registra una compra ni considera comisiones de financiamiento.").font(.caption).foregroundStyle(.secondary)
                }
                if let value = parsePlanningAmount(amount), value > 0 {
                    if planning.monthlyIncome == nil { Text("Configura tu ingreso para saber cómo queda tu disponible.") }
                    else {
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
                                    Text(baseline.map { planningMoney($0 - monthly) } ?? (snapshot.hasUnknownCommitments ? "Falta detalle MSI" : "Sin ingreso")).foregroundStyle((baseline ?? 0) < monthly ? Color.marcelitoDanger : Color.marcelitoNavy)
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
struct RecurringChargesView: View {
    @Environment(FinancialPlanningStore.self) private var planning
    @Environment(FinanceStore.self) private var store
    var body: some View {
        let candidates = planning.recurring(store.realExpenseMovements.filter { !planning.isInstallmentRow($0, store: store) })
        List {
            Section {
                Text("Cargos con importe similar y periodicidad mensual o quincenal. Confirma cuáles son fijos.").font(.caption)
                if candidates.isEmpty { Text("Necesitamos al menos tres cargos comparables para detectar recurrentes.") }
            }
            ForEach(candidates) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.name).font(.headline)
                    Text("\(planningMoney(item.amount)) · \(item.cadence) · ~\(planningMoney(item.annualCost)) al año").font(.subheadline)
                    Button("Confirmar como gasto fijo") {
                        let key = store.categoryRuleKey(for: item.movement)
                        planning.state.fixedMerchantRules[planning.merchantKey(item.movement)] = true
                        for movement in store.netExpenseMovements where store.categoryRuleKey(for: movement) == key {
                            var label = planning.label(for: movement); label.fixed = true; planning.setLabel(label, for: movement)
                        }
                    }
                    CalculationHelp(explanation: "Mediana del importe de al menos tres cargos, separados entre 12–17 o 25–35 días, con variación máxima del 10%. Costo anual = importe × 24 o × 12. Es una sugerencia para revisar, no prueba de una suscripción.")
                }
            }
        }.navigationTitle("Recurrentes")
    }
}
struct SavingsGoalsView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(FinancialPlanningStore.self) private var planning
    @State private var name = "Fondo de emergencia"
    @State private var target = ""
    @State private var saved = ""
    @State private var contribution = ""
    @State private var error: String?
    var body: some View {
        List {
            ForEach(planning.state.goals) { goal in
                VStack(alignment: .leading, spacing: 6) {
                    Text(goal.name).font(.headline)
                    Text("\(planningMoney(goal.saved)) de \(planningMoney(goal.target))")
                    ProgressView(value: min(1, max(0, NSDecimalNumber(decimal: goal.target > 0 ? goal.saved / goal.target : 0).doubleValue)))
                    let contributions = planning.state.goals.reduce(Decimal(0)) { $0 + $1.monthlyContribution }
                    let weight = contributions > 0 ? goal.monthlyContribution / contributions : 1 / Decimal(max(1, planning.state.goals.count))
                    let observedRate = planning.observedOrdinarySavings(store, before: .now).map { $0 * weight }
                    if let rate = observedRate, rate > 0, let estimate = Calendar.current.date(byAdding: .month, value: Int(ceil(NSDecimalNumber(decimal: max(0, goal.target - goal.saved) / rate).doubleValue)), to: .now) {
                        Text("~\(FinancePeriod.month(estimate).label) al ritmo observado, repartido entre metas · \(planningMoney(rate))/mes").font(.caption)
                    } else if observedRate != nil {
                        Text(weight == 0 ? "Esta meta aún no tiene aportación prevista." : "Tu ritmo actual no genera ahorro para esta meta. Revisa tu presupuesto.").font(.caption).foregroundStyle(.secondary)
                    } else if let months = goal.estimatedMonths, let date = Calendar.current.date(byAdding: .month, value: months, to: .now) {
                        Text("~\(FinancePeriod.month(date).label) · si apartas \(planningMoney(goal.monthlyContribution)) al mes").font(.caption)
                    } else { Text("Define una aportación mensual para estimar la fecha.").font(.caption) }
                    CalculationHelp(explanation: "Meses estimados = redondeo hacia arriba de (meta − ahorro registrado) / aportación mensual. El ritmo observado usa ingreso recibido menos consumo total en los últimos meses completos disponibles, repartido según las aportaciones de tus metas (o en partes iguales cuando no están definidas). No supone rendimientos ni movimientos bancarios. Puedes ajustar la aportación cuando cambie tu ritmo.")
                }
            }
            Section("Agregar meta") {
                TextField("Meta · emergencia, viaje…", text: $name)
                TextField("Monto objetivo MXN", text: $target).keyboardType(.decimalPad)
                TextField("Ahorrado MXN", text: $saved).keyboardType(.decimalPad)
                TextField("Aportación mensual MXN", text: $contribution).keyboardType(.decimalPad)
                Button("Guardar meta") {
                    guard let total = parsePlanningAmount(target), total > 0, let current = parsePlanningAmount(saved), let monthly = parsePlanningAmount(contribution), !name.trimmingCharacters(in: .whitespaces).isEmpty else { error = "Completa el objetivo, ahorro actual y aportación mensual."; return }
                    planning.state.goals.append(SavingsGoal(name: name, target: total, saved: current, monthlyContribution: monthly)); planning.save(); target = ""; saved = ""; contribution = ""; error = nil
                }
                if let error { Text(error).foregroundStyle(Color.marcelitoDanger) }
            }
        }.navigationTitle("Metas de ahorro")
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
                    Text("Paga \(planningMoney(amount)) antes del \(due.formatted(.dateTime.locale(Locale(identifier: "es_MX")).day().month())) para no pagar intereses").font(.headline)
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
                    ForEach(plans.filter { $0.remaining(after: .now.addingTimeInterval(-86400 * 31)) > 0 }) { item in
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
                    PlanningMetric(title: "Gasto personal registrado", value: planning.expenseRows(store, period: period).isEmpty ? "Sin cargos" : planningMoney(planning.personalTotal(store, period: period)), period: period.label, explanation: "Gasto personal ordinario por fecha del cargo en el periodo seleccionado. Excluye transferencias propias y pagos de tarjeta; no representa actividad en tiempo real.")
                    PlanningMetric(title: "Ingreso recibido", value: store.realIncomeMovements.contains(where: { period.contains($0.date) }) ? planningMoney(planning.observedIncome(store, period: period)) : "Sin depósitos", period: period.label, explanation: "Depósitos reales del periodo seleccionado. El ingreso habitual de tus fuentes se utiliza por separado para planear.")
                }
                if !monthIsCovered(store, period: period, through: min(.now, period.end.addingTimeInterval(-1))) {
                    Text("Cobertura parcial · falta actualizar algunas cuentas").font(.caption).foregroundStyle(.secondary)
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
                PlanningMetric(title: "Deuda", value: store.dashboardIsBlocked ? "Por revisar" : store.debtTotal.map(planningMoney) ?? "Falta estado", period: balancePeriodLabel(store, kind: .card), explanation: "Deuda financiera declarada. Cuando existe límite y disponible, su diferencia incluye principal pendiente MSI. No es solo el pago de este mes.")
            }
            if showActivity, planning.hasData(store, period: period), !store.operationalMetricsBlocked {
                HStack(alignment: .top, spacing: 12) {
                    PlanningMetric(title: "Gasto personal", value: planning.expenseRows(store, period: period).isEmpty ? "Sin cargos" : planningMoney(planning.personalTotal(store, period: period)), period: period.label, explanation: "Consumo ordinario por fecha del cargo. Excluye transferencias propias, pagos de tarjeta, extraordinarios y la parte compartida. MSI se registra completo el día de compra.")
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
    guard let first = dates.first, let last = dates.last else { return "Sin corte confirmado" }
    let c = Calendar.current
    return "Cortes · " + FinancePeriod(start: c.startOfDay(for: first), end: c.date(byAdding: .day, value: 1, to: c.startOfDay(for: last))!).label
}
