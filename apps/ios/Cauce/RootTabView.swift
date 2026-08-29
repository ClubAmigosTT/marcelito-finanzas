import SwiftUI
import UniformTypeIdentifiers

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
    }
}

struct HomeView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(AuthenticationModel.self) private var auth
    @State private var isImporterPresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var importMessage: String?

    private var hasData: Bool { !store.movements.isEmpty || !store.statements.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if hasData {
                        NetWorthSummary(hasData: true)
                        MetricsStrip(income: store.totalIncome, transfers: store.totalTransfers, monthlyExpense: store.monthlyExpense)
                        DecisionCallout(statement: store.statements.first)
                        MoneyFlowView(store: store)
                        if let lastImportedFile = store.lastImportedFile {
                            Label("Último estado importado: \(lastImportedFile)", systemImage: "checkmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.marcelitoNavyMid)
                        }
                    } else {
                        EmptyDataCard { isImporterPresented = true }
                    }
                }
                .padding()
            }
            .background(Color.marcelitoCream.ignoresSafeArea())
            .navigationTitle("Inicio")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isImporterPresented = true } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Importar estado de cuenta")
                }
                ToolbarItem(placement: .topBarTrailing) {
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
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let url):
                    do {
                        let summary = try store.importPDF(from: url)
                        let duplicateNote = summary.skipped > 0 ? " Se omitieron \(summary.skipped) repetidos." : ""
                        let reviewNote = summary.requiresReview ? " Quedó pendiente de revisión manual." : ""
                        importMessage = "\(summary.source) · \(summary.period): se agregaron \(summary.imported) movimientos.\(duplicateNote)\(reviewNote)"
                    } catch {
                        importMessage = error.localizedDescription
                    }
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
                .foregroundStyle(.marcelitoNavy)
            Text("Empieza con tus estados reales")
                .font(.title2.bold())
            Text("Marcelito no carga cifras de muestra. Importa un PDF mensual para guardar banco, periodo y movimientos en este dispositivo.")
                .foregroundStyle(.secondary)
            Button("Importar primer estado", action: importAction)
                .buttonStyle(.borderedProminent)
                .tint(.marcelitoNavy)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .foregroundStyle(.marcelitoNavy)
        .background(Color.marcelitoCreamSoft, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct NetWorthSummary: View {
    let hasData: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Patrimonio líquido").foregroundStyle(.secondary)
            Text("—")
                .font(.largeTitle.bold())
                .monospacedDigit()
            Text(hasData ? "Pendiente de saldos al corte" : "Importa un estado para comenzar")
                .font(.subheadline)
                .foregroundStyle(.marcelitoNavyMid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .foregroundStyle(.marcelitoNavy)
        .background(Color.marcelitoCreamSoft, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct MetricsStrip: View {
    let income: Decimal
    let transfers: Decimal
    let monthlyExpense: Decimal

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                MetricTile(title: "Ingresos", value: income, symbol: "arrow.down.circle.fill", color: .marcelitoNavyMid)
                MetricTile(title: "Transferencias", value: transfers, symbol: "arrow.left.arrow.right.circle.fill", color: .marcelitoNavySoft)
                MetricTile(title: "Gasto del mes", value: monthlyExpense, symbol: "receipt.fill", color: .marcelitoNavy)
            }
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
        .frame(width: 156, alignment: .leading)
        .padding()
        .foregroundStyle(.marcelitoNavy)
        .background(Color.marcelitoCreamSoft, in: RoundedRectangle(cornerRadius: 16))
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
        .padding()
        .foregroundStyle(.marcelitoNavy)
        .background(Color.marcelitoNavy.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct MoneyFlowView: View {
    let store: FinanceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Así se movió tu dinero").font(.title2.bold())
            FlowLine(flow: .income, value: store.totalIncome)
            FlowLine(flow: .transfer, value: store.totalTransfers)
            FlowLine(flow: .expense, value: store.totalExpenses)
        }
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
