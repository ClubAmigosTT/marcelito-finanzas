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

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    NetWorthSummary(value: store.liquidNetWorth)
                    MetricsStrip(cash: store.cash, debt: store.debt, monthlyExpense: store.monthlyExpense)
                    DecisionCallout()
                    MoneyFlowView()
                    if let lastImportedFile = store.lastImportedFile {
                        Label("Último estado importado: \(lastImportedFile)", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.marcelitoNavyMid)
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
                        if let lastImportedFile = store.lastImportedFile {
                            Label(lastImportedFile, systemImage: "doc.text.fill")
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
                        let duplicateNote = summary.skipped > 0
                            ? " Se omitieron \(summary.skipped) repetidos."
                            : ""
                        importMessage = "Se agregaron \(summary.imported) movimientos de \(summary.source).\(duplicateNote)"
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

private struct NetWorthSummary: View {
    let value: Decimal
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Patrimonio líquido").foregroundStyle(.secondary)
            Text(value, format: .currency(code: "MXN").precision(.fractionLength(0)))
                .font(.largeTitle.bold())
                .monospacedDigit()
                .minimumScaleFactor(0.75)
            Text("Subió $6,840 desde julio")
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
    let cash: Decimal
    let debt: Decimal
    let monthlyExpense: Decimal
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                MetricTile(title: "Efectivo", value: cash, symbol: "wallet.bifold.fill", color: .marcelitoNavyMid)
                MetricTile(title: "Deuda", value: debt, symbol: "creditcard.fill", color: .marcelitoNavy)
                MetricTile(title: "Gasto del mes", value: monthlyExpense, symbol: "receipt.fill", color: .marcelitoNavySoft)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Decisión para septiembre", systemImage: "lightbulb.fill")
                .font(.headline)
            Text("Reserva $6,500 antes del día 12 para cubrir Amex sin tocar tu fondo de viaje.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .foregroundStyle(.marcelitoNavy)
        .background(Color.marcelitoNavy.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct MoneyFlowView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Así se movió tu dinero").font(.title2.bold())
            ForEach(FlowKind.allCases) { flow in
                HStack {
                    Image(systemName: flow.symbol).foregroundStyle(flow.color)
                    Text(flow.rawValue)
                    Spacer()
                    Text(flow == .income ? "$48,200" : flow == .debt ? "$23,151" : "$19,405")
                        .monospacedDigit()
                }
                .padding(.vertical, 7)
            }
        }
    }
}
