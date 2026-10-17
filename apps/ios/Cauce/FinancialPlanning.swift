import Foundation
import Observation

/// Local planning data is versioned separately from the audited ledger. It never
/// replaces an amount, beneficiary, category, or accounting decision in a PDF.
enum FinancePeriodMode: String, CaseIterable, Identifiable, Codable {
    case day = "Día", week = "Semana", month = "Mes", year = "Año", range = "Rango"
    var id: String { rawValue }
}
struct FinancePeriod: Equatable {
    let start: Date
    let end: Date // exclusive, all queries share this convention
    func contains(_ date: Date) -> Bool { date >= start && date < end }
    var label: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "es_MX")
        let c = Calendar.current
        let last = c.date(byAdding: .day, value: -1, to: end) ?? start
        if let year = c.dateInterval(of: .year, for: start), year.start == start, year.end == end {
            f.dateFormat = "yyyy"; return f.string(from: start)
        }
        if c.isDate(start, equalTo: last, toGranularity: .month) {
            f.dateFormat = c.component(.day, from: start) == 1 && c.component(.day, from: last) == c.range(of: .day, in: .month, for: last)?.count ? "MMMM yyyy" : "d MMM"
            if f.dateFormat == "MMMM yyyy" { return f.string(from: start).capitalized }
            if c.isDate(start, inSameDayAs: last) { f.dateFormat = "d MMM yyyy"; return f.string(from: start) }
            let a = f.string(from: start); f.dateFormat = "d MMM yyyy"; return a + "–" + f.string(from: last)
        }
        if c.component(.day, from: start) == 1, c.component(.day, from: last) == c.range(of: .day, in: .month, for: last)?.count, c.component(.year, from: start) == c.component(.year, from: last) {
            f.dateFormat = "MMM"; let first = f.string(from: start).replacingOccurrences(of: ".", with: "").capitalized
            let ending = f.string(from: last).replacingOccurrences(of: ".", with: "").capitalized
            f.dateFormat = "yyyy"; return first + "–" + ending + " " + f.string(from: last)
        }
        f.dateFormat = "d MMM yyyy"; return f.string(from: start) + "–" + f.string(from: last)
    }
    static func month(_ date: Date, calendar: Calendar = .current) -> Self {
        let interval = calendar.dateInterval(of: .month, for: date)!
        return Self(start: interval.start, end: interval.end)
    }
    static func selected(_ mode: FinancePeriodMode, date: Date, from: Date, through: Date, calendar: Calendar = .current) -> Self {
        if mode == .range {
            let first = calendar.startOfDay(for: min(from, through)); let last = calendar.startOfDay(for: max(from, through))
            return Self(start: first, end: calendar.date(byAdding: .day, value: 1, to: last)!)
        }
        let component: Calendar.Component = mode == .day ? .day : mode == .week ? .weekOfYear : mode == .year ? .year : .month
        var displayCalendar = calendar
        if mode == .week { displayCalendar.firstWeekday = 2; displayCalendar.minimumDaysInFirstWeek = 4 }
        let interval = displayCalendar.dateInterval(of: component, for: date)!
        return Self(start: interval.start, end: interval.end)
    }
}
extension FinancePeriod {
    /// Shift calendar periods from their first day. This prevents Jan 31 ->
    /// Mar 3 and Feb 29 -> March errors, and keeps DST days as calendar days.
    func shifted(by offset: Int, mode: FinancePeriodMode, calendar: Calendar = .current) -> FinancePeriod {
        if mode == .range {
            let count = max(1, calendar.dateComponents([.day], from: start, to: end).day ?? 1)
            return FinancePeriod(start: calendar.date(byAdding: .day, value: count * offset, to: start)!, end: calendar.date(byAdding: .day, value: count * offset, to: end)!)
        }
        let component: Calendar.Component = mode == .day ? .day : mode == .week ? .weekOfYear : mode == .year ? .year : .month
        let anchor = calendar.date(byAdding: component, value: offset, to: start)!
        return .selected(mode, date: anchor, from: anchor, through: anchor, calendar: calendar)
    }
    func months(calendar: Calendar = .current) -> [Date] {
        var result: [Date] = []; var cursor = FinancePeriod.month(start, calendar: calendar).start
        while cursor < end { result.append(cursor); cursor = calendar.date(byAdding: .month, value: 1, to: cursor)! }
        return result
    }
}

struct PersonalExpenseLabel: Codable, Equatable {
    var extraordinary: Bool? = nil
    var sharedPerson = ""
    var sharedAmount: Decimal = 0
    var collectedAmount: Decimal = 0
    var fixed: Bool? = nil
    /// Evidence-preserving alternate lookup if a canonical rebuild replaces UUIDs.
    var identity = ""
    var outstanding: Decimal { max(0, sharedAmount - collectedAmount) }
}
struct InstallmentCommitment: Identifiable, Codable {
    var id = UUID()
    var merchant: String
    var account: String
    var purchaseDate: Date
    var total: Decimal
    var monthly: Decimal
    var count: Int
    var firstDueMonth: Date
    var paidThroughMonth: Date? = nil
    var linkedMovementIDs: [UUID]
    var linkedIdentities: [String]
    var category: String
    func due(in month: Date, calendar: Calendar = .current) -> Decimal {
        let first = FinancePeriod.month(firstDueMonth, calendar: calendar).start
        let target = FinancePeriod.month(month, calendar: calendar).start
        let offset = calendar.dateComponents([.month], from: first, to: target).month ?? -1
        guard offset >= 0, offset < count else { return 0 }
        // Final installment carries the exact remaining cents.
        return min(monthly, max(0, total - monthly * Decimal(offset)))
    }
    func remaining(after month: Date, calendar: Calendar = .current) -> Int {
        let elapsed = calendar.dateComponents([.month], from: FinancePeriod.month(firstDueMonth, calendar: calendar).start, to: FinancePeriod.month(month, calendar: calendar).start).month ?? -1
        return max(0, count - max(0, elapsed + 1))
    }
}
struct SavingsGoal: Codable, Identifiable {
    var id = UUID()
    var name: String
    var target: Decimal
    var saved: Decimal
    var monthlyContribution: Decimal
    var estimatedMonths: Int? {
        guard monthlyContribution > 0 else { return nil }
        return Int(ceil(NSDecimalNumber(decimal: max(0, target - saved) / monthlyContribution).doubleValue))
    }
}
struct CardPaymentTerms: Codable {
    var statementID: UUID? = nil
    var dueDate: Date?
    var annualRate: Decimal?
}
enum SurplusDestination: String, Codable, CaseIterable {
    case savings = "A ahorro", nextMonth = "Al siguiente mes"
}
struct MonthBudgetPlan: Codable {
    var limits: [String: Decimal] = [:]
    var fixedLimits: [String: Decimal] = [:]
    var savingsTarget: Decimal = 0
    var surplusDestination: SurplusDestination = .savings
    var carryIn: Decimal = 0
    var closed = false
}
struct PlanningIncomeSource: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var amount: Decimal
    var cadence: String
    var account: String = ""
    var detectedKey: String? = nil
    var monthlyAmount: Decimal { cadence == "Quincenal" ? amount * 2 : amount }
}

struct PlanningState: Codable {
    var schema = 1
    var incomeAmount: Decimal? = nil
    var incomeCadence = "Mensual"
    // nil means a v1 total has not yet been split into sources. An explicit
    // empty array means the user removed every source, not a zero income.
    var incomeSources: [PlanningIncomeSource]? = nil
    var incomeOnboardingCompleted = false
    var labels: [String: PersonalExpenseLabel] = [:]
    var installments: [InstallmentCommitment] = []
    var completeMSIAccounts: [String] = []
    var budgets: [String: MonthBudgetPlan] = [:]
    var goals: [SavingsGoal] = []
    var cardTerms: [String: CardPaymentTerms] = [:]
    var remindersEnabled = false
    var fixedMerchantRules: [String: Bool] = [:]
}
@Observable final class FinancialPlanningStore {
    var state: PlanningState
    private let defaults: UserDefaults
    private let key = "marcelito.planning.v1"
    private(set) var loadError: String? = nil
    private(set) var revision = UUID()
    @ObservationIgnored private var coverageKey = ""
    @ObservationIgnored private var coveredCache = Set<Date>()
    @ObservationIgnored private var proposalCache: [String: [String: Decimal]] = [:]
    @ObservationIgnored private var fixedCache: [String: [String: Decimal]] = [:]
    func coveredDays(_ store: FinanceStore) -> Set<Date> {
        let key = "\(store.ledgerVersion)|\(Calendar.current.startOfDay(for: .now))"
        if coverageKey != key { coveredCache = store.spendingCoveredDays(); coverageKey = key; proposalCache.removeAll(); fixedCache.removeAll() }
        return coveredCache
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            do { state = try JSONDecoder().decode(PlanningState.self, from: data); if state.schema != 1 { loadError = "Tu planificación requiere una versión más reciente. Los datos se conservan." } }
            catch {
                state = PlanningState(); loadError = "No se pudo abrir tu planificación. Los datos guardados se conservan."
            }
        } else { state = PlanningState() }
    }
    @discardableResult func save() -> Bool {
        // Never overwrite a future/corrupted schema with an empty plan.
        guard loadError == nil, state.schema == 1, let data = try? JSONEncoder().encode(state) else { return false }
        if let previous = defaults.data(forKey: key) { defaults.set(previous, forKey: key + ".backup") }
        defaults.set(data, forKey: key); revision = UUID(); proposalCache.removeAll(); fixedCache.removeAll(); return true
    }
    func clearLocalData() {
        state = PlanningState(); loadError = nil
        defaults.removeObject(forKey: key); defaults.removeObject(forKey: key + ".backup")
        proposalCache.removeAll(); fixedCache.removeAll(); revision = UUID()
    }
    var incomeSources: [PlanningIncomeSource] {
        if let sources = state.incomeSources { return sources }
        guard let amount = state.incomeAmount else { return [] }
        return [PlanningIncomeSource(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Ingreso habitual", amount: amount, cadence: state.incomeCadence)]
    }
    var monthlyIncome: Decimal? {
        guard !incomeSources.isEmpty else { return nil }
        return incomeSources.reduce(0) { $0 + $1.monthlyAmount }
    }
    @discardableResult func setIncomeSources(_ sources: [PlanningIncomeSource]) -> Bool {
        guard sources.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.amount >= 0 && ["Mensual", "Quincenal"].contains($0.cadence) }), Set(sources.map(\.id)).count == sources.count else { return false }
        let previous = state
        state.incomeSources = sources
        // Preserve an equivalent aggregate for older app versions. This never
        // creates a deposit in the audited ledger.
        state.incomeAmount = sources.isEmpty ? nil : sources.reduce(0) { $0 + $1.monthlyAmount }
        state.incomeCadence = "Mensual"
        state.incomeOnboardingCompleted = true
        if save() { return true }
        state = previous
        return false
    }
    func latestMovementDate(_ store: FinanceStore, account: String? = nil, now: Date = .now) -> Date? {
        let dates = (store.netExpenseMovements + store.realIncomeMovements).filter { (account == nil || $0.account == account) && $0.date <= now }.map(\.date)
        let purchases = state.installments.filter { (account == nil || $0.account == account) && $0.purchaseDate <= now }.map(\.purchaseDate)
        return (dates + purchases).max()
    }
    func initialExpenseDate(_ store: FinanceStore, now: Date = .now) -> Date {
        latestMovementDate(store, now: now) ?? now
    }
    func latestDataDate(_ store: FinanceStore, account: String? = nil, now: Date = .now) -> Date? {
        let cutoffs = store.periodMetrics.filter { account == nil || $0.source == account || $0.accountKey == account }.compactMap { store.statementCutoffDate(for: $0.id) }.filter { $0 <= now }
        return (cutoffs + [latestMovementDate(store, account: account, now: now)].compactMap { $0 }).max()
    }
    func incomeSuggestions(_ store: FinanceStore) -> [RecurringFinancialItem] {
        let confirmedKeys = Set(incomeSources.compactMap(\.detectedKey))
        return recurring(store.realIncomeMovements, income: true).filter { !confirmedKeys.contains($0.id) }
    }
    func monthKey(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM"; return f.string(from: date)
    }
    func identity(_ movement: Movement) -> String {
        // UUID is primary; a unique identity can survive an import replay. An
        // ambiguous same-day repeated purchase is deliberately not propagated.
        "\(movement.account)|\(movement.date.timeIntervalSince1970)|\(movement.amount)|\(movement.extractionEvidence?.page ?? -1)|\(movement.title)"
    }
    func label(for movement: Movement) -> PersonalExpenseLabel {
        if let label = state.labels[movement.id.uuidString] { return label }
        let matches = state.labels.values.filter { $0.identity == identity(movement) }
        return matches.count == 1 ? matches[0] : PersonalExpenseLabel()
    }
    func setLabel(_ label: PersonalExpenseLabel, for movement: Movement) {
        var saved = label; saved.identity = identity(movement)
        let charge = max(0, movement.expenseContribution)
        saved.sharedAmount = min(charge, max(0, saved.sharedAmount))
        saved.collectedAmount = min(saved.sharedAmount, max(0, saved.collectedAmount))
        state.labels[movement.id.uuidString] = saved; save()
    }
    func category(_ movement: Movement) -> String { movement.category == "ITAM" ? "Educación" : movement.category }
    func merchantLabel(_ movement: Movement) -> String {
        let text = (movement.normalizedMerchant ?? movement.title).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_MX"))
        if text.range(of: #"(?i)\bitam\b|instituto tecnologico autonomo de mexico"#, options: .regularExpression) != nil { return "ITAM" }
        return movement.summaryDisplayTitle
    }
    func merchantKey(_ movement: Movement) -> String {
        (movement.normalizedMerchant ?? movement.displayMerchant ?? movement.title).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_MX")).lowercased()
    }
    func isFixed(_ movement: Movement) -> Bool { label(for: movement).fixed ?? state.fixedMerchantRules[merchantKey(movement)] ?? movement.classificationTags.contains("fijo") }
    func isExtraordinary(_ movement: Movement) -> Bool { label(for: movement).extraordinary ?? (movement.travelRelated || movement.classificationTags.contains("viaje") || movement.classificationTags.contains("extraordinario")) }
    func isOrdinary(_ movement: Movement) -> Bool { !isExtraordinary(movement) }
    func personalContribution(_ movement: Movement) -> Decimal {
        let l = label(for: movement)
        guard isOrdinary(movement) else { return 0 }
        return movement.expenseContribution - min(max(0, movement.expenseContribution), l.sharedAmount)
    }
    func isInstallmentRow(_ movement: Movement, store: FinanceStore? = nil) -> Bool {
        if state.installments.contains(where: { $0.linkedMovementIDs.contains(movement.id) }) { return true }
        guard let store, store.movements.filter({ identity($0) == identity(movement) }).count == 1 else { return false }
        return state.installments.contains { $0.linkedIdentities.contains(identity(movement)) }
    }
    func expenseRows(_ store: FinanceStore, period: FinancePeriod) -> [Movement] {
        var rows = store.netExpenseMovements.filter { period.contains($0.date) && !isInstallmentRow($0, store: store) }
        for plan in state.installments where period.contains(plan.purchaseDate) {
            let linkedRows = store.movements.filter { row in
                plan.linkedMovementIDs.contains(row.id) || (plan.linkedIdentities.contains(identity(row)) && store.movements.filter { identity($0) == identity(row) }.count == 1)
            }
            guard var row = linkedRows.first else { continue }
            row.id = plan.id; row.date = plan.purchaseDate; row.amount = -plan.total
            row.kind = .purchase; row.flow = .expense; row.title = plan.merchant; row.displayMerchant = plan.merchant; row.category = plan.category
            rows.append(row)
        }
        return rows.sorted { $0.date > $1.date }
    }
    func personalRows(_ store: FinanceStore, period: FinancePeriod) -> [Movement] {
        expenseRows(store, period: period).filter(isOrdinary)
    }
    func total(_ store: FinanceStore, period: FinancePeriod) -> Decimal {
        expenseRows(store, period: period).reduce(0) { $0 + $1.expenseContribution }
    }
    func personalTotal(_ store: FinanceStore, period: FinancePeriod) -> Decimal {
        personalRows(store, period: period).reduce(0) { $0 + personalContribution($1) }
    }
    func categoryTotals(_ store: FinanceStore, period: FinancePeriod, fixed: Bool? = nil) -> [String: Decimal] {
        personalRows(store, period: period).filter { fixed == nil || isFixed($0) == fixed }.reduce(into: [:]) { result, row in result[category(row), default: 0] += personalContribution(row) }
    }
    /// Budget is a cash commitment view: the financed principal is displayed
    /// once in consumption; installments enter the monthly budget separately.
    func budgetCategoryTotals(_ store: FinanceStore, period: FinancePeriod, fixed: Bool? = nil) -> [String: Decimal] {
        store.netExpenseMovements.filter { period.contains($0.date) && !isInstallmentRow($0, store: store) && isOrdinary($0) && (fixed == nil || isFixed($0) == fixed) }.reduce(into: [:]) { result, row in result[category(row), default: 0] += personalContribution(row) }
    }
    func commitmentTotal(in month: Date) -> Decimal { state.installments.reduce(0) { $0 + $1.due(in: month) } }
    /// Aggregate issuer load is used only when that account has no itemized plan;
    /// never count the itemized and printed monthly load twice.
    func commitments(_ store: FinanceStore, month: Date) -> Decimal {
        let period = FinancePeriod.month(month)
        let grouped = Dictionary(grouping: store.periodMetrics.filter { $0.kind == .card }, by: { $0.accountKey ?? $0.source })
        var extra: Decimal = 0
        for (account, metrics) in grouped {
            let itemized = state.installments.filter { $0.account == account || $0.account == metrics.first?.source }.reduce(Decimal(0)) { $0 + $1.due(in: month) }
            if state.completeMSIAccounts.contains(account) { continue }
            let ids = Set(metrics.map(\.id))
            let observed = store.movements.filter { row in
                row.statementId.map(ids.contains) == true && row.kind == .msi && row.amount < 0 && period.contains(row.date)
            }.reduce(Decimal(0)) { $0 + abs($1.amount) }
            let printed = metrics.compactMap { metric -> Decimal? in
                let statement = store.statements.first { $0.id == metric.id }
                let terms = state.cardTerms[account].flatMap { $0.statementID == metric.id ? $0 : nil }
                let due = terms?.dueDate ?? statement?.summary?.paymentDueDate
                guard let due, period.contains(due) else { return nil }
                return metric.msiMonthlyLoad
            }.first
            extra += max(0, max(observed, printed ?? 0) - itemized)
        }
        return commitmentTotal(in: month) + extra
    }
    func hasUnknownCommitments(_ store: FinanceStore, month: Date) -> Bool {
        let period = FinancePeriod.month(month)
        let grouped = Dictionary(grouping: store.periodMetrics.filter { $0.kind == .card }, by: { $0.accountKey ?? $0.source })
        return grouped.contains { account, metrics in
            let applicable = metrics.first { metric in store.statementCutoffDate(for: metric.id).map { $0 < period.end } == true }
                ?? (period.start >= FinancePeriod.month(.now).start ? metrics.first : nil)
            guard let latest = applicable, (latest.msiPending ?? 0) > 0, !state.completeMSIAccounts.contains(account) else { return false }
            let verifiedMonthly = metrics.contains { metric in
                let statement = store.statements.first { $0.id == metric.id }
                let due = state.cardTerms[account].flatMap { $0.statementID == metric.id ? $0.dueDate : nil } ?? statement?.summary?.paymentDueDate
                return due.map(period.contains) == true && metric.msiMonthlyLoad != nil
            }
            // Recorded installments prove that a charge happened, but cannot
            // prove the whole month's schedule. Require a printed full load
            // or an explicit confirmation that every plan is itemized.
            return !verifiedMonthly
        }
    }
    func observedIncome(_ store: FinanceStore, period: FinancePeriod) -> Decimal {
        store.realIncomeMovements.filter { period.contains($0.date) }.reduce(0) { $0 + abs($1.amount) }
    }
    func hasData(_ store: FinanceStore, period: FinancePeriod) -> Bool {
        store.netExpenseMovements.contains { period.contains($0.date) } || store.realIncomeMovements.contains { period.contains($0.date) } || state.installments.contains { period.contains($0.purchaseDate) }
    }
    func proposalMonths(_ store: FinanceStore, before date: Date) -> [Date] {
        let c = Calendar.current; let covered = coveredDays(store)
        let candidates = (1...12).compactMap { c.date(byAdding: .month, value: -$0, to: FinancePeriod.month(date).start) }
        return Array(candidates.filter { month in
            let period = FinancePeriod.month(month); var day = period.start
            while day < period.end { guard covered.contains(day) else { return false }; day = c.date(byAdding: .day, value: 1, to: day)! }
            return true
        }.prefix(3))
    }
    func proposals(_ store: FinanceStore, month: Date) -> [String: Decimal] {
        _ = coveredDays(store)
        let cacheKey = "\(store.ledgerVersion)|\(revision)|\(monthKey(month))"
        if let cached = proposalCache[cacheKey] { return cached }
        // Use the latest three complete observed months, searching at most
        // one year. A partial immediately preceding month never becomes zero.
        let complete = proposalMonths(store, before: month)
        guard complete.count == 3 else { proposalCache[cacheKey] = [:]; return [:] }
        let all = complete.map { budgetCategoryTotals(store, period: .month($0), fixed: false) }
        let categories = Set(all.flatMap { $0.keys })
        let result = Dictionary(uniqueKeysWithValues: categories.map { category in
            let values = all.map { max(0, $0[category, default: 0]) }.sorted()
            return (category, values[1])
        })
        proposalCache[cacheKey] = result; return result
    }
    func fixedProposal(_ store: FinanceStore, month: Date) -> [String: Decimal] {
        _ = coveredDays(store)
        let cacheKey = "\(store.ledgerVersion)|\(revision)|\(monthKey(month))"
        if let cached = fixedCache[cacheKey] { return cached }
        // Most recent observed month, fixed labels only; incomplete history is
        // disclosed in the UI and the amounts remain editable.
        let previous = Calendar.current.date(byAdding: .month, value: -1, to: FinancePeriod.month(month).start)!
        let previousFixed = budgetCategoryTotals(store, period: .month(previous), fixed: true)
        let result = previousFixed.isEmpty ? budgetCategoryTotals(store, period: .month(month), fixed: true) : previousFixed
        fixedCache[cacheKey] = result; return result
    }
    func plan(for date: Date) -> MonthBudgetPlan { state.budgets[monthKey(date)] ?? MonthBudgetPlan() }
    func setPlan(_ plan: MonthBudgetPlan, for date: Date) { state.budgets[monthKey(date)] = plan; save() }
    func limits(_ store: FinanceStore, month: Date) -> [String: Decimal] {
        var result = proposals(store, month: month)
        for (key, value) in plan(for: month).limits { result[key] = value }
        return result
    }
    func fixedLimits(_ store: FinanceStore, month: Date) -> [String: Decimal] {
        var result = fixedProposal(store, month: month)
        for (key, value) in plan(for: month).fixedLimits { result[key] = value }
        return result
    }
    func consumptionBudget(_ store: FinanceStore, month: Date) -> Decimal {
        limits(store, month: month).values.reduce(0, +) + fixedLimits(store, month: month).values.reduce(0, +) + state.installments.filter { FinancePeriod.month(month).contains($0.purchaseDate) }.reduce(0) { $0 + $1.total }
    }
    func snapshot(_ store: FinanceStore, month: Date, now: Date = .now) -> BudgetSnapshot {
        let period = FinancePeriod.month(month); let plan = plan(for: month)
        let fixedBudget = fixedLimits(store, month: month).values.reduce(0, +)
        let variableSpent = budgetCategoryTotals(store, period: period, fixed: false).values.reduce(0, +)
        let monthlyMSI = commitments(store, month: month)
        let income = monthlyIncome
        let unknown = hasUnknownCommitments(store, month: month)
        let available = unknown ? nil : income.map { $0 + plan.carryIn - fixedBudget - plan.savingsTarget - monthlyMSI }
        let remaining = available.map { $0 - variableSpent }
        let c = Calendar.current
        let today = c.startOfDay(for: now)
        let from = max(period.start, today)
        let days = from < period.end ? c.dateComponents([.day], from: from, to: period.end).day ?? 0 : 0
        return BudgetSnapshot(period: period, income: income, fixed: fixedBudget, msi: monthlyMSI, savings: plan.savingsTarget, variableSpent: variableSpent, available: available, remaining: remaining, remainingDays: days, hasData: hasData(store, period: period), hasUnknownCommitments: unknown)
    }
    @discardableResult func closeMonth(_ month: Date, surplus: Decimal) -> Bool {
        let range = FinancePeriod.month(month)
        guard range.end <= Date.now, !plan(for: month).closed, surplus >= 0 else { return false }
        var plan = plan(for: month)
        if plan.surplusDestination == .nextMonth {
            var next = self.plan(for: range.end); next.carryIn += surplus; setPlan(next, for: range.end)
        } else if !state.goals.isEmpty { state.goals[0].saved += surplus }
        else { return false }
        plan.closed = true; setPlan(plan, for: month); return true
    }
    private func recurrenceKey(_ row: Movement, income: Bool) -> String {
        let descriptor = row.transferRecipient ?? row.normalizedMerchant ?? row.title
        guard income else { return (row.account + "|" + descriptor).lowercased() }
        var normalized = descriptor.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_MX")).lowercased()
        // Payroll descriptions often change folios and pay-period dates. Only
        // normalize these on explicit payroll evidence; never group every SPEI
        // from the same intermediary into a purported salary.
        if normalized.range(of: #"\b(nomina|sueldo|salario|payroll)\b"#, options: .regularExpression) != nil {
            normalized = normalized.replacingOccurrences(of: #"\b(ref(?:erencia)?|folio)\b.*$"#, with: "", options: .regularExpression)
            normalized = normalized.replacingOccurrences(of: #"\b\w*\d\w*\b|\b(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|octubre|noviembre|diciembre)\b"#, with: " ", options: .regularExpression)
            normalized = normalized.replacingOccurrences(of: #"[^a-z ]"#, with: " ", options: .regularExpression)
        }
        normalized = normalized.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return row.account.lowercased() + "|" + normalized
    }
    func recurring(_ rows: [Movement], income: Bool = false) -> [RecurringFinancialItem] {
        let grouped = Dictionary(grouping: rows) { recurrenceKey($0, income: income) }
        return grouped.compactMap { key, rows in
            let sorted = rows.sorted { $0.date < $1.date }
            guard sorted.count >= 3, Set(sorted.map { monthKey($0.date) }).count >= 2 else { return nil }
            let amounts = sorted.map { abs($0.amount) }.sorted(); let median = amounts[amounts.count / 2]
            guard median > 0, amounts.allSatisfy({ abs($0 - median) / median <= Decimal(string: "0.1")! }) else { return nil }
            let gaps = zip(sorted, sorted.dropFirst()).map { Calendar.current.dateComponents([.day], from: $0.date, to: $1.date).day ?? 0 }.sorted()
            let gap = gaps[gaps.count / 2]
            guard (12...18).contains(gap) || (25...35).contains(gap) else { return nil }
            let validGaps = gaps.filter { (12...18).contains(gap) ? (12...18).contains($0) : (25...35).contains($0) }
            guard validGaps.count * 4 >= gaps.count * 3 else { return nil }
            return RecurringFinancialItem(id: key, name: sorted.last!.displayMerchant ?? sorted.last!.title, amount: median, cadence: (12...18).contains(gap) ? "Quincenal" : "Mensual", isIncome: income, movement: sorted.last!)
        }.sorted { $0.amount > $1.amount }
    }
}
struct BudgetSnapshot {
    let period: FinancePeriod
    let income: Decimal?
    let fixed: Decimal
    let msi: Decimal
    let savings: Decimal
    let variableSpent: Decimal
    let available: Decimal?
    let remaining: Decimal?
    let remainingDays: Int
    let hasData: Bool
    let hasUnknownCommitments: Bool
    var daily: Decimal? { guard let remaining, remainingDays > 0 else { return nil }; return remaining / Decimal(remainingDays) }
}
struct RecurringFinancialItem: Identifiable {
    let id: String, name: String
    let amount: Decimal
    let cadence: String
    let isIncome: Bool
    let movement: Movement
    var annualCost: Decimal { amount * (cadence == "Quincenal" ? 24 : 12) }
}

extension FinancialPlanningStore {
    func observedOrdinarySavings(_ store: FinanceStore, before date: Date) -> Decimal? {
        let samples = proposalMonths(store, before: date).map { month in
            let period = FinancePeriod.month(month)
            return observedIncome(store, period: period) - total(store, period: period)
        }
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Decimal(samples.count)
    }

    func ordinaryMonthlyAverage(_ store: FinanceStore, before date: Date) -> Decimal? {
        let samples = proposalMonths(store, before: date).map { personalTotal(store, period: .month($0)) }
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Decimal(samples.count)
    }
}
