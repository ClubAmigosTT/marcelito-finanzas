import Foundation
import Observation

/// Observation stays on the UI side; the persistence/accounting book is also
/// executable in a Foundation-only regression harness.
@Observable final class LoanLedger {
    @ObservationIgnored private let book: LoanBook
    @ObservationIgnored var onChange: (() -> Void)?
    private(set) var revision = UUID()
    static let storageKey = LoanBook.storageKey
    var state: LoanState { _ = revision; return book.state }
    var loadError: String? { _ = revision; return book.loadError }
    init(defaults: UserDefaults? = .standard) {
        book = LoanBook(defaults: defaults)
        book.onChange = { [weak self] in self?.revision = UUID(); self?.onChange?() }
    }
    @discardableResult func importStatement(_ statement: LoanStatement) throws -> Bool { try book.importStatement(statement) }
    func quote(asOf date: Date = .now) -> LoanUDIQuote? { _ = revision; return book.quote(asOf: date) }
    func setQuote(value: Decimal, date: Date, now: Date = .now) throws { try book.setQuote(value: value, date: date, now: now) }
    func debt(asOf date: Date = .now) -> Decimal? { _ = revision; return book.debt(asOf: date) }
    func receipts(_ accountID: String) -> [LoanReceipt] { _ = revision; return book.receipts(accountID) }
    func confirmLink(accountID: String, receipt: LoanReceipt, movementID: UUID, identity: String, amount: Decimal) throws { try book.confirmLink(accountID: accountID, receipt: receipt, movementID: movementID, identity: identity, amount: amount) }
    func unlink(_ receiptID: String) throws { try book.unlink(receiptID) }
    func setCatchUp(_ value: Decimal, accountID: String, month: Date) throws { try book.setCatchUp(value, accountID: accountID, month: month) }
    func reserve(month: Date, paid: Decimal) -> LoanMonthlyReserve { _ = revision; return book.reserve(month: month, paid: paid) }
    func clear() { book.clear() }
}
