import SwiftUI
import PDFKit
import UIKit
import Charts

func conciseStatementPeriod(_ statement: StatementRecord) -> String {
    let monthNames: [(token: String, label: String)] = [
        ("enero", "Enero"), ("ene", "Enero"),
        ("febrero", "Febrero"), ("feb", "Febrero"),
        ("marzo", "Marzo"), ("mar", "Marzo"),
        ("abril", "Abril"), ("abr", "Abril"),
        ("mayo", "Mayo"), ("may", "Mayo"),
        ("junio", "Junio"), ("jun", "Junio"),
        ("julio", "Julio"), ("jul", "Julio"),
        ("agosto", "Agosto"), ("ago", "Agosto"),
        ("septiembre", "Septiembre"), ("setiembre", "Septiembre"), ("sep", "Septiembre"), ("set", "Septiembre"),
        ("octubre", "Octubre"), ("oct", "Octubre"),
        ("noviembre", "Noviembre"), ("nov", "Noviembre"),
        ("diciembre", "Diciembre"), ("dic", "Diciembre")
    ]
    let source = "\(statement.period) \(statement.fileName)"
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .lowercased()
    var found: [String] = []
    for month in monthNames {
        guard source.range(of: "\\b\(month.token)\\b", options: .regularExpression) != nil else { continue }
        if !found.contains(month.label) { found.append(month.label) }
    }
    let year = source.range(of: "20\\d{2}", options: .regularExpression)
        .map { String(source[$0]) }
    if let first = found.first {
        let month: String
        if found.count > 1, let last = found.last {
            month = "\(first)–\(last)"
        } else {
            month = first
        }
        return year.map { "\(month) \($0)" } ?? month
    }
    let fallback = statement.period
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return fallback.count <= 24 && !fallback.isEmpty ? fallback : "Sin periodo"
}

struct MovementsView: View {
    @Environment(FinanceStore.self) private var store
    @State private var query = ""
    @State private var isAddPresented = false
    @State private var isAISettingsPresented = false
    @State private var isAIConfirmationPresented = false
    @State private var isAIProcessing = false
    @State private var aiMessage: String?
    @State private var aiErrorMessage: String?

    private var pendingForAI: [Movement] {
        store.movements.filter {
            $0.flow == .expense && ["Por revisar", "Sin categoría"].contains($0.category)
        }
    }

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
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(movement.title)
                                        .lineLimit(1)
                                    Text("\(movement.account) · \(statementLabel(for: movement))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(movement.date, format: .dateTime.day().month(.abbreviated).year())
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(movement.amount, format: .currency(code: "MXN"))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Comercio, banco o periodo")
            .navigationTitle("Movimientos")
            .listStyle(.insetGrouped)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isAddPresented = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Agregar movimiento")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isAISettingsPresented = true
                        } label: {
                            Label("Configurar clasificación IA", systemImage: "gearshape")
                        }
                        Button {
                            if ZenAPIKeyStore.apiKey == nil {
                                isAISettingsPresented = true
                            } else {
                                isAIConfirmationPresented = true
                            }
                        } label: {
                            Label("Clasificar pendientes (\(pendingForAI.count))", systemImage: "wand.and.stars")
                        }
                        .disabled(pendingForAI.isEmpty || isAIProcessing)
                    } label: {
                        if isAIProcessing {
                            ProgressView()
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                    }
                    .accessibilityLabel("Clasificación asistida por IA")
                }
            }
            .listRowBackground(Color.marcelitoCreamSoft)
            .foregroundStyle(Color.marcelitoNavy)
            .scrollContentBackground(.hidden)
            .background(Color.marcelitoCream)
            .sheet(isPresented: $isAddPresented) {
                AddMovementView()
            }
            .sheet(isPresented: $isAISettingsPresented) {
                AISettingsView()
            }
            .confirmationDialog(
                "Clasificar movimientos pendientes",
                isPresented: $isAIConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Clasificar \(pendingForAI.count) movimientos") {
                    classifyPending()
                }
                Button("Cancelar", role: .cancel) { }
            } message: {
                Text("Se enviarán al modelo gratuito de OpenCode Zen el comercio, cuenta, importe y fecha de estos movimientos. No se envían PDFs ni movimientos ya clasificados.")
            }
            .alert("Clasificación lista", isPresented: Binding(
                get: { aiMessage != nil },
                set: { if !$0 { aiMessage = nil } }
            )) {
                Button("Aceptar", role: .cancel) { aiMessage = nil }
            } message: {
                Text(aiMessage ?? "")
            }
            .alert("No se pudo clasificar", isPresented: Binding(
                get: { aiErrorMessage != nil },
                set: { if !$0 { aiErrorMessage = nil } }
            )) {
                Button("Aceptar", role: .cancel) { aiErrorMessage = nil }
                Button("Configurar IA") { isAISettingsPresented = true }
            } message: {
                Text(aiErrorMessage ?? "")
            }
        }
    }

    private func classifyPending() {
        guard let apiKey = ZenAPIKeyStore.apiKey else {
            isAISettingsPresented = true
            return
        }
        let items = pendingForAI
        guard !items.isEmpty else { return }
        let model = ZenAPIKeyStore.selectedModel
        isAIProcessing = true
        Task { @MainActor in
            do {
                let classifications = try await ZenExpenseClassifier.classify(
                    movements: items,
                    apiKey: apiKey,
                    model: model
                )
                store.applyAIClassifications(classifications)
                isAIProcessing = false
                aiMessage = classifications.isEmpty
                    ? "La IA no encontró categorías confiables. Puedes corregirlas manualmente."
                    : "Se actualizaron \(classifications.count) movimientos y Marcelito recordará esas categorías para próximos estados."
            } catch {
                isAIProcessing = false
                aiErrorMessage = error.localizedDescription
            }
        }
    }

    private func statementLabel(for movement: Movement) -> String {
        guard let statementId = movement.statementId,
              let statement = store.statements.first(where: { $0.id == statementId }) else {
            return "Manual"
        }
        return "\(statement.source) · \(conciseStatementPeriod(statement))"
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
        "Servicios", "Transporte", "Salud", "Compras", "Entretenimiento", "Educación",
        "Hogar", "Mascotas", "Finanzas", "Sin categoría"
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
            .foregroundStyle(Color.marcelitoNavy)
        }
    }
}

private struct MovementDetailView: View {
    @Environment(FinanceStore.self) private var store
    let movement: Movement
    @State private var selectedCategory: String
    @State private var selectedKind: MovementKind
    @State private var isTravel: Bool
    private let categories = ["Ingresos", "Transferencia", "Alimentos", "Viajes", "Comidas", "Servicios", "Transporte", "Salud", "Compras", "Entretenimiento", "Educación", "Hogar", "Mascotas", "Finanzas", "Sin categoría"]

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
                LabeledContent("Estado", value: "\(statement.source) · \(conciseStatementPeriod(statement))")
                LabeledContent("Archivo", value: statement.fileName)
            } else {
                LabeledContent("Estado", value: "Movimiento manual")
            }
            if let evidence = movement.extractionEvidence {
                let method = evidence.method == "vision-ocr" ? "OCR visual" : evidence.method == "pdf-text" ? "Texto del PDF" : evidence.method
                let page = evidence.page.map { " · página \($0)" } ?? ""
                LabeledContent("Origen de lectura", value: "\(method)\(page)")
                if let sourceText = evidence.sourceText, !sourceText.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Fragmento de origen")
                            .font(.caption)
                            .foregroundStyle(Color.marcelitoNavySoft)
                        Text(sourceText)
                            .font(.caption2)
                            .foregroundStyle(Color.marcelitoNavy)
                            .textSelection(.enabled)
                    }
                }
                if let bounds = evidence.bounds {
                    LabeledContent(
                        "Coordenadas",
                        value: String(
                            format: "x %.3f · y %.3f · w %.3f · h %.3f",
                            bounds.x,
                            bounds.y,
                            bounds.width,
                            bounds.height
                        )
                    )
                }
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
        .foregroundStyle(Color.marcelitoNavy)
        .scrollContentBackground(.hidden)
        .background(Color.marcelitoCream)
    }
}

struct ExpensesView: View {
    @Environment(FinanceStore.self) private var store
    @State private var selectedCategory: ExpenseCategorySelection?

    private var groups: [(category: String, amount: Decimal)] {
        Dictionary(grouping: store.currentPeriodExpenseMovements, by: { $0.category })
            .map { (category: $0.key, amount: $0.value.reduce(0) { $0 + abs($1.amount) }) }
            .sorted { $0.amount > $1.amount }
    }

    private var total: Decimal { groups.reduce(0) { $0 + $1.amount } }

    private func expenseShare(for amount: Decimal) -> String {
        guard total > 0 else { return "0%" }
        let percentage = NSDecimalNumber(decimal: (amount / total) * 100).doubleValue
        return "\(Int(percentage.rounded()))%"
    }

    private func expenseColor(for index: Int) -> Color {
        switch min(index, 2) {
        case 0: Color.marcelitoNavy
        case 1: Color.marcelitoNavyMid
        default: Color.marcelitoNavySoft
        }
    }

    @ViewBuilder
    private var identifiedExpensesSection: some View {
        Section("Gasto identificado") {
            ForEach(Array(groups.enumerated()), id: \.element.category) { index, item in
                ExpenseRow(name: item.category, amount: item.amount, share: expenseShare(for: item.amount), color: expenseColor(for: index)) {
                    selectedCategory = ExpenseCategorySelection(category: item.category)
                }
            }
        }
    }

    private var readingSection: some View {
        Section("Lectura") {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(groups.count) categorías explican")
                Text(total, format: .currency(code: "MXN").precision(.fractionLength(0)))
                    .font(.headline)
                Text("Puedes corregir el origen o la categoría desde Cuentas > Movimientos.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reconciliationSection: some View {
        Section("Conciliación") {
            LabeledContent("Gasto de viaje", value: store.travelSpend.formatted(.currency(code: "MXN").precision(.fractionLength(0))))
            LabeledContent("Gasto ordinario", value: store.ordinarySpend.formatted(.currency(code: "MXN").precision(.fractionLength(0))))
            LabeledContent("Gasto consolidado", value: store.consolidatedRealSpend.formatted(.currency(code: "MXN").precision(.fractionLength(0))))
            LabeledContent("Tasa de ahorro", value: store.savingsRate.map { "\(Int((NSDecimalNumber(decimal: $0).doubleValue * 100).rounded()))%" } ?? "Pendiente")
        }
    }

    @ViewBuilder
    private var expenseRows: some View {
        List {
            if store.dashboardIsBlocked {
                Section {
                    LedgerQualityBanner(store: store)
                    HistoricalDashboardBlockedCard(store: store)
                }
            } else if groups.isEmpty {
                ContentUnavailableView("Sin gastos", systemImage: "chart.pie", description: Text("Importa un estado de cuenta para construir tus categorías reales."))
            } else {
                identifiedExpensesSection
                readingSection
                reconciliationSection
            }
        }
    }
    var body: some View {
        NavigationStack {
            expenseRows
                .navigationTitle("Gastos")
                .listStyle(.insetGrouped)
                .listRowBackground(Color.marcelitoCreamSoft)
                .foregroundStyle(Color.marcelitoNavy)
                .scrollContentBackground(.hidden)
                .background(Color.marcelitoCream)
                .sheet(item: $selectedCategory) { selection in
                    ExpenseCategoryDetailView(category: selection.category, store: store)
                }
        }
    }
}

private struct ExpenseCategorySelection: Identifiable {
    let category: String
    var id: String { category }
}

private struct ExpenseRow: View {
    let name: String
    let amount: Decimal
    let share: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Circle().fill(color).frame(width: 10, height: 10).accessibilityHidden(true)
                Text(name)
                Spacer()
                Text(share).foregroundStyle(.secondary)
                Text(amount, format: .currency(code: "MXN").precision(.fractionLength(0))).monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Toca para ver el detalle y la tendencia de esta categoría")
    }
}

private struct ExpenseTrendPoint: Identifiable {
    let id: Date
    let date: Date
    let value: Double
}

private struct ExpenseMerchantSummary: Identifiable {
    let id: String
    let name: String
    let count: Int
    let total: Decimal
}

private struct ExpenseCategoryDetailView: View {
    let category: String
    let store: FinanceStore
    @Environment(\.dismiss) private var dismiss

    private var movements: [Movement] {
        store.currentPeriodExpenseMovements.filter { $0.category == category }
    }

    private var total: Decimal {
        movements.reduce(Decimal(0)) { $0 + abs($1.amount) }
    }

    private var points: [ExpenseTrendPoint] {
        let calendar = Calendar.current
        var byDay: [Date: Decimal] = [:]
        movements.forEach { movement in
            let day = calendar.startOfDay(for: movement.date)
            byDay[day, default: 0] += abs(movement.amount)
        }
        return byDay.keys.sorted().map { day in
            ExpenseTrendPoint(
                id: day,
                date: day,
                value: NSDecimalNumber(decimal: byDay[day, default: 0]).doubleValue
            )
        }
    }

    private var recurringMerchants: [ExpenseMerchantSummary] {
        var grouped: [String: ExpenseMerchantSummary] = [:]
        for movement in movements {
            let key = merchantKey(movement.title)
            let display = merchantDisplayName(movement.title)
            if let existing = grouped[key] {
                grouped[key] = ExpenseMerchantSummary(
                    id: key,
                    name: existing.name,
                    count: existing.count + 1,
                    total: existing.total + abs(movement.amount)
                )
            } else {
                grouped[key] = ExpenseMerchantSummary(
                    id: key,
                    name: display,
                    count: 1,
                    total: abs(movement.amount)
                )
            }
        }
        return grouped.values
            .sorted { left, right in
                if left.count != right.count { return left.count > right.count }
                return left.total > right.total
            }
            .prefix(5)
            .map { $0 }
    }

    private var highestMovements: [Movement] {
        Array(movements.sorted { abs($0.amount) > abs($1.amount) }.prefix(5))
    }

    private func merchantKey(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"\b(?:aut\.?|ref\.?|folio|no\.?|num\.?)\s*[:#-]?\s*[a-z0-9-]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b\d{2,}\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func merchantDisplayName(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: #"\b(?:aut\.?|ref\.?|folio|no\.?|num\.?)\s*[:#-]?\s*[a-z0-9-]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Sin descripción" : String(cleaned.prefix(44))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(category, systemImage: "chart.pie.fill")
                            .font(.headline)
                            .foregroundStyle(Color.marcelitoAmber)
                        Text(total, format: .currency(code: "MXN").precision(.fractionLength(0)))
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .monospacedDigit()
                        Text("\(movements.count) movimientos identificados en esta categoría.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if !recurringMerchants.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Gastos más recurrentes")
                                .font(.subheadline.weight(.semibold))
                            ForEach(recurringMerchants) { item in
                                HStack(spacing: 10) {
                                    Image(systemName: "repeat")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.marcelitoAmber)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                        Text(item.count == 1 ? "1 movimiento" : "\(item.count) movimientos")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Text(item.total, format: .currency(code: "MXN").precision(.fractionLength(0)))
                                        .font(.subheadline.monospacedDigit())
                                }
                            }
                        }
                        .padding(14)
                        .background(Color.marcelitoCreamSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    if !highestMovements.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Gastos más altos")
                                .font(.subheadline.weight(.semibold))
                            ForEach(highestMovements) { movement in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.marcelitoNavyMid)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(movement.title)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(2)
                                        Text(movement.date.formatted(.dateTime.day().month(.abbreviated)))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Text(abs(movement.amount), format: .currency(code: "MXN").precision(.fractionLength(0)))
                                        .font(.subheadline.monospacedDigit())
                                }
                            }
                        }
                        .padding(14)
                        .background(Color.marcelitoCreamSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    if points.isEmpty {
                        Text("Aún no hay fechas suficientes para mostrar una tendencia.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Comportamiento por fecha")
                                .font(.subheadline.weight(.semibold))
                            Chart {
                                ForEach(points) { point in
                                    LineMark(
                                        x: .value("Fecha", point.date),
                                        y: .value("Monto", point.value),
                                        series: .value("Serie", category)
                                    )
                                    .foregroundStyle(Color.marcelitoAmber)
                                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                                    PointMark(
                                        x: .value("Fecha", point.date),
                                        y: .value("Monto", point.value)
                                    )
                                    .foregroundStyle(Color.marcelitoAmber)
                                }
                            }
                            .chartXAxis {
                                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                                    AxisGridLine()
                                    AxisTick()
                                    AxisValueLabel()
                                }
                            }
                            .chartYAxis {
                                AxisMarks(position: .leading) { _ in
                                    AxisGridLine()
                                    AxisTick()
                                    AxisValueLabel()
                                }
                            }
                            .frame(height: 170)
                        }
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .background(Color.marcelitoCream.ignoresSafeArea())
            .navigationTitle("Detalle de gasto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.marcelitoCream)
    }
}

private struct AccountDisplayItem: Identifiable {
    let source: String
    let kind: StatementKind
    let accountKey: String?

    var id: String { "\(source)|\(kind.rawValue)|\(accountKey ?? "default")" }
}

private struct AccountSummaryRow: View {
    @Environment(FinanceStore.self) private var store

    let source: String
    let kind: StatementKind
    let accountKey: String?

    private var statement: StatementRecord? {
        store.latestStatement(for: source, kind: kind, accountKey: accountKey)
    }

    private var metric: StatementMetric? {
        guard let statementID = statement?.id else { return nil }
        return store.metric(for: statementID)
    }

    private var balanceText: String {
        if store.dashboardIsBlocked { return "Bloqueado" }
        guard let balance = kind == .card ? metric?.debtBalance : metric?.cashBalance else {
            return "Pendiente"
        }
        let formatted = balance.formatted(.currency(code: "MXN").precision(.fractionLength(0)))
        return kind == .card ? "−\(formatted)" : formatted
    }

    private var detailText: String {
        guard kind == .card else { return "Cuenta de efectivo" }
        let minimum = statement?.summary?.minimumPayment?.formatted(.currency(code: "MXN").precision(.fractionLength(0))) ?? "Pendiente"
        let noInterest = metric?.paymentForNoInterest?.formatted(.currency(code: "MXN").precision(.fractionLength(0))) ?? "Pendiente"
        return "Pago próximo: \(minimum) · No intereses: \(noInterest)"
    }

    var body: some View {
        NavigationLink {
            AccountDetailView(source: source, kind: kind, accountKey: accountKey)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Image(systemName: kind == .card ? "creditcard.fill" : "building.columns.fill")
                        .foregroundStyle(Color.marcelitoNavyMid)
                    Text(source + (accountKey.flatMap { $0.split(separator: ":").last }.map { " · ••••\(String($0))" } ?? ""))
                        .font(.headline)
                    Spacer()
                    Text(balanceText)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AccountsView: View {
    @Environment(FinanceStore.self) private var store

    private var displayedAccounts: [AccountDisplayItem] {
        let preferred = ["Santander", "BBVA", "Amex"]
        var seen = Set<String>()
        var result: [AccountDisplayItem] = []
        for statement in store.statements {
            let kind = statement.kind ?? (statement.source.localizedCaseInsensitiveContains("Amex") ? .card : .bank)
            let item = AccountDisplayItem(source: statement.source, kind: kind, accountKey: statement.accountKey)
            if seen.insert(item.id).inserted { result.append(item) }
        }
        return result.sorted { left, right in
            let leftRank = preferred.firstIndex(of: left.source) ?? preferred.count
            let rightRank = preferred.firstIndex(of: right.source) ?? preferred.count
            return leftRank != rightRank
                ? leftRank < rightRank
                : left.id.localizedCompare(right.id) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Cuentas") {
                    if store.dashboardIsBlocked {
                        LedgerQualityBanner(store: store)
                    }
                    ForEach(displayedAccounts) { account in
                        AccountSummaryRow(source: account.source, kind: account.kind, accountKey: account.accountKey)
                    }
                    NavigationLink {
                        MovementsView()
                    } label: {
                        Label("Movimientos", systemImage: "list.bullet.rectangle")
                    }
                }
                Section("Documentos importados") {
                    if store.statements.isEmpty {
                        Text("Aún no hay documentos importados. Usa el botón de carga en Resumen.")
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 142), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(store.statements) { statement in
                                NavigationLink {
                                    StatementDocumentView(statement: statement)
                                } label: {
                                    StatementDocumentTile(statement: statement)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 6)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
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
                                    Text("\(statement.source) · \(conciseStatementPeriod(statement))")
                                    Text("Saldos, pagos, crédito y MSI")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Cuentas")
            .listStyle(.insetGrouped)
            .listRowBackground(Color.marcelitoCreamSoft)
            .foregroundStyle(Color.marcelitoNavy)
            .scrollContentBackground(.hidden)
            .background(Color.marcelitoCream)
        }
    }
}

private struct AccountTrendPoint: Identifiable {
    let id: UUID
    let label: String
    let value: Double
}

private struct AccountDetailView: View {
    @Environment(FinanceStore.self) private var store
    let source: String
    let kind: StatementKind
    let accountKey: String?

    private var metrics: [StatementMetric] {
        store.periodMetrics
            .filter { $0.source == source && $0.kind == kind && $0.accountKey == accountKey }
            .reversed()
    }

    private var latest: StatementMetric? {
        metrics.last
    }

    private var balance: Decimal? {
        kind == .card ? latest?.debtBalance : latest?.cashBalance
    }

    private var trend: [AccountTrendPoint] {
        metrics.compactMap { metric in
            let value = kind == .card ? metric.debtBalance : metric.cashBalance
            guard let value else { return nil }
            return AccountTrendPoint(
                id: metric.id,
                label: metric.period,
                value: NSDecimalNumber(decimal: value).doubleValue
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(source, systemImage: kind == .card ? "creditcard.fill" : "building.columns.fill")
                .font(.headline)
                .foregroundStyle(Color.marcelitoNavyMid)
            Text(balance?.formatted(.currency(code: "MXN").precision(.fractionLength(0))) ?? "Pendiente")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color.marcelitoNavy)
            Text(kind == .card ? "Deuda registrada al último corte." : "Efectivo disponible al último corte.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var paymentSummary: some View {
        if let latest, kind == .card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Próxima decisión")
                    .font(.subheadline.weight(.semibold))
                LabeledContent("Pago para no generar intereses", value: latest.paymentForNoInterest?.formatted(.currency(code: "MXN").precision(.fractionLength(0))) ?? "Pendiente")
            }
            .foregroundStyle(Color.marcelitoNavy)
            .padding(16)
            .background(Color.marcelitoCreamSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder
    private var trendSection: some View {
        if store.dashboardIsBlocked {
            HistoricalDashboardBlockedCard(store: store)
        } else if trend.isEmpty {
            Text("Aún no hay suficientes cortes para mostrar una tendencia.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            AccountEvolutionChart(points: trend, source: source, kind: kind)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                paymentSummary
                trendSection
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .background(Color.marcelitoCream.ignoresSafeArea())
        .navigationTitle("Detalle de cuenta")
        .navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(Color.marcelitoNavy)
    }
}

private struct AccountEvolutionChart: View {
    let points: [AccountTrendPoint]
    let source: String
    let kind: StatementKind

    private var lineColor: Color {
        kind == .card ? Color.marcelitoNavy : Color.marcelitoNavyMid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Evolución por corte")
                .font(.subheadline.weight(.semibold))
            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("Periodo", point.label),
                        y: .value("Monto", point.value),
                        series: .value("Serie", source)
                    )
                    .foregroundStyle(lineColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    PointMark(
                        x: .value("Periodo", point.label),
                        y: .value("Monto", point.value)
                    )
                    .foregroundStyle(lineColor)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                }
            }
            .frame(height: 180)
        }
        .foregroundStyle(Color.marcelitoNavy)
    }
}

private struct StatementDocumentTile: View {
    let statement: StatementRecord

    private var iconName: String {
        statement.kind == .card || statement.source.localizedCaseInsensitiveContains("amex")
            ? "creditcard.fill"
            : "building.columns.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: iconName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.marcelitoNavyMid)
                    .frame(width: 28, height: 28)
                    .background(Color.marcelitoNavy.opacity(0.08), in: Circle())
                Spacer(minLength: 8)
                Image(systemName: statement.requiresReview ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(statement.requiresReview ? Color.marcelitoAmber : Color.marcelitoSuccess)
                    .accessibilityLabel(statement.requiresReview ? "Pendiente de revisión" : "Revisado")
            }
            Text(statement.source)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(conciseStatementPeriod(statement))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.marcelitoNavyMid)
                .lineLimit(1)
            Text("\(statement.transactionCount) mov.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
        .padding(14)
        .background(Color.marcelitoCreamSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.marcelitoLine.opacity(0.62), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(statement.source), \(conciseStatementPeriod(statement))")
        .accessibilityHint("Abre el estado de cuenta")
    }
}

private struct StatementDocumentView: View {
    @Environment(FinanceStore.self) private var store
    let statement: StatementRecord

    var body: some View {
        Group {
            if let url = store.statementFileURL(for: statement),
               let document = PDFDocument(url: url) {
                PDFDocumentRepresentable(document: document)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView(
                    "Archivo no disponible",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Este estado se importó antes de guardar documentos localmente. Puedes volver a importarlo para abrirlo desde aquí.")
                )
            }
        }
        .navigationTitle("\(statement.source) · \(conciseStatementPeriod(statement))")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.marcelitoCream)
        .foregroundStyle(Color.marcelitoNavy)
    }
}

private struct PDFDocumentRepresentable: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = UIColor(red: 0.96, green: 0.94, blue: 0.88, alpha: 1)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
        view.autoScales = true
    }
}

private struct StatementSummaryEditor: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let statement: StatementRecord
    @State private var summary: StatementSummaryRecord
    @State private var source: String
    @State private var statementKind: StatementKind
    @State private var isReimporting = false
    @State private var reimportError: String?

    init(statement: StatementRecord) {
        self.statement = statement
        _summary = State(initialValue: statement.summary ?? StatementSummaryRecord())
        _source = State(initialValue: statement.source)
        _statementKind = State(initialValue: statement.kind ?? (statement.source.localizedCaseInsensitiveContains("Amex") ? .card : .bank))
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
            Section("Origen") {
                TextField("Banco o tarjeta", text: $source)
                    .textInputAutocapitalization(.words)
                Picker("Tipo de documento", selection: $statementKind) {
                    Text("Tarjeta de crédito").tag(StatementKind.card)
                    Text("Cuenta bancaria").tag(StatementKind.bank)
                    Text("No identificado").tag(StatementKind.unknown)
                }
                Text("Si el banco no se identificó automáticamente, escribe aquí el nombre que quieres ver en tus cuentas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            if statementKind == .card {
                Section("Crédito y MSI") {
                    decimalField("Límite de crédito", \.creditLimit)
                    decimalField("Crédito disponible", \.creditAvailable)
                    decimalField("Deuda al corte", \.debtBalance)
                    decimalField("Saldo revolvente", \.revolvingBalance)
                    decimalField("MSI pendientes", \.msiPending)
                    decimalField("MSI original diferido", \.msiOriginalDeferred)
                    TextField("Mensualidades MSI activas", text: installmentBinding)
                        .keyboardType(.numberPad)
                    decimalField("Carga mensual MSI", \.msiMonthlyLoad)
                }
            } else {
                Section("Banco") {
                    decimalField("Efectivo disponible", \.cashBalance)
                    decimalField("Depósitos / abonos", \.depositTotal)
                    decimalField("Retiros / cargos", \.withdrawalTotal)
                }
            }
            if let localURL = store.statementFileURL(for: statement) {
                Section("Releer PDF") {
                    Button {
                        isReimporting = true
                        reimportError = nil
                        Task { @MainActor in
                            do {
                                _ = try await store.importPDFAsync(
                                    from: localURL,
                                    allowOCR: true,
                                    preserveExistingOnEmpty: false,
                                    sourceOverride: source,
                                    kindOverride: statementKind
                                )
                                dismiss()
                            } catch {
                                reimportError = error.localizedDescription
                            }
                            isReimporting = false
                        }
                    } label: {
                        Label(
                            isReimporting ? "Releyendo…" : "Releer con esta configuración",
                            systemImage: isReimporting ? "hourglass" : "arrow.clockwise.doc"
                        )
                    }
                    .disabled(isReimporting || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("Usa el PDF original guardado y vuelve a construir sus filas con el banco y tipo seleccionados. El resultado seguirá sujeto a conciliación y revisión.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let reimportError {
                        Text(reimportError)
                            .font(.caption)
                            .foregroundStyle(Color.marcelitoAmber)
                    }
                }
            }
            Section {
                Button("Guardar cifras del corte") {
                    store.updateStatementSource(for: statement, to: source, kind: statementKind)
                    store.updateStatementSummary(for: statement, summary: summary)
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                if statement.requiresReview {
                    Button("Confirmar estado revisado") {
                        _ = store.confirmStatementReviewed(statement)
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(statement.reconciliation?.status != .valid)
                    Text("Confirma después de revisar las filas OCR y los importes. Solo los estados conciliados pueden entrar a los KPI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Cifras del corte")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Color.marcelitoCream)
        .foregroundStyle(Color.marcelitoNavy)
    }
}

struct NetWorthView: View {
    @Environment(FinanceStore.self) private var store
    @State private var selectedMetric: DashboardMetric?

    private var patrimonyText: String {
        if store.dashboardIsBlocked { return "Bloqueado" }
        return store.liquidPatrimony?.formatted(.currency(code: "MXN").precision(.fractionLength(0))) ?? "—"
    }

    var body: some View {
        NavigationStack {
            List {
                if store.dashboardIsBlocked {
                    Section {
                        LedgerQualityBanner(store: store)
                        HistoricalDashboardBlockedCard(store: store)
                    }
                }
                Section {
                    Button {
                        selectedMetric = .patrimony
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Patrimonio líquido").foregroundStyle(.secondary)
                            Text(patrimonyText)
                                .font(.largeTitle.bold())
                                .monospacedDigit()
                            Text(store.liquidPatrimony == nil ? "Pendiente de saldos al corte" : "Efectivo disponible menos deuda")
                                .foregroundStyle(Color.marcelitoNavyMid)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Toca para ver el detalle y la tendencia del patrimonio")
                    .padding(.vertical, 10)
                }
                Section("Saldos calculados") {
                    LabeledContent("Efectivo disponible", value: store.dashboardIsBlocked ? "Bloqueado" : (store.cashAvailable?.formatted(.currency(code: "MXN").precision(.fractionLength(0))) ?? "Pendiente"))
                    LabeledContent("Deuda total", value: store.dashboardIsBlocked ? "Bloqueado" : (store.debtTotal?.formatted(.currency(code: "MXN").precision(.fractionLength(0))) ?? "Pendiente"))
                    LabeledContent("Utilización de crédito", value: store.dashboardIsBlocked ? "Bloqueado" : (store.creditUtilizationRate.map { "\(Int((NSDecimalNumber(decimal: $0).doubleValue * 100).rounded()))%" } ?? "Pendiente"))
                }
            }
            .navigationTitle("Patrimonio")
            .listStyle(.insetGrouped)
            .listRowBackground(Color.marcelitoCreamSoft)
            .foregroundStyle(Color.marcelitoNavy)
            .scrollContentBackground(.hidden)
            .background(Color.marcelitoCream)
            .sheet(item: $selectedMetric) { metric in
                MetricDetailSheet(metric: metric, store: store)
            }
        }
    }
}
