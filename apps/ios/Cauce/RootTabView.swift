import SwiftUI
import UniformTypeIdentifiers
import Foundation
import Charts

struct RootTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Resumen", systemImage: "house.fill") }
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
    @State private var importReport: ImportReport?
    @State private var isImporting = false
    @State private var importProgress = 0
    @State private var importStatus = "Preparando…"
    @State private var isDiagnosticsPresented = false

    private var hasData: Bool { !store.movements.isEmpty || !store.statements.isEmpty }

    @ViewBuilder
    private var homeContent: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            if hasData {
                NetWorthSummary(store: store)
                LedgerQualityBanner(store: store)
                MetricsStrip()
                if store.dashboardIsBlocked {
                    HistoricalDashboardBlockedCard(store: store)
                } else {
                    CashFlowChart(store: store)
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
                    Label("\(statement.source) · \(conciseStatementPeriod(statement))", systemImage: statement.requiresReview ? "exclamationmark.triangle" : "checkmark.circle")
                }
            }
            Button {
                isDiagnosticsPresented = true
            } label: {
                Label("Diagnóstico", systemImage: "stethoscope")
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
            .navigationTitle("Resumen")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.marcelitoCream, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .disabled(isImporting)
            .overlay {
                if isImporting {
                    ImportProgressOverlay(progress: importProgress, status: importStatus)
                        .transition(.opacity)
                }
            }
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
                        importReport = ImportReport(
                            fileCount: 0,
                            items: [],
                            selectionError: "No elegiste ningún PDF. Selecciona un estado de cuenta para revisar sus movimientos."
                        )
                        return
                    }
                    isImporting = true
                    importProgress = 0
                    importStatus = urls.count == 1 ? "Preparando el estado…" : "Preparando \(urls.count) estados…"
                    DiagnosticsRecorder.record(
                        stage: "import.start",
                        message: "Importación iniciada: \(urls.count) PDF(s)."
                    )
                    Task { @MainActor in
                        var items: [ImportReportItem] = []
                        for (index, url) in urls.enumerated() {
                            importStatus = "Leyendo \(url.lastPathComponent)…"
                            let completedCount = Double(index)
                            let totalCount = max(Double(urls.count), 1)
                            let completedPercent = (completedCount / totalCount) * 100
                            importProgress = Int(completedPercent.rounded())
                            // Give SwiftUI one frame to present the loading
                            // overlay before PDFKit/Vision starts its work.
                            await Task.yield()
                            do {
                                let summary = try store.importPDF(from: url)
                                items.append(ImportReportItem(summary: summary))
                                DiagnosticsRecorder.record(
                                    stage: "import.file",
                                    message: "\(summary.source) · \(summary.period): \(summary.imported) movimiento(s)\(summary.usedOCR ? " · OCR" : "")."
                                )
                            } catch {
                                DiagnosticsRecorder.record(
                                    level: "error",
                                    stage: "import.error",
                                    message: "\(url.lastPathComponent): \(error.localizedDescription)"
                                )
                                items.append(ImportReportItem(
                                    fileName: url.lastPathComponent,
                                    errorMessage: error.localizedDescription
                                ))
                            }
                            let finishedCount = Double(index + 1)
                            let finishedPercent = (finishedCount / totalCount) * 100
                            importProgress = Int(finishedPercent.rounded())
                            await Task.yield()
                        }
                        importStatus = "Listo"
                        isImporting = false
                        importReport = ImportReport(fileCount: urls.count, items: items)
                        DiagnosticsRecorder.record(
                            stage: "import.done",
                            message: "Importación terminada: \(items.filter { $0.errorMessage == nil }.count)/\(urls.count) archivo(s) procesado(s)."
                        )
                    }
                case .failure(let error):
                    isImporting = false
                    DiagnosticsRecorder.record(level: "error", stage: "import.selection", message: error.localizedDescription)
                    importReport = ImportReport(
                        fileCount: 0,
                        items: [],
                        selectionError: error.localizedDescription
                    )
                }
            }
            .sheet(item: $importReport) { report in
                ImportReportSheet(report: report)
            }
            .sheet(isPresented: $isDiagnosticsPresented) {
                DiagnosticsView()
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
            .task {
                guard store.hasCanonicalRebuildPending else { return }
                isImporting = true
                importProgress = 0
                importStatus = "Reconstruyendo el libro canónico…"
                await Task.yield()
                let result = store.rebuildCanonicalLedgerIfNeeded { completed, total, fileName in
                    let denominator = max(total, 1)
                    importProgress = Int((Double(completed) / Double(denominator) * 100).rounded())
                    importStatus = "Validando \(fileName)…"
                }
                importProgress = 100
                if result.invalidCount > 0 {
                    importStatus = "\(result.importedCount) estados listos · \(result.invalidCount) requieren revisión"
                } else {
                    importStatus = "\(result.importedCount) estados reconstruidos"
                }
                await Task.yield()
                isImporting = false
                store.runAutomaticAudit(trigger: "launch")
            }
        }
    }
}

private struct ImportReport: Identifiable {
    let id = UUID()
    let fileCount: Int
    let items: [ImportReportItem]
    let selectionError: String?

    init(fileCount: Int, items: [ImportReportItem], selectionError: String? = nil) {
        self.fileCount = fileCount
        self.items = items
        self.selectionError = selectionError
    }

    var hasErrors: Bool {
        selectionError != nil || items.contains { $0.errorMessage != nil || $0.imported == 0 }
    }

    var totalImported: Int {
        items.reduce(0) { $0 + $1.imported }
    }

    var reviewCount: Int {
        items.filter { $0.requiresReview }.count
    }

    var title: String {
        if selectionError != nil { return "No se pudo importar" }
        if items.isEmpty { return "No hay archivos para revisar" }
        if items.allSatisfy({ $0.imported == 0 && $0.errorMessage == nil }) {
            return "Necesita atención"
        }
        return hasErrors ? "Importación completada" : "Datos listos para revisar"
    }

    var subtitle: String {
        if let selectionError { return selectionError }
        if items.isEmpty { return "Selecciona un PDF mensual para comenzar." }
        let files = fileCount == 1 ? "1 archivo revisado" : "\(fileCount) archivos revisados"
        let movements = totalImported == 1 ? "1 movimiento nuevo" : "\(totalImported) movimientos nuevos"
        return "\(files) · \(movements)"
    }
}

private struct ImportReportItem: Identifiable {
    enum State: Equatable {
        case imported
        case review
        case empty
        case error

        var icon: String {
            switch self {
            case .imported: "checkmark.circle.fill"
            case .review: "checkmark.seal.fill"
            case .empty: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .imported: .marcelitoSuccess
            case .review: .marcelitoNavyMid
            case .empty: .marcelitoAmber
            case .error: .marcelitoDanger
            }
        }
    }

    let id = UUID()
    let fileName: String
    let source: String?
    let period: String?
    let imported: Int
    let skipped: Int
    let requiresReview: Bool
    let usedOCR: Bool
    let errorMessage: String?
    let sourceDetection: SourceDetectionEvidence?
    let ocrConfidence: Double?
    let ocrPageConfidences: [Double]?

    init(summary: ImportSummary) {
        fileName = summary.fileName
        source = summary.source
        period = summary.period
        imported = summary.imported
        skipped = summary.skipped
        requiresReview = summary.requiresReview
        usedOCR = summary.usedOCR
        errorMessage = nil
        sourceDetection = summary.sourceDetection
        ocrConfidence = summary.ocrConfidence
        ocrPageConfidences = summary.ocrPageConfidences
    }

    init(fileName: String, errorMessage: String) {
        self.fileName = fileName
        source = nil
        period = nil
        imported = 0
        skipped = 0
        requiresReview = false
        usedOCR = false
        self.errorMessage = errorMessage
        sourceDetection = nil
        ocrConfidence = nil
        ocrPageConfidences = nil
    }

    var state: State {
        if errorMessage != nil { return .error }
        if imported == 0 { return .empty }
        return requiresReview ? .review : .imported
    }

    var heading: String {
        if let source, let period { return "\(source) · \(period)" }
        return fileName
    }

    var statusText: String {
        if let errorMessage { return errorMessage }
        if imported == 0 { return "No se encontraron movimientos" }
        return imported == 1 ? "1 movimiento nuevo" : "\(imported) movimientos nuevos"
    }
}

private struct ImportReportSheet: View {
    let report: ImportReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryHeader

                    if !report.items.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Archivos")
                                .font(.headline)
                                .foregroundStyle(Color.marcelitoNavy)

                            ForEach(report.items) { item in
                                ImportReportRow(item: item)
                            }
                        }
                    }

                    if report.reviewCount > 0 {
                        Label(
                            "El OCR ayuda a leer escaneos, pero conviene confirmar los importes en Movimientos.",
                            systemImage: "info.circle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(Color.marcelitoNavyMid)
                        .padding(.horizontal, 2)
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .background(Color.marcelitoCream.ignoresSafeArea())
            .navigationTitle("Importación")
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

    private var summaryHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: report.hasErrors ? "arrow.triangle.2.circlepath" : "checkmark.seal.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(report.hasErrors ? Color.marcelitoAmber : Color.marcelitoSuccess)
                .frame(width: 44, height: 44)
                .background(
                    (report.hasErrors ? Color.marcelitoAmber : Color.marcelitoSuccess).opacity(0.14),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(report.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.marcelitoNavy)
                Text(report.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.marcelitoNavyMid)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.marcelitoCreamSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ImportReportRow: View {
    let item: ImportReportItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.state.icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(item.state.color)
                .frame(width: 34, height: 34)
                .background(item.state.color.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.heading)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.marcelitoNavy)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if item.usedOCR {
                        Text(item.ocrConfidence.map { "OCR \(Int(($0 * 100).rounded()))%" } ?? "OCR")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.marcelitoNavyMid)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.marcelitoNavy.opacity(0.08), in: Capsule())
                    }
                }

                Text(item.statusText)
                    .font(.subheadline)
                    .foregroundStyle(item.state == .empty || item.state == .error ? item.state.color : Color.marcelitoNavyMid)
                    .fixedSize(horizontal: false, vertical: true)

                Text(item.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let detection = item.sourceDetection {
                    Text("Emisor \(Int((detection.confidence * 100).rounded()))% · \(detection.evidence.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(detection.status == .verified ? Color.marcelitoSuccess : Color.marcelitoAmber)
                        .fixedSize(horizontal: false, vertical: true)
                    if !detection.ignoredBodyMentions.isEmpty {
                        Text("Mención(es) ignorada(s) en movimientos: \(detection.ignoredBodyMentions.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(Color.marcelitoNavyMid)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if item.skipped > 0 || item.requiresReview {
                    HStack(spacing: 6) {
                        if item.skipped > 0 {
                            Text("\(item.skipped) repetidos omitidos")
                        }
                        if item.requiresReview {
                            Text("Revisa algunos datos")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(Color.marcelitoNavySoft)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(Color.marcelitoCreamSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            Text("Marcelito no carga cifras de muestra. Importa un PDF mensual de cualquier banco o tarjeta para guardar cuenta, periodo y movimientos en este dispositivo.")
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

struct LedgerQualityBanner: View {
    let store: FinanceStore

    private var percentText: String {
        "\(Int(store.ledgerQuality.reconciledPercent.rounded()))% conciliado"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: store.dashboardIsBlocked ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundStyle(store.dashboardIsBlocked ? Color.marcelitoAmber : Color.marcelitoSuccess)
            VStack(alignment: .leading, spacing: 3) {
                Text("Calidad de datos / conciliación")
                    .font(.caption.weight(.semibold))
                Text(percentText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let message = store.ledgerQuality.message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(store.dashboardIsBlocked ? Color.marcelitoAmber : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.marcelitoNavy)
        .padding(12)
        .background(
            (store.dashboardIsBlocked ? Color.marcelitoAmber : Color.marcelitoSuccess).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Calidad de datos \(percentText)")
    }
}

struct HistoricalDashboardBlockedCard: View {
    let store: FinanceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Histórico bloqueado", systemImage: "lock.fill")
                .font(.subheadline.weight(.semibold))
            Text(store.ledgerQuality.message ?? "Valida los estados de cuenta antes de usar tendencias históricas.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Los movimientos cuestionables se conservaron fuera del libro canónico.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(Color.marcelitoNavy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .marcelitoCard(fill: Color.marcelitoCreamSoft, radius: 16, padding: 18)
    }
}

private struct ImportProgressOverlay: View {
    let progress: Int
    let status: String

    var body: some View {
        ZStack {
            Color.marcelitoNavy.opacity(0.16)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.marcelitoNavy)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Cargando estados…")
                            .font(.headline)
                            .foregroundStyle(Color.marcelitoNavy)
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(Color.marcelitoNavyMid)
                            .lineLimit(2)
                    }
                }
                ProgressView(value: Double(progress), total: 100)
                    .tint(Color.marcelitoAmber)
                Text("\(progress)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(Color.marcelitoCream, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Color.marcelitoNavy.opacity(0.18), radius: 18, y: 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Cargando estados de cuenta")
            .accessibilityValue(status)
        }
    }
}

enum DashboardMetric: String, Identifiable {
    case patrimony
    case cash
    case debt
    case expense
    case flow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .patrimony: "Patrimonio líquido"
        case .cash: "Efectivo disponible"
        case .debt: "Deuda total"
        case .expense: "Gasto del mes"
        case .flow: "Flujo neto"
        }
    }

    var symbol: String {
        switch self {
        case .patrimony: "chart.line.uptrend.xyaxis"
        case .cash: "wallet.pass.fill"
        case .debt: "creditcard.fill"
        case .expense: "receipt.fill"
        case .flow: "arrow.left.arrow.right"
        }
    }

    var color: Color {
        switch self {
        case .patrimony: Color.marcelitoNavy
        case .cash: Color.marcelitoNavyMid
        case .debt: Color.marcelitoNavy
        case .expense: Color.marcelitoAmber
        case .flow: Color.marcelitoNavyMid
        }
    }

    var explanation: String {
        switch self {
        case .patrimony: "Efectivo disponible menos la deuda total registrada."
        case .cash: "Suma de los saldos de tus cuentas de efectivo en los últimos cortes."
        case .debt: "Deuda registrada en tus tarjetas en los últimos cortes."
        case .expense: "Gasto real del mes, sin pagos de tarjeta ni transferencias internas."
        case .flow: "Ingresos reales menos gasto real del periodo."
        }
    }
}

private struct NetWorthSummary: View {
    let store: FinanceStore
    @State private var selectedMetric: DashboardMetric?

    private var displayValue: String {
        if store.dashboardIsBlocked { return "Bloqueado" }
        guard let value = store.liquidPatrimony else { return "—" }
        return value.formatted(.currency(code: "MXN").precision(.fractionLength(0)))
    }

    private var trendText: String {
        if store.dashboardIsBlocked { return "Conciliación requerida antes de mostrar el patrimonio" }
        guard let trend = store.liquidPatrimonyChangePercent else { return "Compara con tu siguiente corte" }
        let percent = Int((NSDecimalNumber(decimal: trend).doubleValue * 100).rounded())
        return "\(percent >= 0 ? "+" : "−")\(abs(percent))% vs mes anterior"
    }

    var body: some View {
        Button {
            selectedMetric = .patrimony
        } label: {
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
                Text(trendText)
                    .font(.subheadline)
                    .foregroundStyle(Color.marcelitoCream.opacity(0.78))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color.marcelitoCream)
            .marcelitoCard(fill: Color.marcelitoNavy, radius: 18, padding: 20)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Toca para ver el detalle y la tendencia del patrimonio")
        .sheet(item: $selectedMetric) { metric in
            MetricDetailSheet(metric: metric, store: store)
        }
    }
}

private struct DecisionMetricsView: View {
    @Environment(FinanceStore.self) private var store

    private func money(_ value: Decimal?) -> String {
        if store.dashboardIsBlocked { return "Bloqueado" }
        return value?.formatted(.currency(code: "MXN").precision(.fractionLength(0))) ?? "Pendiente"
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
            CalculationLine(label: "Saldo acumulado", value: money(store.accumulatedBalance), detail: "Cargos − abonos − créditos")
            CalculationLine(label: "Porcentaje pagado", value: percent(store.paidPercent), detail: "Abonos / nuevos cargos")
            CalculationLine(label: "Porcentaje pendiente", value: percent(store.pendingPercent), detail: "Saldo / nuevos cargos")
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
    @Environment(FinanceStore.self) private var store
    @State private var selectedMetric: DashboardMetric?

    private func money(_ value: Decimal?) -> String {
        if store.dashboardIsBlocked { return "Bloqueado" }
        return value?.formatted(.currency(code: "MXN").precision(.fractionLength(0))) ?? "Pendiente"
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            MetricTile(title: "Efectivo disponible", value: money(store.cashAvailable), symbol: "wallet.pass.fill", color: Color.marcelitoNavyMid) { selectedMetric = .cash }
            MetricTile(title: "Deuda total", value: money(store.debtTotal), symbol: "creditcard.fill", color: Color.marcelitoNavy) { selectedMetric = .debt }
            MetricTile(title: "Gasto del mes", value: money(store.monthlyExpense), symbol: "receipt.fill", color: Color.marcelitoAmber) { selectedMetric = .expense }
            MetricTile(title: "Flujo neto", value: money(store.monthlyNetFlow), symbol: "chart.line.uptrend.xyaxis", color: Color.marcelitoNavyMid) { selectedMetric = .flow }
        }
        .sheet(item: $selectedMetric) { metric in
            MetricDetailSheet(metric: metric, store: store)
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, minHeight: 106, alignment: .leading)
            .foregroundStyle(Color.marcelitoNavy)
            .marcelitoCard(fill: Color.marcelitoCreamSoft, radius: 14, padding: 14)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Toca para ver el detalle y la tendencia")
    }
}

private struct MetricTrendPoint: Identifiable {
    let id: String
    let label: String
    let value: Double
}

struct MetricDetailSheet: View {
    let metric: DashboardMetric
    let store: FinanceStore
    @Environment(\.dismiss) private var dismiss

    private var value: Decimal? {
        switch metric {
        case .patrimony: store.liquidPatrimony
        case .cash: store.cashAvailable
        case .debt: store.debtTotal
        case .expense: store.monthlyExpense
        case .flow: store.monthlyNetFlow
        }
    }

    private var trend: [MetricTrendPoint] {
        switch metric {
        case .patrimony:
            patrimonyTrend()
        case .cash:
            statementTrend(kind: .bank, keyPath: \.cashBalance)
        case .debt:
            statementTrend(kind: .card, keyPath: \.debtBalance)
        case .expense:
            store.cashFlowHistory.suffix(12).map { point in
                MetricTrendPoint(id: point.id.description, label: dateLabel(point.date), value: point.expense)
            }
        case .flow:
            store.cashFlowHistory.suffix(12).map { point in
                MetricTrendPoint(id: point.id.description, label: dateLabel(point.date), value: point.balance)
            }
        }
    }

    private func dateLabel(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    private func statementTrend(kind: StatementKind, keyPath: KeyPath<StatementMetric, Decimal?>) -> [MetricTrendPoint] {
        var seen = Set<String>()
        let points = store.periodMetrics.reversed().compactMap { metric -> MetricTrendPoint? in
            guard metric.kind == kind, seen.insert(metric.period).inserted else { return nil }
            let values = store.periodMetrics
                .filter { $0.kind == kind && $0.period == metric.period }
                .compactMap { $0[keyPath: keyPath] }
            guard !values.isEmpty else { return nil }
            let total = values.reduce(Decimal(0), +)
            return MetricTrendPoint(
                id: "\(kind.rawValue)-\(metric.period)",
                label: metric.period,
                value: NSDecimalNumber(decimal: total).doubleValue
            )
        }
        return Array(points.suffix(8))
    }

    private func patrimonyTrend() -> [MetricTrendPoint] {
        var seen = Set<String>()
        let points = store.periodMetrics.reversed().compactMap { metric -> MetricTrendPoint? in
            guard seen.insert(metric.period).inserted else { return nil }
            let group = store.periodMetrics.filter { $0.period == metric.period }
            let cash = group.filter { $0.kind == .bank }.compactMap(\.cashBalance).reduce(Decimal(0), +)
            let debt = group.filter { $0.kind == .card }.compactMap(\.debtBalance).reduce(Decimal(0), +)
            guard group.contains(where: { $0.kind == .bank && $0.cashBalance != nil }),
                  group.contains(where: { $0.kind == .card && $0.debtBalance != nil }) else { return nil }
            return MetricTrendPoint(
                id: "patrimony-\(metric.period)",
                label: metric.period,
                value: NSDecimalNumber(decimal: cash - debt).doubleValue
            )
        }
        return Array(points.suffix(8))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(metric.title, systemImage: metric.symbol)
                            .font(.headline)
                            .foregroundStyle(metric.color)
                        Text(store.dashboardIsBlocked ? "Bloqueado" : (value?.formatted(.currency(code: "MXN").precision(.fractionLength(0))) ?? "Pendiente"))
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.marcelitoNavy)
                        Text(metric.explanation)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if store.dashboardIsBlocked {
                        HistoricalDashboardBlockedCard(store: store)
                    } else if trend.isEmpty {
                        Text("Aún no hay suficientes periodos para mostrar una tendencia.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 18)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Comportamiento reciente")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.marcelitoNavy)
                            Chart {
                                ForEach(trend) { point in
                                    LineMark(
                                        x: .value("Periodo", point.label),
                                        y: .value("Monto", point.value),
                                        series: .value("Serie", metric.title)
                                    )
                                    .foregroundStyle(metric.color)
                                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                                    PointMark(
                                        x: .value("Periodo", point.label),
                                        y: .value("Monto", point.value)
                                    )
                                    .foregroundStyle(metric.color)
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

                    Text("Los valores se actualizan al importar o corregir movimientos y estados de cuenta.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .background(Color.marcelitoCream.ignoresSafeArea())
            .navigationTitle("Detalle")
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

private struct CashFlowChart: View {
    let store: FinanceStore
    @State private var selectedPoint: CashFlowPoint?

    private var points: [CashFlowPoint] {
        store.cashFlowHistory
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.flatMap { [$0.income, $0.expense, $0.balance] }
        guard let minimumValue = values.min(), let maximumValue = values.max() else {
            return -1...1
        }

        if abs(maximumValue - minimumValue) < 0.01 {
            let padding = max(abs(maximumValue) * 0.2, 1)
            return (minimumValue - padding)...(maximumValue + padding)
        }

        let lowerBound = min(minimumValue, 0)
        let upperBound = max(maximumValue, 0)
        let padding = max((upperBound - lowerBound) * 0.12, 1)
        return (lowerBound - padding)...(upperBound + padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ingresos, gastos y balance")
                    .font(.title3.weight(.bold))
                Text("Monto en MXN · balance acumulado por fecha")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if points.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title2)
                        .foregroundStyle(Color.marcelitoNavyMid)
                    Text("Aún no hay movimientos con fecha")
                        .font(.subheadline.weight(.semibold))
                    Text("Importa un estado de cuenta para comparar visualmente tus ingresos y gastos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 16)
            } else {
                CashFlowLineChart(points: points, yDomain: yDomain, selectedPoint: $selectedPoint)

                Text("Transferencias internas y pagos de tarjeta no se muestran para no inflar el gasto.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(Color.marcelitoNavy)
        .marcelitoCard(fill: Color.marcelitoCreamSoft, radius: 16, padding: 18)
        .sheet(item: $selectedPoint) { point in
            CashFlowPointDetail(point: point, points: points)
        }
    }
}

private struct CashFlowLineChart: View {
    let points: [CashFlowPoint]
    let yDomain: ClosedRange<Double>
    @Binding var selectedPoint: CashFlowPoint?

    private var selectedIndex: Int? {
        guard let selectedPoint else { return nil }
        return points.firstIndex { $0.id == selectedPoint.id }
    }

    private func xPosition(index: Int, width: CGFloat) -> CGFloat {
        guard points.count > 1 else { return width / 2 }
        return CGFloat(index) / CGFloat(points.count - 1) * width
    }

    private func yPosition(value: Double, height: CGFloat) -> CGFloat {
        let range = max(yDomain.upperBound - yDomain.lowerBound, 1)
        let normalized = (value - yDomain.lowerBound) / range
        return height - CGFloat(normalized) * height
    }

    private func linePath(
        keyPath: KeyPath<CashFlowPoint, Double>,
        width: CGFloat,
        height: CGFloat
    ) -> Path {
        var path = Path()
        for (index, point) in points.enumerated() {
            let coordinate = CGPoint(
                x: xPosition(index: index, width: width),
                y: yPosition(value: point[keyPath: keyPath], height: height)
            )
            if index == 0 {
                path.move(to: coordinate)
            } else {
                path.addLine(to: coordinate)
            }
        }
        return path
    }

    private func axisLabel(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0)))
    }

    private func dateLabel(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    private func selectPoint(at locationX: CGFloat, width: CGFloat) {
        guard !points.isEmpty else { return }
        let leftInset: CGFloat = 44
        let plotWidth = max(width - leftInset, 1)
        let relativeX = min(max(locationX - leftInset, 0), plotWidth)
        let ratio = relativeX / plotWidth
        let rawIndex = Int((ratio * CGFloat(max(points.count - 1, 0))).rounded())
        let index = min(max(rawIndex, 0), points.count - 1)
        selectedPoint = points[index]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let plotHeight = max(geometry.size.height - 8, 1)
                let plotWidth = max(geometry.size.width - 44, 1)
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(axisLabel(yDomain.upperBound))
                        Spacer()
                        Text(axisLabel(0))
                        Spacer()
                        Text(axisLabel(yDomain.lowerBound))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: plotHeight, alignment: .trailing)

                    ZStack(alignment: .topLeading) {
                        Path { path in
                            let y = yPosition(value: 0, height: plotHeight)
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: plotWidth, y: y))
                        }
                        .stroke(Color.marcelitoNavy.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                        Path { path in
                            path.addPath(linePath(keyPath: \CashFlowPoint.income, width: plotWidth, height: plotHeight))
                        }
                        .stroke(Color.marcelitoSuccess, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                        Path { path in
                            path.addPath(linePath(keyPath: \CashFlowPoint.expense, width: plotWidth, height: plotHeight))
                        }
                        .stroke(Color.marcelitoAmber, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                        Path { path in
                            path.addPath(linePath(keyPath: \CashFlowPoint.balance, width: plotWidth, height: plotHeight))
                        }
                        .stroke(Color.marcelitoNavy, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [6, 4]))

                        if let selectedIndex {
                            let x = xPosition(index: selectedIndex, width: plotWidth)
                            Path { path in
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: plotHeight))
                            }
                            .stroke(Color.marcelitoNavy.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        }
                    }
                    .frame(width: plotWidth, height: plotHeight, alignment: .topLeading)
                    .offset(x: 44)
                }
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture()
                        .onEnded { event in
                            selectPoint(at: event.location.x, width: geometry.size.width)
                        }
                )
            }
            .frame(height: 170)

            if let first = points.first, let last = points.last {
                HStack {
                    Spacer().frame(width: 44)
                    Text(dateLabel(first.date))
                    Spacer()
                    if points.count > 2 {
                        Text(dateLabel(points[points.count / 2].date))
                        Spacer()
                    }
                    Text(dateLabel(last.date))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                CashFlowLegendItem(label: "Ingresos", color: Color.marcelitoSuccess)
                CashFlowLegendItem(label: "Gastos", color: Color.marcelitoAmber)
                CashFlowLegendItem(label: "Balance", color: Color.marcelitoNavy)
            }
            .font(.caption2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gráfica de líneas de ingresos, gastos y balance acumulado por fecha")
        .accessibilityHint("Toca una fecha para ver sus importes y comportamiento reciente")
    }
}

private struct CashFlowLegendItem: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
        }
        .foregroundStyle(Color.marcelitoNavy)
    }
}

private struct CashFlowPointDetail: View {
    let point: CashFlowPoint
    let points: [CashFlowPoint]
    @Environment(\.dismiss) private var dismiss

    private var nearbyPoints: [CashFlowPoint] {
        guard let index = points.firstIndex(where: { $0.id == point.id }) else { return [point] }
        let start = max(0, index - 3)
        let end = min(points.count, index + 4)
        return Array(points[start..<end])
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(point.date.formatted(.dateTime.day().month(.wide).year()))
                            .font(.title2.weight(.bold))
                        Text("Detalle del movimiento financiero")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        CashFlowDetailValue(title: "Ingresos", value: point.income, color: Color.marcelitoSuccess)
                        CashFlowDetailValue(title: "Gastos", value: point.expense, color: Color.marcelitoAmber)
                    }
                    CashFlowDetailValue(title: "Balance acumulado", value: point.balance, color: Color.marcelitoNavy)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Comportamiento cercano")
                            .font(.subheadline.weight(.semibold))
                        MiniCashFlowChart(points: nearbyPoints)
                            .frame(height: 150)
                        Text("El balance acumula ingresos menos gastos desde la primera fecha registrada.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(Color.marcelitoNavy)
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .background(Color.marcelitoCream.ignoresSafeArea())
            .navigationTitle("Detalle")
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

private struct CashFlowDetailValue: View {
    let title: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value, format: .currency(code: "MXN").precision(.fractionLength(0)))
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.marcelitoCreamSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct MiniCashFlowChart: View {
    let points: [CashFlowPoint]

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("Fecha", point.date),
                    y: .value("Monto", point.income),
                    series: .value("Serie", "Ingresos")
                )
                .foregroundStyle(Color.marcelitoSuccess)
                LineMark(
                    x: .value("Fecha", point.date),
                    y: .value("Monto", point.expense),
                    series: .value("Serie", "Gastos")
                )
                .foregroundStyle(Color.marcelitoAmber)
                LineMark(
                    x: .value("Fecha", point.date),
                    y: .value("Monto", point.balance),
                    series: .value("Serie", "Balance")
                )
                .foregroundStyle(Color.marcelitoNavy)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mini gráfica del comportamiento de ingresos, gastos y balance")
    }
}

private struct DecisionCallout: View {
    let statement: StatementRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Revisión de origen", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            Text(statement.map { "\($0.source) · \(conciseStatementPeriod($0)) está guardado como \($0.transactionCount) movimientos. Corrige categorías desde Movimientos antes de usarlo para decidir." } ?? "Importa un estado de cuenta para empezar a revisar.")
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
