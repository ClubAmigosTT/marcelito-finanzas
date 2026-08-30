import CryptoKit
import Foundation
import LocalAuthentication
import Observation
import PDFKit
import Security
import SwiftUI
import UIKit
import Vision

enum FlowKind: String, CaseIterable, Identifiable, Codable, Hashable {
    case income = "Ingreso"
    case transfer = "Transferencia"
    case expense = "Gasto"
    case debt = "Deuda"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .income: Color.marcelitoSuccess
        case .transfer: Color.marcelitoNavySoft
        case .expense: Color.marcelitoAmber
        case .debt: Color.marcelitoViolet
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

enum StatementKind: String, Codable, Hashable, CaseIterable {
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
    /// Nombre relativo del PDF que guardamos en Application Support para poder
    /// volver a abrirlo desde la tarjeta de documentos.
    var localFileName: String? = nil
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
    let usedOCR: Bool
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

    var paidPercent: Decimal? { newCharges == 0 ? nil : realPayments / newCharges }
    var pendingPercent: Decimal? { newCharges == 0 ? nil : max(Decimal(0), accumulatedBalance) / newCharges }
}

enum FinanceImportError: LocalizedError {
    case unreadableDocument
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case .unreadableDocument:
            "No pudimos leer este PDF. Verifica que sea un estado de cuenta válido."
        case .emptyDocument:
            "Este PDF no contiene texto ni movimientos reconocibles. Revisa que sea un estado de cuenta y, si es un escaneo, confirma los importes en Movimientos después de importarlo."
        }
    }
}

@Observable
final class FinanceStore {
    private let movementKey = "marcelito.movements.v2"
    private let statementKey = "marcelito.statements.v1"
    private let importKey = "marcelito.lastImport"
    private let categoryRulesKey = "marcelito.categoryRules.v1"
    private let statementFilesDirectoryName = "ImportedStatements"

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
    var accumulatedBalance: Decimal { totalNewCharges - totalRealPayments - totalCredits }
    var latestDifference: Decimal { cardPeriodMetrics.first?.difference ?? 0 }
    var paidPercent: Decimal? { totalNewCharges == 0 ? nil : totalRealPayments / totalNewCharges }
    var pendingPercent: Decimal? { totalNewCharges == 0 ? nil : max(Decimal(0), accumulatedBalance) / totalNewCharges }
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
            return statementKind(statement) != .card
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
    var liquidPatrimonyChangePercent: Decimal? {
        var groups: [[StatementMetric]] = []
        for metric in periodMetrics {
            let key = periodKey(metric.period)
            if let index = groups.firstIndex(where: { periodKey($0[0].period) == key }) {
                groups[index].append(metric)
            } else {
                groups.append([metric])
            }
        }
        guard groups.count > 1,
              let current = patrimony(for: groups[0]),
              let previous = patrimony(for: groups[1]),
              previous != 0 else { return nil }
        let absolutePrevious = previous < 0 ? -previous : previous
        return (current - previous) / absolutePrevious
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

    var monthlyIncome: Decimal {
        let monthStart = Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month], from: .now)
        ) ?? .now
        return movements
            .filter { movement in
                guard movement.date >= monthStart, movement.flow == .income else { return false }
                let kind = movementKind(movement)
                return kind != .credit && kind != .refund
            }
            .reduce(0) { $0 + absolute($1.amount) }
    }

    var monthlyNetFlow: Decimal { monthlyIncome - monthlyExpense }

    private func absolute(_ value: Decimal) -> Decimal { value < 0 ? -value : value }

    private func statementKind(_ statement: StatementRecord) -> StatementKind {
        if let kind = statement.kind { return kind }
        if statement.source.localizedCaseInsensitiveContains("Amex") { return .card }
        if statement.source.localizedCaseInsensitiveContains("Importado") { return .unknown }
        return .bank
    }

    private func movementKind(_ movement: Movement) -> MovementKind {
        if let kind = movement.kind { return kind }
        let value = movement.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if value.contains("msi")
            || value.contains("meses sin intereses")
            || value.contains("meses en automatico")
            || value.contains("diferir")
            || value.contains("diferid") { return .msi }
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

    private func patrimony(for metrics: [StatementMetric]) -> Decimal? {
        let bank = latestMetricsBySource(metrics.filter { $0.kind == .bank }).compactMap { $0.cashBalance }
        let cards = latestMetricsBySource(metrics.filter { $0.kind == .card }).compactMap { $0.debtBalance }
        guard !bank.isEmpty, !cards.isEmpty else { return nil }
        return bank.reduce(0, +) - cards.reduce(0, +)
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
            difference: newCharges - realPayments,
            accumulatedBalance: newCharges - realPayments - creditTotal,
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
        let key = Self.categoryRuleKey(movements[index].title)
        if !key.isEmpty {
            var rules = UserDefaults.standard.dictionary(forKey: categoryRulesKey) as? [String: String] ?? [:]
            if ["Por revisar", "Sin categoría"].contains(category) {
                rules.removeValue(forKey: key)
            } else {
                rules[key] = category
            }
            UserDefaults.standard.set(rules, forKey: categoryRulesKey)
        }
        persist()
    }

    func applyAIClassifications(_ classifications: [AIClassification]) {
        var rules = UserDefaults.standard.dictionary(forKey: categoryRulesKey) as? [String: String] ?? [:]
        for classification in classifications {
            guard let index = movements.firstIndex(where: { $0.id == classification.movementID }) else { continue }
            movements[index].category = classification.category
            movements[index].travelRelated = classification.travelRelated
            let key = Self.categoryRuleKey(movements[index].title)
            if !key.isEmpty {
                rules[key] = classification.category
            }
        }
        UserDefaults.standard.set(rules, forKey: categoryRulesKey)
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

    func updateStatementSource(for statement: StatementRecord, to source: String, kind: StatementKind? = nil) {
        let cleaned = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let index = statements.firstIndex(where: { $0.id == statement.id }) else { return }
        let previousSource = statements[index].source
        statements[index].source = cleaned
        if let kind {
            statements[index].kind = kind
        }
        for movementIndex in movements.indices where movements[movementIndex].statementId == statement.id {
            if movements[movementIndex].account == previousSource || movements[movementIndex].account == "Importado" {
                movements[movementIndex].account = cleaned
            }
        }
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
        defaults.removeObject(forKey: categoryRulesKey)
        try? FileManager.default.removeItem(at: statementFilesDirectoryURL)
    }

    /// Devuelve la URL local del PDF importado. Solo se aceptan nombres de
    /// archivo relativos generados por Marcelito para evitar rutas externas.
    func statementFileURL(for statement: StatementRecord) -> URL? {
        guard let localFileName = statement.localFileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !localFileName.isEmpty else { return nil }
        let safeFileName = URL(fileURLWithPath: localFileName).lastPathComponent
        let url = statementFilesDirectoryURL.appendingPathComponent(safeFileName, isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func importPDF(from url: URL) throws -> ImportSummary {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let documentData: Data
        do {
            documentData = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw FinanceImportError.unreadableDocument
        }
        guard let document = PDFDocument(data: documentData) else {
            throw FinanceImportError.unreadableDocument
        }

        let extractedText = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
        let usedOCR = extractedText.trimmingCharacters(in: .whitespacesAndNewlines).count < 120
        let ocrObservations = usedOCR ? Self.ocrObservations(from: document) : []
        let text = usedOCR ? Self.ocrText(from: ocrObservations) : extractedText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FinanceImportError.emptyDocument
        }
        let fileSource = Self.accountName(from: url.lastPathComponent)
        let source = fileSource == "Importado"
            ? Self.accountName(from: text)
            : fileSource
        let detectedKind = Self.statementKind(from: text, source: source)
        let parsedCandidates: [Movement]
        if usedOCR, source == "Santander" {
            let santanderCandidates = Self.parseSantanderOCR(ocrObservations, fileName: url.lastPathComponent)
            parsedCandidates = santanderCandidates.isEmpty
                ? Self.parse(text: text, fileName: url.lastPathComponent)
                : santanderCandidates
        } else if usedOCR, source == "Amex" {
            let amexCandidates = Self.parseAmexOCR(Self.ocrLines(from: ocrObservations), fileName: url.lastPathComponent)
            parsedCandidates = amexCandidates.isEmpty
                ? Self.parse(text: text, fileName: url.lastPathComponent)
                : amexCandidates
        } else if usedOCR {
            let genericCandidates = Self.parseGenericOCR(
                ocrObservations,
                fileName: url.lastPathComponent,
                source: source,
                kind: detectedKind
            )
            parsedCandidates = genericCandidates.isEmpty
                ? Self.parse(text: text, fileName: url.lastPathComponent)
                : genericCandidates
        } else {
            parsedCandidates = Self.parse(text: text, fileName: url.lastPathComponent)
        }
        let learnedRules = UserDefaults.standard.dictionary(forKey: categoryRulesKey) as? [String: String] ?? [:]
        let candidates = parsedCandidates.map { candidate -> Movement in
            var corrected = candidate
            if let learned = learnedRules[Self.categoryRuleKey(candidate.title)] {
                corrected.category = learned
            }
            return corrected
        }
        let period = Self.periodLabel(from: text, fileName: url.lastPathComponent)
        let summary = Self.summary(from: text, source: source)
        let existingStatement = statements.first(where: { $0.fileName == url.lastPathComponent })
        let statementId = existingStatement?.id ?? UUID()
        let fresh = candidates.map { candidate -> Movement in
            var imported = candidate
            imported.statementId = statementId
            return imported
        }
        let needsReview = fresh.isEmpty
            || usedOCR
            || summary == nil
            || detectedKind == .unknown
            || fresh.contains { $0.category == "Por revisar" }

        movements.removeAll { $0.statementId == statementId }
        movements.insert(contentsOf: fresh.reversed(), at: 0)
        let storedFileName = persistStatementFile(documentData, statementId: statementId)
            ?? existingStatement?.localFileName
        let statement = StatementRecord(
            id: statementId,
            source: source,
            period: period,
            fileName: url.lastPathComponent,
            localFileName: storedFileName,
            importedAt: .now,
            transactionCount: fresh.count,
            requiresReview: needsReview,
            kind: detectedKind,
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
            // Rows are scoped to their statement; identical purchases from a
            // different import are legitimate and are never treated as repeats.
            skipped: 0,
            requiresReview: needsReview,
            summary: summary,
            usedOCR: usedOCR
        )
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(movements) else { return }
        UserDefaults.standard.set(data, forKey: movementKey)
        if let data = try? JSONEncoder().encode(statements) {
            UserDefaults.standard.set(data, forKey: statementKey)
        }
    }

    private var statementFilesDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(statementFilesDirectoryName, isDirectory: true)
    }

    private func persistStatementFile(_ data: Data, statementId: UUID) -> String? {
        let localFileName = "(statementId.uuidString).pdf"
        do {
            try FileManager.default.createDirectory(
                at: statementFilesDirectoryURL,
                withIntermediateDirectories: true
            )
            try data.write(
                to: statementFilesDirectoryURL.appendingPathComponent(localFileName),
                options: [.atomic]
            )
            return localFileName
        } catch {
            // La importación contable sigue siendo válida aunque iOS no pueda
            // conservar el archivo; en ese caso la tarjeta lo indicará.
            return nil
        }
    }

    private static let demoMovements: [Movement] = [/*
        Movement(date: .now, title: "Nómina mensual", account: "Santander", category: "Ingresos", amount: 48_200, flow: .income),
        Movement(date: .now.addingTimeInterval(-86_400), title: "Pago de tarjeta", account: "Santander a Amex", category: "Transferencia", amount: -19_405, flow: .transfer),
        Movement(date: .now.addingTimeInterval(-172_800), title: "Supermercado", account: "Amex", category: "Alimentos", amount: -1_842.70, flow: .expense),
        Movement(date: .now.addingTimeInterval(-259_200), title: "Reserva de viaje", account: "Amex", category: "Viajes", amount: -6_270, flow: .expense)
    */]

    private struct OCRObservation {
        let page: Int
        let text: String
        let boundingBox: CGRect

        var centerX: CGFloat { boundingBox.midX }
        var centerY: CGFloat { boundingBox.midY }
    }

    private struct OCRAmountCandidate {
        let value: Decimal
        let text: String
        let x: CGFloat
        let order: Int
    }

    private static func ocrObservations(from document: PDFDocument) -> [OCRObservation] {
        var observations: [OCRObservation] = []
        let pageSize = CGSize(width: 1800, height: 2400)

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let image = page.thumbnail(of: pageSize, for: .mediaBox)
            guard let cgImage = image.cgImage else { continue }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["es-MX", "en-US"]
            request.usesLanguageCorrection = true

            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            } catch {
                continue
            }

            let pageObservations = (request.results ?? []).compactMap { result -> OCRObservation? in
                guard let text = result.topCandidates(1).first?.string,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return OCRObservation(page: pageIndex, text: text, boundingBox: result.boundingBox)
            }
            .sorted {
                if abs($0.centerY - $1.centerY) > 0.008 {
                    return $0.centerY > $1.centerY
                }
                return $0.centerX < $1.centerX
            }
            observations.append(contentsOf: pageObservations)
        }

        return observations
    }

    private static func ocrText(from observations: [OCRObservation]) -> String {
        ocrLines(from: observations).map(\.text).joined(separator: "\n")
    }

    private static func ocrLines(from observations: [OCRObservation]) -> [OCRObservation] {
        let observationsByPage = Dictionary(grouping: observations, by: \.page)
        var lines: [OCRObservation] = []

        for page in observationsByPage.keys.sorted() {
            let pageObservations = (observationsByPage[page] ?? []).sorted {
                if abs($0.centerY - $1.centerY) > 0.012 {
                    return $0.centerY > $1.centerY
                }
                return $0.centerX < $1.centerX
            }
            var groups: [[OCRObservation]] = []
            for observation in pageObservations {
                if let last = groups.last,
                   let reference = last.first,
                   abs(reference.centerY - observation.centerY) <= 0.012 {
                    groups[groups.count - 1].append(observation)
                } else {
                    groups.append([observation])
                }
            }

            for group in groups {
                guard let first = group.first else { continue }
                let box = group.dropFirst().reduce(first.boundingBox) { $0.union($1.boundingBox) }
                lines.append(
                    OCRObservation(
                        page: page,
                        text: group.sorted { $0.centerX < $1.centerX }.map(\.text).joined(separator: " "),
                        boundingBox: box
                    )
                )
            }
        }

        return lines
    }

    private struct TextMatch {
        let range: NSRange
        let text: String
    }

    private static func parse(text: String, fileName: String) -> [Movement] {
        let dateRegex = try? NSRegularExpression(
            pattern: #"(?<!\d)(\d{1,2})[\/\-.](\d{1,2})[\/\-.](\d{2,4})(?!\d)"#
        )
        let isoDateRegex = try? NSRegularExpression(
            pattern: #"(?<!\d)(\d{4})[\/\-.](\d{1,2})[\/\-.](\d{1,2})(?!\d)"#
        )
        let textDateRegex = try? NSRegularExpression(
            pattern: #"(?i)(?<!\d)(\d{1,2})\s+(?:de\s+)?([A-Za-zÁÉÍÓÚáéíóú]{3,})(?:\s+(?:de\s+)?(\d{4}))?"#
        )
        let amountRegex = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9])[-+]?\s*\$?\s*(?:\d{1,3}(?:[ ,. ]\d{3})+|\d+)(?:[.,]\d{1,2})?(?![A-Za-z0-9])"#
        )
        let filenameAccount = accountName(from: fileName)
        let documentNormalized = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        let account = filenameAccount == "Importado"
            ? accountName(from: documentNormalized)
            : filenameAccount
        let documentKind = statementKind(from: documentNormalized, source: account)
        let ignoredPhrases = [
            "saldo anterior", "saldo al corte", "pago minimo",
            "limite de credito", "tasa anual", "numero de cuenta",
            "fecha de corte", "fecha limite", "total a pagar",
            "periodo de facturacion", "este no es un documento",
            "total de las transacciones", "el estado de cuenta incluye",
            "estimado cliente", "en caso de que la fecha",
            "resumen informativo", "cuenta de cheques", "saldo inicial",
            "saldo final", "saldo promedio", "saldo disponible", "mes anterior",
            "mes actual", "intereses brutos", "comisiones cobradas", "otros cargos",
            "dias del periodo", "codigo de cliente", "rfc",
            "depositos", "retiros", "abonos"
        ]

        // Amex puts the merchant, RFC and amount on separate PDF text lines.
        // Group each date-started row before extracting the amount.
        var rows: [String] = []
        var pendingRow = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count > 1 else { continue }
            let hasDate = (dateRegex.flatMap { firstMatch(in: line, regex: $0) } != nil)
                || (isoDateRegex.flatMap { firstMatch(in: line, regex: $0) } != nil)
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
                ?? isoDateRegex.flatMap { firstMatch(in: working, regex: $0) }
                ?? textDateRegex.flatMap { firstMatch(in: working, regex: $0) }
            if let dateMatch {
                date = parseDate(dateMatch.text) ?? date
                working = working.replacingCharacters(in: Range(dateMatch.range, in: working)!, with: " ")
            }

            guard let amountRegex else { return nil }
            let allAmountMatches = allMatches(in: working, regex: amountRegex)
            let moneyMatches = allAmountMatches.filter {
                $0.text.contains("$") || $0.text.range(of: #"[.,]\d{1,2}$"#, options: .regularExpression) != nil
            }
            let usableAmountMatches = moneyMatches.isEmpty ? allAmountMatches : moneyMatches
            let foreignCurrency = ["dolar", "euro", "peso colombiano", "tipo de cambio", " tc:"].contains { normalized.contains($0) }
            let bankLikeRow = documentKind == .bank
                || ["deposito", "retiro", "saldo", "cuenta de cheques", "cuenta de ahorro", "abono"]
                    .contains { normalized.contains($0) }
            let amountMatch = foreignCurrency
                ? usableAmountMatches.first
                : bankLikeRow && usableAmountMatches.count > 1
                    ? usableAmountMatches[usableAmountMatches.count - 2]
                    : usableAmountMatches.last
            guard let amountMatch,
                  let parsedAmount = parseAmount(amountMatch.text),
                  parsedAmount != 0,
                  abs(parsedAmount) < 10_000_000 else {
                return nil
            }
            working = working.replacingCharacters(in: Range(amountMatch.range, in: working)!, with: " ")

            var title = working
                .replacingOccurrences(of: #"\bRFC[A-Z0-9]+\b"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"/REF[A-Z0-9_]+\b"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\bCR\b"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            title = cleanMerchantTitle(title)
            guard title.count >= 3 else { return nil }
            guard title.rangeOfCharacter(from: .letters) != nil else { return nil }

            let titleNormalized = title.folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: .current
            )
            let hasCreditMarker = normalized.range(of: #"\b(cr|abono|credito)\b"#, options: .regularExpression) != nil
            let isRefund = titleNormalized.contains("devolucion")
                || titleNormalized.contains("reembolso")
                || titleNormalized.contains("bonificacion")
            let isCardPayment = titleNormalized.contains("gracias por su pago")
                || titleNormalized.contains("pago de tarjeta")
                || (titleNormalized.contains("pago")
                    && (titleNormalized.contains("tarjeta") || titleNormalized.contains("credito") || documentKind == .card))
            let isIncome = titleNormalized.contains("nomina")
                || titleNormalized.contains("sueldo")
                || titleNormalized.contains("salario")
                || titleNormalized.contains("deposito")
                || titleNormalized.contains("abono")
                || titleNormalized.contains("ingreso")
                || titleNormalized.contains("transferencia recibida")
            let isTransfer = titleNormalized.contains("transfer")
                || titleNormalized.contains("traspaso")
                || titleNormalized.contains("spei")
                || titleNormalized.contains("entre cuentas")
                || titleNormalized.contains("clabe")
            let isStatementCredit = hasCreditMarker && !isCardPayment && !isRefund && !isIncome
            let flow: FlowKind
            if isRefund || isStatementCredit {
                flow = .income
            } else if isCardPayment {
                flow = .debt
            } else if isIncome {
                flow = .income
            } else if isTransfer {
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
            if isStatementCredit {
                kind = .credit
            } else if titleNormalized.contains("msi")
                || titleNormalized.contains("meses sin intereses")
                || titleNormalized.contains("meses en automatico")
                || titleNormalized.contains("diferir")
                || titleNormalized.contains("diferid") {
                kind = .msi
            } else if titleNormalized.contains("interes") {
                kind = .interest
            } else if titleNormalized.contains("comision") || titleNormalized.contains("anualidad") {
                kind = .fee
            } else if isRefund && signedAmount > 0 {
                kind = .refund
            } else if isCardPayment {
                kind = .cardPayment
            } else if isTransfer {
                kind = .bankTransfer
            } else if isIncome {
                kind = .income
            } else if flow == .income {
                kind = .credit
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

    /// Universal OCR fallback for scanned statements that are not one of the
    /// known Santander or Amex layouts. It uses the date as the row anchor and
    /// the last right-aligned amount (or the penultimate amount for bank rows,
    /// where the final value is commonly the running balance).
    private static func parseGenericOCR(
        _ observations: [OCRObservation],
        fileName: String,
        source: String,
        kind: StatementKind
    ) -> [Movement] {
        guard let dayFirstDateRegex = try? NSRegularExpression(
            pattern: #"(?<!\d)(\d{1,2})\s*[\/\-.]\s*(\d{1,2})\s*[\/\-.]\s*(\d{2,4})(?!\d)"#
        ), let isoDateRegex = try? NSRegularExpression(
            pattern: #"(?<!\d)(\d{4})\s*[\/\-.]\s*(\d{1,2})\s*[\/\-.]\s*(\d{1,2})(?!\d)"#
        ), let textDateRegex = try? NSRegularExpression(
            pattern: #"(?i)(?<!\d)(\d{1,2})\s+(?:de\s+)?([A-Za-zÁÉÍÓÚáéíóú]{3,})(?:\s+(?:de\s+)?(\d{4}))?"#
        ), let amountRegex = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9])[-+]?\s*\$?(?:\d{1,3}(?:[ ,.]\d{3})+|\d+)[.,]\d{2}(?![A-Za-z0-9])"#
        ) else {
            return []
        }

        let linesByPage = Dictionary(grouping: ocrLines(from: observations), by: \.page)
        var rows: [[OCRObservation]] = []
        let ignoredHeaderPhrases = [
            "estado de cuenta", "resumen de cuenta", "resumen de movimientos",
            "resumen de meses", "periodo de facturacion", "periodo de corte",
            "fecha de corte", "fecha limite", "pago minimo", "saldo anterior",
            "saldo al corte", "saldo final", "saldo actual", "saldo disponible",
            "limite de credito", "credito disponible", "fecha descripcion",
            "fecha folio", "total de movimientos", "total de transacciones",
            "total de las transacciones", "informacion al cliente", "titular de la cuenta",
            "saldo inicial", "saldo promedio", "pagina"
        ]
        for page in linesByPage.keys.sorted() {
            let pageLines = (linesByPage[page] ?? []).sorted {
                if abs($0.centerY - $1.centerY) > 0.012 {
                    return $0.centerY > $1.centerY
                }
                return $0.centerX < $1.centerX
            }
            var pendingRow: [OCRObservation] = []

            for line in pageLines {
                let normalized = line.text.folding(
                    options: [.diacriticInsensitive, .caseInsensitive],
                    locale: .current
                )
                // End the current row before dropping totals or a new section
                // header. This keeps the final charge in each page/section.
                if normalized.contains("total de movimientos")
                    || normalized.contains("total de transacciones")
                    || normalized.contains("total de las transacciones")
                    || normalized.contains("total de meses sin intereses") {
                    if !pendingRow.isEmpty {
                        rows.append(pendingRow)
                        pendingRow.removeAll(keepingCapacity: true)
                    }
                    continue
                }

                let dateMatch = firstMatch(in: line.text, regex: dayFirstDateRegex)
                    ?? firstMatch(in: line.text, regex: isoDateRegex)
                    ?? firstMatch(in: line.text, regex: textDateRegex)
                let isTransactionDate = dateMatch != nil
                    // The date column is usually left aligned, but some banks
                    // place it farther inboard on a narrow/mobile statement.
                    // Keep the threshold broad; headers are filtered by text.
                    && line.boundingBox.minX < 0.72
                    && !ignoredHeaderPhrases.contains(where: { normalized.contains($0) })

                if isTransactionDate {
                    if !pendingRow.isEmpty { rows.append(pendingRow) }
                    pendingRow = [line]
                } else if !pendingRow.isEmpty {
                    if ignoredHeaderPhrases.contains(where: { normalized.contains($0) }) {
                        rows.append(pendingRow)
                        pendingRow.removeAll(keepingCapacity: true)
                    } else {
                        pendingRow.append(line)
                    }
                }
            }
            if !pendingRow.isEmpty { rows.append(pendingRow) }
        }

        return rows.compactMap {
            parseGenericOCRRow(
                $0,
                dayFirstDateRegex: dayFirstDateRegex,
                isoDateRegex: isoDateRegex,
                textDateRegex: textDateRegex,
                amountRegex: amountRegex,
                source: source,
                kind: kind
            )
        }
    }

    private static func parseGenericOCRRow(
        _ row: [OCRObservation],
        dayFirstDateRegex: NSRegularExpression,
        isoDateRegex: NSRegularExpression,
        textDateRegex: NSRegularExpression,
        amountRegex: NSRegularExpression,
        source: String,
        kind: StatementKind
    ) -> Movement? {
        let fullText = row.map(\.text).joined(separator: " ")
        let dateMatch = firstMatch(in: fullText, regex: dayFirstDateRegex)
            ?? firstMatch(in: fullText, regex: isoDateRegex)
            ?? firstMatch(in: fullText, regex: textDateRegex)
        guard let dateMatch, let date = parseDate(dateMatch.text) else { return nil }

        let normalizedFullText = fullText.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        let ignoredPhrases = [
            "estado de cuenta", "resumen de cuenta", "resumen de movimientos",
            "resumen de meses", "periodo de facturacion", "fecha de corte",
            "fecha limite", "pago minimo", "saldo anterior", "saldo al corte",
            "saldo final", "saldo actual", "saldo disponible", "limite de credito",
            "credito disponible", "total de movimientos", "total de transacciones",
            "total de las transacciones", "informacion al cliente", "titular de la cuenta",
            "saldo inicial", "saldo promedio"
        ]
        guard !ignoredPhrases.contains(where: { normalizedFullText.contains($0) }) else { return nil }

        let candidates = row.enumerated().flatMap { observationOrder, observation in
            allMatches(in: observation.text, regex: amountRegex).enumerated().compactMap { matchOrder, match -> OCRAmountCandidate? in
                guard let value = parseAmount(match.text), abs(value) > 0, abs(value) < 100_000_000 else {
                    return nil
                }
                return OCRAmountCandidate(
                    value: value,
                    text: match.text,
                    x: observation.boundingBox.minX,
                    order: observationOrder * 100 + matchOrder
                )
            }
        }.sorted { $0.order < $1.order }
        guard !candidates.isEmpty else { return nil }

        let hasForeignCurrency = ["dolar", "euro", "peso colombiano", "tipo de cambio", " tc:"].contains {
            normalizedFullText.contains($0)
        }
        let bankLikeRow = kind == .bank
            || ["deposito", "retiro", "saldo", "cuenta de cheques", "cuenta de ahorro", "abono"]
                .contains { normalizedFullText.contains($0) }
        let selected: OCRAmountCandidate
        if hasForeignCurrency {
            selected = candidates[0]
        } else if bankLikeRow, candidates.count > 1 {
            selected = candidates[max(0, candidates.count - 2)]
        } else {
            selected = candidates[candidates.count - 1]
        }

        var title = fullText
            .replacingOccurrences(
                of: #"(?i)(?<!\d)\d{1,4}\s*[\/\-.]\s*\d{1,4}\s*[\/\-.]\s*\d{2,4}(?!\d)"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)(?<!\d)\d{1,2}\s+(?:de\s+)?[A-Za-zÁÉÍÓÚáéíóú]{3,}(?:\s+(?:de\s+)?\d{4})?"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?<![A-Za-z0-9])[-+]?\s*\$?(?:\d{1,3}(?:[ ,.]\d{3})+|\d+)[.,]\d{2}(?![A-Za-z0-9])"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\bRFC[A-Z0-9]+\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"/REF[A-Z0-9_]+\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\bCR\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        title = cleanMerchantTitle(title)
        guard title.count >= 3, title.rangeOfCharacter(from: .letters) != nil else { return nil }

        let titleNormalized = title.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        let hasCreditMarker = normalizedFullText.range(of: #"\b(cr|abono|credito)\b"#, options: .regularExpression) != nil
        let isRefund = titleNormalized.contains("devolucion")
            || titleNormalized.contains("reembolso")
            || titleNormalized.contains("bonificacion")
        let isCardPayment = titleNormalized.contains("gracias por su pago")
            || titleNormalized.contains("pago de tarjeta")
            || (titleNormalized.contains("pago")
                && (titleNormalized.contains("tarjeta") || titleNormalized.contains("credito") || kind == .card))
        let isIncome = titleNormalized.contains("nomina")
            || titleNormalized.contains("sueldo")
            || titleNormalized.contains("salario")
            || titleNormalized.contains("deposito")
            || titleNormalized.contains("abono")
            || titleNormalized.contains("ingreso")
            || titleNormalized.contains("transferencia recibida")
        let isTransfer = titleNormalized.contains("transfer")
            || titleNormalized.contains("traspaso")
            || titleNormalized.contains("spei")
            || titleNormalized.contains("entre cuentas")
            || titleNormalized.contains("clabe")
        let isStatementCredit = hasCreditMarker && !isCardPayment && !isRefund && !isIncome

        let flow: FlowKind
        if isRefund || isStatementCredit {
            flow = .income
        } else if isCardPayment {
            flow = .debt
        } else if isIncome {
            flow = .income
        } else if isTransfer {
            flow = .transfer
        } else {
            flow = .expense
        }
        let signedAmount = flow == .income ? abs(selected.value) : -abs(selected.value)
        let displayAccount = flow == .transfer && titleNormalized.contains("amex")
            ? "Santander a Amex"
            : source
        let movementKind: MovementKind
        if isStatementCredit {
            movementKind = .credit
        } else if titleNormalized.contains("msi")
            || titleNormalized.contains("meses sin intereses")
            || titleNormalized.contains("meses en automatico")
            || titleNormalized.contains("diferir")
            || titleNormalized.contains("diferid") {
            movementKind = .msi
        } else if titleNormalized.contains("interes") {
            movementKind = .interest
        } else if titleNormalized.contains("comision") || titleNormalized.contains("anualidad") {
            movementKind = .fee
        } else if isRefund {
            movementKind = .refund
        } else if isCardPayment {
            movementKind = .cardPayment
        } else if isTransfer {
            movementKind = .bankTransfer
        } else if isIncome {
            movementKind = .income
        } else {
            movementKind = .purchase
        }
        let travelRelated = [
            "viaje", "hotel", "hospedaje", "aerolinea", "vuelo", "avion",
            "transporte", "uber", "taxi", "metro", "renta de auto", "destino", "equipaje",
            "airbnb", "aeromexico", "vivaaerobus", "volaris"
        ].contains { titleNormalized.contains($0) }

        return Movement(
            date: date,
            title: title,
            account: displayAccount,
            category: category(for: titleNormalized, flow: flow),
            amount: signedAmount,
            flow: flow,
            kind: movementKind,
            travelRelated: travelRelated
        )
    }

    /// Santander's statement is a scanned table. A plain text OCR stream loses
    /// the distinction between the transaction amount and the running balance,
    /// so use Vision bounding boxes to read the deposit/withdrawal columns.
    private static func parseSantanderOCR(
        _ observations: [OCRObservation],
        fileName: String
    ) -> [Movement] {
        guard let dateRegex = try? NSRegularExpression(
            pattern: #"(?i)(?<!\d)(\d{1,2})\s*[\/\-.]\s*(\d{1,2}|[A-Za-z]{3,})\s*[\/\-.]\s*(\d{2,4})(?!\d)"#
        ), let amountRegex = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9])[-+]?\s*\$?(?:\d{1,3}(?:[ ,. ]\d{3})+|\d+)[.,]\d{2}(?![A-Za-z0-9])"#
        ) else {
            return []
        }

        let observationsByPage = Dictionary(grouping: observations, by: \.page)
        var parsed: [Movement] = []

        for page in observationsByPage.keys.sorted() {
            let pageObservations = (observationsByPage[page] ?? []).sorted {
                if abs($0.centerY - $1.centerY) > 0.008 {
                    return $0.centerY > $1.centerY
                }
                return $0.centerX < $1.centerX
            }

            var rows: [[OCRObservation]] = []
            var pendingRow: [OCRObservation] = []
            for observation in pageObservations {
                let normalized = observation.text.folding(
                    options: [.diacriticInsensitive, .caseInsensitive],
                    locale: .current
                )
                let hasDate = firstMatch(in: observation.text, regex: dateRegex) != nil
                let isDateCell = hasDate
                    && observation.boundingBox.minX < 0.24
                    && !normalized.contains("periodo")
                    && !normalized.contains("corte")
                    && !normalized.contains("pagina")

                if isDateCell {
                    if !pendingRow.isEmpty { rows.append(pendingRow) }
                    pendingRow = [observation]
                } else if !pendingRow.isEmpty {
                    pendingRow.append(observation)
                }
            }
            if !pendingRow.isEmpty { rows.append(pendingRow) }

            for row in rows {
                if let movement = parseSantanderRow(row, dateRegex: dateRegex, amountRegex: amountRegex) {
                    parsed.append(movement)
                }
            }
        }

        return parsed
    }

    private static func parseSantanderRow(
        _ row: [OCRObservation],
        dateRegex: NSRegularExpression,
        amountRegex: NSRegularExpression
    ) -> Movement? {
        guard let dateObservation = row.first(where: {
            $0.boundingBox.minX < 0.24 && firstMatch(in: $0.text, regex: dateRegex) != nil
        }), let dateMatch = firstMatch(in: dateObservation.text, regex: dateRegex),
        let date = parseDate(dateMatch.text) else {
            return nil
        }

        let fullText = row.map(\.text).joined(separator: " ")
        let normalizedFullText = fullText.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        let ignoredPhrases = [
            "detalle de movimientos", "saldo final del periodo anterior",
            "fecha folio descripcion", "cuenta de cheques", "super nomina",
            "estado de cuenta nomina"
        ]
        guard !ignoredPhrases.contains(where: { normalizedFullText.contains($0) }) else {
            return nil
        }

        var amountCandidates: [OCRAmountCandidate] = []
        for (observationOrder, observation) in row.enumerated() {
            for (matchOrder, match) in allMatches(in: observation.text, regex: amountRegex).enumerated() {
                guard let value = parseAmount(match.text), abs(value) > 0, abs(value) < 10_000_000 else {
                    continue
                }
                amountCandidates.append(
                    OCRAmountCandidate(
                        value: value,
                        text: match.text,
                        x: observation.boundingBox.minX,
                        order: observationOrder * 100 + matchOrder
                    )
                )
            }
        }
        guard !amountCandidates.isEmpty else { return nil }

        // On Santander's table the deposit and withdrawal columns sit before
        // the running balance. Prefer those columns so the balance is never
        // mistaken for a purchase.
        let columnCandidates = amountCandidates.filter { $0.x >= 0.59 && $0.x < 0.86 }
        let selected = columnCandidates.sorted { $0.order < $1.order }.first
            ?? { () -> OCRAmountCandidate? in
                let fallbackCandidates = amountCandidates
                    .filter { $0.x < 0.90 && ($0.text.contains(".") || $0.text.contains(",")) }
                    .sorted { $0.order < $1.order }
                // If Vision returns the whole row as one observation, the
                // final amount is usually the running balance. Use the
                // penultimate amount (the transaction) in that case.
                if fallbackCandidates.count > 1 {
                    return fallbackCandidates[fallbackCandidates.count - 2]
                }
                return fallbackCandidates.first
            }()
        guard let selected else { return nil }

        let titleParts = row
            .filter { $0.centerX >= 0.18 && $0.centerX < 0.62 }
            .map(\.text)
        var title = titleParts.isEmpty ? fullText : titleParts.joined(separator: " ")
        title = title
            .replacingOccurrences(
                of: #"(?i)(?<!\d)\d{1,2}\s*[\/\-.]\s*(?:\d{1,2}|[A-Za-z]{3,})\s*[\/\-.]\s*\d{2,4}(?!\d)"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?<![A-Za-z0-9])[-+]?\s*\$?(?:\d{1,3}(?:[ ,]\d{3})+|\d+)[.,]\d{2}(?![A-Za-z0-9])"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\bRFC[A-Z0-9]+\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"/REF[A-Z0-9_]+\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\bCR\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        title = cleanMerchantTitle(title)
        guard title.count >= 3, title.rangeOfCharacter(from: .letters) != nil else { return nil }

        let titleNormalized = title.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        let depositColumn = selected.x >= 0.59 && selected.x < 0.73
        let semanticDeposit = titleNormalized.contains("nomina")
            || titleNormalized.contains("sueldo")
            || titleNormalized.contains("deposito")
            || titleNormalized.contains("abono")
            || titleNormalized.contains("transferencia recibida")
        let flow: FlowKind
        if depositColumn || semanticDeposit {
            flow = .income
        } else if titleNormalized.contains("transfer")
                    || titleNormalized.contains("traspaso")
                    || titleNormalized.contains("pago de tarjeta") {
            flow = .transfer
        } else {
            flow = .expense
        }

        let signedAmount = flow == .income ? abs(selected.value) : -abs(selected.value)
        let displayAccount = flow == .transfer && titleNormalized.contains("amex")
            ? "Santander a Amex"
            : "Santander"
        let category = category(for: titleNormalized, flow: flow)
        let kind: MovementKind
        if titleNormalized.contains("msi") || titleNormalized.contains("meses sin intereses") || titleNormalized.contains("diferid") {
            kind = .msi
        } else if titleNormalized.contains("interes") {
            kind = .interest
        } else if titleNormalized.contains("comision") || titleNormalized.contains("anualidad") {
            kind = .fee
        } else if titleNormalized.contains("pago") && (titleNormalized.contains("tarjeta") || titleNormalized.contains("amex") || titleNormalized.contains("credito")) {
            kind = .cardPayment
        } else if titleNormalized.contains("transfer") || titleNormalized.contains("traspaso") {
            kind = .bankTransfer
        } else if flow == .income {
            kind = titleNormalized.contains("credito") || titleNormalized.contains("abono") ? .credit : .income
        } else {
            kind = .purchase
        }
        let travelRelated = [
            "viaje", "hotel", "hospedaje", "aerolinea", "vuelo", "avion",
            "transporte", "uber", "taxi", "metro", "renta de auto", "destino", "equipaje"
        ].contains { titleNormalized.contains($0) }

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

    /// Amex statements use a date/description block followed by the amount;
    /// OCR may split the date into several observations, so group visual lines
    /// before looking for a new transaction.
    private static func parseAmexOCR(
        _ lines: [OCRObservation],
        fileName: String
    ) -> [Movement] {
        guard let dateRegex = try? NSRegularExpression(
            pattern: #"(?i)(?<!\d)(\d{1,2})\s*[\/\-.]\s*(\d{1,2}|[A-Za-z]{3,})\s*[\/\-.]\s*(\d{2,4})(?!\d)"#
        ), let textDateRegex = try? NSRegularExpression(
            pattern: #"(?i)(?<!\d)(\d{1,2})\s+(?:de\s+)?([A-Za-zÁÉÍÓÚáéíóú]{3,})(?:\s+(?:de\s+)?(\d{4}))?"#
        ), let amountRegex = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9])[-+]?\s*\$?(?:\d{1,3}(?:[ ,. ]\d{3})+|\d+)[.,]\d{2}(?![A-Za-z0-9])"#
        ) else {
            return []
        }

        let linesByPage = Dictionary(grouping: lines, by: \.page)
        var rows: [[OCRObservation]] = []
        let ignoredHeaderPhrases = [
            "estado de cuenta", "tarjetahabiente", "marcelo andres",
            "fecha y detalle", "este no es", "paga desde", "total nuevos cargos",
            "nuevas transacciones", "fecha limite", "periodo de facturacion",
            "saldo actual", "pago minimo", "american express", "resumen de meses",
            "consolidado de compras", "fecha original", "monto original",
            "tasa de interes anual", "saldo pendiente", "numero de mensualidad",
            "monto total a pagar", "conoce tus meses", "informacion al tarjetahabiente",
            "a partir del", "anualidad de la tarjeta"
        ]

        for page in linesByPage.keys.sorted() {
            let pageLines = (linesByPage[page] ?? []).sorted {
                if abs($0.centerY - $1.centerY) > 0.012 {
                    return $0.centerY > $1.centerY
                }
                return $0.centerX < $1.centerX
            }
            var pendingRow: [OCRObservation] = []
            var inMSISummary = false
            for line in pageLines {
                let normalized = line.text.folding(
                    options: [.diacriticInsensitive, .caseInsensitive],
                    locale: .current
                )
                if normalized.contains("resumen de meses sin intereses")
                    || normalized.contains("consolidado de compras en meses sin intereses") {
                    if !pendingRow.isEmpty {
                        rows.append(pendingRow)
                        pendingRow.removeAll(keepingCapacity: true)
                    }
                    inMSISummary = true
                    continue
                }
                if inMSISummary { continue }

                // The totals after each transaction section are not movements.
                // Flush the last real row before dropping the total line so a
                // deferred/foreign charge immediately before it is preserved.
                if normalized.contains("total de las transacciones")
                    || normalized.contains("total de transacciones en moneda extranjera")
                    || normalized.contains("total de meses sin intereses")
                    || normalized.contains("total de plan de meses sin intereses") {
                    if !pendingRow.isEmpty {
                        rows.append(pendingRow)
                        pendingRow.removeAll(keepingCapacity: true)
                    }
                    continue
                }
                let hasDate = firstMatch(in: line.text, regex: dateRegex) != nil
                    || firstMatch(in: line.text, regex: textDateRegex) != nil
                let isTransactionDate = hasDate
                    && line.boundingBox.minX < 0.30
                    && !ignoredHeaderPhrases.contains(where: { normalized.contains($0) })

                if isTransactionDate {
                    if !pendingRow.isEmpty { rows.append(pendingRow) }
                    pendingRow = [line]
                } else if !pendingRow.isEmpty {
                    pendingRow.append(line)
                }
            }
            if !pendingRow.isEmpty { rows.append(pendingRow) }
        }

        return rows.compactMap { parseAmexRow($0, dateRegex: dateRegex, textDateRegex: textDateRegex, amountRegex: amountRegex) }
    }

    private static func parseAmexRow(
        _ row: [OCRObservation],
        dateRegex: NSRegularExpression,
        textDateRegex: NSRegularExpression,
        amountRegex: NSRegularExpression
    ) -> Movement? {
        let fullText = row.map(\.text).joined(separator: " ")
        let dateMatch = firstMatch(in: fullText, regex: dateRegex)
            ?? firstMatch(in: fullText, regex: textDateRegex)
        guard let dateMatch, let date = parseDate(dateMatch.text) else { return nil }

        let normalizedFullText = fullText.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        let ignoredPhrases = [
            "detalle de movimientos", "fecha y detalle", "estado de cuenta",
            "este no es un documento", "paga desde", "periodo de facturacion",
            "fecha limite de pago", "informacion al tarjetahabiente"
        ]
        guard !ignoredPhrases.contains(where: { normalizedFullText.contains($0) }) else { return nil }

        var amountCandidates: [OCRAmountCandidate] = []
        for (observationOrder, observation) in row.enumerated() {
            for (matchOrder, match) in allMatches(in: observation.text, regex: amountRegex).enumerated() {
                guard let value = parseAmount(match.text), abs(value) > 0, abs(value) < 10_000_000 else {
                    continue
                }
                amountCandidates.append(
                    OCRAmountCandidate(
                        value: value,
                        text: match.text,
                        x: observation.boundingBox.minX,
                        order: observationOrder * 100 + matchOrder
                    )
                )
            }
        }
        let orderedAmounts = amountCandidates.sorted(by: { $0.order < $1.order })
        guard let selected = (hasForeignCurrency(in: normalizedFullText) ? orderedAmounts.first : orderedAmounts.last) else { return nil }

        var title = fullText
            .replacingOccurrences(
                of: #"(?i)(?<!\d)\d{1,2}\s*[\/\-.]\s*(?:\d{1,2}|[A-Za-z]{3,})\s*[\/\-.]\s*\d{2,4}(?!\d)"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)(?<!\d)\d{1,2}\s+(?:de\s+)?[A-Za-zÁÉÍÓÚáéíóú]{3,}(?:\s+(?:de\s+)?\d{4})?"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?<![A-Za-z0-9])[-+]?\s*\$?(?:\d{1,3}(?:[ ,]\d{3})+|\d+)[.,]\d{2}(?![A-Za-z0-9])"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\bRFC[A-Z0-9]+\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"/REF[A-Z0-9_]+\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\bCR\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        title = cleanMerchantTitle(title)
        guard title.count >= 3, title.rangeOfCharacter(from: .letters) != nil else { return nil }

        let titleNormalized = title.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        let hasCreditMarker = row.contains {
            let normalized = $0.text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return normalized == "cr" || normalized.hasSuffix(" cr")
        }
        let isPayment = titleNormalized.contains("gracias por su pago")
            || (hasCreditMarker && titleNormalized.contains("pago"))
        let isRefund = titleNormalized.contains("devolucion")
            || titleNormalized.contains("reembolso")
            || titleNormalized.contains("bonificacion")
        let isStatementCredit = hasCreditMarker && !isPayment && !isRefund

        let flow: FlowKind
        if isRefund || isStatementCredit {
            flow = .income
        } else if isPayment {
            flow = .debt
        } else {
            flow = .expense
        }
        let signedAmount = flow == .income ? abs(selected.value) : -abs(selected.value)
        let category = category(for: titleNormalized, flow: flow)
        let kind: MovementKind
        if isStatementCredit {
            kind = .credit
        } else if titleNormalized.contains("msi")
                    || titleNormalized.contains("meses sin intereses")
                    || titleNormalized.contains("meses en automatico")
                    || titleNormalized.contains("diferir")
                    || titleNormalized.contains("diferid") {
            kind = .msi
        } else if titleNormalized.contains("interes") {
            kind = .interest
        } else if titleNormalized.contains("comision") || titleNormalized.contains("anualidad") {
            kind = .fee
        } else if isRefund {
            kind = .refund
        } else if isPayment {
            kind = .cardPayment
        } else {
            kind = .purchase
        }
        let travelRelated = [
            "viaje", "hotel", "hospedaje", "aerolinea", "vuelo", "avion",
            "transporte", "uber", "taxi", "metro", "renta de auto", "destino", "equipaje",
            "airbnb", "aeromexico", "vivaaerobus", "volaris"
        ].contains { titleNormalized.contains($0) }

        return Movement(
            date: date,
            title: title,
            account: "Amex",
            category: category,
            amount: signedAmount,
            flow: flow,
            kind: kind,
            travelRelated: travelRelated
        )
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
        var cleaned = value
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let commaIndex = cleaned.lastIndex(of: ",")
        let dotIndex = cleaned.lastIndex(of: ".")
        if let commaIndex, dotIndex == nil {
            let decimalDigits = cleaned.distance(from: commaIndex, to: cleaned.endIndex) - 1
            if decimalDigits == 1 || decimalDigits == 2 {
                cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
            } else {
                cleaned = cleaned.replacingOccurrences(of: ",", with: "")
            }
        } else if let commaIndex, let dotIndex, commaIndex > dotIndex {
            cleaned = cleaned.replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: ",", with: ".")
        } else {
            cleaned = cleaned.replacingOccurrences(of: ",", with: "")
        }

        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func cleanMerchantTitle(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"(?i)\s+(?:d[oó]lar(?:es)?(?:\s+u\.s\.a\.)?|euro?s?|peso(?:s)?\s+colombiano?s?|tipo\s+de\s+cambio).*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasForeignCurrency(in normalizedText: String) -> Bool {
        ["dolar", "euro", "peso colombiano", "tipo de cambio", " tc:"].contains {
            normalizedText.contains($0)
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let normalized = value.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        let parts = normalized.split(whereSeparator: { character in
            character == "/" || character == "-" || character == "." || character == " "
        })
        guard let first = parts.first.flatMap({ Int($0) }) else { return nil }
        let day: Int
        let month: Int
        let year: Int
        if first >= 1_000, parts.count >= 3,
           let parsedMonth = Int(parts[1]), let parsedDay = Int(parts[2]) {
            // ISO dates are common in CSV-like PDFs: yyyy-mm-dd.
            year = first
            month = parsedMonth
            day = parsedDay
        } else {
            guard let monthToken = parts.dropFirst().first(where: {
                Int($0) != nil || monthNumber(String($0)) != nil
            }) else { return nil }
            day = first
            month = Int(monthToken) ?? monthNumber(String(monthToken))!
            year = parts.dropFirst()
                .compactMap { Int($0) }
                .last(where: { $0 >= 100 })
                ?? Calendar.current.component(.year, from: .now)
        }
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
        let normalizedFileName = fileName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if let fileMatch = try? NSRegularExpression(pattern: #"(?i)(?:enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre|ene|feb|mar|abr|may|jun|jul|ago|sep|set|oct|nov|dic)[^\d]{0,8}20\d{2}"#) {
            let range = NSRange(normalizedFileName.startIndex..<normalizedFileName.endIndex, in: normalizedFileName)
            if let match = fileMatch.firstMatch(in: normalizedFileName, range: range),
               let valueRange = Range(match.range, in: normalizedFileName) {
                return String(normalizedFileName[valueRange]).replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return fileName
            .replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func statementKind(from text: String, source: String) -> StatementKind {
        if source.localizedCaseInsensitiveContains("Amex") { return .card }
        if source.localizedCaseInsensitiveContains("Santander")
            || source.localizedCaseInsensitiveContains("BBVA")
            || [
                "Banorte", "HSBC", "Scotiabank", "Citibanamex", "Banamex",
                "Inbursa", "Banco Azteca", "Banco del Bajío", "Mifel", "INVEX",
                "Hey Banco", "Nu", "Klar", "Rappi", "Ualá"
            ].contains(where: { source.localizedCaseInsensitiveContains($0) }) {
            return .bank
        }

        let normalized = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        let cardMarkers = [
            "tarjeta de credito", "tarjetahabiente", "credito disponible",
            "limite de credito", "linea de credito", "pago minimo",
            "saldo deudor", "credit card", "mastercard", "visa credit"
        ]
        let bankMarkers = [
            "cuenta de cheques", "cuenta de ahorro", "cuenta clabe",
            "estado de cuenta nomina", "super nomina", "depositos",
            "retiros", "saldo final", "saldo disponible", "cuenta corriente",
            "banorte", "hsbc", "scotiabank", "citibanamex", "banamex",
            "inbursa", "banco azteca", "banco del bajio", "mifel", "invex",
            "hey banco", "nu mexico", "nu banco", "klar", "rappi", "uala"
        ]
        let cardScore = cardMarkers.reduce(into: 0) { score, marker in
            if normalized.contains(marker) { score += 1 }
        }
        let bankScore = bankMarkers.reduce(into: 0) { score, marker in
            if normalized.contains(marker) { score += 1 }
        }
        if cardScore >= 2 && cardScore >= bankScore { return .card }
        if bankScore >= 2 { return .bank }
        return .unknown
    }

    private static func accountName(from fileName: String) -> String {
        let normalized = fileName.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )

        // Scanned Santander statements can contain generic card terminology
        // in OCR noise. Give the bank's own visual/table markers priority so a
        // Santander PDF is never routed through the Amex parser.
        let santanderMarkers = [
            "santander", "banco santander", "estado de cuenta nomina",
            "detalle de movimientos cuenta", "super nomina", "cuenta de cheques",
            "saldo final del periodo anterior", "fecha folio descripcion",
            "deposito retiro saldo", "cuenta clabe"
        ]
        let santanderScore = santanderMarkers.reduce(into: 0) { score, marker in
            if normalized.contains(marker) { score += 1 }
        }
        if normalized.contains("santander")
            || normalized.contains("estado de cuenta nomina")
            || normalized.contains("detalle de movimientos cuenta")
            || normalized.contains("super nomina")
            || santanderScore >= 2 {
            return "Santander"
        }

        let amexMarkers = [
            "amex", "american express", "gracias por su pago en linea",
            "importe en mn", "fecha y detalle de las operaciones",
            "paga desde los canales de amex", "the platinum credit card",
            "total de las transacciones en moneda extranjera"
        ]
        let amexScore = amexMarkers.reduce(into: 0) { score, marker in
            if normalized.contains(marker) { score += 1 }
        }
        if amexScore >= 1 {
            return "Amex"
        }

        if normalized.contains("bbva") {
            return "BBVA"
        }
        let otherBankNames: [(String, [String])] = [
            ("Banorte", ["banorte"]),
            ("HSBC", ["hsbc"]),
            ("Scotiabank", ["scotiabank"]),
            ("Citibanamex", ["citibanamex", "banamex"]),
            ("Inbursa", ["inbursa"]),
            ("Banco Azteca", ["banco azteca"]),
            ("Banco del Bajío", ["banco del bajio"]),
            ("Mifel", ["mifel"]),
            ("INVEX", ["invex"]),
            ("Hey Banco", ["hey banco"]),
            ("Nu", ["nu mexico", "nu banco"]),
            ("Klar", ["klar"]),
            ("Rappi", ["rappi"]),
            ("Ualá", ["uala"])
        ]
        if let detected = otherBankNames.first(where: { _, markers in markers.contains(where: { normalized.contains($0) }) })?.0 {
            return detected
        }
        return "Importado"
    }

    private static func categoryRuleKey(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"(?i)\b(?:rfc|ref|referencia|aut)\s*[a-z0-9_-]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b\d{2,}\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func category(for title: String, flow: FlowKind) -> String {
        if flow == .income { return "Ingresos" }
        if flow == .transfer { return "Transferencia" }
        if flow == .debt { return "Pago de tarjeta" }

        let rules: [(String, [String])] = [
            // Travel is intentionally separate from day-to-day transport.
            ("Viajes", [
                "airbnb", "booking", "expedia", "hotel", "hospedaje", "aeromexico",
                "aerobus", "volaris", "vivaaerobus", "american airlines", "united airlines",
                "delta air", "iberia", "vuelo", "flight", "travel", "renta de auto", "car rental",
                "airport", "aeropuerto", "equipaje", "luggage"
            ]),
            ("Transporte", [
                "uber", "didi", "cabify", "taxi", "metrobus", "metro ", "metrotap", "nyct paygo", "njtransit", "nyc ferry",
                "subway", "mta ", "train ", "estacionamiento", "estac ", "parking", "parco ", "gasolina", "pemex", "shell",
                "bp ", "gulf", "mobil", "caseta", "autopista", "toll", "ecobici", "mueve", "transporte"
            ]),
            ("Salud", [
                "farmacia", "farmacias", "hospital", "clinica", "clínica", "doctor",
                "consultorio", "dent", "dental", "laboratorio", "salud", "medic"
            ]),
            ("Comidas", [
                "restaurant", "rest ", "rest.", "taquer", "taco", "sushi", "cafe",
                "café", "coffee", "starbucks", "burger", "pizza", "pub", "bar ",
                "comida", "food", "flauta", "ramen", "krispy", "pan ", "pastel",
                "helado", "neveria", "churro", "frutos prohibidos", "grill", "deli",
                "pantry", "wine", "beer", "chicken", "cocina", "parrilla", "guac time", "chipotle",
                "dos toros", "dunkin", "italian", "crepes", "sanborns", "cerv", "mariscos", "exquisito",
                "faunna", "terraza", "los gueros", "guero", "harp helu", "serena horneando", "tierra garat",
                "malachy", "sophie", "lovejoy", "smokejazz", "smoke and gift", "metropolis", "mandarin mo", "social",
                "goldbergs", "marta tap", "hana group", "tst*", "shreeji", "jimmys", "primavera", "saio la octava", "fogoncito",
                "burger king", "aifa", "asador"
            ]),
            ("Alimentos", [
                "walmart", "superama", "soriana", "costco", "chedraui", "la comer",
                "city market", "sam's", "sams ", "oxxo", "7 eleven", "seven eleven",
                "extra k", "extra ", "super ", "mercado ", "grocery", "market", "mkt ", "frutos", "abarrotes",
                "cvs", "pharmacy", "wholefds", "whole foods", "queens mkt", "convenience", "meadowland", "mart corp", "7-eleven"
            ]),
            ("Entretenimiento", [
                "cinemex", "cinepolis", "cinépolis", "cine ", "teatro", "spotify",
                "netflix", "disney", "hbo", "prime video", "apple music", "xbox",
                "playstation", "nintendo", "steam", "videojuego", "club deportivo", "entret ", "jazz",
                "museum", "museo", "amnh", "guggenheim", "aquarium", "acuario", "zoo", "attraction", "atraccion", "ticket",
                "boletos", "show", "concierto", "club ", "soccer", "summit one", "world of coca", "circo", "stadium",
                "rounders", "empire hall", "hard rock", "salon de perreo", "asdeporte", "pickle"
            ]),
            ("Educación", [
                "universidad", "escuela", "colegio", "curso", "udemy", "coursera",
                "domestika", "libros", "libreria", "librería"
            ]),
            ("Mascotas", [
                "veterin", "petco", "pet shop", "mascota", "mundo animal"
            ]),
            ("Hogar", [
                "ikea", "home depot", "ferreter", "muebles", "hogar", "limpieza",
                "decoracion", "decoración", "mantenimiento"
            ]),
            ("Servicios", [
                "canva", "telcel", "at&t", "movistar", "izzi", "totalplay", "cfe",
                "luz ", "agua ", "internet", "seguro", "asegur", "suscripcion",
                "suscripción", "membresia", "membresía", "adobe", "microsoft",
                "google storage", "apple.com/bill", "paypal", "stripe", "apple.com/mx", "holafly", "wi-fi onboard", "wifi onboard"
            ]),
            ("Compras", [
                "amazon", "shein", "mercadolibre", "mercado libre", "mercadopago", "lumen", "steren",
                "bout", "tienda", "shop", "store", "ropa", "zapateria", "departamental", "old navy", "fanatics", "thriftland", "miniso"
            ]),
            ("Finanzas", [
                "comision", "comisión", "interes", "interés", "cajero", "retiro",
                "anualidad", "financ", "keepcash", "meses sin intereses", "meses en automatico", "meses automatico", "monto a diferir", "diferid"
            ])
        ]
        for (category, markers) in rules where markers.contains(where: { title.contains($0) }) {
            return category
        }
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
