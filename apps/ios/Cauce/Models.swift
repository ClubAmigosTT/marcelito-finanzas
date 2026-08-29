import CryptoKit
import Foundation
import LocalAuthentication
import Observation
import PDFKit
import Security
import SwiftUI

enum FlowKind: String, CaseIterable, Identifiable, Codable, Hashable {
    case income = "Ingreso"
    case transfer = "Transferencia"
    case expense = "Gasto"
    case debt = "Deuda"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .income: Color.marcelitoNavyMid
        case .transfer: Color.marcelitoNavySoft
        case .expense: Color.marcelitoNavy
        case .debt: Color.marcelitoNavy
        }
    }

    var symbol: String {
        switch self {
        case .income: "arrow.down.circle.fill"
        case .transfer: "arrow.left.arrow.right.circle.fill"
        case .expense: "receipt.fill"
        case .debt: "creditcard.fill"
        }
    }
}

enum MovementKind: String, CaseIterable, Identifiable, Codable, Hashable {
    case purchase = "Compra"
    case cardPayment = "Pago de tarjeta"
    case bankTransfer = "Traspaso propio"
    case income = "Ingreso"
    case credit = "Crédito contable"
    case refund = "Devolución"
    case msi = "MSI"
    case interest = "Interés"
    case fee = "Comisión"
    case other = "Otro"

    var id: String { rawValue }
}

enum StatementKind: String, Codable {
    case card
    case bank
    case unknown
}

struct StatementSummaryRecord: Codable {
    var previousBalance: Decimal? = nil
    var statementBalance: Decimal? = nil
    var debtBalance: Decimal? = nil
    var newTransactions: Decimal? = nil
    var payments: Decimal? = nil
    var credits: Decimal? = nil
    var newCharges: Decimal? = nil
    var interest: Decimal? = nil
    var fees: Decimal? = nil
    var creditLimit: Decimal? = nil
    var creditAvailable: Decimal? = nil
    var minimumPayment: Decimal? = nil
    var paymentForNoInterest: Decimal? = nil
    var cashBalance: Decimal? = nil
    var msiOriginalDeferred: Decimal? = nil
    var msiInstallments: Int? = nil
    var msiMonthlyLoad: Decimal? = nil
}

struct Movement: Identifiable, Codable {
    var id: UUID
    var date: Date
    var title: String
    var account: String
    var category: String
    var amount: Decimal
    var flow: FlowKind
    var statementId: UUID?
    var kind: MovementKind?
    var travelRelated: Bool

    init(
        id: UUID = UUID(),
        date: Date,
        title: String,
        account: String,
        category: String,
        amount: Decimal,
        flow: FlowKind,
        statementId: UUID? = nil,
        kind: MovementKind? = nil,
        travelRelated: Bool = false
    ) {
        self.id = id
        self.date = date
        self.title = title
        self.account = account
        self.category = category
        self.amount = amount
        self.flow = flow
        self.statementId = statementId
        self.kind = kind
        self.travelRelated = travelRelated
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, title, account, category, amount, flow, statementId, kind, travelRelated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        title = try container.decode(String.self, forKey: .title)
        account = try container.decode(String.self, forKey: .account)
        category = try container.decode(String.self, forKey: .category)
        amount = try container.decode(Decimal.self, forKey: .amount)
        flow = try container.decode(FlowKind.self, forKey: .flow)
        statementId = try container.decodeIfPresent(UUID.self, forKey: .statementId)
        kind = try container.decodeIfPresent(MovementKind.self, forKey: .kind)
        travelRelated = try container.decodeIfPresent(Bool.self, forKey: .travelRelated) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(title, forKey: .title)
        try container.encode(account, forKey: .account)
        try container.encode(category, forKey: .category)
        try container.encode(amount, forKey: .amount)
        try container.encode(flow, forKey: .flow)
        try container.encodeIfPresent(statementId, forKey: .statementId)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encode(travelRelated, forKey: .travelRelated)
    }
}

struct StatementRecord: Identifiable, Codable {
    var id: UUID
    var source: String
    var period: String
    var fileName: String
    var importedAt: Date
    var transactionCount: Int
    var requiresReview: Bool
    var kind: StatementKind? = nil
    var summary: StatementSummaryRecord? = nil
}

struct ImportSummary {
    let source: String
    let period: String
    let fileName: String
    let imported: Int
    let skipped: Int
    let requiresReview: Bool
    let summary: StatementSummaryRecord?
}

struct StatementMetric: Identifiable {
    let id: UUID
    let source: String
    let period: String
    let kind: StatementKind
    let newTransactions: Decimal
    let msiInstallments: Decimal
    let interest: Decimal
    let fees: Decimal
    let newCharges: Decimal
    let realPayments: Decimal
    let credits: Decimal
    let refunds: Decimal
    let difference: Decimal
    let accumulatedBalance: Decimal
    let travelSpend: Decimal
    let ordinarySpend: Decimal
    let creditLimit: Decimal?
    let creditAvailable: Decimal?
    let creditUsed: Decimal?
    let creditUtilizationRate: Decimal?
    let paymentForNoInterest: Decimal?
    let msiOriginalDeferred: Decimal?
    let msiInstallmentsCount: Int?
    let msiMonthlyLoad: Decimal?
    let cashBalance: Decimal?
    let debtBalance: Decimal?

    var paidPercent: Decimal? { newTransactions == 0 ? nil : realPayments / newTransactions }
    var pendingPercent: Decimal? { newTransactions == 0 ? nil : max(Decimal(0), accumulatedBalance) / newTransactions }
}

enum FinanceImportError: LocalizedError {
    case unreadableDocument
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case .unreadableDocument:
            "No pudimos leer este PDF. Verifica que sea un estado de cuenta válido."
        case .emptyDocument:
            "El PDF no contiene movimientos reconocibles. Ve a Movimientos y usa + para agregarlos manualmente."
        }
    }
}

@Observable
final class FinanceStore {
    private let movementKey = "marcelito.movements.v2"
    private let statementKey = "marcelito.statements.v1"
    private let importKey = "marcelito.lastImport"

    var movements: [Movement]
    var statements: [StatementRecord]

    private(set) var lastImportedFile: String?

    var periodMetrics: [StatementMetric] { statements.map { calculateMetric(for: $0) }.sorted { periodKey($0.period) > periodKey($1.period) } }
    var cardPeriodMetrics: [StatementMetric] { periodMetrics.filter { $0.kind == .card } }
    var cardPeriodCount: Int { Set(cardPeriodMetrics.map { periodKey($0.period) }).count }
    var totalNewTransactions: Decimal { cardPeriodMetrics.reduce(0) { $0 + $1.newTransactions } }
    var averageMonthlySpend: Decimal { cardPeriodCount == 0 ? 0 : totalNewTransactions / Decimal(cardPeriodCount) }
    var totalNewCharges: Decimal { cardPeriodMetrics.reduce(0) { $0 + $1.newCharges } }
    var totalRealPayments: Decimal { cardPeriodMetrics.reduce(0) { $0 + $1.realPayments } }
    var totalCredits: Decimal { cardPeriodMetrics.reduce(0) { $0 + $1.credits } }
    var totalRefunds: Decimal { cardPeriodMetrics.reduce(0) { $0 + $1.refunds } }
    var accumulatedBalance: Decimal { totalNewTransactions - totalRealPayments }
    var latestDifference: Decimal { cardPeriodMetrics.first?.difference ?? 0 }
    var paidPercent: Decimal? { totalNewTransactions == 0 ? nil : totalRealPayments / totalNewTransactions }
    var pendingPercent: Decimal? { totalNewTransactions == 0 ? nil : max(Decimal(0), accumulatedBalance) / totalNewTransactions }
    var travelSpend: Decimal { periodMetrics.reduce(0) { $0 + $1.travelSpend } }
    var travelPercent: Decimal? { consolidatedRealSpend == 0 ? nil : travelSpend / consolidatedRealSpend }
    var ordinarySpend: Decimal { max(Decimal(0), consolidatedRealSpend - travelSpend) }
    var ordinaryAverageMonthly: Decimal { cardPeriodCount == 0 ? 0 : ordinarySpend / Decimal(cardPeriodCount) }
    var latestMsiMonthlyLoad: Decimal? { cardPeriodMetrics.first?.msiMonthlyLoad }
    var latestMsiOriginalDeferred: Decimal? { cardPeriodMetrics.first?.msiOriginalDeferred }
    var latestMsiInstallmentsCount: Int? { cardPeriodMetrics.first?.msiInstallmentsCount }
    var latestPaymentForNoInterest: Decimal? { cardPeriodMetrics.first?.paymentForNoInterest }
    var cardSpend: Decimal { cardPeriodMetrics.reduce(0) { $0 + $1.newCharges } }
    var directBankSpend: Decimal {
        movements.filter { movement in
            guard isSpend(movement), let statementId = movement.statementId,
                  let statement = statements.first(where: { $0.id == statementId }) else { return false }
            return statementKind(statement) == .bank
        }.reduce(0) { $0 + absolute($1.amount) }
    }
    var rawExpense: Decimal { movements.filter { $0.flow == .expense }.reduce(0) { $0 + absolute($1.amount) } }
    var excludedCardPayments: Decimal { movements.filter { movementKind($0) == .cardPayment }.reduce(0) { $0 + absolute($1.amount) } }
    var excludedInternalTransfers: Decimal { movements.filter { movementKind($0) == .bankTransfer }.reduce(0) { $0 + absolute($1.amount) } }
    var consolidatedRealSpend: Decimal {
        let manualSpend = movements.filter { $0.statementId == nil && isSpend($0) }.reduce(0) { $0 + absolute($1.amount) }
        return max(Decimal(0), cardSpend + directBankSpend + manualSpend - totalRefunds)
    }
    var totalIncome: Decimal { realIncome }
    var totalTransfers: Decimal { movements.filter { $0.flow == .transfer }.reduce(0) { $0 + absolute($1.amount) } }
    var totalExpenses: Decimal { consolidatedRealSpend }
    var realExpenseMovements: [Movement] { movements.filter(isSpend) }
    var realIncome: Decimal {
        movements.filter { movement in
            guard movement.flow == .income else { return false }
            let kind = movementKind(movement)
            if kind == .credit || kind == .refund { return false }
            if let statementId = movement.statementId,
               let statement = statements.first(where: { $0.id == statementId }), statementKind(statement) == .card {
                return false
            }
            return true
        }.reduce(0) { $0 + absolute($1.amount) }
    }
    var netFlow: Decimal { realIncome - consolidatedRealSpend }
    var savingsRate: Decimal? { realIncome == 0 ? nil : netFlow / realIncome }
    var cashAvailable: Decimal? {
        let values = latestMetricsBySource(periodMetrics.filter { $0.kind == .bank }).compactMap { $0.cashBalance }
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    var debtTotal: Decimal? {
        let values = latestMetricsBySource(cardPeriodMetrics).compactMap { $0.debtBalance }
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    var liquidPatrimony: Decimal? {
        guard let cashAvailable, let debtTotal else { return nil }
        return cashAvailable - debtTotal
    }
    var creditLimit: Decimal? {
        let values = latestMetricsBySource(cardPeriodMetrics).compactMap { $0.creditLimit }
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    var creditAvailable: Decimal? {
        let values = latestMetricsBySource(cardPeriodMetrics).compactMap { $0.creditAvailable }
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    var creditUsed: Decimal? {
        guard let creditLimit, let creditAvailable else { return nil }
        return max(Decimal(0), creditLimit - creditAvailable)
    }
    var creditUtilizationRate: Decimal? {
        guard let creditLimit, creditLimit != 0, let creditUsed else { return nil }
        return creditUsed / creditLimit
    }

    var monthlyExpense: Decimal {
        let monthStart = Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month], from: .now)
        ) ?? .now
        return movements
            .filter { isSpend($0) && $0.date >= monthStart }
            .reduce(0) { $0 + absolute($1.amount) }
    }

    private func absolute(_ value: Decimal) -> Decimal { value < 0 ? -value : value }

    private func statementKind(_ statement: StatementRecord) -> StatementKind {
        if let kind = statement.kind { return kind }
        return statement.source.localizedCaseInsensitiveContains("Amex") ? .card : .bank
    }

    private func movementKind(_ movement: Movement) -> MovementKind {
        if let kind = movement.kind { return kind }
        let value = movement.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if value.contains("msi") || value.contains("meses sin intereses") || value.contains("diferid") { return .msi }
        if value.contains("interes") { return .interest }
        if value.contains("comision") || value.contains("anualidad") { return .fee }
        if (value.contains("devolucion") || value.contains("reembolso") || value.contains("bonificacion")) && movement.amount > 0 { return .refund }
        if value.contains("pago") && (value.contains("tarjeta") || value.contains("amex") || value.contains("credito")) { return .cardPayment }
        if movement.flow == .transfer { return value.contains("transfer") || value.contains("traspaso") ? .bankTransfer : .cardPayment }
        if movement.flow == .income { return value.contains("credito") || value.contains("abono") ? .credit : .income }
        return movement.flow == .expense ? .purchase : .other
    }

    private func isSpend(_ movement: Movement) -> Bool {
        guard movement.flow == .expense else { return false }
        return ![.cardPayment, .bankTransfer, .refund].contains(movementKind(movement))
    }

    private func isTravel(_ movement: Movement) -> Bool {
        if movement.travelRelated { return true }
        let value = "\(movement.title) \(movement.category)".folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return ["viaje", "hotel", "hospedaje", "aerolinea", "vuelo", "avion", "transporte", "uber", "taxi", "metro", "renta de auto", "destino", "equipaje"].contains { value.contains($0) }
    }

    private func periodKey(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
    }

    private func summaryValue(_ summary: StatementSummaryRecord?, _ keyPath: KeyPath<StatementSummaryRecord, Decimal?>, fallback: Decimal) -> Decimal {
        guard let value = summary?[keyPath: keyPath] else { return fallback }
        return absolute(value)
    }

    private func latestMetricsBySource(_ metrics: [StatementMetric]) -> [StatementMetric] {
        var latest: [String: StatementMetric] = [:]
        for metric in metrics where latest[metric.source] == nil {
            latest[metric.source] = metric
        }
        return Array(latest.values)
    }

    private func calculateMetric(for statement: StatementRecord) -> StatementMetric {
        let kind = statementKind(statement)
        let linked = movements.filter { $0.statementId == statement.id }
        let spend = linked.filter(isSpend)
        let regular = spend.filter { movementKind($0) == .purchase }
        let msi = spend.filter { movementKind($0) == .msi }
        let interests = spend.filter { movementKind($0) == .interest }
        let fees = spend.filter { movementKind($0) == .fee }
        let payments = linked.filter { movementKind($0) == .cardPayment }
        let credits = linked.filter { movementKind($0) == .credit }
        let refunds = linked.filter { movementKind($0) == .refund }
        let newTransactions = summaryValue(statement.summary, \.newTransactions, fallback: regular.reduce(0) { $0 + absolute($1.amount) })
        let msiFallback: Decimal
        if let original = statement.summary?.msiOriginalDeferred, let count = statement.summary?.msiInstallments, count > 0 {
            msiFallback = absolute(original) / Decimal(count)
        } else {
            msiFallback = msi.reduce(0) { $0 + absolute($1.amount) }
        }
        let msiInstallments = summaryValue(statement.summary, \.msiMonthlyLoad, fallback: msiFallback)
        let interest = summaryValue(statement.summary, \.interest, fallback: interests.reduce(0) { $0 + absolute($1.amount) })
        let feeTotal = summaryValue(statement.summary, \.fees, fallback: fees.reduce(0) { $0 + absolute($1.amount) })
        let newCharges = summaryValue(statement.summary, \.newCharges, fallback: newTransactions + msiInstallments + interest + feeTotal)
        let realPayments = summaryValue(statement.summary, \.payments, fallback: payments.reduce(0) { $0 + absolute($1.amount) })
        let creditTotal = summaryValue(statement.summary, \.credits, fallback: credits.reduce(0) { $0 + absolute($1.amount) })
        let refundTotal = refunds.reduce(0) { $0 + absolute($1.amount) }
        let travel = spend.filter(isTravel).reduce(0) { $0 + absolute($1.amount) }
        let previousBalance = statement.summary?.previousBalance.map(absolute)
        let paymentNoInterest = statement.summary?.paymentForNoInterest.map(absolute)
            ?? previousBalance.map { max(Decimal(0), $0 - realPayments - creditTotal + newCharges) }
            ?? statement.summary?.statementBalance.map(absolute)
        let creditLimit = statement.summary?.creditLimit.map(absolute)
        let creditAvailable = statement.summary?.creditAvailable.map(absolute)
        let creditUsed: Decimal?
        if let creditLimit, let creditAvailable {
            creditUsed = max(Decimal(0), creditLimit - creditAvailable)
        } else {
            creditUsed = nil
        }
        let utilization: Decimal?
        if let creditLimit, creditLimit != 0, let creditUsed {
            utilization = creditUsed / creditLimit
        } else {
            utilization = nil
        }
        let debt = statement.summary?.debtBalance.map(absolute)
            ?? (kind == .card ? statement.summary?.statementBalance.map(absolute) : nil)
        let cash = statement.summary?.cashBalance.map(absolute)

        return StatementMetric(
            id: statement.id,
            source: statement.source,
            period: statement.period,
            kind: kind,
            newTransactions: newTransactions,
            msiInstallments: msiInstallments,
            interest: interest,
            fees: feeTotal,
            newCharges: newCharges,
            realPayments: realPayments,
            credits: creditTotal,
            refunds: refundTotal,
            difference: newTransactions - realPayments,
            accumulatedBalance: newTransactions - realPayments,
            travelSpend: travel,
            ordinarySpend: max(Decimal(0), newCharges - travel),
            creditLimit: creditLimit,
            creditAvailable: creditAvailable,
            creditUsed: creditUsed,
            creditUtilizationRate: utilization,
            paymentForNoInterest: paymentNoInterest,
            msiOriginalDeferred: statement.summary?.msiOriginalDeferred.map(absolute),
            msiInstallmentsCount: statement.summary?.msiInstallments,
            msiMonthlyLoad: statement.summary?.msiMonthlyLoad.map(absolute) ?? (msiInstallments == 0 ? nil : msiInstallments),
            cashBalance: cash,
            debtBalance: debt
        )
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: movementKey),
           let saved = try? JSONDecoder().decode([Movement].self, from: data) {
            movements = saved
        } else {
            movements = []
        }
        if let data = defaults.data(forKey: statementKey),
           let saved = try? JSONDecoder().decode([StatementRecord].self, from: data) {
            statements = saved
        } else {
            statements = []
        }
        lastImportedFile = defaults.string(forKey: importKey)
    }

    func updateCategory(for movement: Movement, to category: String) {
        guard let index = movements.firstIndex(where: { $0.id == movement.id }) else { return }
        movements[index].category = category
        persist()
    }

    func updateClassification(for movement: Movement, kind: MovementKind, travelRelated: Bool) {
        guard let index = movements.firstIndex(where: { $0.id == movement.id }) else { return }
        movements[index].kind = kind
        movements[index].travelRelated = travelRelated
        switch kind {
        case .cardPayment, .bankTransfer:
            movements[index].flow = .transfer
        case .income, .credit, .refund:
            movements[index].flow = .income
        default:
            movements[index].flow = .expense
        }
        persist()
    }

    func updateStatementSummary(for statement: StatementRecord, summary: StatementSummaryRecord) {
        guard let index = statements.firstIndex(where: { $0.id == statement.id }) else { return }
        statements[index].summary = summary
        persist()
    }

    func addMovement(
        title: String,
        account: String,
        category: String,
        amount: Decimal,
        flow: FlowKind,
        date: Date
    ) {
        let signedAmount = flow == .income ? abs(amount) : -abs(amount)
        movements.insert(
            Movement(
                date: date,
                title: title,
                account: account,
                category: category,
                amount: signedAmount,
                flow: flow,
                statementId: nil
            ),
            at: 0
        )
        persist()
    }

    func clearLocalData() {
        movements = []
        statements = []
        lastImportedFile = nil
        persist()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: movementKey)
        defaults.removeObject(forKey: statementKey)
        defaults.removeObject(forKey: importKey)
    }

    func importPDF(from url: URL) throws -> ImportSummary {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let document = PDFDocument(url: url) else {
            throw FinanceImportError.unreadableDocument
        }

        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
        let candidates = Self.parse(text: text, fileName: url.lastPathComponent)
        let source = Self.accountName(from: url.lastPathComponent) == "Importado"
            ? Self.accountName(from: text)
            : Self.accountName(from: url.lastPathComponent)
        let period = Self.periodLabel(from: text, fileName: url.lastPathComponent)
        let summary = Self.summary(from: text, source: source)
        let existingStatement = statements.first(where: { $0.fileName == url.lastPathComponent })
        let statementId = existingStatement?.id ?? UUID()
        let existingKeys = Set(movements.filter { $0.statementId != statementId }.map(Self.identityKey))
        let fresh = candidates.compactMap { candidate -> Movement? in
            let keyed = Self.identityKey(candidate)
            guard !existingKeys.contains(keyed) else { return nil }
            var imported = candidate
            imported.statementId = statementId
            return imported
        }

        movements.removeAll { $0.statementId == statementId }
        movements.insert(contentsOf: fresh.reversed(), at: 0)
        let statement = StatementRecord(
            id: statementId,
            source: source,
            period: period,
            fileName: url.lastPathComponent,
            importedAt: .now,
            transactionCount: fresh.count,
            requiresReview: fresh.isEmpty,
            kind: source == "Amex" ? .card : .bank,
            summary: summary
        )
        if let index = statements.firstIndex(where: { $0.id == statementId }) {
            statements[index] = statement
        } else {
            statements.insert(statement, at: 0)
        }
        lastImportedFile = url.lastPathComponent
        persist()
        UserDefaults.standard.set(lastImportedFile, forKey: importKey)

        return ImportSummary(
            source: source,
            period: period,
            fileName: url.lastPathComponent,
            imported: fresh.count,
            skipped: candidates.count - fresh.count,
            requiresReview: fresh.isEmpty,
            summary: summary
        )
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(movements) else { return }
        UserDefaults.standard.set(data, forKey: movementKey)
        if let data = try? JSONEncoder().encode(statements) {
            UserDefaults.standard.set(data, forKey: statementKey)
        }
    }

    private static func identityKey(_ movement: Movement) -> String {
        "\(Calendar.current.startOfDay(for: movement.date).timeIntervalSince1970)|\(movement.title.lowercased())|\(movement.account.lowercased())|\(movement.amount)"
    }

    private static let demoMovements: [Movement] = [/*
        Movement(date: .now, title: "Nómina mensual", account: "Santander", category: "Ingresos", amount: 48_200, flow: .income),
        Movement(date: .now.addingTimeInterval(-86_400), title: "Pago de tarjeta", account: "Santander a Amex", category: "Transferencia", amount: -19_405, flow: .transfer),
        Movement(date: .now.addingTimeInterval(-172_800), title: "Supermercado", account: "Amex", category: "Alimentos", amount: -1_842.70, flow: .expense),
        Movement(date: .now.addingTimeInterval(-259_200), title: "Reserva de viaje", account: "Amex", category: "Viajes", amount: -6_270, flow: .expense)
    */]

    private struct TextMatch {
        let range: NSRange
        let text: String
    }

    private static func parse(text: String, fileName: String) -> [Movement] {
        let dateRegex = try? NSRegularExpression(
            pattern: #"(?<!\d)(\d{1,2})[\/\-.](\d{1,2})[\/\-.](\d{2,4})(?!\d)"#
        )
        let textDateRegex = try? NSRegularExpression(
            pattern: #"(?i)(?<!\d)(\d{1,2})\s+de\s+([A-Za-zÁÉÍÓÚáéíóú]+)(?:\s+de\s+(\d{4}))?"#
        )
        let amountRegex = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9])[-+]?\s*\$?\s*(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?(?![A-Za-z0-9])"#
        )
        let filenameAccount = accountName(from: fileName)
        let documentNormalized = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        let account = filenameAccount == "Importado"
            ? accountName(from: documentNormalized)
            : filenameAccount
        let ignoredPhrases = [
            "saldo anterior", "saldo al corte", "pago minimo",
            "limite de credito", "tasa anual", "numero de cuenta",
            "fecha de corte", "fecha limite", "total a pagar",
            "periodo de facturacion", "este no es un documento",
            "total de las transacciones", "el estado de cuenta incluye",
            "estimado cliente", "en caso de que la fecha"
        ]

        // Amex puts the merchant, RFC and amount on separate PDF text lines.
        // Group each date-started row before extracting the amount.
        var rows: [String] = []
        var pendingRow = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count > 1 else { continue }
            let hasDate = (dateRegex.flatMap { firstMatch(in: line, regex: $0) } != nil)
                || (textDateRegex.flatMap { firstMatch(in: line, regex: $0) } != nil)
            if hasDate {
                if !pendingRow.isEmpty { rows.append(pendingRow) }
                pendingRow = line
            } else if !pendingRow.isEmpty {
                pendingRow += " " + line
            }
        }
        if !pendingRow.isEmpty { rows.append(pendingRow) }

        return rows.compactMap { row in
            let original = row.trimmingCharacters(in: .whitespacesAndNewlines)
            guard original.count > 3 else { return nil }

            let normalized = original.folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: .current
            )
            guard !ignoredPhrases.contains(where: { normalized.contains($0) }) else { return nil }

            var working = original
            var date = Date()
            let dateMatch = dateRegex.flatMap { firstMatch(in: working, regex: $0) }
                ?? textDateRegex.flatMap { firstMatch(in: working, regex: $0) }
            if let dateMatch {
                date = parseDate(dateMatch.text) ?? date
                working = working.replacingCharacters(in: Range(dateMatch.range, in: working)!, with: " ")
            }

            guard let amountRegex,
                  let amountMatch = allMatches(in: working, regex: amountRegex).last,
                  let parsedAmount = parseAmount(amountMatch.text),
                  parsedAmount != 0,
                  abs(parsedAmount) < 10_000_000 else {
                return nil
            }
            working = working.replacingCharacters(in: Range(amountMatch.range, in: working)!, with: " ")

            let title = working
                .replacingOccurrences(of: #"\bRFC[A-Z0-9]+\b"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"/REF[A-Z0-9_]+\b"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\bCR\b"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count >= 3 else { return nil }
            guard title.rangeOfCharacter(from: .letters) != nil else { return nil }

            let titleNormalized = title.folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: .current
            )
            let flow: FlowKind
            if titleNormalized.contains("nomina")
                || titleNormalized.contains("sueldo")
                || titleNormalized.contains("deposito")
                || titleNormalized.contains("abono")
                || titleNormalized.contains("transferencia recibida") {
                flow = .income
            } else if titleNormalized.contains("pago")
                        && account.localizedCaseInsensitiveContains("Amex") {
                flow = .debt
            } else if titleNormalized.contains("transfer")
                        || titleNormalized.contains("traspaso")
                        || titleNormalized.contains("pago de tarjeta") {
                flow = .transfer
            } else {
                flow = .expense
            }

            let signedAmount = flow == .income ? abs(parsedAmount) : -abs(parsedAmount)
            let displayAccount = flow == .transfer && titleNormalized.contains("amex")
                ? "Santander a Amex"
                : account
            let category = category(for: titleNormalized, flow: flow)
            let kind: MovementKind
            if titleNormalized.contains("msi") || titleNormalized.contains("meses sin intereses") || titleNormalized.contains("diferid") {
                kind = .msi
            } else if titleNormalized.contains("interes") {
                kind = .interest
            } else if titleNormalized.contains("comision") || titleNormalized.contains("anualidad") {
                kind = .fee
            } else if (titleNormalized.contains("devolucion") || titleNormalized.contains("reembolso") || titleNormalized.contains("bonificacion")) && signedAmount > 0 {
                kind = .refund
            } else if titleNormalized.contains("pago") && (titleNormalized.contains("tarjeta") || titleNormalized.contains("amex") || titleNormalized.contains("credito")) {
                kind = .cardPayment
            } else if titleNormalized.contains("transfer") || titleNormalized.contains("traspaso") {
                kind = .bankTransfer
            } else if flow == .income {
                kind = titleNormalized.contains("credito") || titleNormalized.contains("abono") ? .credit : .income
            } else {
                kind = .purchase
            }
            let travelRelated = ["viaje", "hotel", "hospedaje", "aerolinea", "vuelo", "avion", "transporte", "uber", "taxi", "metro", "renta de auto", "destino", "equipaje"].contains { titleNormalized.contains($0) }

            return Movement(
                date: date,
                title: title,
                account: displayAccount,
                category: category,
                amount: signedAmount,
                flow: flow,
                kind: kind,
                travelRelated: travelRelated
            )
        }
    }

    private static func firstMatch(in string: String, regex: NSRegularExpression) -> TextMatch? {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let result = regex.firstMatch(in: string, range: range),
              let swiftRange = Range(result.range, in: string) else {
            return nil
        }
        return TextMatch(range: result.range, text: String(string[swiftRange]))
    }

    private static func allMatches(in string: String, regex: NSRegularExpression) -> [TextMatch] {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.matches(in: string, range: range).compactMap { result in
            guard let swiftRange = Range(result.range, in: string) else { return nil }
            return TextMatch(range: result.range, text: String(string[swiftRange]))
        }
    }

    private static func parseAmount(_ value: String) -> Decimal? {
        let cleaned = value
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: "")
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func parseDate(_ value: String) -> Date? {
        let normalized = value.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        let parts = normalized.split(whereSeparator: { character in
            character == "/" || character == "-" || character == "." || character == " "
        })
        guard let day = parts.first.flatMap({ Int($0) }) else { return nil }
        let monthToken = parts.dropFirst().first(where: {
            Int($0) != nil || monthNumber(String($0)) != nil
        })
        guard let monthToken else { return nil }
        let month = Int(monthToken) ?? monthNumber(String(monthToken))!
        let year = parts.dropFirst()
            .compactMap { Int($0) }
            .last(where: { $0 >= 100 })
            ?? Calendar.current.component(.year, from: .now)
        var dateComponents = DateComponents()
        dateComponents.day = day
        dateComponents.month = month
        dateComponents.year = year < 100 ? year + 2_000 : year
        return Calendar(identifier: .gregorian).date(from: dateComponents)
    }

    private static func monthNumber(_ value: String) -> Int? {
        switch value {
        case let month where month.hasPrefix("ene"): return 1
        case let month where month.hasPrefix("feb"): return 2
        case let month where month.hasPrefix("mar"): return 3
        case let month where month.hasPrefix("abr"): return 4
        case let month where month.hasPrefix("may"): return 5
        case let month where month.hasPrefix("jun"): return 6
        case let month where month.hasPrefix("jul"): return 7
        case let month where month.hasPrefix("ago"): return 8
        case let month where month.hasPrefix("sep") || month.hasPrefix("set"): return 9
        case let month where month.hasPrefix("oct"): return 10
        case let month where month.hasPrefix("nov"): return 11
        case let month where month.hasPrefix("dic"): return 12
        default: return nil
        }
    }

    private static func summary(from text: String, source: String) -> StatementSummaryRecord? {
        let normalized = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        func amount(after labels: [String]) -> Decimal? {
            let joined = labels.joined(separator: "|")
            let pattern = "(?:\(joined))[^0-9$-]{0,90}([-+]?\\s*\\$?\\s*(?:\\d{1,3}(?:,\\d{3})+|\\d+)(?:\\.\\d{1,2})?)"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: normalized, range: range),
                  let valueRange = Range(match.range(at: 1), in: normalized) else { return nil }
            return parseAmount(String(normalized[valueRange]))
        }

        var summary = StatementSummaryRecord()
        var hasValue = false
        func assign(_ keyPath: WritableKeyPath<StatementSummaryRecord, Decimal?>, _ value: Decimal?) {
            guard let value else { return }
            summary[keyPath: keyPath] = abs(value)
            hasValue = true
        }
        assign(\.previousBalance, amount(after: ["saldo anterior", "saldo previo"]))
        assign(\.statementBalance, amount(after: ["saldo nuevo", "saldo al corte", "saldo actual", "saldo deudor"]))
        assign(\.newTransactions, amount(after: ["nuevas transacciones", "compras nuevas"]))
        assign(\.payments, amount(after: ["pagos realizados", "pagos efectuados"]))
        assign(\.credits, amount(after: ["pagos y creditos", "creditos", "abonos"]))
        assign(\.newCharges, amount(after: ["nuevos cargos", "total de cargos"]))
        assign(\.interest, amount(after: ["intereses", "interes del periodo"]))
        assign(\.fees, amount(after: ["comisiones", "comision"]))
        assign(\.creditLimit, amount(after: ["limite de credito", "linea de credito"]))
        assign(\.creditAvailable, amount(after: ["credito disponible", "disponible para compras"]))
        assign(\.minimumPayment, amount(after: ["pago minimo"]))
        assign(\.paymentForNoInterest, amount(after: ["pago para no generar intereses", "pago para no generar interes"]))
        if source.localizedCaseInsensitiveContains("Amex") {
            summary.debtBalance = summary.statementBalance
        } else {
            summary.cashBalance = amount(after: ["saldo disponible", "saldo final", "saldo actual"]).map(abs)
            hasValue = hasValue || summary.cashBalance != nil
        }
        return hasValue ? summary : nil
    }

    private static func periodLabel(from text: String, fileName: String) -> String {
        let normalized = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        if let regex = try? NSRegularExpression(pattern: #"period(?:o|os)\s*(?:de\s+facturacion)?\s*[:-]?\s*([^\n]{8,80})"#),
           let match = regex.firstMatch(in: normalized, range: range),
           let valueRange = Range(match.range(at: 1), in: normalized) {
            return String(normalized[valueRange]).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fileName
            .replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func accountName(from fileName: String) -> String {
        let normalized = fileName.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        if normalized.contains("amex") || normalized.contains("american express") {
            return "Amex"
        }
        if normalized.contains("bbva") {
            return "BBVA"
        }
        if normalized.contains("santander") {
            return "Santander"
        }
        return "Importado"
    }

    private static func category(for title: String, flow: FlowKind) -> String {
        if flow == .income { return "Ingresos" }
        if flow == .transfer { return "Transferencia" }
        if title.contains("super")
            || title.contains("costco")
            || title.contains("walmart")
            || title.contains("soriana") {
            return "Alimentos"
        }
        if title.contains("hotel")
            || title.contains("vuelo")
            || title.contains("aeromexico")
            || title.contains("aerobus")
            || title.contains("airbnb")
            || title.contains("volaris")
            || title.contains("uber") {
            return "Viajes"
        }
        if flow == .debt { return "Pago de tarjeta" }
        return "Por revisar"
    }
}

private enum SecureAccountStore {
    private static let service = "mx.marcelito.personal.account"

    static func string(for account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String) {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func deleteAll() {
        SecItemDelete(baseQuery(account: "username") as CFDictionary)
        SecItemDelete(baseQuery(account: "passwordHash") as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

@Observable
final class AuthenticationModel {
    var isAuthenticated = false
    var message: String?

    private let usernameAccount = "username"
    private let passwordHashAccount = "passwordHash"
    private let deletedKey = "marcelito.account.deleted"
    private let seedUsername = "Marcelodiazs"
    private let seedPasswordHash = "ed6357244f855d10e821359702d859df700ba81431a98b88ba1de5156a1e9f61"

    init() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: deletedKey) else { return }

        if SecureAccountStore.string(for: usernameAccount) == nil
            || SecureAccountStore.string(for: passwordHashAccount) == nil {
            SecureAccountStore.deleteAll()
            SecureAccountStore.save(seedUsername, account: usernameAccount)
            SecureAccountStore.save(seedPasswordHash, account: passwordHashAccount)
        }
    }

    func signIn(username: String, password: String) {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanUsername.count >= 3, password.count >= 6 else {
            isAuthenticated = false
            message = "Revisa tu usuario y contraseña."
            return
        }

        let savedUsername = SecureAccountStore.string(for: usernameAccount)
        let savedHash = SecureAccountStore.string(for: passwordHashAccount)
        let hash = Self.passwordHash(username: savedUsername ?? cleanUsername, password: password)
        guard savedUsername?.caseInsensitiveCompare(cleanUsername) == .orderedSame,
              savedHash == hash else {
            isAuthenticated = false
            message = "Usuario o contraseña no válidos."
            return
        }

        isAuthenticated = true
        message = nil
    }

    func createAccount(username: String, password: String) {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanUsername.count >= 3, password.count >= 6 else {
            isAuthenticated = false
            message = "Usa un usuario de al menos 3 caracteres y una contraseña de 6 o más."
            return
        }
        guard SecureAccountStore.string(for: usernameAccount) == nil else {
            isAuthenticated = false
            message = "Ya existe un usuario en este dispositivo. Entra con él o elimina la cuenta desde tu perfil."
            return
        }

        SecureAccountStore.save(cleanUsername, account: usernameAccount)
        SecureAccountStore.save(Self.passwordHash(username: cleanUsername, password: password), account: passwordHashAccount)
        UserDefaults.standard.set(false, forKey: deletedKey)
        isAuthenticated = true
        message = nil
    }

    func deleteAccount() {
        SecureAccountStore.deleteAll()
        UserDefaults.standard.set(true, forKey: deletedKey)
        isAuthenticated = false
        message = nil
    }

    func unlockWithFaceID() async {
        guard SecureAccountStore.string(for: usernameAccount) != nil else {
            await MainActor.run { message = "Primero crea un usuario en este dispositivo." }
            return
        }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            await MainActor.run { message = "Face ID no está disponible en este dispositivo." }
            return
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Desbloquea tu panorama financiero"
            )
            await MainActor.run {
                isAuthenticated = success
                message = success ? nil : "No pudimos confirmar tu identidad."
            }
        } catch {
            await MainActor.run { message = "No pudimos confirmar tu identidad." }
        }
    }

    private static func passwordHash(username: String, password: String) -> String {
        let digest = SHA256.hash(data: Data("\(username):\(password)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
