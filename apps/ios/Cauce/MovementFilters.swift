import Foundation

/// Read-only list selection. Statement dates and calendar months are distinct.
struct MovementListFilter {
    var bank: String? = nil
    var month: Date? = nil
    var statementID: UUID? = nil
    var query = ""

    func includes(_ movement: Movement, statement: StatementRecord?, calendar: Calendar) -> Bool {
        if let bank, (statement?.source ?? movement.account) != bank { return false }
        if let statementID, movement.statementId != statementID { return false }
        if let month, !calendar.isDate(movement.date, equalTo: month, toGranularity: .month) { return false }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return true }
        return [movement.title, movement.displayMerchant ?? "", movement.rawDescription ?? "",
                movement.category, movement.account, statement?.source ?? "", statement?.period ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(search) }
    }
}
