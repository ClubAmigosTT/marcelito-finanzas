import SwiftUI
import UniformTypeIdentifiers
import Foundation

struct RootTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Inicio", systemImage: "house.fill") }
            MovementsView()
                .tabItem { Label("Movimientos", systemImage: "list.bullet.rectangle") }
            ExpensesView()
                .tabItem { Label("Gastos", systemImage: "chart.pie.fill") }
            AccountsView()
                .tabItem { Label("Cuentas", systemImage: "creditcard.fill") }
            NetWorthView()
                .tabItem { Label("Patrimonio", systemImage: "chart.line.uptrend.xyaxis") }
        }
        .tint(Color.marcelitoNavy)
        .toolbarBackground(Color.marcelitoCreamSoft, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

struct HomeView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(AuthenticationModel.self) private var auth
    @State private var isImporterPresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var importMessage: String?

    private var hasData: Bool { !store.movements.isEmpty || !store.statements.isEmpty }

    @ViewBuilder
    private var homeContent: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            if hasData {
                NetWorthSummary(store: store)
                MetricsStrip(income: store.totalIncome, transfers: store.totalTransfers, monthlyExpense: store.monthlyExpense)
                DecisionMetricsView()
                DecisionCallout(statement: store.statements.first)
                MoneyFlowView(store: store)
                if let lastImportedFile = store.lastImportedFile {
                    Label("Último estado importado: \(lastImportedFile)", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.marcelitoNavyMid)
                }
            } else {
                EmptyDataCard { isImporterPresented = true }
            }
        }
    }

    @ViewBuilder
    private var accountMenu: some View {
        Menu {
            if store.statements.isEmpty {
                Label("Sin estados importados", systemImage: "doc.text")
            } else {
                ForEach(store.statements.prefix(4)) { statement in
                    Label("\(statement.source) · \(statement.period)", systemImage: statement.requiresReview ? "exclamationmark.triangle" : "checkmark.circle")
                }
            }
            Button("Eliminar cuenta", role: .destructive) {
                isDeleteConfirmationPresented = true
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Opciones de cuenta")
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                homeContent
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
            }
            .scrollIndicators(.hidden)
            .background(Color.marcelitoCream.ignoresSafeArea())
            .navigationTitle("Inicio")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.marcelitoCream, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isImporterPresented = true } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Importar estado de cuenta")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    accountMenu
                }
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    guard !urls.isEmpty else {
                        importMessage = "No se seleccionó un archivo."
                        return
                    }
                    var reports: [String] = []
                    for url in urls {
                        do {
                            let summary = try store.importPDF(from: url)
                            let movementText = summary.imported == 0
                                ? "no se detectaron movimientos"
                                : "se agregaron \(summary.imported) movimientos"
                            let duplicateNote = summary.skipped > 0 ? "; \(summary.skipped) repetidos omitidos" : ""
                            let reviewNote = summary.requiresReview ? "; requiere revisión" : ""
                            let ocrNote = summary.usedOCR ? "; OCR aplicado" : ""
                            reports.append("\(summary.source) · \(summary.period): \(movementText)\(duplicateNote)\(reviewNote)\(ocrNote)")
                        } catch {
                            reports.append("\(url.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                    let prefix = urls.count > 1 ? "Se revisaron \(urls.count) archivos.\n\n" : ""
                    importMessage = prefix + reports.joined(separator: "\n\n")
                case .failure(let error):
                    importMessage = error.localizedDescription
                }
            }
            .alert(
                "Estado de cuenta",
                isPresented: Binding(
                    get: { importMessage != nil },
                    set: { if !$0 { importMessage = nil } }
                )
            ) {
                Button("Listo", role: .cancel) { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
            .confirmationDialog(
                "Eliminar cuenta",
                isPresented: $isDeleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Eliminar cuenta y datos", role: .destructive) {
                    store.clearLocalData()
                    auth.deleteAccount()
                }
                Button("Cancelar", role: .cancel) { }
            } message: {
                Text("Se borrarán tu usuario, movimientos y estados importados de este dispositivo. Esta acción no se puede deshacer.")
            }
        }
    }
}

private struct EmptyDataCard: View {
    let importAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.title2)
                .foregroundStyle(Color.marcelitoNavy)
            Text("Empieza con tus estados reales")
                .font(.title2.bold())
            Text("Marcelito no carga cifras de muestra. Importa un PDF mensual para guardar banco, periodo y movimientos en este dispositivo.")
                .foregroundStyle(.secondary)
            Button("Importar primer estado", action: importAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.marcelitoNavy)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Color.marcelitoNavy)
        .marcelitoCard(fill: Color.marcelitoCreamSoft, radius: 16, padding: 18)
    }
}

private struct NetWorthSummary: View {
    let store: FinanceStore

    private var displayValue: String {
        guard let value = store.liquidPatrimony else { return "—" }
        return value.formatted(.currency(code: "MXN").precision(.fractionLength(0)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Patrimonio líquido")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Color.marcelitoCream.opacity(0.78))
            Text(displayValue)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(store.liquidPatrimony == nil ? "Pendiente de saldos al corte" : "Efectivo disponible menos deuda")
                .font(.subheadline)
                .foregroundStyle(Color.marcelitoCream.opacity(0.78))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Color.marcelitoCream)
        .marcelitoCard(fill: Color.marcelitoNavy, radius: 18, padding: 20)
    }
}

private struct DecisionMetricsView: View {
    @Environment(FinanceStore.self) private var store

    private func money(_ value: Decimal?) -> String {
        value?.formatted(.currency(code: "MXN").precision(.fractionLength(0))) ?? "Pendiente"
    }

    private func percent(_ value: Decimal?) -> String {
        guard let value else { return "Pendiente" }
        return "\(Int((NSDecimalNumber(decimal: value).doubleValue * 100).rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Cálculos para decidir")
                .font(.title3.weight(.bold))
                .padding(.bottom, 6)
            CalculationLine(label: "Gasto total de tarjeta", value: money(store.totalNewTransactions), detail: "Compras nuevas")
            CalculationLine(label: "Promedio mensual", value: money(store.averageMonthlySpend), detail: "Compras / periodos")
            CalculationLine(label: "Abonos reales", value: money(store.totalRealPayments), detail: "Pagos, sin créditos contables")
            CalculationLine(label: "Saldo acumulado", value: money(store.accumulatedBalance), detail: "Gasto − abonos")
            CalculationLine(label: "Porcentaje pagado", value: percent(store.paidPercent), detail: "Abonos / gasto total")
            CalculationLine(label: "Porcentaje pendiente", value: percent(store.pendingPercent), detail: "Saldo / gasto total")
            Divider().padding(.vertical, 4)
            CalculationLine(label: "Gasto real consolidado", value: money(store.consolidatedRealSpend), detail: "Tarjeta + bancos, sin pagos propios")
            CalculationLine(label: "Gasto de viaje", value: money(store.travelSpend), detail: store.travelPercent.map { "\(percent($0)) del consolidado" } ?? "Pendiente de identificar")
            CalculationLine(label: "Gasto ordinario", value: money(store.ordinarySpend), detail: "Consolidado − viajes")
            CalculationLine(label: "Flujo neto", value: money(store.netFlow), detail: "Ingresos reales − gastos reales")
            CalculationLine(label: "Tasa de ahorro", value: percent(store.savingsRate), detail: "Flujo neto / ingresos")
            Divider().padding(.vertical, 4)
            CalculationLine(label: "Utilización de crédito", value: percent(store.creditUtilizationRate), detail: store.creditUsed.map { "\(money($0)) utilizado" } ?? "Captura límite y disponible")
            CalculationLine(label: "Carga mensual MSI", value: money(store.latestMsiMonthlyLoad), detail: "Mensualidades activas")
            CalculationLine(label: "Nuevos cargos del corte", value: money(store.cardPeriodMetrics.first?.newCharges), detail: "Compras + MSI + intereses + comisiones")
            CalculationLine(label: "Pago para no generar intereses", value: money(store.latestPaymentForNoInterest), detail: "Del estado o calculado")
        }
        .foregroundStyle(Color.marcelitoNavy)
        .marcelitoCard(fill: Color.marcelitoCreamSoft, radius: 16, padding: 18)
    }
}

private struct CalculationLine: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(minWidth: 78, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }
}

private struct MetricsStrip: View {
    let income: Decimal
    let transfers: Decimal
    let monthlyExpense: Decimal

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
            MetricTile(title: "Ingresos", value: income, symbol: "arrow.down.circle.fill", color: Color.marcelitoSuccess)
            MetricTile(title: "Transferencias", value: transfers, symbol: "arrow.left.arrow.right.circle.fill", color: Color.marcelitoNavyMid)
            MetricTile(title: "Gasto del mes", value: monthlyExpense, symbol: "receipt.fill", color: Color.marcelitoAmber)
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: Decimal
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value, format: .currency(code: "MXN").precision(.fractionLength(0)))
                .font(.headline)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 106, alignment: .leading)
        .foregroundStyle(Color.marcelitoNavy)
        .marcelitoCard(fill: Color.marcelitoCreamSoft, radius: 14, padding: 14)
    }
}

private struct DecisionCallout: View {
    let statement: StatementRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Revisión de origen", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            Text(statement.map { "\($0.source) · \($0.period) está guardado como \($0.transactionCount) movimientos. Corrige categorías desde Movimientos antes de usarlo para decidir." } ?? "Importa un estado de cuenta para empezar a revisar.")
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(Color.marcelitoNavy)
        .marcelitoCard(fill: Color.marcelitoNavy.opacity(0.12), radius: 14, padding: 16)
    }
}

private struct MoneyFlowView: View {
    let store: FinanceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Así se movió tu dinero")
                .font(.title3.weight(.bold))
            FlowLine(flow: .income, value: store.totalIncome)
            FlowLine(flow: .transfer, value: store.totalTransfers)
            FlowLine(flow: .expense, value: store.totalExpenses)
        }
        .foregroundStyle(Color.marcelitoNavy)
        .marcelitoCard(fill: Color.marcelitoCreamTint, radius: 16, padding: 18)
    }
}

private struct FlowLine: View {
    let flow: FlowKind
    let value: Decimal

    var body: some View {
        HStack {
            Image(systemName: flow.symbol).foregroundStyle(flow.color)
            Text(flow.rawValue)
            Spacer()
            Text(value, format: .currency(code: "MXN").precision(.fractionLength(0)))
                .monospacedDigit()
        }
        .padding(.vertical, 7)
    }
}
