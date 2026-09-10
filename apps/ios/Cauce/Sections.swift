import SwiftUI
import PDFKit
import UIKit
import Charts
import PhotosUI
import UniformTypeIdentifiers

private let expenseCategoryOptions = [
    "Restaurantes y bares", "Tiendita", "Despensa / supermercado", "Entretenimiento",
    "Viajes", "Transporte", "Deporte", "Compras personales", "Software y suscripciones",
    "Salud", "Club Amigos / Proyectos", "Comisiones y finanzas", "Otros / Por revisar"
]

private let movementCategoryOptions = ["Ingresos", "Transferencia"] + expenseCategoryOptions

func conciseStatementPeriod(_ statement: StatementRecord) -> String {
    if statement.source == "BBVA" {
        let parts = statement.period.components(separatedBy: " - ")
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "dd/MM/yyyy"
        parser.isLenient = false
        if parts.count == 2, let start = parser.date(from: parts[0]), let end = parser.date(from: parts[1]) {
            let display = DateFormatter()
            display.locale = Locale(identifier: "es_MX")
            display.dateFormat = Calendar.current.component(.year, from: start) == Calendar.current.component(.year, from: end)
                ? "d MMM" : "d MMM yyyy"
            let first = display.string(from: start)
            display.dateFormat = "d MMM yyyy"
            return "\(first) – \(display.string(from: end))"
        }
    }
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
    // `period` is accounting metadata; the upload filename is deliberately
    // excluded so an arbitrary UUID or user-chosen PDF name can never leak
    // into the account document grid.
    let source = statement.period
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
    let looksLikeFileName = fallback.localizedCaseInsensitiveContains(".pdf")
        || fallback.range(of: #"^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$"#, options: [.regularExpression, .caseInsensitive]) != nil
    return fallback.count <= 48 && !fallback.isEmpty && !looksLikeFileName
        ? fallback
        : "Periodo no identificado"
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
        // Zen is enrichment for already accepted accounting rows only. A
        // quarantined OCR row must never reach the provider, even when the
        // user has enabled the provisional dashboard preview.
        store.canonicalMovements.filter {
            guard $0.flow == .expense,
                  ["Por revisar", "Sin categoría", "Otros / Por revisar"].contains($0.category) else { return false }
            switch $0.kind {
            case .cardPayment?, .bankTransfer?, .refund?, .credit?, .msi?:
                return false
            default:
                return true
            }
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
                                    Text(movement.category)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(
                                            ["Por revisar", "Sin categoría", "Otros / Por revisar"].contains(movement.category)
                                                ? Color.marcelitoAmber
                                                : Color.marcelitoSuccess
                                        )
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
                            let updated = store.applyDeterministicCategoryRules()
                            let eligible = store.classifiableExpenseCount
                            let pending = store.pendingExpenseCategoryCount
                            let classified = max(0, eligible - pending)
                            aiMessage = "Reglas locales terminadas: \(classified) de \(eligible) gastos clasificados; \(pending) por revisar. Se actualizaron \(updated) movimientos en esta ejecución."
                        } label: {
                            Label("Aplicar reglas automáticas", systemImage: "bolt.fill")
                        }
                        Button {
                            isAISettingsPresented = true
                        } label: {
                            Label("Configurar clasificación IA", systemImage: "gearshape")
                        }
                        Button {
                            let provider = ExpenseAISettingsStore.selectedProvider
                            if ExpenseAISettingsStore.apiKey(for: provider) == nil {
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
            .background(MarcelitoAmbientBackground())
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
                Text("Se enviarán a \(ExpenseAISettingsStore.selectedProvider.displayName) únicamente el comercio, importe y fecha de estos gastos. No se envían cuentas, PDFs, saldos, ingresos, transferencias ni movimientos ya clasificados.")
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
        let provider = ExpenseAISettingsStore.selectedProvider
        guard let apiKey = ExpenseAISettingsStore.apiKey(for: provider) else {
            isAISettingsPresented = true
            return
        }
        let items = pendingForAI
        guard !items.isEmpty else { return }
        let model = ExpenseAISettingsStore.selectedModel(for: provider)
        isAIProcessing = true
        Task { @MainActor in
            do {
                let result = try await ExpenseAIClassifier.classify(
                    movements: items,
                    apiKey: apiKey,
                    model: model,
                    provider: provider
                )
                let updated = store.applyAIClassifications(result.classifications)
                DiagnosticsRecorder.record(
                    level: result.unresolvedCount > 0 ? "error" : "info",
                    stage: "categories.ai",
                    message: "\(result.diagnosticSummary) Aplicados \(updated)."
                )
                isAIProcessing = false
                let remaining = max(items.count - updated, 0)
                aiMessage = updated == 0
                    ? "La IA respondió, pero no encontró categorías con confianza suficiente. Quedan \(remaining) por revisar y puedes asignarlas manualmente desde el detalle."
                    : "Se actualizaron \(updated) movimientos y Marcelito recordará esas categorías. Quedan \(remaining) por revisar."
            } catch {
                DiagnosticsRecorder.record(
                    level: "error",
                    stage: "categories.ai",
                    message: "Proveedor \(provider.displayName); modelo \(model); solicitados \(items.count); ejecución fallida antes de aplicar cambios."
                )
                isAIProcessing = false
                aiErrorMessage = error.localizedDescription
            }
        }
    }

    private func statementLabel(for movement: Movement) -> String {
        if store.isProvisionalScreenshotMovement(movement) {
            return "Captura provisional"
        }
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
    @State private var category = "Otros / Por revisar"
    @State private var amount = ""
    @State private var flow: FlowKind = .expense
    @State private var date = Date.now

    private let categoryOptions = movementCategoryOptions

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
                        ForEach(categoryOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
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
            .background(MarcelitoAmbientBackground())
            .foregroundStyle(Color.marcelitoNavy)
        }
    }
}

struct MovementDetailView: View {
    @Environment(FinanceStore.self) private var store
    let movement: Movement
    @State private var selectedCategory: String
    @State private var selectedKind: MovementKind
    @State private var isTravel: Bool
    @State private var categorySaveMessage: String?
    private let categories = movementCategoryOptions

    private var currentMovement: Movement {
        store.movements.first(where: { $0.id == movement.id }) ?? movement
    }

    init(movement: Movement) {
        self.movement = movement
        _selectedCategory = State(initialValue: movementCategoryOptions.contains(movement.category) ? movement.category : "Otros / Por revisar")
        _selectedKind = State(initialValue: movement.kind ?? .purchase)
        _isTravel = State(initialValue: movement.travelRelated)
        _categorySaveMessage = State(initialValue: nil)
    }

    var body: some View {
        Form {
            LabeledContent("Importe") { Text(movement.amount, format: .currency(code: "MXN")).monospacedDigit() }
            LabeledContent("Cuenta", value: movement.account)
            if let statement = movement.statementId.flatMap({ id in store.statements.first(where: { $0.id == id }) }) {
                LabeledContent("Estado", value: "\(statement.source) · \(conciseStatementPeriod(statement))")
                LabeledContent("Archivo", value: statement.fileName)
            } else if store.isProvisionalScreenshotMovement(currentMovement) {
                LabeledContent("Estado", value: "Captura provisional")
                Label("Ya está incluido en las métricas y se sustituirá al conciliarse con el estado oficial.", systemImage: "clock.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(Color.marcelitoAmber)
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
            if let confidence = currentMovement.reconciliationConfidence,
               let reason = currentMovement.reconciliationReason {
                Section("Conciliación entre cuentas") {
                    LabeledContent("Confianza", value: "\(confidence)%")
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let matchedID = currentMovement.matchedMovementId,
                       let counterpart = store.movements.first(where: { $0.id == matchedID }) {
                        NavigationLink {
                            AnyView(MovementDetailView(movement: counterpart))
                        } label: {
                            LabeledContent(
                                "Contraparte",
                                value: "\(counterpart.account) · \(counterpart.amount.formatted(.currency(code: "MXN")))"
                            )
                        }
                    } else {
                        LabeledContent("Contraparte", value: "Estado no importado")
                    }
                }
            }
            Picker("Categoría", selection: Binding(
                get: { selectedCategory },
                set: {
                    selectedCategory = $0
                    categorySaveMessage = store.updateCategory(for: movement, to: $0)
                        ? "Guardado como \($0)"
                        : "No se pudo guardar; el movimiento ya no está disponible."
                }
            )) {
                ForEach(categories, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            Text("La categoría se guarda al seleccionarla y se recordará para movimientos futuros del mismo comercio.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let categorySaveMessage {
                Label(categorySaveMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.marcelitoSuccess)
            }
            if !currentMovement.classificationTags.isEmpty {
                LabeledContent("Etiquetas", value: currentMovement.classificationTags.joined(separator: " · "))
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
        .background(MarcelitoAmbientBackground())
    }
}

struct ExpensesView: View {
    @Environment(FinanceStore.self) private var store
    @State private var selectedCategory: ExpenseCategorySelection?

    private var groups: [(category: String, amount: Decimal)] {
        // Movements already contains the user's saved/manual category. The
        // expense dashboard must summarize the complete reconciled spend
        // ledger instead of borrowing one institution's latest cutoff period;
        // BBVA, Santander and Amex do not share the same statement dates.
        Dictionary(grouping: store.realExpenseMovements, by: { $0.category })
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
                Text("Incluye todo el historial conciliado. Puedes corregir el origen o la categoría desde Cuentas > Ajustes.")
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
            if store.operationalMetricsBlocked {
                Section {
                    LedgerQualityBanner(store: store)
                    HistoricalDashboardBlockedCard(store: store)
                }
            } else if groups.isEmpty {
                ContentUnavailableView("Sin gastos", systemImage: "chart.pie", description: Text("Importa un estado de cuenta para construir tus categorías reales."))
            } else {
                if store.dashboardIsProvisional {
                    Section {
                        LedgerQualityBanner(store: store)
                    }
                }
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
                .background(MarcelitoAmbientBackground())
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
        store.realExpenseMovements.filter { $0.category == category }
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
        Array(movements.sorted { abs($0.amount) > abs($1.amount) }.prefix(10))
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
                            Text("Top 10 de montos")
                                .font(.subheadline.weight(.semibold))
                            ForEach(highestMovements) { movement in
                                NavigationLink {
                                    MovementDetailView(movement: movement)
                                } label: {
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
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Toca para cambiar la categoría")
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
            .background(MarcelitoAmbientBackground())
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
        .presentationBackground(.regularMaterial)
    }
}

private enum AccountBrand: String, CaseIterable {
    case amex
    case bbva
    case santander
    case rappi

    var displayName: String {
        switch self {
        case .amex: "Amex"
        case .bbva: "BBVA"
        case .santander: "Santander"
        case .rappi: "Rappi"
        }
    }

    var artworkName: String {
        switch self {
        case .amex: "CardAmex"
        case .bbva: "CardBBVA"
        case .santander: "CardSantander"
        case .rappi: "CardRappi"
        }
    }

    /// The supplied artwork was photographed/exported with different white
    /// margins. Matching each viewport to the actual card bounds avoids
    /// clipping Amex and over-zooming BBVA.
    var artworkAspectRatio: CGFloat {
        switch self {
        case .amex: 1.70
        case .bbva: 1.75
        case .santander: 1.66
        case .rappi: 1.66
        }
    }

    var artworkScale: CGFloat {
        switch self {
        case .amex: 1.075
        case .bbva: 1.045
        case .santander, .rappi: 1.08
        }
    }

    var fallbackKind: StatementKind {
        switch self {
        case .amex, .rappi: .card
        case .bbva, .santander: .bank
        }
    }

    static func identify(_ source: String) -> AccountBrand? {
        let normalized = source.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        if normalized.contains("amex") || normalized.contains("american express") { return .amex }
        if normalized.contains("bbva") { return .bbva }
        if normalized.contains("santander") { return .santander }
        if normalized.contains("rappi") { return .rappi }
        return nil
    }
}

private struct AccountDisplayItem: Identifiable {
    let source: String
    let kind: StatementKind
    let accountKey: String?
    let isPlaceholder: Bool

    init(source: String, kind: StatementKind, accountKey: String?, isPlaceholder: Bool = false) {
        self.source = source
        self.kind = kind
        self.accountKey = accountKey
        self.isPlaceholder = isPlaceholder
    }

    var brand: AccountBrand? { AccountBrand.identify(source) }
    var displayName: String { brand?.displayName ?? source }
    var artworkName: String? { brand?.artworkName }
    var artworkAspectRatio: CGFloat { brand?.artworkAspectRatio ?? 1.66 }
    var artworkScale: CGFloat { brand?.artworkScale ?? 1.0 }
    var id: String {
        "\(isPlaceholder ? "placeholder" : "account")|\(source)|\(kind.rawValue)|\(accountKey ?? "default")"
    }

    var maskedAccount: String? {
        accountKey.flatMap { $0.split(separator: ":").last }.map { "•••• \(String($0))" }
    }
}

private struct AccountCardArtwork: View {
    let account: AccountDisplayItem
    let isSelected: Bool

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let artworkName = account.artworkName {
                    Image(artworkName)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        // The supplied artwork includes a narrow white photo
                        // margin. Zooming inside the card-shaped viewport keeps
                        // only the physical card visible without modifying the
                        // original asset.
                        .scaleEffect(account.artworkScale)
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [Color.marcelitoNavy, Color.marcelitoNavyMid],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Image(systemName: account.kind == .card ? "creditcard.fill" : "building.columns.fill")
                            .font(.system(size: 52, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
        }
        .aspectRatio(account.artworkAspectRatio, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if account.isPlaceholder {
                Text("Sin estados")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.68), in: Capsule())
                    .padding(12)
            }
        }
        .shadow(color: Color.black.opacity(isSelected ? 0.14 : 0.07), radius: isSelected ? 12 : 6, y: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.displayName + (account.maskedAccount.map { ", \($0)" } ?? ""))
        .accessibilityValue(account.isPlaceholder ? "Sin estados subidos" : "Cuenta seleccionable")
    }
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
        let minimum = (statement?.summary?.minimumPlusMsi ?? statement?.summary?.minimumPayment)?
            .formatted(.currency(code: "MXN").precision(.fractionLength(0))) ?? "Pendiente"
        let noInterest = metric?.paymentForNoInterest?.formatted(.currency(code: "MXN").precision(.fractionLength(0))) ?? "Pendiente"
        return "Pago mínimo + MSI: \(minimum) · Pago para no intereses: \(noInterest)"
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
    @State private var selectedAccountID = ""
    @State private var isMovementManagementPresented = false
    @State private var isScreenshotPickerPresented = false
    @State private var selectedScreenshotItems: [PhotosPickerItem] = []
    @State private var isImportingScreenshots = false
    @State private var screenshotImportError: String?
    @State private var screenshotImportReceipt: BankScreenshotImportReceipt?
    @State private var isStatementImporterPresented = false
    @State private var statementImportReport: ImportReport?
    @State private var isImportingStatements = false
    @State private var statementImportProgress = 0
    @State private var statementImportStatus = "Preparando…"
    @State private var isDiagnosticsPresented = false

    private var displayedAccounts: [AccountDisplayItem] {
        var seen = Set<String>()
        var imported: [AccountDisplayItem] = []
        for statement in store.statements {
            let kind = statement.kind ?? (statement.source.localizedCaseInsensitiveContains("Amex") ? .card : .bank)
            let item = AccountDisplayItem(source: statement.source, kind: kind, accountKey: statement.accountKey)
            if seen.insert(item.id).inserted { imported.append(item) }
        }

        var result: [AccountDisplayItem] = []
        for brand in AccountBrand.allCases {
            let matching = imported
                .filter { $0.brand == brand }
                .sorted { $0.id.localizedCompare($1.id) == .orderedAscending }
            if matching.isEmpty {
                result.append(AccountDisplayItem(
                    source: brand.displayName,
                    kind: brand.fallbackKind,
                    accountKey: nil,
                    isPlaceholder: true
                ))
            } else {
                result.append(contentsOf: matching)
            }
        }
        result.append(contentsOf: imported
            .filter { $0.brand == nil }
            .sorted { $0.id.localizedCompare($1.id) == .orderedAscending })
        return result
    }

    private var selectedAccount: AccountDisplayItem? {
        displayedAccounts.first(where: { $0.id == selectedAccountID }) ?? displayedAccounts.first
    }

    private var selectedStatements: [StatementRecord] {
        guard let account = selectedAccount, !account.isPlaceholder else { return [] }
        return store.statements(for: account.source, kind: account.kind, accountKey: account.accountKey)
    }

    private var selectedScreenshotCaptures: [BankScreenshotCapture] {
        guard let account = selectedAccount else { return [] }
        return store.screenshotCaptures(for: account.source, accountKey: account.accountKey)
    }

    private var carouselSelection: Binding<String> {
        Binding(
            get: { selectedAccount?.id ?? "" },
            set: { selectedAccountID = $0 }
        )
    }

    private func ensureValidSelection() {
        guard !displayedAccounts.contains(where: { $0.id == selectedAccountID }) else { return }
        selectedAccountID = displayedAccounts.first?.id ?? ""
    }

    @MainActor
    private func importSelectedScreenshots(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, !isImportingScreenshots else { return }
        let sourceHint = selectedAccount?.source
        let accountKey = selectedAccount?.accountKey
        isImportingScreenshots = true
        screenshotImportError = nil
        Task {
            defer {
                isImportingScreenshots = false
                selectedScreenshotItems = []
            }
            do {
                var inputs: [BankScreenshotInput] = []
                for (index, item) in items.enumerated() {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw BankScreenshotImportError.unreadableImage
                    }
                    inputs.append(BankScreenshotInput(data: data, fileName: "captura-\(index + 1)"))
                }
                let preparedInputs = inputs
                let result = try await Task.detached(priority: .userInitiated) {
                    try BankScreenshotReader.inspect(preparedInputs, sourceHint: sourceHint, accountKey: accountKey)
                }.value
                screenshotImportReceipt = try store.saveBankScreenshotImport(result)
            } catch {
                screenshotImportError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func handleStatementImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else {
                statementImportReport = ImportReport(
                    fileCount: 0,
                    items: [],
                    selectionError: "No elegiste ningún PDF. Selecciona un estado de cuenta para revisar sus movimientos."
                )
                return
            }
            isImportingStatements = true
            statementImportProgress = 0
            statementImportStatus = urls.count == 1 ? "Preparando el estado…" : "Preparando \(urls.count) estados…"
            DiagnosticsRecorder.record(stage: "import.start", message: "Importación iniciada desde Cuentas: \(urls.count) PDF(s).")
            Task { @MainActor in
                var items: [ImportReportItem] = []
                for (index, url) in urls.enumerated() {
                    statementImportStatus = "Leyendo \(url.lastPathComponent)…"
                    let totalCount = max(Double(urls.count), 1)
                    statementImportProgress = Int((Double(index) / totalCount * 100).rounded())
                    await Task.yield()
                    do {
                        let summary = try await store.importPDFAsync(from: url, stage: { message in
                            statementImportStatus = message
                        })
                        items.append(ImportReportItem(summary: summary))
                        DiagnosticsRecorder.record(
                            stage: "import.file",
                            message: "\(summary.source) · \(summary.period): \(summary.imported) movimiento(s)\(summary.usedOCR ? " · OCR" : "")."
                        )
                    } catch {
                        DiagnosticsRecorder.record(level: "error", stage: "import.error", message: "\(url.lastPathComponent): \(error.localizedDescription)")
                        items.append(ImportReportItem(fileName: url.lastPathComponent, errorMessage: error.localizedDescription))
                    }
                    statementImportProgress = Int((Double(index + 1) / totalCount * 100).rounded())
                    await Task.yield()
                }
                statementImportStatus = "Listo"
                isImportingStatements = false
                statementImportReport = ImportReport(fileCount: urls.count, items: items)
                store.runAutomaticAuditIfNeeded(trigger: "import")
                DiagnosticsRecorder.record(
                    stage: "import.done",
                    message: "Importación terminada: \(items.filter { $0.errorMessage == nil }.count)/\(urls.count) archivo(s) procesado(s)."
                )
            }
        case .failure(let error):
            isImportingStatements = false
            DiagnosticsRecorder.record(level: "error", stage: "import.selection", message: error.localizedDescription)
            statementImportReport = ImportReport(fileCount: 0, items: [], selectionError: error.localizedDescription)
        }
    }

    private var statementImportButton: some View {
        Button {
            isStatementImporterPresented = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.plus")
                    .font(.title3.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Subir estado bancario")
                        .font(.headline)
                    Text("PDF oficial · uno o varios meses")
                        .font(.caption)
                        .opacity(0.78)
                }
                Spacer()
                Image(systemName: "plus.circle.fill")
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.marcelitoNavy)
        .background(Color.marcelitoCreamSoft, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color.marcelitoNavy.opacity(0.16), lineWidth: 1)
        }
        .disabled(isImportingStatements)
        .accessibilityHint("Selecciona estados de cuenta oficiales en PDF")
    }

    private var screenshotImportButton: some View {
        Button {
            isScreenshotPickerPresented = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title3.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Subir capturas")
                        .font(.headline)
                    Text("BBVA, Santander o American Express")
                        .font(.caption)
                        .opacity(0.78)
                }
                Spacer()
                if isImportingScreenshots {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "plus.circle.fill")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(Color.marcelitoNavy, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .disabled(isImportingScreenshots)
        .accessibilityHint("Selecciona pantallas de movimientos; aparecen de inmediato como provisionales y se sustituyen al conciliarlas")
    }

    @ViewBuilder
    private var screenshotCaptureSection: some View {
        if !selectedScreenshotCaptures.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Capturas procesadas")
                    .font(.headline)
                Text("Ya alimentan las métricas como provisionales; el estado oficial las confirma y sustituye sin duplicarlas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ForEach(selectedScreenshotCaptures) { capture in
                    ScreenshotCaptureRow(capture: capture) {
                        store.deleteBankScreenshotCapture(capture)
                    }
                }
            }
        }
    }

    private var screenshotErrorIsPresented: Binding<Bool> {
        Binding(
            get: { screenshotImportError != nil },
            set: { if !$0 { screenshotImportError = nil } }
        )
    }

    private var accountsHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mis cuentas")
                .font(.title3.weight(.bold))
            Text("Desliza para elegir cuál quieres consultar")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var accountCarousel: some View {
        VStack(spacing: 8) {
            TabView(selection: carouselSelection) {
                ForEach(displayedAccounts) { account in
                    AccountCardArtwork(account: account, isSelected: selectedAccount?.id == account.id)
                        .tag(account.id)
                }
            }
            .frame(height: 220)
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 7) {
                ForEach(displayedAccounts) { account in
                    Circle()
                        .fill(account.id == selectedAccount?.id ? Color.marcelitoNavy : Color.marcelitoNavy.opacity(0.20))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
        }
        .animation(.snappy, value: selectedAccountID)
    }

    private func selectedAccountHeading(_ account: AccountDisplayItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.displayName)
                    .font(.title3.weight(.bold))
                if let maskedAccount = account.maskedAccount {
                    Text(maskedAccount)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(selectedStatements.count) estado\(selectedStatements.count == 1 ? "" : "s")")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.marcelitoNavyMid)
        }
    }

    private func emptyAccountView(_ account: AccountDisplayItem) -> some View {
        ContentUnavailableView(
            "Sin estados subidos",
            systemImage: "doc.badge.plus",
            description: Text("Cuando importes un estado de \(account.displayName), aparecerá aquí identificado por su periodo.")
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color.marcelitoCreamSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var statementTiles: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
            spacing: 12
        ) {
            ForEach(selectedStatements) { statement in
                NavigationLink {
                    StatementDocumentView(statement: statement)
                } label: {
                    StatementDocumentTile(statement: statement)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var statementEditors: some View {
        VStack(spacing: 10) {
            ForEach(selectedStatements) { statement in
                NavigationLink {
                    StatementSummaryEditor(statement: statement)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(Color.marcelitoNavyMid)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(conciseStatementPeriod(statement))
                                .font(.subheadline.weight(.semibold))
                            Text(statement.kind == .bank ? "Periodo, saldos, abonos y cargos" : "Saldos, pagos, crédito y MSI")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(Color.marcelitoCreamSoft, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func selectedAccountContent(_ account: AccountDisplayItem) -> some View {
        selectedAccountHeading(account)
        statementImportButton
        screenshotImportButton

        HStack(spacing: 10) {
            Button {
                isDiagnosticsPresented = true
            } label: {
                Label("Diagnóstico", systemImage: "stethoscope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                isMovementManagementPresented = true
            } label: {
                Label("Movimientos", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }

        if account.isPlaceholder || selectedStatements.isEmpty {
            emptyAccountView(account)
        } else {
            AccountSummaryRow(source: account.source, kind: account.kind, accountKey: account.accountKey)
                .padding(16)
                .background(Color.marcelitoCreamSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text("Estados subidos")
                .font(.headline)
            statementTiles

            Text("Cifras detectadas y relectura")
                .font(.headline)
            statementEditors
        }

        screenshotCaptureSection
    }

    private var accountsScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if store.dashboardIsBlocked || store.dashboardIsProvisional {
                    LedgerQualityBanner(store: store)
                }
                accountsHeading
                accountCarousel
                if let account = selectedAccount {
                    selectedAccountContent(account)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }

    var body: some View {
        NavigationStack {
            accountsScrollView
            .navigationTitle("Cuentas")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isMovementManagementPresented = true
                    } label: {
                        Label("Ajustes", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityHint("Abre la asignación y edición de gastos y movimientos")
                }
            }
            .foregroundStyle(Color.marcelitoNavy)
            .background(MarcelitoAmbientBackground())
            .onAppear(perform: ensureValidSelection)
            .task { await store.repairBBVAPeriods() }
            .onChange(of: displayedAccounts.map(\.id)) { _, _ in
                ensureValidSelection()
            }
            .sheet(isPresented: $isMovementManagementPresented) {
                MovementsView()
            }
            .sheet(isPresented: $isDiagnosticsPresented) {
                DiagnosticsView()
            }
            .fileImporter(
                isPresented: $isStatementImporterPresented,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: true
            ) { result in
                handleStatementImport(result)
            }
            .photosPicker(
                isPresented: $isScreenshotPickerPresented,
                selection: $selectedScreenshotItems,
                maxSelectionCount: 20,
                matching: .images
            )
            .onChange(of: selectedScreenshotItems) { _, items in
                importSelectedScreenshots(items)
            }
            .sheet(item: $screenshotImportReceipt) { receipt in
                BankScreenshotImportReceiptView(receipt: receipt)
            }
            .sheet(item: $statementImportReport) { report in
                ImportReportSheet(report: report)
            }
            .disabled(isImportingStatements)
            .overlay {
                if isImportingStatements {
                    ImportProgressOverlay(progress: statementImportProgress, status: statementImportStatus)
                        .transition(.opacity)
                }
            }
            .alert("No se pudieron importar las capturas", isPresented: screenshotErrorIsPresented) {
                Button("Aceptar", role: .cancel) { screenshotImportError = nil }
            } message: {
                Text(screenshotImportError ?? "Error desconocido")
            }
        }
    }
}

private struct ScreenshotCaptureRow: View {
    let capture: BankScreenshotCapture
    let onDelete: () -> Void

    private var isFullyConfirmed: Bool {
        !capture.uniqueMovements.isEmpty && capture.confirmedCount == capture.uniqueMovements.count
    }

    private var statusText: String {
        if isFullyConfirmed { return "Conciliada con estado oficial" }
        return "En métricas · \(capture.unconfirmedCount) provisional\(capture.unconfirmedCount == 1 ? "" : "es")"
    }

    private var detailText: String {
        let base = "\(capture.uniqueMovements.count) movimientos detectados"
        guard capture.pendingCount > 0 else { return base }
        return "\(base) · \(capture.pendingCount) pendientes en el banco"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isFullyConfirmed ? "checkmark.seal.fill" : "viewfinder")
                .foregroundStyle(isFullyConfirmed ? Color.green : Color.marcelitoNavyMid)
            VStack(alignment: .leading, spacing: 3) {
                Text(capture.coverageLabel)
                    .font(.subheadline.weight(.semibold))
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isFullyConfirmed ? Color.green : Color.marcelitoAmber)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Eliminar capturas", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 32, height: 32)
            }
        }
        .padding(14)
        .background(Color.marcelitoCreamSoft, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
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

    private var latestStatement: StatementRecord? {
        guard let latest else { return nil }
        return store.statements.first(where: { $0.id == latest.id })
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
                LabeledContent(
                    "Pago mínimo + MSI",
                    value: (latestStatement?.summary?.minimumPlusMsi
                        ?? latestStatement?.summary?.minimumPayment)
                        .map { $0.formatted(.currency(code: "MXN").precision(.fractionLength(0))) }
                        ?? "Pendiente"
                )
                LabeledContent("Pago para no generar intereses", value: latest.paymentForNoInterest?.formatted(.currency(code: "MXN").precision(.fractionLength(0))) ?? "Pendiente")
            }
            .foregroundStyle(Color.marcelitoNavy)
            .padding(16)
            .background(Color.marcelitoCreamSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder
    private var trendSection: some View {
        // The explicit manual unlock may show this operational trend as
        // provisional. The data source remains canonical-only; quarantined
        // rows never enter the chart.
        if store.dashboardIsBlocked || store.operationalMetricsBlocked {
            HistoricalDashboardBlockedCard(store: store)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if store.dashboardIsProvisional {
                    LedgerQualityBanner(store: store)
                }
                if trend.isEmpty {
                    Text("Aún no hay suficientes cortes para mostrar una tendencia.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    AccountEvolutionChart(points: trend, source: source, kind: kind)
                }
            }
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
        .background(MarcelitoAmbientBackground())
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
            Text(conciseStatementPeriod(statement))
                .font(.headline)
                .foregroundStyle(Color.marcelitoNavy)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
            Text(statement.source)
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .background(MarcelitoAmbientBackground())
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

    private func decimalField(_ title: String, _ keyPath: WritableKeyPath<StatementSummaryRecord, Decimal?>) -> some View {
        LabeledContent(title) {
            Text(summary[keyPath: keyPath]?.formatted(.currency(code: "MXN")) ?? "No detectado")
                .foregroundStyle(summary[keyPath: keyPath] == nil ? Color.secondary : Color.marcelitoNavy)
                .monospacedDigit()
        }
    }

    private var reconciliationText: String {
        switch statement.reconciliation?.status {
        case .valid: "Conciliado al centavo"
        case .invalid: "No conciliado"
        case .pending: "Pendiente de conciliación"
        case nil: statement.requiresReview ? "Requiere revisión" : "Sin diagnóstico"
        }
    }

    private var reconciliationColor: Color {
        statement.reconciliation?.status == .valid ? Color.marcelitoSuccess : Color.marcelitoAmber
    }

    var body: some View {
        Form {
            Section("Estado detectado") {
                LabeledContent("Periodo", value: conciseStatementPeriod(statement))
                LabeledContent("Movimientos", value: "\(statement.transactionCount)")
                LabeledContent("Conciliación") {
                    Label(
                        reconciliationText,
                        systemImage: statement.reconciliation?.status == .valid
                            ? "checkmark.seal.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(reconciliationColor)
                }
                if let reason = statement.reconciliation?.reason,
                   statement.reconciliation?.status != .valid {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
            if statementKind == .card {
                Section("Resumen del corte") {
                    decimalField("Saldo anterior", \.previousBalance)
                    decimalField("Nuevas transacciones", \.newTransactions)
                    decimalField("Pagos realizados", \.payments)
                    decimalField("Créditos", \.credits)
                    decimalField("Nuevos cargos", \.newCharges)
                    decimalField("Intereses", \.interest)
                    decimalField("Comisiones", \.fees)
                    decimalField("Saldo al corte", \.statementBalance)
                    decimalField("Pago mínimo", \.minimumPayment)
                    decimalField("Pago para no generar intereses", \.paymentForNoInterest)
                }
                Section("Crédito y MSI") {
                    decimalField("Límite de crédito", \.creditLimit)
                    decimalField("Crédito disponible", \.creditAvailable)
                    decimalField("Deuda al corte", \.debtBalance)
                    decimalField("Saldo revolvente", \.revolvingBalance)
                    decimalField("MSI pendientes", \.msiPending)
                    decimalField("MSI original diferido", \.msiOriginalDeferred)
                    LabeledContent(
                        "Mensualidades MSI activas",
                        value: summary.msiInstallments.map(String.init) ?? "No detectado"
                    )
                    decimalField("Carga mensual MSI", \.msiMonthlyLoad)
                }
            } else {
                Section("Resumen del periodo bancario") {
                    decimalField("Saldo inicial", \.previousBalance)
                    decimalField("Depósitos / abonos", \.depositTotal)
                    if let count = summary.depositCount {
                        LabeledContent("Movimientos de abono", value: "\(count)")
                    }
                    decimalField("Retiros / cargos", \.withdrawalTotal)
                    if let count = summary.withdrawalCount {
                        LabeledContent("Movimientos de cargo", value: "\(count)")
                    }
                    decimalField("Saldo final", \.cashBalance)
                    Text("Estas cifras pertenecen al estado oficial. Las capturas más recientes se muestran aparte como movimientos provisionales hasta que un PDF las concilie.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Text("El emisor, las cifras oficiales y el estado de conciliación son inmutables. Un estado solo entra al libro canónico cuando su parser determinista concilia al centavo; no existe confirmación manual.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Cifras del corte")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(MarcelitoAmbientBackground())
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
                } else if store.dashboardIsProvisional {
                    Section {
                        LedgerQualityBanner(store: store)
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
            .background(MarcelitoAmbientBackground())
            .sheet(item: $selectedMetric) { metric in
                MetricDetailSheet(metric: metric, store: store)
            }
        }
    }
}
