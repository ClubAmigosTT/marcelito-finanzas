import Foundation

struct LoanSpendingProjection {
    let content: UUID
    let revision: UUID
    let payments: [UUID: LoanBankLink]
    let interestRows: [Movement]
    let interestLinks: [UUID: LoanBankLink]
}
extension FinanceStore {
    var loanDebtUnavailableLabel: String {
        if loanLedger.loadError != nil { return "Revisar préstamo" }
        if !loanLedger.state.accounts.isEmpty && loanLedger.quote() == nil { return "Falta valor UDI" }
        return "Falta estado"
    }
    var loanBalancePeriodLabel: String {
        guard !loanLedger.state.accounts.isEmpty else { return "" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "es_MX"); formatter.dateFormat = "d MMM yyyy"
        let dates = Array(Set(loanLedger.state.accounts.compactMap { $0.latest?.asOf })).sorted().map { formatter.string(from: $0) }
        let quote = loanLedger.quote().map { "UDI " + formatter.string(from: $0.date) } ?? "falta valor UDI"
        return "Préstamos · " + dates.joined(separator: ", ") + " · " + quote
    }
    static func loanBankIdentity(_ row: Movement) -> String {
        // A unique full evidence identity can survive a canonical UUID rebuild.
        LoanMath.hash("\(row.account)|\(LoanMath.dayKey(row.date))|\(row.amount)|\(row.extractionEvidence?.page ?? -1)|\(row.rawDescription ?? row.title)")
    }
    var loanSpendingProjection: LoanSpendingProjection {
        if let value = loanProjectionCache, value.content == analyticsGeneration, value.revision == loanLedger.revision { return value }
        var payments: [UUID: LoanBankLink] = [:]; var interests: [Movement] = []; var interestLinks: [UUID: LoanBankLink] = [:]
        if !loanLedger.state.links.isEmpty {
            let eligibleIDs = Set(loanEligibleBankMovements.map(\.id))
            let bank = movements.map { row in
                LoanBankEvidence(id: row.id, identity: Self.loanBankIdentity(row), date: row.date, amount: row.amount,
                    canRepayLoan: eligibleIDs.contains(row.id) && row.flow == .expense && row.kind != .bankTransfer && row.kind != .cardPayment && row.matchedMovementId == nil)
            }
            payments = LoanPaymentResolver.resolve(state: loanLedger.state, bank: bank)
            let receipts = Dictionary(grouping: loanLedger.state.accounts.flatMap { $0.latest?.receipts ?? [] }, by: \.id)
            for row in movements {
                guard let link = payments[row.id], let receipt = receipts[link.receiptID]?.first else { continue }
                if receipt.interest > 0 {
                    let hex = LoanMath.hash("interest|" + link.receiptID)
                    let uuid = String(hex.prefix(8)) + "-" + String(hex.dropFirst(8).prefix(4)) + "-" + String(hex.dropFirst(12).prefix(4)) + "-" + String(hex.dropFirst(16).prefix(4)) + "-" + String(hex.dropFirst(20).prefix(12))
                    var interest = row
                    interest.id = UUID(uuidString: uuid)!
                    interest.title = "Intereses · Préstamo ITAM"; interest.displayMerchant = interest.title
                    interest.normalizedMerchant = "intereses prestamo itam"
                    interest.amount = -receipt.interest; interest.kind = .interest
                    interest.category = "Comisiones y finanzas"; interest.travelRelated = false
                    interest.classificationTags = ["ordinario", "loan-interest"]
                    interest.manuallyReviewed = true; interest.rawDescription = "Interés confirmado en el estado ITAM. Folio \(receipt.folio). Abono total: \(receipt.total) MXN. \(row.rawDescription ?? row.title)"
                    interests.append(interest); interestLinks[interest.id] = link
                }
            }
        }
        let value = LoanSpendingProjection(content: analyticsGeneration, revision: loanLedger.revision, payments: payments, interestRows: interests, interestLinks: interestLinks)
        loanProjectionCache = value; return value
    }
    func loanPaid(in period: FinancePeriod) -> Decimal {
        let payments = loanSpendingProjection.payments
        return movements.filter { period.contains($0.date) && payments[$0.id] != nil }.reduce(0) { $0 + abs($1.amount) }
    }
    func loanPrincipalPaid(in period: FinancePeriod) -> Decimal {
        let payments = loanSpendingProjection.payments
        return movements.filter { period.contains($0.date) && payments[$0.id] != nil }.reduce(0) { $0 + abs($1.amount) - (payments[$1.id]?.receiptInterest ?? 0) }
    }
    func loanBankCandidates(for receipt: LoanReceipt) -> [Movement] {
        let bankIDs = Set(statements.filter { $0.kind == .bank }.map(\.id))
        let linked = loanSpendingProjection.payments
        return loanEligibleBankMovements.filter { row in
            row.flow == .expense && row.amount < 0 && row.statementId.map(bankIDs.contains) == true
            && row.kind != .bankTransfer && row.kind != .cardPayment && row.matchedMovementId == nil && linked[row.id] == nil
            && abs(abs(row.amount) - receipt.total) <= Decimal(string: "0.05")!
            && abs(Calendar.current.dateComponents([.day], from: row.date, to: receipt.date).day ?? 999) <= 5
        }.sorted { $0.date > $1.date }
    }
    /// Links ITAM receipts to the bank charge that paid them without asking
    /// when the match is unambiguous both ways: the receipt has exactly one
    /// candidate charge (same total ±0.05 within five days), that charge fits
    /// no other unlinked receipt, and its text names the institution. Then the
    /// principal stops counting as spend and only the interest remains.
    @discardableResult func autoLinkLoanPayments() -> Int {
        guard loanLedger.loadError == nil else { return 0 }
        var linked = 0
        for account in loanLedger.state.accounts {
            let receipts = loanLedger.receipts(account.id)
            for receipt in receipts {
                let linkedReceipts = Set(loanLedger.state.links.map(\.receiptID))
                guard !linkedReceipts.contains(receipt.id) else { continue }
                let candidates = loanBankCandidates(for: receipt).filter { Self.namesLoanInstitution($0) }
                guard candidates.count == 1, let row = candidates.first else { continue }
                let competing = receipts.contains { other in
                    other.id != receipt.id && !linkedReceipts.contains(other.id)
                        && loanBankCandidates(for: other).contains { $0.id == row.id }
                }
                guard !competing else { continue }
                if (try? confirmLoanPayment(accountID: account.id, receipt: receipt, movement: row)) != nil { linked += 1 }
            }
        }
        if linked > 0 {
            DiagnosticsRecorder.record(stage: "loans.autolink", message: "\(linked) abono(s) del préstamo vinculados automáticamente con el banco.")
        }
        return linked
    }
    static func namesLoanInstitution(_ row: Movement) -> Bool {
        let text = (row.title + " " + (row.rawDescription ?? "")).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        return text.range(of: #"\b(itam|instituto tecnolog|tecnologico autonomo|ayudas financieras)"#, options: .regularExpression) != nil
    }
    func confirmLoanPayment(accountID: String, receipt: LoanReceipt, movement: Movement) throws {
        guard loanBankCandidates(for: receipt).contains(where: { $0.id == movement.id }) else { throw LoanError.invalid("El movimiento cambió o ya está vinculado. Revisa de nuevo el abono.") }
        try loanLedger.confirmLink(accountID: accountID, receipt: receipt, movementID: movement.id, identity: Self.loanBankIdentity(movement), amount: movement.amount)
    }
}
