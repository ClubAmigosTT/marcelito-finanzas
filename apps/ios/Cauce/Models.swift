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
    var msiPending: Decimal? = nil
    var revolvingBalance: Decimal? = nil
    var msiInstallments: Int? = nil
    var msiMonthlyLoad: Decimal? = nil
    var domesticTransactionTotal: Decimal? = nil
    /// Amex may print the domestic subtotal as a credit (CR). The
    /// reconciliation layer compares net section values, so this flag is
    /// retained when the parser can identify it.
    var domesticTransactionTotalIsCredit: Bool? = nil
    var foreignTransactionTotal: Decimal? = nil
    /// Totals declared by bank statements. They are used as a hard control
    /// against the rows reconstructed from the PDF table.
    var depositTotal: Decimal? = nil
    var withdrawalTotal: Decimal? = nil
    var depositCount: Int? = nil
    var withdrawalCount: Int? = nil
}

enum StatementReconciliationStatus: String, Codable {
    case valid
    case invalid
    case pending
}

enum SourceDetectionStatus: String, Codable, Equatable {
    case verified
    case review
    case unknown
}

/// Evidence captured at import time. The body mention list is diagnostic only:
/// a counterparty such as Santander in a BBVA transfer must never identify the
/// issuer of the statement.
struct SourceDetectionEvidence: Codable {
    let source: String
    let confidence: Double
    let status: SourceDetectionStatus
    let evidence: [String]
    let ignoredBodyMentions: [String]
}

/// Evidence that an imported statement was compared with the issuer totals.
/// Keeping this next to the statement makes the quality gate reproducible
/// after an app restart instead of inferring it from the current dashboard.
struct StatementReconciliationRecord: Codable {
    var status: StatementReconciliationStatus
    var tolerance: Decimal
    var extractedDepositTotal: Decimal? = nil
    var extractedWithdrawalTotal: Decimal? = nil
    var extractedChargeTotal: Decimal? = nil
    var extractedDomesticChargeTotal: Decimal? = nil
    var extractedForeignChargeTotal: Decimal? = nil
    var extractedCreditTotal: Decimal? = nil
    var extractedPaymentTotal: Decimal? = nil
    var extractedMovementCount: Int? = nil
    /// Expected rows when both deposit and withdrawal counts are printed.
    var expectedMovementCount: Int? = nil
    var reason: String? = nil
}

/// Provenance for a single reconstructed row.  Keeping the method and page
/// with the movement makes an accepted amount traceable without retaining the
/// whole PDF text in the ledger.
struct MovementExtractionEvidence: Codable {
    var method: String
    var page: Int? = nil
    var confidence: Double
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
    var foreignCurrency: Bool
    var extractionEvidence: MovementExtractionEvidence?

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
        travelRelated: Bool = false,
        foreignCurrency: Bool = false,
        extractionEvidence: MovementExtractionEvidence? = nil
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
        self.foreignCurrency = foreignCurrency
        self.extractionEvidence = extractionEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, title, account, category, amount, flow, statementId, kind, travelRelated, foreignCurrency, extractionEvidence
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
        foreignCurrency = try container.decodeIfPresent(Bool.self, forKey: .foreignCurrency) ?? false
        extractionEvidence = try container.decodeIfPresent(MovementExtractionEvidence.self, forKey: .extractionEvidence)
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
        try container.encode(foreignCurrency, forKey: .foreignCurrency)
        try container.encodeIfPresent(extractionEvidence, forKey: .extractionEvidence)
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
    var reconciliation: StatementReconciliationRecord? = nil
    var sourceDetection: SourceDetectionEvidence? = nil
    /// Mean Vision confidence for scanned imports. Text-layer statements keep
    /// this nil because no OCR signal was used.
    var ocrConfidence: Double? = nil
    /// Mean Vision confidence grouped by page for targeted review.
    var ocrPageConfidences: [Double]? = nil
    /// SHA-256 of the original PDF bytes. This is the stable document identity
    /// used to reprocess a UUID-named stored file without relying on its name.
    var sourceFingerprint: String? = nil
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
    let reconciliation: StatementReconciliationRecord?
    let sourceDetection: SourceDetectionEvidence
    let sourceFingerprint: String
    let ocrConfidence: Double?
    let ocrPageConfidences: [Double]?
}

/// Deterministic reader output used by the iOS contract tests. Keeping this
/// snapshot separate from the persisted ledger lets CI exercise extraction,
/// issuer detection and statement classification without writing user data.
struct ReaderParseSnapshot {
    let sourceDetection: SourceDetectionEvidence
    let source: String
    let kind: StatementKind
    let movements: [Movement]
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
    let msiPending: Decimal?
    let revolvingBalance: Decimal?
    let msiInstallmentsCount: Int?
    let msiMonthlyLoad: Decimal?
    let cashBalance: Decimal?
    let debtBalance: Decimal?

    var paidPercent: Decimal? { newCharges == 0 ? nil : realPayments / newCharges }
    var pendingPercent: Decimal? { newCharges == 0 ? nil : max(Decimal(0), accumulatedBalance) / newCharges }
}

/// A daily point used to compare real income, real spending, and the
/// accumulated balance on the dashboard. Values are already converted to
/// `Double` so Swift Charts can render them without exposing accounting
/// formulas in the view layer.
struct CashFlowPoint: Identifiable {
    let id: Date
    let date: Date
    let income: Double
    let expense: Double
    let balance: Double
}

enum FinanceImportError: LocalizedError {
    case unreadableDocument
    case emptyDocument
    case invalidReconciliation(String)

    var errorDescription: String? {
        switch self {
        case .unreadableDocument:
            "No pudimos leer este PDF. Verifica que sea un estado de cuenta válido."
        case .emptyDocument:
            "Este PDF no contiene texto ni movimientos reconocibles. Revisa que sea un estado de cuenta y, si es un escaneo, confirma los importes en Movimientos después de importarlo."
        case .invalidReconciliation(let reason):
            "El estado no concilia contra los totales declarados por el banco. \(reason) No se incorporó al libro canónico."
        }
    }
}

struct LedgerQuality {
    let statementCount: Int
    let validatedStatementCount: Int
    let invalidStatementCount: Int
    let pendingStatementCount: Int
    let movementCount: Int
    let reviewMovementCount: Int
    let absurdMovementCount: Int
    let reconciledPercent: Double
    let isBlocking: Bool
    let message: String?
}

struct CanonicalRebuildResult {
    let candidateCount: Int
    let importedCount: Int
    let invalidCount: Int
}

struct LedgerConsistencyCheck: Identifiable {
    let id: String
    let label: String
    let expected: Decimal?
    let actual: Decimal?
    let difference: Decimal?
    let tolerance: Decimal
    let passed: Bool
}

enum LedgerAuditStatus: String, Codable {
    case passed
    case warning
    case blocked
}

/// Persisted evidence for the last automatic audit. The audit id is also
/// written to the diagnostic trail so a TestFlight crash can be correlated
/// with the exact ledger version without exporting financial data.
struct LedgerAuditRun: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    let completedAt: Date
    let trigger: String
    let status: LedgerAuditStatus
    let ledgerVersion: UUID
    let statementCount: Int
    let canonicalMovementCount: Int
    let reconciledPercent: Double
    let issueCount: Int
    let message: String?
}

/// Single-key envelope used as the active ledger pointer. Keeping movements
/// and statements in one value prevents a crash between two UserDefaults
/// writes from producing a mixed-generation ledger.
private struct LedgerEnvelope: Codable {
    let schemaVersion: Int
    let version: UUID
    let savedAt: Date
    let movements: [Movement]
    let statements: [StatementRecord]
}

@Observable
final class FinanceStore {
    private let movementKey = "marcelito.movements.v2"
    private let statementKey = "marcelito.statements.v1"
    private let importKey = "marcelito.lastImport"
    private let categoryRulesKey = "marcelito.categoryRules.v1"
    private let numericRepairKey = "marcelito.numericRepair.v1"
    private let canonicalRebuildKey = "marcelito.canonicalRebuild.v1"
    private let canonicalRebuildExpectedCountKey = "marcelito.canonicalRebuild.expectedCount.v1"
    private let ledgerEnvelopeKey = "marcelito.ledger.active.v1"
    private let ledgerBackupKey = "marcelito.ledger.backup.v1"
    private let rebuildStateKey = "marcelito.ledger.rebuildState.v1"
    private let auditRunKey = "marcelito.ledger.lastAudit.v1"
    private let ledgerSchemaVersion = 1
    private let statementFilesDirectoryName = "ImportedStatements"
    private var repairInProgress = false

    /// Runs the same text-layer reader path used during import, without
    /// touching UserDefaults or the canonical ledger. The test target uses
    /// this to lock down issuer detection and administrative-row rejection.
    static func readerParseSnapshotForTesting(
        text: String,
        fileName: String,
        sourceHint: String? = nil
    ) -> ReaderParseSnapshot {
        let detection = sourceDetection(from: text, fileName: fileName)
        let source = sourceHint ?? detection.source
        let kind = statementKind(from: text, source: source)
        let movements = parse(text: text, fileName: fileName, sourceHint: source)
        let summary = summary(from: text, source: source)
        return ReaderParseSnapshot(
            sourceDetection: detection,
            source: source,
            kind: kind,
            movements: movements,
            summary: summary
        )
    }

    var movements: [Movement]
    var statements: [StatementRecord]
    private(set) var ledgerVersion: UUID
    private(set) var lastAuditRun: LedgerAuditRun?

    private(set) var lastImportedFile: String?

    /// `movements` is the persisted canonical ledger. Raw parser candidates
    /// are never stored separately or consumed by any screen; every
    /// aggregate below is derived only after normalization, deduplication and
    /// account matching have completed.
    var canonicalMovements: [Movement] { movements }

    /// Quality gate shared by Resumen, Gastos, Cuentas, Patrimonio and all
    /// historical charts. A statement that has not reconciled is visible in
    /// diagnostics, but cannot silently feed executive figures.
    var ledgerQuality: LedgerQuality {
        let validated = statements.filter { $0.reconciliation?.status == .valid }
        let invalid = statements.filter { $0.reconciliation?.status == .invalid }
        let pending = statements.filter { $0.reconciliation?.status != .valid }
        let reviewCount = movements.filter { $0.category == "Por revisar" || $0.category == "Sin categoría" }.count
        let absurdCount = movements.filter { abs($0.amount) >= 10_000_000 || !isValidStoredMovement($0) }.count
        let statementCount = statements.count
        let reconciledPercent = statementCount == 0 ? 100 : Double(validated.count) / Double(statementCount) * 100
        let expectedRebuildCount = UserDefaults.standard.integer(forKey: canonicalRebuildExpectedCountKey)
        let missingRebuiltStatements = UserDefaults.standard.bool(forKey: canonicalRebuildKey)
            && expectedRebuildCount > 0
            && validated.count < expectedRebuildCount
        let canonicalGross = movements.filter(isSpend).reduce(Decimal(0)) { $0 + absolute($1.amount) }
        let canonicalRefunds = movements.filter { movementKind($0) == .refund }.reduce(Decimal(0)) { $0 + absolute($1.amount) }
        let canonicalNetSpend = max(Decimal(0), canonicalGross - canonicalRefunds)
        let spendMismatch = consolidatedRealSpend > canonicalNetSpend + max(Decimal(1), canonicalNetSpend * Decimal(string: "0.01")!)
        let failedChecks = consistencyChecks.filter { !$0.passed }
        let blocking = invalid.count > 0 || pending.count > 0 || absurdCount > 0 || spendMismatch || !failedChecks.isEmpty || missingRebuiltStatements
        let message: String?
        if invalid.count > 0 {
            message = "\(invalid.count) estado(s) no concilian contra sus totales originales."
        } else if pending.count > 0 {
            message = "\(pending.count) estado(s) aún no tienen conciliación validada."
        } else if absurdCount > 0 {
            message = "Hay \(absurdCount) movimiento(s) con importes fuera de rango."
        } else if spendMismatch {
            message = "El gasto consolidado supera los movimientos canónicos; se bloqueó el KPI."
        } else if let failed = failedChecks.first {
            message = "La conciliación no cuadra: \(failed.label)."
        } else if missingRebuiltStatements {
            message = "Faltan \(expectedRebuildCount - validated.count) estado(s) validado(s) de la reconstrucción."
        } else {
            message = nil
        }
        return LedgerQuality(
            statementCount: statementCount,
            validatedStatementCount: validated.count,
            invalidStatementCount: invalid.count,
            pendingStatementCount: pending.count,
            movementCount: movements.count,
            reviewMovementCount: reviewCount,
            absurdMovementCount: absurdCount,
            reconciledPercent: reconciledPercent,
            isBlocking: blocking,
            message: message
        )
    }

    var dashboardIsBlocked: Bool { ledgerQuality.isBlocking }

    /// Re-runs the complete set of cheap local controls and persists the
    /// result. This is intentionally deterministic: it never mutates a row
    /// based on a guess, and any blocking issue remains visible to the UI.
    @discardableResult
    func runAutomaticAudit(trigger: String = "foreground") -> LedgerAuditRun {
        let startedAt = Date()
        normalizeStoredLedger()
        let quality = ledgerQuality
        let status: LedgerAuditStatus = quality.isBlocking
            ? .blocked
            : quality.reviewMovementCount > 0
                ? .warning
                : .passed
        let run = LedgerAuditRun(
            id: UUID(),
            startedAt: startedAt,
            completedAt: .now,
            trigger: trigger,
            status: status,
            ledgerVersion: ledgerVersion,
            statementCount: quality.statementCount,
            canonicalMovementCount: quality.movementCount,
            reconciledPercent: quality.reconciledPercent,
            issueCount: quality.invalidStatementCount + quality.pendingStatementCount + quality.absurdMovementCount + quality.reviewMovementCount,
            message: quality.message
        )
        lastAuditRun = run
        if let data = try? JSONEncoder().encode(run) {
            UserDefaults.standard.set(data, forKey: auditRunKey)
        }
        persist()
        DiagnosticsRecorder.record(
            level: quality.isBlocking ? "error" : "info",
            stage: "audit.\(trigger)",
            message: "Auditoría \(run.id.uuidString.prefix(8)): \(status.rawValue), \(quality.reconciledPercent.rounded())% conciliado, \(quality.movementCount) movimiento(s) canónico(s)."
        )
        return run
    }

    var consistencyChecks: [LedgerConsistencyCheck] {
        let tolerance = Decimal(string: "0.05", locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(0.05)
        func check(_ id: String, _ label: String, expected: Decimal?, actual: Decimal?) -> LedgerConsistencyCheck {
            guard let expected, let actual else {
                return LedgerConsistencyCheck(id: id, label: label, expected: expected, actual: actual, difference: nil, tolerance: tolerance, passed: true)
            }
            let difference = actual - expected
            return LedgerConsistencyCheck(id: id, label: label, expected: expected, actual: actual, difference: difference, tolerance: tolerance, passed: absolute(difference) <= tolerance)
        }

        var checks = [
            check("flow", "Ingresos − gasto real = flujo neto", expected: realIncome - consolidatedRealSpend, actual: netFlow),
            check("patrimony", "Efectivo − deuda = patrimonio líquido", expected: cashAvailable.flatMap { cash in debtTotal.map { cash - $0 } }, actual: liquidPatrimony),
            check("credit", "Límite − crédito disponible = deuda utilizada", expected: creditLimit.flatMap { limit in creditAvailable.map { limit - $0 } }, actual: creditUsed),
        ]
        for metric in latestMetricsBySource(periodMetrics.filter { $0.kind == .bank }) {
            guard let opening = statements.first(where: { $0.id == metric.id })?.summary?.previousBalance,
                  let closing = metric.cashBalance else { continue }
            let delta = movements
                .filter { $0.statementId == metric.id }
                .reduce(Decimal(0)) { $0 + $1.amount }
            checks.append(check(
                "cash-\(metric.id)",
                "Saldo inicial + movimientos = saldo final (\(metric.source))",
                expected: opening + delta,
                actual: closing
            ))
        }
        return checks
    }

    /// Calculated statements are always ordered by their real cutoff date.
    /// Import order is not a financial ordering: importing May after August
    /// must never make May look like the current balance.
    var periodMetrics: [StatementMetric] {
        // Only reconciled statements may participate in balances, trends or
        // fallbacks. Invalid/pending records remain in `statements` solely so
        // the audit UI can explain why the dashboard is blocked.
        statements
            .filter { $0.reconciliation?.status == .valid }
            .map { calculateMetric(for: $0) }
            .sorted { left, right in
                let leftDate = statementEndDate(for: left.id)
                let rightDate = statementEndDate(for: right.id)
                if leftDate != rightDate { return leftDate > rightDate }
                let leftImported = statements.first(where: { $0.id == left.id })?.importedAt ?? .distantPast
                let rightImported = statements.first(where: { $0.id == right.id })?.importedAt ?? .distantPast
                return leftImported > rightImported
            }
    }
    var cardPeriodMetrics: [StatementMetric] { periodMetrics.filter { $0.kind == .card } }
    var cardPeriodCount: Int { Set(cardPeriodMetrics.map { periodKey($0.period) }).count }

    /// Resolves a statement metric outside of a SwiftUI view builder. Keeping
    /// the lookup here avoids making the compiler type-check the entire
    /// calculated-metrics expression while it is building a `ForEach` row.
    func metric(for statementID: UUID) -> StatementMetric? {
        for candidate in periodMetrics where candidate.id == statementID {
            return candidate
        }
        return nil
    }

    /// Returns the newest statement for an account, independent of the order
    /// in which PDFs were imported.
    func latestStatement(for source: String) -> StatementRecord? {
        statements
            .filter { $0.source == source }
            .max { left, right in
                let leftDate = statementEndDate(for: left.id)
                let rightDate = statementEndDate(for: right.id)
                if leftDate != rightDate { return leftDate < rightDate }
                return left.importedAt < right.importedAt
            }
    }

    var totalNewTransactions: Decimal {
        movements.filter { isCardMovement($0) && movementKind($0) == .purchase }.reduce(0) { $0 + absolute($1.amount) }
    }
    var averageMonthlySpend: Decimal { cardPeriodCount == 0 ? 0 : totalNewTransactions / Decimal(cardPeriodCount) }
    var totalNewCharges: Decimal {
        movements.filter { isCardMovement($0) && isSpend($0) }.reduce(0) { $0 + absolute($1.amount) }
    }
    var totalRealPayments: Decimal {
        movements.filter { isCardMovement($0) && movementKind($0) == .cardPayment }.reduce(0) { $0 + absolute($1.amount) }
    }
    var totalCredits: Decimal {
        movements.filter { isCardMovement($0) && movementKind($0) == .credit }.reduce(0) { $0 + absolute($1.amount) }
    }
    var totalRefunds: Decimal {
        movements.filter { isCardMovement($0) && movementKind($0) == .refund }.reduce(0) { $0 + absolute($1.amount) }
    }
    var accumulatedBalance: Decimal { totalNewCharges - totalRealPayments - totalCredits - totalRefunds }
    var latestDifference: Decimal { cardPeriodMetrics.first?.difference ?? 0 }
    var paidPercent: Decimal? { totalNewCharges == 0 ? nil : totalRealPayments / totalNewCharges }
    var pendingPercent: Decimal? { totalNewCharges == 0 ? nil : max(Decimal(0), accumulatedBalance) / totalNewCharges }
    var travelSpend: Decimal {
        movements.filter { isSpend($0) && isTravel($0) }.reduce(0) { $0 + absolute($1.amount) }
    }
    var travelPercent: Decimal? { consolidatedRealSpend == 0 ? nil : travelSpend / consolidatedRealSpend }
    var ordinarySpend: Decimal { max(Decimal(0), consolidatedRealSpend - travelSpend) }
    var ordinaryAverageMonthly: Decimal { cardPeriodCount == 0 ? 0 : ordinarySpend / Decimal(cardPeriodCount) }
    var latestMsiMonthlyLoad: Decimal? { cardPeriodMetrics.first?.msiMonthlyLoad }
    var latestMsiOriginalDeferred: Decimal? { cardPeriodMetrics.first?.msiOriginalDeferred }
    var latestMsiPending: Decimal? { cardPeriodMetrics.first?.msiPending }
    var latestRevolvingBalance: Decimal? { cardPeriodMetrics.first?.revolvingBalance }
    var latestMsiInstallmentsCount: Int? { cardPeriodMetrics.first?.msiInstallmentsCount }
    var latestPaymentForNoInterest: Decimal? { cardPeriodMetrics.first?.paymentForNoInterest }
    var cardSpend: Decimal { totalNewCharges }
    var directBankSpend: Decimal {
        movements.filter { movement in
            guard isSpend(movement), let statementId = movement.statementId,
                  let statement = statements.first(where: { $0.id == statementId }) else { return false }
            return statementKind(statement) != .card
        }.reduce(0) { $0 + absolute($1.amount) }
    }
    var rawExpense: Decimal { movements.filter { $0.flow == .expense }.reduce(0) { $0 + absolute($1.amount) } }
    var excludedCardPayments: Decimal { movements.filter { movementKind($0) == .cardPayment && isBankMovement($0) }.reduce(0) { $0 + absolute($1.amount) } }
    var excludedInternalTransfers: Decimal { movements.filter { movementKind($0) == .bankTransfer && $0.amount < 0 }.reduce(0) { $0 + absolute($1.amount) } }
    var consolidatedRealSpend: Decimal {
        let manualSpend = movements.filter { $0.statementId == nil && isSpend($0) }.reduce(0) { $0 + absolute($1.amount) }
        let allRefunds = movements.filter { movementKind($0) == .refund }.reduce(0) { $0 + absolute($1.amount) }
        return max(Decimal(0), cardSpend + directBankSpend + manualSpend - allRefunds)
    }
    var totalIncome: Decimal { realIncome }
    var totalTransfers: Decimal { movements.filter { $0.flow == .transfer }.reduce(0) { $0 + absolute($1.amount) } }
    var totalExpenses: Decimal { consolidatedRealSpend }
    var realExpenseMovements: [Movement] { movements.filter(isSpend) }

    /// Expenses shown in the dashboard are scoped to the newest available
    /// statement period. Keeping the complete ledger above is useful for
    /// audits, but it must not inflate the current-month view.
    var currentPeriodExpenseMovements: [Movement] {
        movements.filter { movement in
            guard let currentPeriodKey else { return true }
            return movementPeriodKey(movement) == currentPeriodKey
        }.filter(isSpend)
    }
    var realIncome: Decimal {
        movements.filter(isRealIncome).reduce(0) { $0 + absolute($1.amount) }
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
        currentPeriodExpenseMovements.reduce(0) { $0 + absolute($1.amount) }
    }

    var monthlyIncome: Decimal {
        movements
            .filter { movement in
                guard let currentPeriodKey else { return isRealIncome(movement) }
                return movementPeriodKey(movement) == currentPeriodKey && isRealIncome(movement)
            }
            .reduce(0) { $0 + absolute($1.amount) }
    }

    var monthlyNetFlow: Decimal { monthlyIncome - monthlyExpense }

    /// Daily cash-flow history for the executive comparison chart. Card
    /// payments and internal transfers are intentionally excluded so the
    /// balance line reflects real income minus real spending only.
    var cashFlowHistory: [CashFlowPoint] {
        var incomeByDay: [Date: Decimal] = [:]
        var expenseByDay: [Date: Decimal] = [:]
        let calendar = Calendar.current

        for movement in movements {
            let day = calendar.startOfDay(for: movement.date)
            if isRealIncome(movement) {
                incomeByDay[day, default: 0] += absolute(movement.amount)
            } else if isSpend(movement) {
                expenseByDay[day, default: 0] += absolute(movement.amount)
            }
        }

        let days = Set(incomeByDay.keys).union(expenseByDay.keys).sorted()
        guard !days.isEmpty else { return [] }

        var accumulatedBalance: Decimal = 0
        return days.map { day in
            let income = incomeByDay[day, default: 0]
            let expense = expenseByDay[day, default: 0]
            accumulatedBalance += income - expense
            return CashFlowPoint(
                id: day,
                date: day,
                income: NSDecimalNumber(decimal: income).doubleValue,
                expense: NSDecimalNumber(decimal: expense).doubleValue,
                balance: NSDecimalNumber(decimal: accumulatedBalance).doubleValue
            )
        }
    }

    private func absolute(_ value: Decimal) -> Decimal { value < 0 ? -value : value }

    private func statementKind(_ statement: StatementRecord) -> StatementKind {
        if let kind = statement.kind { return kind }
        if statement.source.localizedCaseInsensitiveContains("Amex") { return .card }
        if statement.source.localizedCaseInsensitiveContains("Importado") { return .unknown }
        return .bank
    }

    private func isCardMovement(_ movement: Movement) -> Bool {
        guard let statementId = movement.statementId,
              let statement = statements.first(where: { $0.id == statementId }) else { return false }
        return statementKind(statement) == .card
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
        if value.contains("devolucion") || value.contains("reembolso") || value.contains("bonificacion") { return .refund }
        if (value.contains("pago") && (value.contains("tarjeta") || value.contains("amex") || value.contains("credito") || value.contains("recibido")))
            || (value.contains("abono") && (value.contains("tarjeta") || value.contains("credito") || value.contains("recibido"))) { return .cardPayment }
        if movement.flow == .transfer { return value.contains("transfer") || value.contains("traspaso") ? .bankTransfer : .cardPayment }
        if movement.flow == .income { return value.contains("credito") || value.contains("abono") ? .credit : .income }
        return movement.flow == .expense ? .purchase : .other
    }

    private func isRealIncome(_ movement: Movement) -> Bool {
        guard movement.flow == .income else { return false }
        let kind = movementKind(movement)
        // Card payments, own transfers, credits and refunds are balance
        // movements, not new income. They are deliberately excluded from
        // the income KPI even when the bank PDF labels them as deposits.
        guard kind != .credit && kind != .refund && kind != .bankTransfer && kind != .cardPayment else { return false }
        if let statementId = movement.statementId,
           let statement = statements.first(where: { $0.id == statementId }) {
            return statementKind(statement) != .card
        }
        return true
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

    private var currentPeriodKey: String? {
        periodMetrics.first.map { periodKey($0.period) }
    }

    private func movementPeriodKey(_ movement: Movement) -> String? {
        // Prefer the statement's normalized cutoff period. Card statements
        // often run from the 28th to the 27th, so using only the calendar
        // month of each row would silently drop the first days of the latest
        // cycle. Legacy/manual rows without a statement still use their date.
        if let statementID = movement.statementId,
           let statement = statements.first(where: { $0.id == statementID }) {
            return periodKey(statement.period)
        }
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: movement.date)
        guard let year = components.year, let month = components.month else { return nil }
        return String(format: "%04d-%02d", year, month)
    }

    private func periodKey(_ value: String) -> String {
        guard let date = periodDate(from: value) else {
            return value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        }
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else {
            return value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        }
        return String(format: "%04d-%02d", year, month)
    }

    /// Resolves the end/cutoff date encoded in a period label. It accepts
    /// numeric and Spanish month-name dates, plus month/year-only labels.
    private func periodDate(from value: String) -> Date? {
        let normalized = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let patterns = [
            #"(?i)\b\d{4}[\/.\-]\d{1,2}[\/.\-]\d{1,2}\b"#,
            #"(?i)\b\d{1,2}[\/.\-](?:\d{1,2}|ene(?:ro)?|feb(?:rero)?|mar(?:zo)?|abr(?:il)?|may(?:o)?|jun(?:io)?|jul(?:io)?|ago(?:sto)?|sep(?:tiembre)?|set(?:iembre)?|oct(?:ubre)?|nov(?:iembre)?|dic(?:iembre)?)[\/.\-]\d{2,4}\b"#,
            #"(?i)\b\d{1,2}\s+(?:de\s+)?(?:ene(?:ro)?|feb(?:rero)?|mar(?:zo)?|abr(?:il)?|may(?:o)?|jun(?:io)?|jul(?:io)?|ago(?:sto)?|sep(?:tiembre)?|set(?:iembre)?|oct(?:ubre)?|nov(?:iembre)?|dic(?:iembre)?)(?:\s+de)?\s+\d{2,4}\b"#
        ]
        var lastDate: Date? = nil
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: normalized, range: range) {
                guard let swiftRange = Range(match.range, in: normalized),
                      let parsed = Self.parseDate(String(normalized[swiftRange])) else { continue }
                lastDate = parsed
            }
            if lastDate != nil { return lastDate }
        }

        let monthPattern = #"(?i)\b(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre|ene|feb|mar|abr|may|jun|jul|ago|sep|set|oct|nov|dic)\b"#
        let yearPattern = #"\b20\d{2}\b"#
        guard let monthRegex = try? NSRegularExpression(pattern: monthPattern),
              let yearRegex = try? NSRegularExpression(pattern: yearPattern),
              let yearMatch = yearRegex.matches(in: normalized, range: range).last,
              let yearRange = Range(yearMatch.range, in: normalized),
              let year = Int(normalized[yearRange]) else { return nil }
        let months = monthRegex.matches(in: normalized, range: range).compactMap { match -> Int? in
            guard let monthRange = Range(match.range(at: 1), in: normalized) else { return nil }
            return Self.monthNumber(String(normalized[monthRange]))
        }
        guard let month = months.last else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: 1))
    }

    private func statementEndDate(for statementID: UUID) -> Date {
        guard let statement = statements.first(where: { $0.id == statementID }) else { return .distantPast }
        return periodDate(from: statement.period) ?? statement.importedAt
    }

    private func statementsOverlap(_ left: StatementRecord, _ right: StatementRecord) -> Bool {
        if periodKey(left.period) == periodKey(right.period) { return true }
        guard let leftRange = statementRange(from: left.period),
              let rightRange = statementRange(from: right.period) else { return false }
        return leftRange.lowerBound <= rightRange.upperBound
            && rightRange.lowerBound <= leftRange.upperBound
    }

    private func statementRange(from value: String) -> ClosedRange<Date>? {
        let normalized = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let patterns = [
            #"(?i)\b\d{4}[\/.\-]\d{1,2}[\/.\-]\d{1,2}\b"#,
            #"(?i)\b\d{1,2}[\/.\-](?:\d{1,2}|ene(?:ro)?|feb(?:rero)?|mar(?:zo)?|abr(?:il)?|may(?:o)?|jun(?:io)?|jul(?:io)?|ago(?:sto)?|sep(?:tiembre)?|set(?:iembre)?|oct(?:ubre)?|nov(?:iembre)?|dic(?:iembre)?)[\/.\-]\d{2,4}\b"#,
            #"(?i)\b\d{1,2}\s+(?:de\s+)?(?:ene(?:ro)?|feb(?:rero)?|mar(?:zo)?|abr(?:il)?|may(?:o)?|jun(?:io)?|jul(?:io)?|ago(?:sto)?|sep(?:tiembre)?|set(?:iembre)?|oct(?:ubre)?|nov(?:iembre)?|dic(?:iembre)?)(?:\s+de)?\s+\d{2,4}\b"#
        ]
        var dates: [Date] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            dates.append(contentsOf: regex.matches(in: normalized, range: range).compactMap { match in
                guard let swiftRange = Range(match.range, in: normalized) else { return nil }
                return Self.parseDate(String(normalized[swiftRange]))
            })
        }
        if let first = dates.min(), let last = dates.max() {
            return first...last
        }

        guard let monthStart = periodDate(from: value) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: monthStart)
        guard let year = components.year, let month = components.month,
              let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let next = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return start...next.addingTimeInterval(-1)
    }

    private func summaryValue(_ summary: StatementSummaryRecord?, _ keyPath: KeyPath<StatementSummaryRecord, Decimal?>, fallback: Decimal) -> Decimal {
        guard let value = summary?[keyPath: keyPath] else { return fallback }
        return absolute(value)
    }

    private func latestMetricsBySource(_ metrics: [StatementMetric]) -> [StatementMetric] {
        var latest: [String: StatementMetric] = [:]
        for metric in metrics {
            // Source alone is not an account identity: a bank account and a
            // credit card can share an issuer name.
            let key = "\(metric.source)|\(metric.kind.rawValue)"
            if let current = latest[key] {
                let metricDate = statementEndDate(for: metric.id)
                let currentDate = statementEndDate(for: current.id)
                if metricDate < currentDate { continue }
                if metricDate == currentDate {
                    let metricImported = statements.first(where: { $0.id == metric.id })?.importedAt ?? .distantPast
                    let currentImported = statements.first(where: { $0.id == current.id })?.importedAt ?? .distantPast
                    if metricImported <= currentImported { continue }
                }
            }
            latest[key] = metric
        }
        return Array(latest.values)
    }

    private func patrimony(for metrics: [StatementMetric]) -> Decimal? {
        let bank = latestMetricsBySource(metrics.filter { $0.kind == .bank }).compactMap { $0.cashBalance }
        let cards = latestMetricsBySource(metrics.filter { $0.kind == .card }).compactMap { $0.debtBalance }
        guard !bank.isEmpty, !cards.isEmpty else { return nil }
        return bank.reduce(0, +) - cards.reduce(0, +)
    }

    private func normalizedConcept(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"\b(?:rfc|ref(?:erencia)?|folio|aut(?:orizacion)?|operacion)\s*[:#./_-]+\s*[a-z0-9-]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b\d{2,}\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedDate(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func deduplicationKey(_ movement: Movement) -> String {
        // Normalize to cents so 1,000, 1000.0 and 1000.00 share the same
        // identity across PDF parsers and repeated uploads.
        let amount = NSDecimalNumber(decimal: absolute(movement.amount) * Decimal(100)).intValue.description
        return [normalizedConcept(movement.account), normalizedDate(movement.date), amount, normalizedConcept(movement.title), movementKind(movement).rawValue].joined(separator: "|")
    }

    private func amountsMatch(_ left: Decimal, _ right: Decimal) -> Bool {
        let tolerance = Decimal(string: "0.01", locale: Locale(identifier: "en_US_POSIX")) ?? 0
        return absolute(left - right) <= tolerance
    }

    private func hasTransferHint(_ movement: Movement) -> Bool {
        let value = normalizedConcept(movement.title)
        return ["transfer", "traspaso", "spei", "entre cuentas", "cuenta propia", "clabe"].contains { value.contains($0) }
    }

    private func hasCardPaymentHint(_ movement: Movement) -> Bool {
        let value = normalizedConcept(movement.title)
        return value.contains("pago de tarjeta") || value.contains("pago amex") || value.contains("gracias por su pago") || value.contains("pago credito")
    }

    private func isOutflow(_ movement: Movement) -> Bool {
        movement.amount < 0 || movement.flow == .expense || movement.flow == .debt
    }

    private func isInflow(_ movement: Movement) -> Bool {
        movement.amount > 0 || movement.flow == .income
    }

    /// Rebuilds the local ledger after every import. Identical rows in one
    /// statement remain separate (two genuine purchases can be identical),
    /// while an occurrence from another statement is treated as overlap.
    private func normalizeStoredLedger() {
        // Drop malformed legacy rows before any aggregate can see them. This
        // is especially important for builds that previously stored PDF
        // headings or running balances as if they were transactions.
        movements = movements.filter { movement in
            guard isValidStoredMovement(movement) else { return false }
            // PDF rows are canonical only after their parent statement has
            // reconciled. Manual rows (statementId == nil) remain available.
            guard let statementId = movement.statementId else { return true }
            return statements.first(where: { $0.id == statementId })?.reconciliation?.status == .valid
        }
        var seen: [String: (statementId: UUID?, movementId: UUID)] = [:]
        var canonical: [Movement] = []
        for movement in movements {
            let key = deduplicationKey(movement)
            if let previous = seen[key], let statementId = movement.statementId,
               let previousStatementId = previous.statementId, statementId != previousStatementId {
                let currentStatement = statements.first(where: { $0.id == statementId })
                let previousStatement = statements.first(where: { $0.id == previousStatementId })
                // Only collapse rows when their statement periods overlap.
                // Two genuinely identical purchases in different months must
                // remain two occurrences in the ledger.
                if let currentStatement, let previousStatement,
                   statementsOverlap(currentStatement, previousStatement) {
                    continue
                }
            }
            seen[key] = (movement.statementId, movement.id)
            canonical.append(movement)
        }
        movements = canonical
        reconcileStoredMovements()
    }

    private func isValidStoredMovement(_ movement: Movement) -> Bool {
        guard movement.amount != 0,
              movement.title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3,
              movement.title.rangeOfCharacter(from: .letters) != nil,
              !Self.isAdministrativeTitle(movement.title) else { return false }
        let year = Calendar(identifier: .gregorian).component(.year, from: movement.date)
        return (1900...2_200).contains(year)
    }

    private func reconcileStoredMovements() {
        var consumed = Set<UUID>()
        let twoDays: TimeInterval = 2 * 24 * 60 * 60

        for index in movements.indices {
            let bank = movements[index]
            guard !consumed.contains(bank.id), isBankMovement(bank), isOutflow(bank) else { continue }

            if let cardIndex = movements.indices.first(where: { candidateIndex in
                let card = movements[candidateIndex]
                guard !consumed.contains(card.id), candidateIndex != index, isCardMovement(card), amountsMatch(bank.amount, card.amount), abs(bank.date.timeIntervalSince(card.date)) <= twoDays else { return false }
                let cardText = normalizedConcept(card.title)
                return movementKind(card) == .cardPayment
                    || hasCardPaymentHint(card)
                    || hasCardPaymentHint(bank)
                    || isInflow(card)
                    || (card.flow == .debt && (cardText.contains("pago") || cardText.contains("abono") || cardText.contains("recib")))
            }) {
                movements[index].flow = .transfer
                movements[index].kind = .cardPayment
                movements[cardIndex].flow = .debt
                movements[cardIndex].kind = .cardPayment
                consumed.insert(bank.id)
                consumed.insert(movements[cardIndex].id)
                continue
            }

            if let ownIndex = movements.indices.first(where: { candidateIndex in
                let incoming = movements[candidateIndex]
                guard !consumed.contains(incoming.id), candidateIndex != index, isBankMovement(incoming), isInflow(incoming), incoming.account != bank.account, amountsMatch(bank.amount, incoming.amount), abs(bank.date.timeIntervalSince(incoming.date)) <= twoDays else { return false }
                return true
            }) {
                movements[index].flow = .transfer
                movements[index].kind = .bankTransfer
                movements[ownIndex].flow = .transfer
                movements[ownIndex].kind = .bankTransfer
                consumed.insert(bank.id)
                consumed.insert(movements[ownIndex].id)
            }
        }
    }

    private func isBankMovement(_ movement: Movement) -> Bool {
        guard let statementId = movement.statementId,
              let statement = statements.first(where: { $0.id == statementId }) else { return false }
        return statementKind(statement) == .bank
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
        let hasParsedCharges = !spend.isEmpty
        let parsedCharges = spend.reduce(0) { $0 + absolute($1.amount) }
        let newTransactions = hasParsedCharges
            ? regular.reduce(0) { $0 + absolute($1.amount) }
            : summaryValue(statement.summary, \.newTransactions, fallback: 0)
        let msiFallback: Decimal
        if let original = statement.summary?.msiOriginalDeferred, let count = statement.summary?.msiInstallments, count > 0 {
            msiFallback = absolute(original) / Decimal(count)
        } else {
            msiFallback = msi.reduce(0) { $0 + absolute($1.amount) }
        }
        let msiInstallments = hasParsedCharges
            ? msi.reduce(0) { $0 + absolute($1.amount) }
            : summaryValue(statement.summary, \.msiMonthlyLoad, fallback: msiFallback)
        let interest = hasParsedCharges
            ? interests.reduce(0) { $0 + absolute($1.amount) }
            : summaryValue(statement.summary, \.interest, fallback: 0)
        let feeTotal = hasParsedCharges
            ? fees.reduce(0) { $0 + absolute($1.amount) }
            : summaryValue(statement.summary, \.fees, fallback: 0)
        let newCharges = hasParsedCharges
            ? parsedCharges
            : summaryValue(statement.summary, \.newCharges, fallback: newTransactions + msiInstallments + interest + feeTotal)
        let realPayments = payments.isEmpty
            ? summaryValue(statement.summary, \.payments, fallback: 0)
            : payments.reduce(0) { $0 + absolute($1.amount) }
        let creditTotal = credits.isEmpty
            ? summaryValue(statement.summary, \.credits, fallback: 0)
            : credits.reduce(0) { $0 + absolute($1.amount) }
        let refundTotal = refunds.reduce(0) { $0 + absolute($1.amount) }
        let travel = spend.filter(isTravel).reduce(0) { $0 + absolute($1.amount) }
        let previousBalance = statement.summary?.previousBalance.map(absolute)
        let paymentNoInterest = statement.summary?.paymentForNoInterest.map(absolute)
            ?? previousBalance.map { max(Decimal(0), $0 - realPayments - creditTotal - refundTotal + newCharges) }
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
        // For cards the issuer's limit/disponible pair is the authoritative
        // committed debt (including future MSI). It must win over a stale or
        // statement-only balance captured from an earlier PDF.
        let debt: Decimal?
        if kind == .card, let creditLimit, let creditAvailable {
            debt = max(Decimal(0), creditLimit - creditAvailable)
        } else {
            debt = statement.summary?.debtBalance.map(absolute)
                ?? (kind == .card ? statement.summary?.statementBalance.map(absolute) : nil)
        }
        let msiPending = statement.summary?.msiPending.map(absolute)
            ?? statement.summary?.msiOriginalDeferred.map(absolute)
            ?? statement.summary?.msiMonthlyLoad.map(absolute).flatMap { load in
                guard let count = statement.summary?.msiInstallments, count > 0 else { return nil }
                return load * Decimal(count)
            }
        let revolvingBalance = statement.summary?.revolvingBalance.map(absolute)
            ?? debt.map { balance in max(Decimal(0), balance - (msiPending ?? 0)) }
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
            difference: newCharges - realPayments - creditTotal - refundTotal,
            accumulatedBalance: newCharges - realPayments - creditTotal - refundTotal,
            travelSpend: travel,
            ordinarySpend: max(Decimal(0), newCharges - travel - refundTotal),
            creditLimit: creditLimit,
            creditAvailable: creditAvailable,
            creditUsed: creditUsed,
            creditUtilizationRate: utilization,
            paymentForNoInterest: paymentNoInterest,
            msiOriginalDeferred: statement.summary?.msiOriginalDeferred.map(absolute),
            msiPending: msiPending,
            revolvingBalance: revolvingBalance,
            msiInstallmentsCount: statement.summary?.msiInstallments,
            msiMonthlyLoad: statement.summary?.msiMonthlyLoad.map(absolute) ?? (msiInstallments == 0 ? nil : msiInstallments),
            cashBalance: cash,
            debtBalance: debt
        )
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: ledgerEnvelopeKey),
           let envelope = try? JSONDecoder().decode(LedgerEnvelope.self, from: data),
           envelope.schemaVersion == ledgerSchemaVersion {
            movements = envelope.movements
            statements = envelope.statements
            ledgerVersion = envelope.version
        } else {
            // One-time compatibility path for versions that stored the two
            // arrays separately. The next persist() writes the atomic envelope.
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
            ledgerVersion = UUID()
        }
        lastAuditRun = defaults.data(forKey: auditRunKey).flatMap { try? JSONDecoder().decode(LedgerAuditRun.self, from: $0) }
        lastImportedFile = defaults.string(forKey: importKey)
        recoverInterruptedRebuildIfNeeded()
        normalizeStoredLedger()
        persist()
        DiagnosticsRecorder.record(
            stage: "store.init",
            message: "Libro \(ledgerVersion.uuidString.prefix(8)) cargado: \(statements.count) estado(s), \(movements.count) movimiento(s)."
        )
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
        let linked = movements.filter { $0.statementId == statement.id }
        statements[index].reconciliation = reconcileStatement(
            kind: statementKind(statements[index]),
            summary: summary,
            movements: linked
        )
        statements[index].requiresReview = statements[index].reconciliation?.status != .valid
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
        if previousSource != cleaned || kind != nil {
            statements[index].reconciliation = StatementReconciliationRecord(
                status: .pending,
                tolerance: Decimal(string: "0.05", locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(0.05),
                reason: "El origen o tipo del estado cambió; vuelve a conciliar sus filas."
            )
            statements[index].requiresReview = true
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
        ledgerVersion = UUID()
        lastAuditRun = nil
        lastImportedFile = nil
        persist()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: movementKey)
        defaults.removeObject(forKey: statementKey)
        defaults.removeObject(forKey: importKey)
        defaults.removeObject(forKey: categoryRulesKey)
        defaults.removeObject(forKey: numericRepairKey)
        defaults.removeObject(forKey: canonicalRebuildKey)
        defaults.removeObject(forKey: canonicalRebuildExpectedCountKey)
        defaults.removeObject(forKey: ledgerEnvelopeKey)
        defaults.removeObject(forKey: ledgerBackupKey)
        defaults.removeObject(forKey: rebuildStateKey)
        defaults.removeObject(forKey: auditRunKey)
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

    private var storedPDFURLs: [URL] {
        var urls: [URL] = []
        if let directoryContents = try? FileManager.default.contentsOfDirectory(
            at: statementFilesDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            urls.append(contentsOf: directoryContents.filter { $0.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame })
        }
        urls.append(contentsOf: statements.compactMap { statementFileURL(for: $0) })
        return Set(urls.map(\.path))
            .map { URL(fileURLWithPath: $0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var hasCanonicalRebuildPending: Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: canonicalRebuildKey) else { return false }
        return !statements.isEmpty || !storedPDFURLs.isEmpty
    }

    private func currentEnvelope() -> LedgerEnvelope {
        LedgerEnvelope(
            schemaVersion: ledgerSchemaVersion,
            version: ledgerVersion,
            savedAt: .now,
            movements: movements,
            statements: statements
        )
    }

    /// If the process died during a rebuild, discard its partial writes and
    /// restore the last complete snapshot. `canonicalRebuildKey` remains false
    /// so the next foreground launch retries the rebuild from the PDFs.
    private func recoverInterruptedRebuildIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: rebuildStateKey) == "inProgress",
              let data = defaults.data(forKey: ledgerBackupKey),
              let backup = try? JSONDecoder().decode(LedgerEnvelope.self, from: data) else {
            defaults.removeObject(forKey: rebuildStateKey)
            defaults.removeObject(forKey: ledgerBackupKey)
            return
        }
        movements = backup.movements
        statements = backup.statements
        ledgerVersion = backup.version
        defaults.set(false, forKey: canonicalRebuildKey)
        defaults.removeObject(forKey: rebuildStateKey)
        defaults.removeObject(forKey: ledgerBackupKey)
        DiagnosticsRecorder.record(
            level: "error",
            stage: "rebuild.recover",
            message: "Se restauró el último libro completo tras una interrupción; la reconstrucción se reintentará."
        )
    }

    private func pdfFingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Destructively replaces every PDF-derived row with a fresh canonical
    /// import. Manual rows (those without statementId) are intentionally kept.
    /// Invalid/pending statements remain as metadata for diagnostics, but
    /// their rows are quarantined and never reach an aggregate.
    @discardableResult
    func rebuildCanonicalLedgerIfNeeded(
        progress: ((Int, Int, String) -> Void)? = nil
    ) -> CanonicalRebuildResult {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: canonicalRebuildKey), !repairInProgress else {
            return CanonicalRebuildResult(candidateCount: 0, importedCount: 0, invalidCount: 0)
        }
        repairInProgress = true
        defer { repairInProgress = false }

        // Capture files before clearing statement metadata. Several older
        // builds used UUID filenames, so the directory itself is the source
        // of truth and the statement records are only an additional index.
        var seenFingerprints = Set<String>()
        let candidates: [URL] = storedPDFURLs.compactMap { url in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            let fingerprint = pdfFingerprint(data)
            guard seenFingerprints.insert(fingerprint).inserted else { return nil }
            return url
        }
        // Keep a conservative count when an older build indexed more
        // statements than it could physically retain. In particular, the
        // legacy importer could point several records at one overwritten PDF;
        // using only `candidates.count` would make a one-file rebuild look
        // complete and silently lose the rest of the user's history. Distinct
        // source/kind/period keys avoid penalizing a repeated upload of the
        // same statement while still requiring every known cutoff to be
        // revalidated.
        let statementKeys = Set(statements.map { statement in
            "\(normalizedConcept(statement.source))|\(statementKind(statement).rawValue)|\(normalizedConcept(statement.period))"
        })
        defaults.set(max(candidates.count, statementKeys.count), forKey: canonicalRebuildExpectedCountKey)

        // Save the last complete generation before any destructive operation.
        // Imports below may persist intermediate rows, but they can always be
        // rolled back if the app is killed or crashes mid-rebuild.
        if let backupData = try? JSONEncoder().encode(currentEnvelope()) {
            defaults.set(backupData, forKey: ledgerBackupKey)
        }
        defaults.set("inProgress", forKey: rebuildStateKey)

        movements = movements.filter { $0.statementId == nil }
        statements = []
        normalizeStoredLedger()
        persist()

        guard !candidates.isEmpty else {
            defaults.set(true, forKey: canonicalRebuildKey)
            defaults.set(true, forKey: numericRepairKey)
            defaults.set("complete", forKey: rebuildStateKey)
            defaults.removeObject(forKey: ledgerBackupKey)
            DiagnosticsRecorder.record(stage: "rebuild.done", message: "No había PDFs locales para reconstruir; el libro quedó limpio.")
            return CanonicalRebuildResult(candidateCount: 0, importedCount: 0, invalidCount: 0)
        }

        DiagnosticsRecorder.record(
            stage: "rebuild.start",
            message: "Reconstrucción canónica iniciada con \(candidates.count) PDF(s) únicos."
        )
        var importedCount = 0
        var invalidCount = 0
        for (index, url) in candidates.enumerated() {
            progress?(index, candidates.count, url.lastPathComponent)
            do {
                let result = try importPDF(
                    from: url,
                    allowOCR: true,
                    preserveExistingOnEmpty: false,
                    requireValidReconciliation: true
                )
                if result.reconciliation?.status == .valid {
                    importedCount += 1
                    DiagnosticsRecorder.record(
                        stage: "rebuild.statement",
                        message: "Estado válido: \(result.source) · \(result.period) · \(result.imported) movimiento(s)."
                    )
                } else {
                    invalidCount += 1
                    DiagnosticsRecorder.record(
                        level: "error",
                        stage: "rebuild.invalid",
                        message: "Estado fuera del libro canónico: \(result.fileName) · \(result.reconciliation?.reason ?? "sin conciliación")."
                    )
                }
            } catch {
                invalidCount += 1
                DiagnosticsRecorder.record(
                    level: "error",
                    stage: "rebuild.error",
                    message: "No se pudo reconstruir \(url.lastPathComponent): \(error.localizedDescription)"
                )
            }
            progress?(index + 1, candidates.count, url.lastPathComponent)
        }
        defaults.set(true, forKey: canonicalRebuildKey)
        defaults.set(true, forKey: numericRepairKey)
        defaults.set("complete", forKey: rebuildStateKey)
        defaults.removeObject(forKey: ledgerBackupKey)
        persist()
        DiagnosticsRecorder.record(
            stage: "rebuild.done",
            message: "Reconstrucción terminada: \(importedCount) válido(s), \(invalidCount) bloqueado(s), \(movements.count) movimiento(s) canónicos."
        )
        return CanonicalRebuildResult(candidateCount: candidates.count, importedCount: importedCount, invalidCount: invalidCount)
    }

    /// Older TestFlight builds persisted rows produced by the former parser.
    /// Re-read those local PDFs once with the current extraction/reconciliation
    /// pipeline so an app update does not require the user to upload every
    /// statement again.
    var hasStoredImportsNeedingRepair: Bool {
        guard !UserDefaults.standard.bool(forKey: numericRepairKey) else { return false }
        return !storedImportRepairCandidates.isEmpty
    }

    /// Automatic repair is intentionally limited to the newest local state
    /// for each account/kind. Older states stay available in Documentos
    /// importados and can be re-read manually, while launch-time work remains
    /// bounded and cannot run OCR over an entire archive.
    private var storedImportRepairCandidates: [StatementRecord] {
        let eligible = statements.filter { statementFileURL(for: $0) != nil }
        var newestByAccount: [String: StatementRecord] = [:]
        for statement in eligible {
            let key = "\(normalizedConcept(statement.source))|\(statementKind(statement).rawValue)"
            guard let current = newestByAccount[key] else {
                newestByAccount[key] = statement
                continue
            }
            let statementDate = statementEndDate(for: statement.id)
            let currentDate = statementEndDate(for: current.id)
            if statementDate > currentDate || (statementDate == currentDate && statement.importedAt > current.importedAt) {
                newestByAccount[key] = statement
            }
        }
        return newestByAccount.values.sorted {
            let leftDate = statementEndDate(for: $0.id)
            let rightDate = statementEndDate(for: $1.id)
            if leftDate != rightDate { return leftDate > rightDate }
            return $0.importedAt > $1.importedAt
        }
    }

    @discardableResult
    func repairStoredImportsIfNeeded() -> Int {
        guard !UserDefaults.standard.bool(forKey: numericRepairKey), !repairInProgress else { return 0 }
        repairInProgress = true
        defer { repairInProgress = false }
        let candidates = storedImportRepairCandidates
        guard !candidates.isEmpty else {
            UserDefaults.standard.set(true, forKey: numericRepairKey)
            return 0
        }
        DiagnosticsRecorder.record(
            stage: "repair.start",
            message: "Recalculando \(candidates.count) estado(s) reciente(s) sin OCR automático."
        )
        var repaired = 0
        for statement in candidates {
            guard let file = statementFileURL(for: statement) else { continue }
            do {
                // OCR is deliberately opt-in during launch repair. Vision can
                // hold the main thread for a long time on scanned documents;
                // the user can still import those files manually afterwards.
                _ = try importPDF(
                    from: file,
                    allowOCR: false,
                    preserveExistingOnEmpty: true
                )
                repaired += 1
                DiagnosticsRecorder.record(
                    stage: "repair.statement",
                    message: "Estado actualizado: \(statement.source) · \(statement.period)."
                )
            } catch {
                // Keep the previous rows if a legacy file is unreadable. It
                // will remain visible for a manual re-import/review.
                DiagnosticsRecorder.record(
                    level: "error",
                    stage: "repair.error",
                    message: "No se pudo actualizar \(statement.source) · \(statement.period): \(error.localizedDescription)"
                )
            }
        }
        UserDefaults.standard.set(true, forKey: numericRepairKey)
        DiagnosticsRecorder.record(
            stage: "repair.done",
            message: "Reparación terminada: \(repaired) de \(candidates.count) estado(s)."
        )
        return repaired
    }

    /// Compares the rows reconstructed from one PDF with the totals printed
    /// by its issuer. A pending result is deliberately conservative: the
    /// statement remains visible for diagnosis but cannot feed a KPI until a
    /// user reimports/corrects it.
    private func reconcileStatement(
        kind: StatementKind,
        summary: StatementSummaryRecord?,
        movements fresh: [Movement]
    ) -> StatementReconciliationRecord {
        let tolerance = Decimal(string: "0.05", locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(0.05)
        let validRows = fresh.filter(isValidStoredMovement)
        let deposits = validRows.filter { $0.amount > 0 }.reduce(Decimal(0)) { $0 + absolute($1.amount) }
        let withdrawals = validRows.filter { $0.amount < 0 }.reduce(Decimal(0)) { $0 + absolute($1.amount) }
        let charges = validRows.filter(isSpend).reduce(Decimal(0)) { $0 + absolute($1.amount) }
        let domesticCharges = validRows.filter { isSpend($0) && !$0.foreignCurrency }.reduce(Decimal(0)) { $0 + absolute($1.amount) }
        let foreignCharges = validRows.filter { isSpend($0) && $0.foreignCurrency }.reduce(Decimal(0)) { $0 + absolute($1.amount) }
        let credits = validRows.filter { $0.amount > 0 && [.credit, .refund].contains(movementKind($0)) }.reduce(Decimal(0)) { $0 + absolute($1.amount) }
        let domesticCredits = validRows.filter { $0.amount > 0 && [.credit, .refund].contains(movementKind($0)) && !$0.foreignCurrency }.reduce(Decimal(0)) { $0 + absolute($1.amount) }
        let foreignCredits = validRows.filter { $0.amount > 0 && [.credit, .refund].contains(movementKind($0)) && $0.foreignCurrency }.reduce(Decimal(0)) { $0 + absolute($1.amount) }
        let netDomesticCharges = domesticCharges - domesticCredits
        let netForeignCharges = foreignCharges - foreignCredits
        let payments = validRows.filter { movementKind($0) == .cardPayment }.reduce(Decimal(0)) { $0 + absolute($1.amount) }
        let movementCount = validRows.count
        let expectedMovementCount = summary.flatMap { value in
            guard let deposits = value.depositCount, let withdrawals = value.withdrawalCount else { return nil }
            return deposits + withdrawals
        }

        guard let summary else {
            return StatementReconciliationRecord(
                status: .pending,
                tolerance: tolerance,
                extractedDepositTotal: kind == .bank ? deposits : nil,
                extractedWithdrawalTotal: kind == .bank ? withdrawals : nil,
                extractedChargeTotal: kind == .card ? charges : nil,
                extractedDomesticChargeTotal: kind == .card ? domesticCharges : nil,
                extractedForeignChargeTotal: kind == .card ? foreignCharges : nil,
                extractedCreditTotal: kind == .card ? credits : nil,
                extractedPaymentTotal: kind == .card ? payments : nil,
                extractedMovementCount: movementCount,
                expectedMovementCount: expectedMovementCount,
                reason: "El PDF no expone un resumen financiero verificable."
            )
        }

        var mismatches: [String] = []
        func compare(_ label: String, extracted: Decimal, expected: Decimal?) {
            guard let expected else { return }
            if absolute(extracted - absolute(expected)) > tolerance {
                mismatches.append("\(label): extraído \(extracted) vs declarado \(absolute(expected))")
            }
        }

        func compareCount(_ label: String, extracted: Int, expected: Int?) {
            guard let expected, extracted != expected else { return }
            mismatches.append("\(label): extraído \(extracted) vs declarado \(expected)")
        }

        if kind == .bank {
            compare("depósitos", extracted: deposits, expected: summary.depositTotal)
            compare("retiros", extracted: withdrawals, expected: summary.withdrawalTotal)
            compareCount("cantidad de depósitos", extracted: validRows.filter { $0.amount > 0 }.count, expected: summary.depositCount)
            compareCount("cantidad de retiros", extracted: validRows.filter { $0.amount < 0 }.count, expected: summary.withdrawalCount)
            if summary.depositTotal == nil && summary.withdrawalTotal == nil {
                return StatementReconciliationRecord(
                    status: .pending,
                    tolerance: tolerance,
                    extractedDepositTotal: deposits,
                    extractedWithdrawalTotal: withdrawals,
                    extractedMovementCount: movementCount,
                    expectedMovementCount: expectedMovementCount,
                    reason: "No se encontraron totales de depósitos/retiros en el resumen bancario."
                )
            }
            if deposits == 0 && withdrawals == 0 && (summary.depositTotal ?? 0) + (summary.withdrawalTotal ?? 0) > tolerance {
                mismatches.append("no se reconstruyeron filas de movimientos")
            }
        } else if kind == .card {
            let sectionDeclaredCharge = summary.domesticTransactionTotal.flatMap { domestic in
                summary.foreignTransactionTotal.map { domestic + $0 }
            }
            let declaredChargeCandidates = sectionDeclaredCharge.map { [$0] }
                ?? [summary.newTransactions, summary.newCharges].compactMap { $0 }.map(absolute)
            if declaredChargeCandidates.isEmpty {
                return StatementReconciliationRecord(
                    status: .pending,
                    tolerance: tolerance,
                    extractedChargeTotal: charges,
                    extractedDomesticChargeTotal: domesticCharges,
                    extractedForeignChargeTotal: foreignCharges,
                    extractedCreditTotal: credits,
                    extractedPaymentTotal: payments,
                    extractedMovementCount: movementCount,
                    expectedMovementCount: expectedMovementCount,
                    reason: "No se encontró total de cargos/transacciones en el resumen de tarjeta."
                )
            }
            // If the issuer has no section subtotals, fall back to its
            // “nuevas transacciones” value and only then to “nuevos cargos”.
            let chargeMatches: Bool
            if let expectedDomestic = summary.domesticTransactionTotal,
               let expectedForeign = summary.foreignTransactionTotal {
                // Amex domestic subtotals are net of issuer-side credits such
                // as “MONTO A DIFERIR … CR”. Compare each section separately.
                chargeMatches = absolute(absolute(netDomesticCharges) - absolute(expectedDomestic)) <= tolerance
                    && absolute(absolute(netForeignCharges) - absolute(expectedForeign)) <= tolerance
            } else {
                chargeMatches = declaredChargeCandidates.contains { absolute(charges - $0) <= tolerance }
            }
            if !chargeMatches {
                let declaredText = declaredChargeCandidates
                    .map { NSDecimalNumber(decimal: $0).stringValue }
                    .joined(separator: " o ")
                mismatches.append("cargos: extraído \(charges) vs declarado \(declaredText)")
            }
            if let expectedDomestic = summary.domesticTransactionTotal, absolute(absolute(netDomesticCharges) - absolute(expectedDomestic)) > tolerance {
                mismatches.append("nacionales: extraído \(netDomesticCharges) vs declarado \(absolute(expectedDomestic))")
            }
            if let expectedForeign = summary.foreignTransactionTotal, absolute(absolute(netForeignCharges) - absolute(expectedForeign)) > tolerance {
                mismatches.append("moneda extranjera: extraído \(netForeignCharges) vs declarado \(absolute(expectedForeign))")
            }
            if charges == 0 && declaredChargeCandidates.contains(where: { $0 > tolerance }) {
                mismatches.append("no se reconstruyeron filas de compras")
            }
        } else {
            return StatementReconciliationRecord(
                status: .pending,
                tolerance: tolerance,
                extractedDepositTotal: deposits,
                extractedWithdrawalTotal: withdrawals,
                extractedChargeTotal: charges,
                extractedDomesticChargeTotal: domesticCharges,
                extractedForeignChargeTotal: foreignCharges,
                extractedCreditTotal: credits,
                extractedPaymentTotal: payments,
                extractedMovementCount: movementCount,
                expectedMovementCount: expectedMovementCount,
                reason: "No se pudo determinar si el estado es bancario o de tarjeta."
            )
        }

        return StatementReconciliationRecord(
            status: mismatches.isEmpty ? .valid : .invalid,
            tolerance: tolerance,
            extractedDepositTotal: kind == .bank ? deposits : nil,
            extractedWithdrawalTotal: kind == .bank ? withdrawals : nil,
            extractedChargeTotal: kind == .card ? charges : nil,
            extractedDomesticChargeTotal: kind == .card ? domesticCharges : nil,
            extractedForeignChargeTotal: kind == .card ? foreignCharges : nil,
            extractedCreditTotal: kind == .card ? credits : nil,
            extractedPaymentTotal: kind == .card ? payments : nil,
            extractedMovementCount: movementCount,
            expectedMovementCount: expectedMovementCount,
            reason: mismatches.isEmpty ? nil : mismatches.joined(separator: "; ")
        )
    }

    func importPDF(
        from url: URL,
        allowOCR: Bool = true,
        preserveExistingOnEmpty: Bool = false,
        requireValidReconciliation: Bool = false
    ) throws -> ImportSummary {
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
        let usedOCR = allowOCR && extractedText.trimmingCharacters(in: .whitespacesAndNewlines).count < 120
        let ocrObservations = usedOCR ? Self.ocrObservations(from: document) : []
        let text = usedOCR ? Self.ocrText(from: ocrObservations) : extractedText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FinanceImportError.emptyDocument
        }
        let sourceFingerprint = pdfFingerprint(documentData)
        let ocrPageConfidences: [Double]? = {
            guard usedOCR else { return nil }
            let grouped = Dictionary(grouping: ocrObservations, by: \.page)
            let values = grouped.keys.sorted().compactMap { page -> Double? in
                guard let observations = grouped[page], !observations.isEmpty else { return nil }
                return observations.map(\.confidence).reduce(0, +) / Double(observations.count)
            }
            return values.isEmpty ? nil : values
        }()
        let ocrConfidence = ocrPageConfidences.map { pages in
            pages.reduce(0, +) / Double(pages.count)
        }
        // Institutional text wins over the filename. During a canonical
        // rebuild the stored PDF has a UUID filename, and on a first import a
        // user may have renamed it incorrectly. Transaction counterparties
        // are excluded by sourceDetection's header scope.
        let sourceDetection = Self.sourceDetection(from: text, fileName: url.lastPathComponent)
        let source = sourceDetection.source
        let detectedKind = Self.statementKind(from: text, source: source)
        let parsedCandidates: [Movement]
        if usedOCR, source == "Santander" {
            let santanderCandidates = Self.parseSantanderOCR(ocrObservations, fileName: url.lastPathComponent)
            parsedCandidates = santanderCandidates.isEmpty
                ? Self.parse(text: text, fileName: url.lastPathComponent, sourceHint: source)
                : santanderCandidates
        } else if usedOCR, source == "Amex" {
            let amexCandidates = Self.parseAmexOCR(Self.ocrLines(from: ocrObservations), fileName: url.lastPathComponent)
            parsedCandidates = amexCandidates.isEmpty
                ? Self.parse(text: text, fileName: url.lastPathComponent, sourceHint: source)
                : amexCandidates
        } else if usedOCR {
            let genericCandidates = Self.parseGenericOCR(
                ocrObservations,
                fileName: url.lastPathComponent,
                source: source,
                kind: detectedKind
            )
            parsedCandidates = genericCandidates.isEmpty
                ? Self.parse(text: text, fileName: url.lastPathComponent, sourceHint: source)
                : genericCandidates
        } else {
            parsedCandidates = Self.parse(text: text, fileName: url.lastPathComponent, sourceHint: source)
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
        if preserveExistingOnEmpty, fresh.isEmpty, existingStatement != nil {
            throw FinanceImportError.emptyDocument
        }
        let reconciliation = reconcileStatement(kind: detectedKind, summary: summary, movements: fresh)
        if requireValidReconciliation, reconciliation.status != .valid {
            DiagnosticsRecorder.record(
                level: "error",
                stage: "import.reconciliation",
                message: "\(url.lastPathComponent): \(reconciliation.reason ?? "estado pendiente")"
            )
        }
        let ocrFallbackNeedsReview = usedOCR && fresh.contains {
            guard let evidence = $0.extractionEvidence else { return true }
            return evidence.method != "vision-ocr" || evidence.confidence < 0.88
        }
        if ocrFallbackNeedsReview {
            DiagnosticsRecorder.record(
                stage: "import.ocr.review",
                message: "\(url.lastPathComponent): se requiere revisión porque alguna fila OCR no conserva evidencia visual suficiente."
            )
        }
        let needsReview = fresh.isEmpty
            || summary == nil
            || detectedKind == .unknown
            || reconciliation.status != .valid
            || sourceDetection.status != .verified
            || ocrFallbackNeedsReview
            || fresh.contains { $0.category == "Por revisar" }

        // Invalid/pending rows are quarantined by omission: the statement and
        // its reconciliation evidence remain visible in diagnostics, while
        // no questionable amount can leak into any KPI or chart.
        let canonicalFresh = reconciliation.status == .valid ? fresh : []

        movements.removeAll { $0.statementId == statementId }
        movements.insert(contentsOf: canonicalFresh.reversed(), at: 0)
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
            summary: summary,
            reconciliation: reconciliation,
            sourceDetection: sourceDetection,
            sourceFingerprint: sourceFingerprint,
            ocrConfidence: ocrConfidence,
            ocrPageConfidences: ocrPageConfidences
        )
        if let index = statements.firstIndex(where: { $0.id == statementId }) {
            statements[index] = statement
        } else {
            statements.insert(statement, at: 0)
        }
        normalizeStoredLedger()
        lastImportedFile = url.lastPathComponent
        persist()
        UserDefaults.standard.set(lastImportedFile, forKey: importKey)

        return ImportSummary(
            source: source,
            period: period,
            fileName: url.lastPathComponent,
            imported: canonicalFresh.count,
            // Rows are scoped to their statement; identical purchases from a
            // different import are legitimate and are never treated as repeats.
            skipped: 0,
            requiresReview: needsReview,
            summary: summary,
            usedOCR: usedOCR,
            reconciliation: reconciliation,
            sourceDetection: sourceDetection,
            sourceFingerprint: sourceFingerprint,
            ocrConfidence: ocrConfidence,
            ocrPageConfidences: ocrPageConfidences
        )
    }

    private func persist() {
        let defaults = UserDefaults.standard
        guard let envelopeData = try? JSONEncoder().encode(currentEnvelope()) else { return }
        // The envelope is the authoritative pointer. Keep the old keys for a
        // single-version compatibility window so an older installed build can
        // still open the app if the user rolls back from TestFlight.
        defaults.set(envelopeData, forKey: ledgerEnvelopeKey)
        if let movementsData = try? JSONEncoder().encode(movements) {
            defaults.set(movementsData, forKey: movementKey)
        }
        if let statementsData = try? JSONEncoder().encode(statements) {
            defaults.set(statementsData, forKey: statementKey)
        }
    }

    private var statementFilesDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(statementFilesDirectoryName, isDirectory: true)
    }

    private func persistStatementFile(_ data: Data, statementId: UUID) -> String? {
        let localFileName = "\(statementId.uuidString).pdf"
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
        /// Confidence returned by Vision for this observation (0–1). It is
        /// propagated to every movement instead of using a fixed optimistic
        /// value, so a visually weak row cannot pass the automatic gate.
        let confidence: Double

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
                guard let candidate = result.topCandidates(1).first,
                      let text = candidate.string,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return OCRObservation(
                    page: pageIndex,
                    text: text,
                    boundingBox: result.boundingBox,
                    confidence: Double(candidate.confidence)
                )
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
                        boundingBox: box,
                        confidence: group.map(\.confidence).min() ?? 0
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

    private static func parse(text: String, fileName: String, sourceHint: String? = nil) -> [Movement] {
        let dateRegex = try? NSRegularExpression(
            pattern: #"(?<!\d)(\d{1,2})[\/\-.](\d{1,2})[\/\-.](\d{2,4})(?!\d)"#
        )
        let shortMonthDateRegex = try? NSRegularExpression(
            // Vision occasionally reads a final "o" in AGO as zero (AG0)
            // and a leading zero in the day as O/B/I (O5, OBI). Keep those
            // OCR-only glyphs in the date token; parseDate repairs them in
            // isolation after the row has already been date-anchored.
            pattern: #"(?i)(?<!\d)([0-9OBI]{1,3})\s*[\/\-]\s*[A-Za-zÁÉÍÓÚáéíóú0]{3,}(?:\s*[\/\-]\s*(?:20)?\d{2})?(?![A-Za-z])"#
        )
        let isoDateRegex = try? NSRegularExpression(
            pattern: #"(?<!\d)(\d{4})[\/\-.](\d{1,2})[\/\-.](\d{1,2})(?!\d)"#
        )
        let textDateRegex = try? NSRegularExpression(
            pattern: #"(?i)(?<!\d)([0-9OBI]{1,3})\s*(?:de\s*)?([A-Za-zÁÉÍÓÚáéíóú0]{3,})(?:\s+(?:de\s+)?(\d{4}))?"#
        )
        let amountRegex = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9])[-+]?\s*\$?\s*(?:\d{1,3}(?:[ ,. ]\d{3})+|\d+)(?:[.,]\d{1,2})?(?![A-Za-z0-9])"#
        )
        let yearRegex = try? NSRegularExpression(pattern: #"\b20\d{2}\b"#)
        func inferredYear(in value: String) -> Int? {
            guard let yearRegex,
                  let match = firstMatch(in: value, regex: yearRegex) else { return nil }
            return Int(match.text)
        }
        let defaultYear = inferredYear(in: fileName)
            ?? inferredYear(in: text)
            ?? Calendar.current.component(.year, from: .now)
        let filenameAccount = sourceHint ?? accountName(from: fileName)
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
                || (shortMonthDateRegex.flatMap { firstMatch(in: line, regex: $0) } != nil)
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

            let dateMatch = dateRegex.flatMap { firstMatch(in: original, regex: $0) }
                ?? shortMonthDateRegex.flatMap { firstMatch(in: original, regex: $0) }
                ?? isoDateRegex.flatMap { firstMatch(in: original, regex: $0) }
                ?? textDateRegex.flatMap { firstMatch(in: original, regex: $0) }
            guard let dateMatch,
                  let parsedDate = parseDate(dateMatch.text, defaultYear: defaultYear) else { return nil }
            var working = original
            var date = parsedDate
            working = working.replacingCharacters(in: Range(dateMatch.range, in: working)!, with: " ")
            // BBVA places operation and settlement dates before the merchant
            // (for example `23/JUL 22/JUL FACEBK`). The first date anchors the
            // row; remove the second one before building the description.
            working = working.replacingOccurrences(
                of: #"^\s*\d{1,2}\s*[\/\-]\s*[A-Za-zÁÉÍÓÚáéíóú]{3,}(?:\s*[\/\-]\s*(?:20)?\d{2})?\s+"#,
                with: " ",
                options: .regularExpression
            )

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
            let amountMatch: TextMatch? = {
                guard !usableAmountMatches.isEmpty else { return nil }
                if foreignCurrency { return usableAmountMatches.first }
                if bankLikeRow, account == "BBVA" { return usableAmountMatches.first }
                if bankLikeRow, usableAmountMatches.count > 1 {
                    return usableAmountMatches[usableAmountMatches.count - 2]
                }
                return usableAmountMatches.last
            }()
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
            guard title.count >= 3, !isAdministrativeTitle(title) else { return nil }
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
                || titleNormalized.contains("recibido")
                || titleNormalized.contains("transferencia recibida")
            let isTransfer = titleNormalized.contains("transfer")
                || titleNormalized.contains("traspaso")
                || titleNormalized.contains("spei")
                || titleNormalized.contains("entre cuentas")
                || titleNormalized.contains("clabe")
            let explicitOwnTransfer = titleNormalized.contains("entre cuentas")
                || titleNormalized.contains("cuenta propia")
                || titleNormalized.contains("mismo titular")
                || titleNormalized.contains("traspaso interno")
            let directionSignal = documentKind == .card
                || (bankLikeRow && usableAmountMatches.count > 1)
                || isRefund
                || isCardPayment
                || isIncome
                || isTransfer
                || titleNormalized.range(of: #"\b(cargo|retiro|compra|pago|deposito|abono|nomina|sueldo|salario|credito|devolucion|reembolso)\b"#, options: .regularExpression) != nil
                || amountMatch.text.contains("-")
                || amountMatch.text.contains("+")
                || hasCreditMarker
            guard directionSignal else { return nil }
            let isStatementCredit = hasCreditMarker && !isCardPayment && !isRefund && !isIncome
            let flow: FlowKind
            if isRefund || isStatementCredit {
                flow = .income
            } else if isCardPayment {
                flow = .debt
            } else if explicitOwnTransfer {
                flow = .transfer
            } else if isIncome {
                flow = .income
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
            } else if isTransfer && explicitOwnTransfer {
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
                travelRelated: travelRelated,
                foreignCurrency: foreignCurrency,
                extractionEvidence: MovementExtractionEvidence(
                    method: "pdf-text",
                    confidence: 0.93
                )
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
        ), let shortMonthDateRegex = try? NSRegularExpression(
            pattern: #"(?i)(?<!\d)([0-9OBI]{1,3})\s*[\/\-]\s*[A-Za-zÁÉÍÓÚáéíóú0]{3,}(?:\s*[\/\-]\s*(?:20)?\d{2})?(?![A-Za-z])"#
        ), let textDateRegex = try? NSRegularExpression(
            pattern: #"(?i)(?<!\d)([0-9OBI]{1,3})\s*(?:de\s*)?([A-Za-zÁÉÍÓÚáéíóú0]{3,})(?:\s+(?:de\s+)?(\d{4}))?"#
        ), let amountRegex = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9])[-+]?\s*\$?(?:\d{1,3}(?:[ ,.]\d{3})+|\d+)[.,]\d{2}(?![A-Za-z0-9])"#
        ) else {
            return []
        }

        let defaultYear: Int = {
            if let yearRegex = try? NSRegularExpression(pattern: #"\b20\d{2}\b"#),
               let year = firstMatch(in: fileName, regex: yearRegex).flatMap({ Int($0.text) }) {
                return year
            }
            return Calendar.current.component(.year, from: .now)
        }()

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
                    ?? firstMatch(in: line.text, regex: shortMonthDateRegex)
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
                shortMonthDateRegex: shortMonthDateRegex,
                textDateRegex: textDateRegex,
                amountRegex: amountRegex,
                source: source,
                kind: kind,
                defaultYear: defaultYear
            )
        }
    }

    private static func parseGenericOCRRow(
        _ row: [OCRObservation],
        dayFirstDateRegex: NSRegularExpression,
        isoDateRegex: NSRegularExpression,
        shortMonthDateRegex: NSRegularExpression,
        textDateRegex: NSRegularExpression,
        amountRegex: NSRegularExpression,
        source: String,
        kind: StatementKind,
        defaultYear: Int
    ) -> Movement? {
        let fullText = row.map(\.text).joined(separator: " ")
        let dateMatch = firstMatch(in: fullText, regex: dayFirstDateRegex)
            ?? firstMatch(in: fullText, regex: isoDateRegex)
            ?? firstMatch(in: fullText, regex: shortMonthDateRegex)
            ?? firstMatch(in: fullText, regex: textDateRegex)
        guard let dateMatch, let date = parseDate(dateMatch.text, defaultYear: defaultYear) else { return nil }

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
        } else if bankLikeRow,
                  let columnAmount = candidates
                    .filter({ $0.x >= 0.52 && $0.x < 0.88 })
                    .sorted(by: { $0.order < $1.order })
                    .first {
            // BBVA and similar bank layouts place CARGOS/ABONOS in the
            // middle-right columns and the running balance farther right.
            // Prefer the column evidence whenever Vision returned separate
            // words; this avoids turning a balance into a transaction.
            selected = columnAmount
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
                of: #"(?i)(?<!\d)\d{1,2}\s*(?:de\s*)?[A-Za-zÁÉÍÓÚáéíóú]{3,}(?:\s+(?:de\s+)?\d{4})?"#,
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
        guard title.count >= 3, title.rangeOfCharacter(from: .letters) != nil, !isAdministrativeTitle(title) else { return nil }

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
        let explicitOwnTransfer = titleNormalized.contains("entre cuentas")
            || titleNormalized.contains("cuenta propia")
            || titleNormalized.contains("mismo titular")
            || titleNormalized.contains("traspaso interno")
        let isStatementCredit = hasCreditMarker && !isCardPayment && !isRefund && !isIncome

        let flow: FlowKind
        if isRefund || isStatementCredit {
            flow = .income
        } else if isCardPayment {
            flow = .debt
        } else if explicitOwnTransfer {
            flow = .transfer
        } else if isIncome {
            flow = .income
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
        } else if isTransfer && explicitOwnTransfer {
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
            travelRelated: travelRelated,
            foreignCurrency: hasForeignCurrency,
            extractionEvidence: MovementExtractionEvidence(
                method: "vision-ocr",
                page: row.first.map { $0.page + 1 },
                confidence: row.map(\.confidence).min() ?? 0
            )
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
            // Full dates (16-JUL-2026) and short bank dates (23/JUL) are
            // both common in Santander scans. OCR glyph repairs remain
            // scoped to this date token; parseDate supplies the filename
            // year when the short form has no explicit year.
            pattern: #"(?i)(?<!\d)([0-9OBI]{1,3})\s*[\/\-.]\s*(\d{1,2}|[A-Za-zÁÉÍÓÚáéíóú0]{3,})(?:\s*[\/\-.]\s*(\d{2,4}))?(?![A-Za-z])"#
        ), let amountRegex = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9])[-+]?\s*\$?(?:\d{1,3}(?:[ ,. ]\d{3})+|\d+)[.,]\d{2}(?![A-Za-z0-9])"#
        ) else {
            return []
        }

        let defaultYear: Int = {
            if let yearRegex = try? NSRegularExpression(pattern: #"\b20\d{2}\b"#),
               let year = firstMatch(in: fileName, regex: yearRegex).flatMap({ Int($0.text) }) {
                return year
            }
            return Calendar.current.component(.year, from: .now)
        }()

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
                if let movement = parseSantanderRow(row, dateRegex: dateRegex, amountRegex: amountRegex, defaultYear: defaultYear) {
                    parsed.append(movement)
                }
            }
        }

        return parsed
    }

    private static func parseSantanderRow(
        _ row: [OCRObservation],
        dateRegex: NSRegularExpression,
        amountRegex: NSRegularExpression,
        defaultYear: Int
    ) -> Movement? {
        guard let dateObservation = row.first(where: {
            $0.boundingBox.minX < 0.24 && firstMatch(in: $0.text, regex: dateRegex) != nil
        }), let dateMatch = firstMatch(in: dateObservation.text, regex: dateRegex),
        let date = parseDate(dateMatch.text, defaultYear: defaultYear) else {
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
                of: #"(?i)(?<!\d)[0-9OBI]{1,3}\s*[\/\-.]\s*(?:\d{1,2}|[A-Za-zÁÉÍÓÚáéíóú0]{3,})(?:\s*[\/\-.]\s*\d{2,4})?(?![A-Za-z])"#,
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
        guard title.count >= 3, title.rangeOfCharacter(from: .letters) != nil, !isAdministrativeTitle(title) else { return nil }

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
        let isCardPayment = titleNormalized.contains("pago de tarjeta")
            || (titleNormalized.contains("pago") && (titleNormalized.contains("amex") || titleNormalized.contains("credito")))
        let isTransfer = titleNormalized.contains("transfer")
            || titleNormalized.contains("traspaso")
            || titleNormalized.contains("spei")
        let explicitOwnTransfer = titleNormalized.contains("entre cuentas")
            || titleNormalized.contains("cuenta propia")
            || titleNormalized.contains("mismo titular")
            || titleNormalized.contains("traspaso interno")
        let flow: FlowKind
        if isCardPayment {
            flow = .debt
        } else if explicitOwnTransfer {
            flow = .transfer
        } else if depositColumn || semanticDeposit {
            flow = .income
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
        } else if isCardPayment {
            kind = .cardPayment
        } else if isTransfer && explicitOwnTransfer {
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
            travelRelated: travelRelated,
            foreignCurrency: hasForeignCurrency(in: normalizedFullText),
            extractionEvidence: MovementExtractionEvidence(
                method: "vision-ocr",
                page: row.first.map { $0.page + 1 },
                confidence: row.map(\.confidence).min() ?? 0
            )
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
            // Amex OCR can emit full dates or short bank-style dates. OCR
            // repairs remain scoped to this date token; parseDate supplies the
            // filename year when the short form has no explicit year.
            pattern: #"(?i)(?<!\d)([0-9OBI]{1,3})\s*[\/\-.]\s*(\d{1,2}|[A-Za-zÁÉÍÓÚáéíóú0]{3,})(?:\s*[\/\-.]\s*(\d{2,4}))?(?![A-Za-z])"#
        ), let shortMonthDateRegex = try? NSRegularExpression(
            pattern: #"(?i)(?<!\d)([0-9OBI]{1,3})\s*[\/\-]\s*[A-Za-zÁÉÍÓÚáéíóú0]{3,}(?:\s*[\/\-]\s*(?:20)?\d{2})?(?![A-Za-z])"#
        ), let textDateRegex = try? NSRegularExpression(
            pattern: #"(?i)(?<!\d)([0-9OBI]{1,3})\s*(?:de\s*)?([A-Za-zÁÉÍÓÚáéíóú0]{3,})(?:\s+(?:de\s+)?(\d{4}))?"#
        ), let amountRegex = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9])[-+]?\s*\$?(?:\d{1,3}(?:[ ,. ]\d{3})+|\d+)[.,]\d{2}(?![A-Za-z0-9])"#
        ) else {
            return []
        }

        let defaultYear: Int = {
            if let yearRegex = try? NSRegularExpression(pattern: #"\b20\d{2}\b"#),
               let year = firstMatch(in: fileName, regex: yearRegex).flatMap({ Int($0.text) }) {
                return year
            }
            return Calendar.current.component(.year, from: .now)
        }()

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
                if normalized.contains("transacciones de meses sin intereses")
                    || normalized.contains("descripcion de compras en meses sin intereses")
                    || normalized.contains("resumen de meses sin intereses")
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
                    || firstMatch(in: line.text, regex: shortMonthDateRegex) != nil
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

        return rows.compactMap {
            parseAmexRow(
                $0,
                dateRegex: dateRegex,
                shortMonthDateRegex: shortMonthDateRegex,
                textDateRegex: textDateRegex,
                amountRegex: amountRegex,
                defaultYear: defaultYear
            )
        }
    }

    private static func parseAmexRow(
        _ row: [OCRObservation],
        dateRegex: NSRegularExpression,
        shortMonthDateRegex: NSRegularExpression,
        textDateRegex: NSRegularExpression,
        amountRegex: NSRegularExpression,
        defaultYear: Int
    ) -> Movement? {
        let fullText = row.map(\.text).joined(separator: " ")
        let dateMatch = firstMatch(in: fullText, regex: dateRegex)
            ?? firstMatch(in: fullText, regex: shortMonthDateRegex)
            ?? firstMatch(in: fullText, regex: textDateRegex)
        guard let dateMatch, let date = parseDate(dateMatch.text, defaultYear: defaultYear) else { return nil }

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
                of: #"(?i)(?<!\d)[0-9OBI]{1,3}\s*[\/\-.]\s*(?:\d{1,2}|[A-Za-zÁÉÍÓÚáéíóú0]{3,})(?:\s*[\/\-.]\s*\d{2,4})?(?![A-Za-z])"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)(?<!\d)\d{1,2}\s*[\/\-]\s*[A-Za-zÁÉÍÓÚáéíóú]{3,}(?:\s*[\/\-]\s*(?:20)?\d{2})?(?![A-Za-z])"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)(?<!\d)\d{1,2}\s*(?:de\s*)?[A-Za-zÁÉÍÓÚáéíóú]{3,}(?:\s+(?:de\s+)?\d{4})?"#,
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
        guard title.count >= 3, title.rangeOfCharacter(from: .letters) != nil, !isAdministrativeTitle(title) else { return nil }

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
            travelRelated: travelRelated,
            extractionEvidence: MovementExtractionEvidence(
                method: "vision-ocr",
                page: row.first.map { $0.page + 1 },
                confidence: row.map(\.confidence).min() ?? 0
            )
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

    private static func isAdministrativeTitle(_ value: String) -> Bool {
        let normalized = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"\b\d{2,}\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let phrases = [
            "ciudad de mexico", "serie del certificado", "no de serie del certificado",
            "certificado sat", "total importe cargos", "total importe abonos", "total de cargos",
            "total de abonos", "del al", "fecha de corte", "fecha limite", "numero de cuenta",
            "no de cuenta", "numero de cliente", "cuenta clabe", "rfc", "estado de cuenta",
            "estado de cue", "periodo", "periodo de facturacion", "saldo", "saldo disponible",
            "saldo insoluto", "total", "pagina", "fecha y detalle", "pago minimo", "referencia",
            "movimientos del periodo"
        ]
        if phrases.contains(where: { normalized == $0 || normalized.contains(" \($0) ") || normalized.hasPrefix("\($0) ") || normalized.hasSuffix(" \($0)") }) {
            return true
        }
        let tokens = normalized.split(separator: " ")
        let nonLetterTokens = tokens.filter { String($0).rangeOfCharacter(from: .letters) == nil }.count
        return !tokens.isEmpty && nonLetterTokens >= max(2, tokens.count - 1)
    }

    private static func hasForeignCurrency(in normalizedText: String) -> Bool {
        ["dolar", "euro", "peso colombiano", "tipo de cambio", " tc:"].contains {
            normalizedText.contains($0)
        }
    }

    private static func parseDate(_ value: String, defaultYear: Int? = nil) -> Date? {
        var normalized = value.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        // Some scans collapse the separator in compact dates (for example
        // OBIAGO or 23HUL). Repair those complete date tokens before splitting
        // into day/month/year components; the value came from a date match, so
        // this cannot rewrite a merchant or a reference.
        normalized = normalized.replacingOccurrences(
            of: #"(?i)^O[B8](?:I)?AG[O0]$"#,
            with: "07/AGO",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"(?i)^O([0-9])AG[O0]$"#,
            with: "0$1/AGO",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"(?i)^(\d{1,2})HUL$"#,
            with: "$1/JUL",
            options: .regularExpression
        )
        // OCR repairs are deliberately scoped to tokens that came from the
        // date regex. This prevents changing merchant names or amounts while
        // still recovering common Vision confusions such as O5/AGO and OBIAGO.
        func numericToken(_ token: Substring) -> Int? {
            let raw = String(token).trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int(raw) { return value }
            let upper = raw.uppercased()
            if upper == "OBI" || upper == "OB1" || upper == "O7" || upper == "OB" {
                return 7
            }
            let repaired = upper
                .replacingOccurrences(of: "O", with: "0")
                .replacingOccurrences(of: "B", with: "8")
                .replacingOccurrences(of: "I", with: "1")
            return Int(repaired)
        }
        let parts = normalized.split(whereSeparator: { character in
            character == "/" || character == "-" || character == "." || character == " "
        })
        guard let first = parts.first.flatMap({ numericToken($0) }) else { return nil }
        let day: Int
        let month: Int
        let year: Int
        if first >= 1_000, parts.count >= 3,
           let parsedMonth = numericToken(parts[1]), let parsedDay = numericToken(parts[2]) {
            // ISO dates are common in CSV-like PDFs: yyyy-mm-dd.
            year = first
            month = parsedMonth
            day = parsedDay
        } else {
            guard let monthToken = parts.dropFirst().first(where: {
                numericToken($0) != nil || monthNumber(String($0)) != nil
            }) else { return nil }
            day = first
            month = numericToken(monthToken) ?? monthNumber(String(monthToken))!
            year = parts.dropFirst()
                .compactMap { numericToken($0) }
                .last(where: { $0 >= 100 })
                ?? defaultYear
                ?? Calendar.current.component(.year, from: .now)
        }
        let resolvedYear = year < 100 ? year + 2_000 : year
        guard (1...12).contains(month), (1...31).contains(day), (1900...2_200).contains(resolvedYear) else { return nil }
        var dateComponents = DateComponents()
        dateComponents.day = day
        dateComponents.month = month
        dateComponents.year = resolvedYear
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: dateComponents) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == resolvedYear, roundTrip.month == month, roundTrip.day == day else { return nil }
        return date
    }

    private static func monthNumber(_ value: String) -> Int? {
        // A frequent Vision error in Spanish bank months is AG0 instead of
        // AGO. Normalise only the month token, never the full row text.
        let normalized = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "0", with: "o")
        switch normalized {
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
            let pattern = "(?:\(joined))[^0-9$-]{0,90}((?<![A-Za-z])[-+]?\\s*\\$?\\s*(?:\\d{1,3}(?:,\\d{3})+|\\d+)(?:\\.\\d{1,2})?)"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: normalized, range: range),
                  let valueRange = Range(match.range(at: 1), in: normalized) else { return nil }
            let raw = String(normalized[valueRange])
            if raw.range(of: #"^\s*\d{7,}\s*$"#, options: .regularExpression) != nil { return nil }
            return parseAmount(raw)
        }

        // Bank summaries commonly print a row count before the monetary
        // total (for example, "Depósitos 9 $36,187.42"). The generic helper
        // above intentionally takes the first token for card labels, so use
        // the last monetary token for bank totals to avoid recording `9` as
        // the declared amount.
        func lastAmountOnLabel(_ labels: [String]) -> Decimal? {
            let amountPattern = #"[-+]?\s*\$?\s*(?:\d{1,3}(?:[,.]\d{3})+|\d+)(?:[,.]\d{1,2})?"#
            guard let amountRegex = try? NSRegularExpression(pattern: amountPattern) else { return nil }
            for line in normalized.components(separatedBy: .newlines) {
                guard labels.contains(where: { line.contains($0) }) else { continue }
                // A transaction description can itself contain "depósito" or
                // "retiro". Summary rows do not carry a date, so ignore
                // date-anchored lines before taking their monetary token.
                if line.range(of: #"(?<!\d)\d{1,2}[\/\-.]\d{1,2}[\/\-.]\d{2,4}(?!\d)"#, options: .regularExpression) != nil {
                    continue
                }
                let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
                let matches = amountRegex.matches(in: line, range: lineRange)
                if let match = matches.last,
                   let valueRange = Range(match.range, in: line),
                   let value = parseAmount(String(line[valueRange])) {
                    return value
                }
            }
            return nil
        }

        func countOnLabel(_ labels: [String]) -> Int? {
            let amountToken = #"(?:\$?\s*)?(?:\d{1,3}(?:[,.]\d{3})+|\d+)[.,]\d{2}\b"#
            let pattern = "(?:\(labels.joined(separator: "|")))\\D{0,24}(\\d{1,4})\\s+(?=\(amountToken))"
            guard let countRegex = try? NSRegularExpression(pattern: pattern) else { return nil }
            for line in normalized.components(separatedBy: .newlines) {
                guard labels.contains(where: { line.contains($0) }) else { continue }
                if line.range(of: #"(?<!\d)\d{1,2}[\/\-.]\d{1,2}[\/\-.]\d{2,4}(?!\d)"#, options: .regularExpression) != nil {
                    continue
                }
                let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
                if let match = countRegex.firstMatch(in: line, range: lineRange),
                   let valueRange = Range(match.range(at: 1), in: line),
                   let value = Int(line[valueRange]) {
                    return value
                }
            }
            return nil
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
        assign(\.msiPending, amount(after: ["msi pendientes", "saldo msi", "principal diferido"]))
        assign(\.revolvingBalance, amount(after: ["saldo revolvente", "saldo revolvente al corte"]))
        // Amex prints the authoritative balance as an arithmetic equation.
        // OCR may place vertical bars between columns and may expose an
        // account identifier after “Saldo Actual”; use the equation instead
        // of trusting that identifier.
        if source.localizedCaseInsensitiveContains("Amex"),
           let equationRegex = try? NSRegularExpression(
            pattern: #"(?m)((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})\s*\|?\s*-\s*((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})\s*\|?\s*\+\s*((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})\s*\|?\s*=\s*((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})\s+((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})"#
           ),
           let equationMatch = equationRegex.firstMatch(in: normalized, range: range) {
            func equationValue(_ index: Int) -> Decimal? {
                guard let valueRange = Range(equationMatch.range(at: index), in: normalized) else { return nil }
                return parseAmount(String(normalized[valueRange]))
            }
            summary.previousBalance = equationValue(1)
            summary.newCharges = equationValue(3)
            summary.statementBalance = equationValue(4)
            summary.paymentForNoInterest = equationValue(4)
            summary.minimumPayment = equationValue(5)
            hasValue = true
        }
        // Prefer the issuer's explicit total rows, which may appear after
        // the movement table. Generic “depósitos/retiros” labels also occur
        // in charts and can contain OCR fragments or percentages.
        let declaredDeposits = lastAmountOnLabel(["total importe abonos", "total de abonos", "abonos del periodo"])
            ?? lastAmountOnLabel(["depositos", "depositos / abonos"])
        let declaredWithdrawals = lastAmountOnLabel(["total importe cargos", "total de cargos", "cargos del periodo"])
            ?? lastAmountOnLabel(["retiros", "retiros / cargos"])
        assign(\.depositTotal, declaredDeposits)
        assign(\.withdrawalTotal, declaredWithdrawals)
        assign(\.domesticTransactionTotal, lastAmountOnLabel(["total de las transacciones en"]))
        assign(\.foreignTransactionTotal, lastAmountOnLabel(["total de transacciones en moneda extranjera"]))
        summary.depositCount = countOnLabel(["total movimientos abonos", "total de abonos"])
            ?? countOnLabel(["depositos", "depositos / abonos"])
        summary.withdrawalCount = countOnLabel(["total movimientos cargos", "total de cargos"])
            ?? countOnLabel(["retiros", "retiros / cargos"])
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

    /// Keep only the institutional header when identifying an issuer. Names
    /// occurring in the movement table are counterparties and must not be
    /// allowed to change the account (for example Santander appearing in a
    /// BBVA SPEI description).
    private static func institutionalHeader(from value: String) -> String {
        let normalized = value.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        ).lowercased()
        var header: [String] = []
        for line in normalized.components(separatedBy: .newlines).prefix(120) {
            let compact = line.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if compact.range(of: #"detalle\s+(?:de\s+)?movimientos|movimientos\s+realizados|fecha\s+(?:folio\s+)?descripcion|fecha\s+y\s+detalle"#, options: .regularExpression) != nil {
                break
            }
            if !compact.isEmpty { header.append(compact) }
        }
        return header.joined(separator: " ")
    }

    private static func sourceDetection(from text: String, fileName: String) -> SourceDetectionEvidence {
        let normalizedText = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let normalizedFileName = fileName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let header = institutionalHeader(from: text)
        let sourceFromFile: String? = {
            if normalizedFileName.range(of: #"\bbbva\b|bancomer"#, options: .regularExpression) != nil { return "BBVA" }
            if normalizedFileName.range(of: #"american\s+express|\bamex\b"#, options: .regularExpression) != nil { return "Amex" }
            if normalizedFileName.range(of: #"\bsantander\b"#, options: .regularExpression) != nil { return "Santander" }
            return nil
        }()
        let sourceFromHeader: String? = {
            if header.contains("grupo financiero santander") || header.contains("santander.com") || header.range(of: #"\bsantander\b"#, options: .regularExpression) != nil { return "Santander" }
            if header.contains("grupo financiero bbva") || header.contains("bbva.mx") || header.contains("bba830831lj2") || header.range(of: #"\bbbva\b|bancomer"#, options: .regularExpression) != nil { return "BBVA" }
            if header.contains("american express") || header.contains("the platinum credit card") || header.range(of: #"\bamex\b"#, options: .regularExpression) != nil { return "Amex" }
            return nil
        }()
        // OCR may place the legal issuer footer after the movement table. A
        // strong legal/domain marker anywhere in the document is authoritative
        // evidence; generic names in transaction descriptions are not.
        let sourceFromLegal: String? = {
            if normalizedText.range(of: #"grupo\s+financiero\s+bbva|bbva\s+m[eé]xico[^\n]{0,140}institucion\s+de\s+banca\s+multiple|bbva\.mx"#, options: .regularExpression) != nil { return "BBVA" }
            if normalizedText.range(of: #"americanexpress\.com\.mx|american\s+express[^\n]{0,90}(?:company|the\s+platinum\s+credit\s+card)"#, options: .regularExpression) != nil { return "Amex" }
            if normalizedText.range(of: #"grupo\s+financiero\s+santander|banco\s+santander\s+m[eé]xico[^\n]{0,140}institucion\s+de\s+banca\s+multiple|santander\.com"#, options: .regularExpression) != nil { return "Santander" }
            return nil
        }()
        let source = sourceFromHeader ?? sourceFromLegal ?? sourceFromFile ?? "Importado"
        var evidence: [String] = []
        if sourceFromHeader != nil { evidence.append("encabezado institucional \(source)") }
        else if sourceFromLegal != nil { evidence.append("razón social/dominio del emisor \(source)") }
        if sourceFromFile == source { evidence.append("nombre de archivo (source)") }
        if evidence.isEmpty, source != "Importado" { evidence.append("marca parcial; falta encabezado institucional") }

        let tableStartMarkers = ["detalle de movimientos", "movimientos realizados", "fecha folio descripcion", "fecha y detalle"]
        let body: String
        if let marker = tableStartMarkers.compactMap({ normalizedText.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            body = String(normalizedText[marker.lowerBound...])
        } else {
            body = ""
        }
        let ignoredBodyMentions = ["Santander", "BBVA", "Amex"].filter {
            body.contains($0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased())
                && $0 != source
        }
        let confidence: Double
        if sourceFromHeader != nil, sourceFromFile == source { confidence = 0.999 }
        else if sourceFromHeader != nil || sourceFromLegal != nil { confidence = sourceFromFile == source ? 0.999 : 0.998 }
        else if sourceFromFile != nil { confidence = 0.90 }
        else { confidence = 0 }
        let status: SourceDetectionStatus = confidence >= 0.99 ? .verified : confidence > 0 ? .review : .unknown
        return SourceDetectionEvidence(source: source, confidence: confidence, status: status, evidence: evidence, ignoredBodyMentions: ignoredBodyMentions)
    }

    private static func accountName(from fileName: String) -> String {
        let normalized = fileName.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        let header = institutionalHeader(from: normalized)

        // Prefer official issuer names, domains, and stable document markers.
        // Do not use a bare bank name from the complete PDF body: it can be a
        // legitimate recipient or originator in a transfer description.
        if header.contains("bbva mexico")
            || header.contains("grupo financiero bbva")
            || header.contains("bbva.mx")
            || header.contains("bba830831lj2")
            || header.range(of: #"\bbbva\b|bancomer"#, options: .regularExpression) != nil {
            return "BBVA"
        }

        let amexMarkers = [
            "amex", "american express", "gracias por su pago en linea",
            "importe en mn", "fecha y detalle de las operaciones",
            "paga desde los canales de amex", "the platinum credit card",
            "total de las transacciones en moneda extranjera"
        ]
        if amexMarkers.contains(where: { header.contains($0) }) {
            return "Amex"
        }

        let santanderMarkers = [
            "banco santander", "santander mexico", "grupo financiero santander",
            "santander.com", "estado de cuenta nomina", "super nomina"
        ]
        if santanderMarkers.contains(where: { header.contains($0) })
            || header.range(of: #"\bsantander\b"#, options: .regularExpression) != nil {
            return "Santander"
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
        if let detected = otherBankNames.first(where: { _, markers in markers.contains(where: { header.contains($0) }) })?.0 {
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
