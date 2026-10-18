import Foundation

final class LoanBook {
    private(set) var state = LoanState()
    private(set) var revision = UUID()
    private(set) var loadError: String?
    var onChange: (() -> Void)?
    private let defaults: UserDefaults?
    static let storageKey = "marcelito.loans.v1"
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.storageKey) {
            do {
                let decoded = try JSONDecoder().decode(LoanState.self, from: data)
                guard decoded.schema == 1 else { throw LoanError.invalid("Versión de préstamos no compatible. Actualiza la app; tus datos se conservan.") }
                state = decoded
            } catch { loadError = "No se pudo abrir el registro de préstamos. Los datos guardados se conservan." }
        }
    }
    @discardableResult private func commit(_ next: LoanState) throws -> Bool {
        guard loadError == nil else { throw LoanError.invalid(loadError!) }
        let data = try JSONEncoder().encode(next)
        if let prior = defaults?.data(forKey: Self.storageKey) { defaults?.set(prior, forKey: Self.storageKey + ".backup") }
        defaults?.set(data, forKey: Self.storageKey)
        state = next; revision = UUID(); onChange?(); return true
    }
    @discardableResult func importStatement(_ statement: LoanStatement) throws -> Bool {
        var next = state
        if let index = next.accounts.firstIndex(where: { $0.id == statement.accountID }) {
            if next.accounts[index].statements.contains(where: { $0.id == statement.id }) { return false }
            if let previous = next.accounts[index].statements.first(where: { $0.asOf == statement.asOf }), previous != statement {
                throw LoanError.invalid("Ya existe un estado de esa fecha. Revisa la diferencia antes de reemplazarlo; se conservó el anterior.")
            }
            next.accounts[index].statements.append(statement)
        } else { next.accounts.append(LoanAccount(id: statement.accountID, name: "Préstamo ITAM", statements: [statement])) }
        return try commit(next)
    }
    func quote(asOf date: Date = .now) -> LoanUDIQuote? { state.quotes.filter { $0.date <= date }.max { $0.date < $1.date } }
    func setQuote(value: Decimal, date: Date, now: Date = .now) throws {
        guard value > 0, value < 1000, date <= now else { throw LoanError.invalid("Escribe un valor positivo de UDI y una fecha que no sea futura.") }
        let quote = LoanUDIQuote(date: Calendar.current.startOfDay(for: date), value: value, source: "Banxico · valor confirmado por el usuario")
        var next = state; next.quotes.removeAll { Calendar.current.isDate($0.date, inSameDayAs: quote.date) }; next.quotes.append(quote); try commit(next)
    }
    /// First day the loan needs a UDI value for: its earliest statement or
    /// installment, so every past month's reserve and debt can be priced.
    var earliestQuoteNeeded: Date? {
        state.accounts.flatMap(\.statements).flatMap { statement in [statement.asOf] + statement.installments.map(\.dueDate) }.min()
    }
    /// Adds officially published values for days that have none. A value the
    /// user typed for a day is kept as entered.
    @discardableResult func mergeOfficialQuotes(_ quotes: [LoanUDIQuote], now: Date = .now) throws -> Int {
        let calendar = Calendar.current
        var known = Set(state.quotes.map { calendar.startOfDay(for: $0.date) })
        var next = state
        for quote in quotes where quote.date <= now && quote.value > 0 && known.insert(calendar.startOfDay(for: quote.date)).inserted {
            next.quotes.append(quote)
        }
        let added = next.quotes.count - state.quotes.count
        if added > 0 { next.quotes.sort { $0.date < $1.date }; try commit(next) }
        return added
    }
    func debt(asOf date: Date = .now) -> Decimal? {
        if state.accounts.isEmpty { return 0 }
        var native: Decimal = 0
        for account in state.accounts {
            guard let snapshot = account.statements.filter({ $0.asOf <= date }).max(by: { $0.asOf < $1.asOf }) else { return nil }
            native += snapshot.recognizedDebt
        }
        if native == 0 { return 0 }
        guard let quote = quote(asOf: date) else { return nil }
        return LoanMath.rounded(native * quote.value)
    }
    func receipts(_ accountID: String) -> [LoanReceipt] { state.accounts.first { $0.id == accountID }?.latest?.receipts ?? [] }
    func confirmLink(accountID: String, receipt: LoanReceipt, movementID: UUID, identity: String, amount: Decimal) throws {
        guard let current = receipts(accountID).first(where: { $0.id == receipt.id }), current == receipt,
              abs(abs(amount) - current.total) <= Decimal(string: "0.05")!,
              !state.links.contains(where: { $0.movementID == movementID || $0.identity == identity || $0.receiptID == receipt.id }) else { throw LoanError.invalid("El importe no coincide o el pago ya está vinculado. Tus asignaciones se conservan.") }
        var next = state
        next.links.append(LoanBankLink(accountID: accountID, receiptID: receipt.id, movementID: movementID, identity: identity, amount: abs(amount), receiptPrincipal: current.principal, receiptInterest: current.interest)); try commit(next)
    }
    func unlink(_ receiptID: String) throws { var next = state; next.links.removeAll { $0.receiptID == receiptID }; try commit(next) }
    func setCatchUp(_ value: Decimal, accountID: String, month: Date) throws {
        guard value >= 0, state.accounts.contains(where: { $0.id == accountID }) else { throw LoanError.invalid("Escribe un abono adicional válido.") }
        var next = state; next.catchUp[accountID + "|" + LoanMath.monthKey(month)] = value; try commit(next)
    }
    func reserve(month: Date, paid: Decimal) -> LoanMonthlyReserve {
        let calendar = Calendar.current
        let monthEnd = calendar.dateInterval(of: .month, for: month)?.end.addingTimeInterval(-1) ?? month
        let quote = quote(asOf: min(.now, monthEnd))
        var scheduled: Decimal? = 0; var extra: Decimal = 0
        for account in state.accounts {
            extra += state.catchUp[account.id + "|" + LoanMath.monthKey(month)] ?? 0
            guard let snapshot = account.latest else { scheduled = nil; continue }
            let installments = snapshot.installments.filter { calendar.isDate($0.dueDate, equalTo: month, toGranularity: .month) }
            let monthStart = calendar.dateInterval(of: .month, for: month)?.start ?? month
            let udis = installments.reduce(Decimal(0)) { total, installment in
                let prepaid = snapshot.allocations.filter { $0.installment == installment.number && $0.date < monthStart }.reduce(Decimal(0)) { $0 + $1.udis }
                return total + max(0, installment.total - prepaid)
            }
            // Future installments retain the last known UDI only as an estimate.
            if udis > 0, let quote { scheduled = scheduled.map { $0 + LoanMath.rounded(udis * quote.value) } }
            else if udis > 0 { scheduled = nil }
        }
        return LoanMonthlyReserve(scheduled: scheduled, extra: extra, paid: paid)
    }
    func clear() {
        state = LoanState(); loadError = nil; defaults?.removeObject(forKey: Self.storageKey); defaults?.removeObject(forKey: Self.storageKey + ".backup"); revision = UUID(); onChange?()
    }
}
