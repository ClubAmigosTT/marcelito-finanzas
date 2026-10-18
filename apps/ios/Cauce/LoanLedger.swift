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
    @discardableResult func mergeOfficialQuotes(_ quotes: [LoanUDIQuote], now: Date = .now) throws -> Int { try book.mergeOfficialQuotes(quotes, now: now) }
    /// Downloads the official UDI values the loan still lacks, from its first
    /// statement or installment through today. Offline or on a server error the
    /// manual "valor UDI" entry keeps working.
    @MainActor func refreshOfficialQuotes(now: Date = .now) async {
        guard loadError == nil, let earliest = book.earliestQuoteNeeded else { return }
        let calendar = Calendar.current
        if let latest = book.quote(asOf: now), calendar.isDate(latest.date, inSameDayAs: now) { return }
        let start = max(earliest, calendar.date(byAdding: .year, value: -5, to: now) ?? earliest)
        // Resume after the last official value; a single hand-typed value
        // must not stop older months from being priced.
        let missingFrom = state.quotes.filter { $0.source == LoanUDIFeed.source && $0.date >= start }.map(\.date).max()
            .flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? start
        guard let quotes = try? await LoanUDIFeed.fetch(from: min(missingFrom, now), to: now) else { return }
        _ = try? book.mergeOfficialQuotes(quotes, now: now)
    }
    func debt(asOf date: Date = .now) -> Decimal? { _ = revision; return book.debt(asOf: date) }
    func receipts(_ accountID: String) -> [LoanReceipt] { _ = revision; return book.receipts(accountID) }
    func confirmLink(accountID: String, receipt: LoanReceipt, movementID: UUID, identity: String, amount: Decimal) throws { try book.confirmLink(accountID: accountID, receipt: receipt, movementID: movementID, identity: identity, amount: amount) }
    func unlink(_ receiptID: String) throws { try book.unlink(receiptID) }
    func setCatchUp(_ value: Decimal, accountID: String, month: Date) throws { try book.setCatchUp(value, accountID: accountID, month: month) }
    func reserve(month: Date, paid: Decimal) -> LoanMonthlyReserve { _ = revision; return book.reserve(month: month, paid: paid) }
    func clear() { book.clear() }
}
