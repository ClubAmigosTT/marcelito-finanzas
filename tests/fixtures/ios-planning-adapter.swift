// Synthetic store adapter for the portable domain runner. Not an iOS integration test.
import Foundation
enum MovementKind: Codable { case purchase, msi, income, bankTransfer, cardPayment, refund, credit, interest }
enum FlowKind: Codable { case expense, income, transfer }
enum StatementKind { case card, bank }
struct Evidence: Codable { var page = 1; var sourceText: String? = nil }
struct Movement: Codable {
 var id = UUID(); var date: Date; var title: String; var account: String; var category: String; var amount: Decimal
 var flow: FlowKind = .expense; var kind: MovementKind? = .purchase; var extractionEvidence: Evidence? = nil
 var normalizedMerchant: String? = nil; var displayMerchant: String? = nil; var transferRecipient: String? = nil
 var rawDescription: String? = nil
 var travelRelated = false; var classificationTags: [String] = []; var statementId: UUID? = nil
 var summaryDisplayTitle: String { title }; var expenseContribution: Decimal { kind == .refund ? -amount : abs(amount) }
 var hasTransferOrSpeiDescriptor: Bool { title.range(of: "spei", options: .caseInsensitive) != nil || title.range(of: "transf", options: .caseInsensitive) != nil }
}
struct Summary: Codable { var paymentDueDate: Date? = nil }
struct StatementRecord: Codable { var id = UUID(); var summary: Summary? = nil }
struct Metric { var id = UUID(); var kind: StatementKind = .card; var accountKey: String? = nil; var source = "BBVA"; var msiMonthlyLoad: Decimal? = nil; var msiPending: Decimal? = nil }
struct LoanReserve { var reserved: Decimal? = 0 }
struct LoanLedgerStub { var loadError: String? = nil; func reserve(month: Date, paid: Decimal) -> LoanReserve { LoanReserve() } }
final class FinanceStore {
 var ledgerVersion = UUID(); var analyticsGeneration = UUID(); var manualDashboardUnlockEnabled = false; var hasCanonicalRebuildPending = false
 var movements: [Movement] = [] { didSet { analyticsGeneration = UUID() } }
 var statements: [StatementRecord] = []; var periodMetrics: [Metric] = []; var loanLedger = LoanLedgerStub()
 var netExpenseMovements: [Movement] { movements.filter { $0.flow == .expense && ![MovementKind.income,.bankTransfer,.cardPayment,.credit,.msi].contains($0.kind) } }
 var realIncomeMovements: [Movement] { movements.filter { $0.flow == .income && ![MovementKind.bankTransfer,.cardPayment,.refund,.credit].contains($0.kind) } }
 var covered = Set<Date>(); var operationalMetricsBlocked = false
 func monthlyFinancialAudit(for date: Date) -> MockAudit { MockAudit() }
 func loanPrincipalPaid(in period: FinancePeriod) -> Decimal { 0 }
 func spendingCoveredDays(account: String? = nil) -> Set<Date> { covered }
 func statementCutoffDate(for id: UUID) -> Date? { nil }
 func loanPaid(in period: FinancePeriod) -> Decimal { 0 }
}

struct MockAudit { var canUseForBudget = true }
struct LedgerEnvelope: Codable { var schemaVersion = 1; var movements: [Movement] = [] }
