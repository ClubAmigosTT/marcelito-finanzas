import XCTest
@testable import Marcelito

@MainActor final class LoanIntegrationTests: XCTestCase {
    private func withStores(_ body: (FinanceStore, FinancialPlanningStore) throws -> Void) throws {
        let original = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("marcelito.") }
        let suite = "marcelito.loan.integration.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        let store = FinanceStore(); store.clearLocalData()
        defer { store.clearLocalData(); for (key, value) in original { UserDefaults.standard.set(value, forKey: key) }; defaults.removePersistentDomain(forName: suite) }
        try body(store, FinancialPlanningStore(defaults: defaults))
    }
    private func setup(_ store: FinanceStore) throws -> (LoanStatement, LoanReceipt, Movement) {
        let loan = try ITAMLoanReader.parse(text: LoanBookTests.fixture, fingerprint: "integration", filename: "synthetic.pdf")
        try store.loanLedger.importStatement(loan)
        try store.loanLedger.setQuote(value: 10, date: LoanMath.day("01/06/2026")!)
        let receipt = try XCTUnwrap(loan.receipts.first { $0.folio == "10003" })
        let bank = StatementRecord(id: UUID(), source: "BBVA", accountKey: "bbva:1234", period: "01/06/2026 - 30/06/2026", fileName: "fixture.pdf", importedAt: .now, transactionCount: 1, requiresReview: false, kind: .bank,
            summary: .init(cashBalance: 5000, depositTotal: 0, withdrawalTotal: 500),
            reconciliation: .init(status: .valid, tolerance: 0, extractedDepositTotal: 0, extractedWithdrawalTotal: 500, extractedMovementCount: 1),
            sourceDetection: .init(source: "BBVA", confidence: 1, status: .verified, evidence: ["fixture"], ignoredBodyMentions: []), readerVersion: FinanceStore.readerVersion)
        store.statements = [bank]
        var row = Movement(date: receipt.date, title: "INSTITUTO TECNOLOGICO", account: "BBVA", category: "Educación", amount: -500, flow: .expense, statementId: bank.id, kind: .purchase, extractionEvidence: .init(method: "fixture", page: 1, confidence: 1), rawDescription: "INSTITUTO TECNOLOGICO PAGO 500.00")
        row.manuallyReviewed = true; store.movements = [row]
        return (loan, receipt, row)
    }
    func testConfirmationSeparatesPrincipalAndInterestWithoutRewritingManualClassification() throws {
        try withStores { store, p in
            let (loan, receipt, row) = try setup(store)
            let original = try JSONEncoder().encode(store.movements)
            XCTAssertEqual(store.consolidatedRealSpend, 500)
            XCTAssertEqual(store.loanBankCandidates(for: receipt).count, 1)
            try store.confirmLoanPayment(accountID: loan.accountID, receipt: receipt, movement: row)
            XCTAssertEqual(store.consolidatedRealSpend, 100); XCTAssertEqual(store.netExpenseMovements.count, 1)
            XCTAssertEqual(store.netExpenseMovements.first?.kind, .interest)
            XCTAssertFalse(store.ledgerQuality.spendMismatch)
            XCTAssertEqual(store.directBankSpend, 100)
            XCTAssertEqual(store.cashFlowHistory.reduce(0) { $0 + $1.expense }, 100)
            XCTAssertEqual(store.statementAudits.first?.expenseTotal, 100)
            XCTAssertEqual(store.monthlyFinancialAudit(for: row.date).rows[.spending]?.reduce(Decimal(0)) { $0 + abs($1.amount) }, 100)
            XCTAssertEqual(store.loanPaid(in: .month(row.date)), 500); XCTAssertEqual(store.loanPrincipalPaid(in: .month(row.date)), 400)
            XCTAssertEqual(try JSONEncoder().encode(store.movements), original)
            XCTAssertEqual(p.total(store, period: .month(row.date)), 100)
            XCTAssertTrue(p.budgetCategoryTotals(store, period: .month(row.date)).isEmpty)
            p.state.incomeAmount = 5000
            let snapshot = p.snapshot(store, month: row.date, now: row.date)
            XCTAssertEqual(snapshot.loans, 1000); XCTAssertEqual(snapshot.remaining, 4000); XCTAssertEqual(snapshot.variableSpent, 0)
            try store.loanLedger.unlink(receipt.id)
            XCTAssertEqual(store.consolidatedRealSpend, 500)
            XCTAssertEqual(store.movements[0].category, "Educación"); XCTAssertTrue(store.movements[0].manuallyReviewed)
        }
    }
    func testUniqueBankIdentitySurvivesRebuildAndAmbiguousIdentityDoesNotHidePayments() throws {
        try withStores { store, _ in
            let (loan, receipt, row) = try setup(store)
            try store.confirmLoanPayment(accountID: loan.accountID, receipt: receipt, movement: row)
            var rebuilt = row; rebuilt.id = UUID(); store.movements = [rebuilt]
            XCTAssertEqual(store.consolidatedRealSpend, 100)
            var duplicate = rebuilt; duplicate.id = UUID(); store.movements.append(duplicate)
            XCTAssertTrue(store.loanSpendingProjection.payments.isEmpty)
            XCTAssertEqual(store.consolidatedRealSpend, 1000)
            XCTAssertEqual(store.loanLedger.state.links.count, 1)
        }
    }
    func testLoanDebtDoesNotAlterCardUtilizationAndHistoryRequiresDatedEvidence() throws {
        try withStores { store, _ in
            _ = try setup(store)
            let card = StatementRecord(id: UUID(), source: "Amex", accountKey: "amex:5678", period: "01/06/2026 - 30/06/2026", fileName: "card.pdf", importedAt: .now, transactionCount: 0, requiresReview: false, kind: .card,
                summary: .init(debtBalance: 2000, creditLimit: 10000, creditAvailable: 8000),
                reconciliation: .init(status: .valid, tolerance: 0), sourceDetection: .init(source: "Amex", confidence: 1, status: .verified, evidence: ["fixture"], ignoredBodyMentions: []), readerVersion: FinanceStore.readerVersion)
            store.statements.append(card)
            XCTAssertEqual(store.cardDebtTotal, 2000); XCTAssertEqual(store.debtTotal, 3400)
            XCTAssertEqual(store.liquidPatrimony, 1600); XCTAssertEqual(store.creditUtilizationRate, Decimal(string: "0.2"))
            XCTAssertNil(store.balanceHistory.first?.patrimony)
            XCTAssertEqual(store.balanceHistory.last?.debt, 3400)
        }
    }
}
