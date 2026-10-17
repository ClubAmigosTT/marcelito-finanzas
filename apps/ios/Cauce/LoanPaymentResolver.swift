import Foundation

struct LoanBankEvidence {
    let id: UUID
    let identity: String
    let date: Date
    let amount: Decimal
    let canRepayLoan: Bool // eligible debit; excludes own transfers and card payments
}
enum LoanPaymentResolver {
    static func resolve(state: LoanState, bank: [LoanBankEvidence]) -> [UUID: LoanBankLink] {
        guard !state.links.isEmpty else { return [:] }
        let ids = Dictionary(grouping: bank, by: \.id)
        let identities = Dictionary(grouping: bank, by: \.identity)
        let receipts = Dictionary(grouping: state.accounts.flatMap { $0.latest?.receipts ?? [] }, by: \.id)
        var result: [UUID: LoanBankLink] = [:]; var usedReceipts = Set<String>()
        for link in state.links {
            let candidates = ids[link.movementID] ?? identities[link.identity]
            guard let candidates, candidates.count == 1, let row = candidates.first, row.canRepayLoan, row.amount < 0,
                  abs(abs(row.amount) - link.amount) <= Decimal(string: "0.05")!,
                  let matches = receipts[link.receiptID], matches.count == 1, let receipt = matches.first,
                  abs(receipt.total - link.amount) <= Decimal(string: "0.05")!,
                  receipt.principal == link.receiptPrincipal, receipt.interest == link.receiptInterest,
                  receipt.interest <= abs(row.amount),
                  abs(Calendar.current.dateComponents([.day], from: row.date, to: receipt.date).day ?? 999) <= 5,
                  result[row.id] == nil, !usedReceipts.contains(receipt.id),
                  state.accounts.contains(where: { $0.id == link.accountID && $0.latest?.receipts.contains(where: { $0.id == receipt.id }) == true }) else { continue }
            result[row.id] = link; usedReceipts.insert(receipt.id)
        }
        return result
    }
}
