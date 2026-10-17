import Foundation
import Observation

/// Local planning data is versioned separately from the audited ledger. It never
/// replaces an amount, beneficiary, category, or accounting decision in a PDF.
enum FinancePeriodMode: String, CaseIterable, Identifiable, Codable {
    case day = "Día", week = "Semana", month = "Mes", year = "Año", range = "Rango"
    var id: String { rawValue }
}
struct FinancePeriod: Hashable {
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
struct InstallmentCommitment: Identifiable, Codable, Equatable {
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

enum FixedExpenseCadence: String, CaseIterable, Codable, Identifiable {
    case monthly = "Mensual", fortnightly = "Quincenal", weekly = "Semanal", annual = "Anual"
    var id: String { rawValue }
    var paymentsPerYear: Decimal {
        switch self { case .monthly: return 12; case .fortnightly: return 24; case .weekly: return 52; case .annual: return 1 }
    }
}
struct PlanningFixedExpense: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var amount: Decimal
    var cadence: FixedExpenseCadence = .monthly
    var category: String
    // A bank-scoped merchant/recipient key. Never matches every generic SPEI.
    var matchKey: String = ""
    var account: String = ""
    var startMonth: Date
    var endMonth: Date? = nil
    var monthlyAmount: Decimal {
        var value = amount * cadence.paymentsPerYear / 12
        var rounded: Decimal = 0; NSDecimalRound(&rounded, &value, 2, .plain)
        return rounded
    }
    func includes(_ month: Date) -> Bool {
        let target = FinancePeriod.month(month).start
        return target >= FinancePeriod.month(startMonth).start && endMonth.map { target <= FinancePeriod.month($0).start } != false
    }
}
struct RecurringExpenseSuggestion: Identifiable {
    let id: String, name: String, account: String, category: String
    let amount: Decimal
    let cadence: FixedExpenseCadence
    let regular: Bool
    let count: Int, observedMonths: Int
    let lastDate: Date
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
    // Optional for backward-compatible decoding of existing planning records.
    var fixedExpenses: [PlanningFixedExpense]? = nil
}
@Observable final class FinancialPlanningStore {
    var state: PlanningState {
        didSet {
            snapshotCache.removeAll(); budgetGeneration = UUID()
            if state.labels != oldValue.labels || state.installments != oldValue.installments || state.fixedMerchantRules != oldValue.fixedMerchantRules || state.fixedExpenses != oldValue.fixedExpenses {
                invalidateSpendingProjections()
            }
        }
    }
    private let defaults: UserDefaults
    private let key = "marcelito.planning.v1"
    private(set) var loadError: String? = nil
    private(set) var revision = UUID()
    @ObservationIgnored private var coverageKey = ""
    @ObservationIgnored private var coveredCache = Set<Date>()
    @ObservationIgnored private var proposalCache: [String: [String: Decimal]] = [:]
    @ObservationIgnored private var fixedCache: [String: [String: Decimal]] = [:]
    private struct SpendingKey: Equatable {
        let store: ObjectIdentifier
        let content: UUID
        let ledger: UUID
        let planning: UUID
        let provisional: Bool
        let pending: Bool
    }
    private struct SpendingProjection {
        let key: SpendingKey
        let expenses: [Movement]
        let budgetRows: [Movement]
        let directMSIIDs: Set<UUID>
        let uniqueMSIIdentities: Set<String>
    }
    private struct PeriodCategoryKey: Hashable { let period: FinancePeriod; let fixed: Bool? }
    @ObservationIgnored private var spendingProjection: SpendingProjection?
    @ObservationIgnored private var periodTotalCache: [FinancePeriod: (total: Decimal, personal: Decimal)] = [:]
    private struct SnapshotKey: Hashable { let month: Date; let day: Date }
    @ObservationIgnored private var snapshotCache: [SnapshotKey: BudgetSnapshot] = [:]
    private(set) var budgetGeneration = UUID()
    @ObservationIgnored private var expenseRowCache: [FinancePeriod: [Movement]] = [:]
    @ObservationIgnored private var budgetCategoryCache: [PeriodCategoryKey: [String: Decimal]] = [:]
    @ObservationIgnored private var categoryCache: [PeriodCategoryKey: [String: Decimal]] = [:]
    @ObservationIgnored private var fixedMerchantIdentityCache: [UUID: (fingerprint: String, key: String, linkable: Bool)] = [:]
    @ObservationIgnored private var fixedExpenseIndex: [String: PlanningFixedExpense]?
    @ObservationIgnored private var recurringExpenseCache: (key: SpendingKey, day: Date, items: [RecurringExpenseSuggestion])?
    @ObservationIgnored private var labelIdentityIndex: [String: PersonalExpenseLabel]?
    @ObservationIgnored private var monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM"; return f
    }()
    private(set) var analysisGeneration = UUID()
    @ObservationIgnored private(set) var spendingProjectionBuildCount = 0
    private(set) var hasUnsavedPlanChanges = false
    private func invalidateSpendingProjections() {
        spendingProjection = nil; expenseRowCache.removeAll(); periodTotalCache.removeAll(); snapshotCache.removeAll(); budgetCategoryCache.removeAll(); categoryCache.removeAll()
        labelIdentityIndex = nil; fixedMerchantIdentityCache.removeAll(); fixedExpenseIndex = nil; recurringExpenseCache = nil; proposalCache.removeAll(); fixedCache.removeAll()
        analysisGeneration = UUID()
    }
    private func projection(_ store: FinanceStore) -> SpendingProjection {
        let key = SpendingKey(store: ObjectIdentifier(store), content: store.analyticsGeneration, ledger: store.ledgerVersion, planning: analysisGeneration, provisional: store.manualDashboardUnlockEnabled, pending: store.hasCanonicalRebuildPending)
        if let projection = spendingProjection, projection.key == key { return projection }
        fixedMerchantIdentityCache.removeAll()
        expenseRowCache.removeAll(); periodTotalCache.removeAll(); snapshotCache.removeAll(); budgetCategoryCache.removeAll(); categoryCache.removeAll()
        let plans = state.installments
        let directIDs = Set(plans.flatMap(\.linkedMovementIDs))
        let linkedIdentities = Set(plans.flatMap(\.linkedIdentities))
        var uniqueIdentities = Set<String>()
        var indexByID: [UUID: Int] = [:]
        var identityIndices: [String: [Int]] = [:]
        // No plans means no identity work at all. With plans, index the book
        // once; never scan the entire book separately for every expense row.
        if !plans.isEmpty {
            for (index, row) in store.movements.enumerated() {
                if indexByID[row.id] == nil { indexByID[row.id] = index }
                if !linkedIdentities.isEmpty { identityIndices[identity(row), default: []].append(index) }
            }
            uniqueIdentities = Set(linkedIdentities.filter { identityIndices[$0]?.count == 1 })
        }
        var excludedIDs = directIDs
        for identity in uniqueIdentities {
            if let index = identityIndices[identity]?.first { excludedIDs.insert(store.movements[index].id) }
        }
        let budgetRows = store.netExpenseMovements.filter { !excludedIDs.contains($0.id) }
        var expenses = budgetRows
        for plan in plans {
            let indices = plan.linkedMovementIDs.compactMap { indexByID[$0] }
                + plan.linkedIdentities.filter { uniqueIdentities.contains($0) }.compactMap { identityIndices[$0]?.first }
            guard let first = indices.min() else { continue }
            var row = store.movements[first]
            row.id = plan.id; row.date = plan.purchaseDate; row.amount = -plan.total
            row.kind = .purchase; row.flow = .expense; row.title = plan.merchant; row.displayMerchant = plan.merchant; row.category = plan.category
            expenses.append(row)
        }
        let value = SpendingProjection(key: key, expenses: expenses.sorted { $0.date > $1.date }, budgetRows: budgetRows, directMSIIDs: directIDs, uniqueMSIIdentities: uniqueIdentities)
        spendingProjection = value; spendingProjectionBuildCount += 1
        return value
    }
    func coveredDays(_ store: FinanceStore) -> Set<Date> {
        let key = "\(ObjectIdentifier(store))|\(store.analyticsGeneration)|\(store.ledgerVersion)|\(store.manualDashboardUnlockEnabled)|\(store.hasCanonicalRebuildPending)|\(Calendar.current.startOfDay(for: .now))"
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
        defaults.set(data, forKey: key); revision = UUID(); hasUnsavedPlanChanges = false; return true
    }
    func clearLocalData() {
        state = PlanningState(); loadError = nil
        defaults.removeObject(forKey: key); defaults.removeObject(forKey: key + ".backup")
        invalidateSpendingProjections(); hasUnsavedPlanChanges = false; revision = UUID()
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
    func monthKey(_ date: Date) -> String { monthFormatter.string(from: date) }
    func identity(_ movement: Movement) -> String {
        // UUID is primary; a unique identity can survive an import replay. An
        // ambiguous same-day repeated purchase is deliberately not propagated.
        "\(movement.account)|\(movement.date.timeIntervalSince1970)|\(movement.amount)|\(movement.extractionEvidence?.page ?? -1)|\(movement.title)"
    }
    func label(for movement: Movement) -> PersonalExpenseLabel {
        if let label = state.labels[movement.id.uuidString] { return label }
        guard !state.labels.isEmpty else { return PersonalExpenseLabel() }
        if labelIdentityIndex == nil {
            let grouped = Dictionary(grouping: state.labels.values, by: \.identity)
            labelIdentityIndex = grouped.compactMapValues { $0.count == 1 ? $0.first : nil }
        }
        return labelIdentityIndex?[identity(movement)] ?? PersonalExpenseLabel()
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
    func isFixed(_ movement: Movement) -> Bool { isFixed(movement, planningFor: movement.date) }
    private func isFixed(_ movement: Movement, planningFor month: Date) -> Bool {
        if let value = label(for: movement).fixed { return value }
        if !fixedExpenses.isEmpty, configuredFixedExpense(for: movement)?.includes(month) == true { return true }
        if !state.fixedMerchantRules.isEmpty, let value = state.fixedMerchantRules[merchantKey(movement)] { return value }
        return movement.classificationTags.contains("fijo")
    }
    private func budgetCategory(_ movement: Movement) -> String {
        if !fixedExpenses.isEmpty, label(for: movement).fixed != false,
           let item = configuredFixedExpense(for: movement), item.includes(movement.date) { return item.category }
        return category(movement)
    }
    func isExtraordinary(_ movement: Movement) -> Bool { label(for: movement).extraordinary ?? (movement.travelRelated || movement.classificationTags.contains("viaje") || movement.classificationTags.contains("extraordinario")) }
    func isOrdinary(_ movement: Movement) -> Bool { !isExtraordinary(movement) }
    func personalContribution(_ movement: Movement) -> Decimal {
        let l = label(for: movement)
        let extraordinary = l.extraordinary ?? (movement.travelRelated || movement.classificationTags.contains("viaje") || movement.classificationTags.contains("extraordinario"))
        guard !extraordinary else { return 0 }
        return movement.expenseContribution - min(max(0, movement.expenseContribution), l.sharedAmount)
    }
    func isInstallmentRow(_ movement: Movement, store: FinanceStore? = nil) -> Bool {
        guard !state.installments.isEmpty else { return false }
        guard let store else { return state.installments.contains { $0.linkedMovementIDs.contains(movement.id) } }
        let value = projection(store)
        if value.directMSIIDs.contains(movement.id) { return true }
        return !value.uniqueMSIIdentities.isEmpty && value.uniqueMSIIdentities.contains(identity(movement))
    }
    func expenseRows(_ store: FinanceStore, period: FinancePeriod) -> [Movement] {
        let value = projection(store)
        if let cached = expenseRowCache[period] { return cached }
        let rows = value.expenses.filter { period.contains($0.date) }
        if expenseRowCache.count >= 64 { expenseRowCache.removeAll() }
        expenseRowCache[period] = rows
        return rows
    }
    func personalRows(_ store: FinanceStore, period: FinancePeriod) -> [Movement] {
        expenseRows(store, period: period).filter(isOrdinary)
    }
    private func periodTotals(_ store: FinanceStore, period: FinancePeriod) -> (total: Decimal, personal: Decimal) {
        _ = projection(store)
        if let cached = periodTotalCache[period] { return cached }
        var value: (total: Decimal, personal: Decimal) = (0, 0)
        for row in expenseRows(store, period: period) { value.total += row.expenseContribution; value.personal += personalContribution(row) }
        if periodTotalCache.count >= 64 { periodTotalCache.removeAll() }
        periodTotalCache[period] = value; return value
    }
    func total(_ store: FinanceStore, period: FinancePeriod) -> Decimal { periodTotals(store, period: period).total }
    func personalTotal(_ store: FinanceStore, period: FinancePeriod) -> Decimal { periodTotals(store, period: period).personal }
    func categoryTotals(_ store: FinanceStore, period: FinancePeriod, fixed: Bool? = nil) -> [String: Decimal] {
        _ = projection(store)
        let key = PeriodCategoryKey(period: period, fixed: fixed)
        if let cached = categoryCache[key] { return cached }
        let result = personalRows(store, period: period).filter { fixed == nil || isFixed($0) == fixed }.reduce(into: [String: Decimal]()) { result, row in result[category(row), default: 0] += personalContribution(row) }
        if categoryCache.count >= 96 { categoryCache.removeAll() }
        categoryCache[key] = result; return result
    }
    /// Cash commitments exclude the virtual purchase principal and its linked
    /// printed installments, exactly as the uncached calculation did.
    func budgetCategoryTotals(_ store: FinanceStore, period: FinancePeriod, fixed: Bool? = nil) -> [String: Decimal] {
        let value = projection(store)
        let key = PeriodCategoryKey(period: period, fixed: fixed)
        if let cached = budgetCategoryCache[key] { return cached }
        let result = value.budgetRows.filter { period.contains($0.date) && isOrdinary($0) && (fixed == nil || isFixed($0) == fixed) }.reduce(into: [String: Decimal]()) { result, row in result[budgetCategory(row), default: 0] += personalContribution(row) }
        if budgetCategoryCache.count >= 96 { budgetCategoryCache.removeAll() }
        budgetCategoryCache[key] = result; return result
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
        let cacheKey = "\(store.analyticsGeneration)|\(analysisGeneration)|\(monthKey(month))"
        if let cached = proposalCache[cacheKey] { return cached }
        // Use the latest three complete observed months, searching at most
        // one year. A partial immediately preceding month never becomes zero.
        let complete = proposalMonths(store, before: month)
        guard complete.count == 3 else { proposalCache[cacheKey] = [:]; return [:] }
        let all = complete.map { sample -> [String: Decimal] in
            guard !fixedExpenses.isEmpty else { return budgetCategoryTotals(store, period: .month(sample), fixed: false) }
            // A newly confirmed fixed bill must also leave the historical
            // variable proposal, without rewriting historical classifications.
            let period = FinancePeriod.month(sample)
            return projection(store).budgetRows.filter { period.contains($0.date) && isOrdinary($0) && !isFixed($0, planningFor: month) }
                .reduce(into: [:]) { $0[category($1), default: 0] += personalContribution($1) }
        }
        let categories = Set(all.flatMap { $0.keys })
        let result = Dictionary(uniqueKeysWithValues: categories.map { category in
            let values = all.map { max(0, $0[category, default: 0]) }.sorted()
            return (category, values[1])
        })
        proposalCache[cacheKey] = result; return result
    }
    func fixedProposal(_ store: FinanceStore, month: Date) -> [String: Decimal] {
        _ = coveredDays(store)
        let cacheKey = "\(store.analyticsGeneration)|\(analysisGeneration)|\(monthKey(month))"
        if let cached = fixedCache[cacheKey] { return cached }
        // Most recent observed month, fixed labels only; incomplete history is
        // disclosed in the UI and the amounts remain editable.
        let previous = Calendar.current.date(byAdding: .month, value: -1, to: FinancePeriod.month(month).start)!
        let configured = fixedExpenses.filter { $0.includes(month) }
        let managed = Set(configured.map(\.matchKey).filter { !$0.isEmpty })
        func observed(_ sample: Date) -> [String: Decimal] {
            guard !fixedExpenses.isEmpty else { return budgetCategoryTotals(store, period: .month(sample), fixed: true) }
            let period = FinancePeriod.month(sample)
            return projection(store).budgetRows.filter { period.contains($0.date) && isOrdinary($0) && isFixed($0, planningFor: month) && !managed.contains(fixedExpenseKey($0)) }
                .reduce(into: [:]) { $0[category($1), default: 0] += personalContribution($1) }
        }
        let previousFixed = observed(previous)
        var result = previousFixed.isEmpty ? observed(month) : previousFixed
        for item in configured { result[item.category, default: 0] += item.monthlyAmount }
        fixedCache[cacheKey] = result; return result
    }
    func plan(for date: Date) -> MonthBudgetPlan { state.budgets[monthKey(date)] ?? MonthBudgetPlan() }
    func setPlan(_ plan: MonthBudgetPlan, for date: Date, persist: Bool = true) {
        state.budgets[monthKey(date)] = plan
        hasUnsavedPlanChanges = true
        if persist { save() }
    }
    func savePendingPlanChanges() { if hasUnsavedPlanChanges { save() } }
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
        _ = projection(store); _ = budgetGeneration
        let cacheKey = SnapshotKey(month: FinancePeriod.month(month).start, day: Calendar.current.startOfDay(for: now))
        if let cached = snapshotCache[cacheKey] { return cached }
        let period = FinancePeriod.month(month); let plan = plan(for: month)
        let fixedByCategory = fixedLimits(store, month: month)
        let fixedBudget = fixedByCategory.values.reduce(0, +)
        let fixedOverrun = budgetCategoryTotals(store, period: period, fixed: true).reduce(Decimal(0)) { $0 + max(0, $1.value - fixedByCategory[$1.key, default: 0]) }
        let variableSpent = budgetCategoryTotals(store, period: period, fixed: false).values.reduce(0, +)
        let monthlyMSI = commitments(store, month: month)
        let income = monthlyIncome
        let unknown = hasUnknownCommitments(store, month: month)
        let available = unknown ? nil : income.map { $0 + plan.carryIn - fixedBudget - fixedOverrun - plan.savingsTarget - monthlyMSI }
        let remaining = available.map { $0 - variableSpent }
        let c = Calendar.current
        let today = c.startOfDay(for: now)
        let from = max(period.start, today)
        let days = from < period.end ? c.dateComponents([.day], from: from, to: period.end).day ?? 0 : 0
        let value = BudgetSnapshot(period: period, income: income, fixed: fixedBudget, msi: monthlyMSI, savings: plan.savingsTarget, variableSpent: variableSpent, available: available, remaining: remaining, remainingDays: days, hasData: hasData(store, period: period), hasUnknownCommitments: unknown, fixedOverrun: fixedOverrun)
        if snapshotCache.count >= 24 { snapshotCache.removeAll() }
        snapshotCache[cacheKey] = value; return value
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
    var fixedExpenses: [PlanningFixedExpense] { state.fixedExpenses ?? [] }
    @discardableResult func setFixedExpenses(_ expenses: [PlanningFixedExpense]) -> Bool {
        let keys = expenses.map(\.matchKey).filter { !$0.isEmpty }
        guard Set(expenses.map(\.id)).count == expenses.count, Set(keys).count == keys.count,
              expenses.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.amount > 0 && !$0.amount.isNaN && !$0.category.isEmpty && !["Ingresos", "Transferencia", "Transferencias"].contains($0.category) && validFixedExpenseDates($0) }) else { return false }
        let previous = state
        state.fixedExpenses = expenses
        if save() { return true }
        state = previous; return false
    }
    private func validFixedExpenseDates(_ expense: PlanningFixedExpense) -> Bool {
        expense.endMonth.map { FinancePeriod.month($0).start >= FinancePeriod.month(expense.startMonth).start } ?? true
    }
    func fixedExpenseKey(_ movement: Movement) -> String { fixedMerchantIdentity(movement).key }
    private func fixedMerchantIdentity(_ movement: Movement) -> (key: String, linkable: Bool) {
        let fingerprint = [movement.account, movement.title, movement.normalizedMerchant ?? "", movement.displayMerchant ?? "", movement.rawDescription ?? "", movement.extractionEvidence?.sourceText ?? "", String(describing: movement.kind), String(describing: movement.flow)].joined(separator: "\u{001F}")
        if let cached = fixedMerchantIdentityCache[movement.id], cached.fingerprint == fingerprint { return (cached.key, cached.linkable) }
        let primary = movement.normalizedMerchant ?? movement.displayMerchant ?? movement.title
        let isTransfer = movement.hasTransferOrSpeiDescriptor || primary.range(of: #"(?i)spei|transf"#, options: .regularExpression) != nil
        let recipient = isTransfer ? movement.transferRecipient : nil
        let descriptor = recipient ?? movement.normalizedMerchant ?? movement.displayMerchant ?? movement.title
        let key = (movement.account + "|" + descriptor).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_MX")).lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        let linkable = !isTransfer || recipient?.isEmpty == false
        if fixedMerchantIdentityCache.count >= 4096 { fixedMerchantIdentityCache.removeAll() }
        fixedMerchantIdentityCache[movement.id] = (fingerprint, key, linkable)
        return (key, linkable)
    }
    private func configuredFixedExpense(for movement: Movement) -> PlanningFixedExpense? {
        if fixedExpenseIndex == nil {
            fixedExpenseIndex = fixedExpenses.reduce(into: [:]) { if !$1.matchKey.isEmpty { $0[$1.matchKey] = $1 } }
        }
        return fixedExpenseIndex?[fixedExpenseKey(movement)]
    }
    func canLinkFixedExpense(_ row: Movement) -> Bool {
        guard row.kind != .msi, row.kind != .bankTransfer, row.kind != .cardPayment, row.kind != .income, row.kind != .credit else { return false }
        // An unexpanded bank operation is not a reliable merchant identity.
        return fixedMerchantIdentity(row).linkable
    }
    func recurringExpenseSuggestions(_ store: FinanceStore, now: Date = .now) -> [RecurringExpenseSuggestion] {
        let value = projection(store); let day = Calendar.current.startOfDay(for: now)
        if let cache = recurringExpenseCache, cache.key == value.key, cache.day == day { return cache.items }
        let from = Calendar.current.date(byAdding: .month, value: -12, to: now)!
        let configured = Set(fixedExpenses.map(\.matchKey))
        let rows = value.budgetRows.filter { $0.date >= from && $0.date <= now && $0.expenseContribution > 0 && personalContribution($0) > 0 && isOrdinary($0) && label(for: $0).fixed != false && canLinkFixedExpense($0) }
        let grouped = Dictionary(grouping: rows, by: fixedExpenseKey)
        let items = grouped.compactMap { key, rows -> RecurringExpenseSuggestion? in
            guard !configured.contains(key), rows.count >= 3 else { return nil }
            let sorted = rows.sorted { $0.date < $1.date }
            let monthCount = Set(rows.map { monthKey($0.date) }).count
            guard monthCount >= 2, Set(rows.map { Calendar.current.startOfDay(for: $0.date) }).count >= 3 else { return nil }
            let amounts = rows.map { personalContribution($0) }.sorted()
            let median = amounts.count.isMultiple(of: 2) ? (amounts[amounts.count / 2 - 1] + amounts[amounts.count / 2]) / 2 : amounts[amounts.count / 2]
            guard median > 0 else { return nil }
            let gaps = zip(sorted, sorted.dropFirst()).map { Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: $0.date), to: Calendar.current.startOfDay(for: $1.date)).day ?? 0 }.sorted()
            let gap = gaps[gaps.count / 2]
            let cadence: FixedExpenseCadence? = (5...9).contains(gap) ? .weekly : (12...18).contains(gap) ? .fortnightly : (25...35).contains(gap) ? .monthly : nil
            let stable = amounts.allSatisfy { abs($0 - median) <= median / 10 }
            let regular = cadence.map { cadence in
                let range = cadence == .weekly ? 5...9 : cadence == .fortnightly ? 12...18 : 25...35
                return stable && gaps.filter { range.contains($0) }.count * 4 >= gaps.count * 3
            } ?? false
            guard regular || rows.count >= 4 else { return nil }
            // Irregular frequent merchants use a suggested monthly allowance,
            // not a purported recurring bill. It always requires confirmation.
            let totals = Dictionary(grouping: rows, by: { monthKey($0.date) }).values.map { $0.reduce(Decimal(0)) { $0 + personalContribution($1) } }.sorted()
            let last = sorted.last!
            return RecurringExpenseSuggestion(id: key, name: merchantLabel(last), account: last.account, category: category(last), amount: regular ? median : (totals.count.isMultiple(of: 2) ? (totals[totals.count / 2 - 1] + totals[totals.count / 2]) / 2 : totals[totals.count / 2]), cadence: regular ? cadence! : .monthly, regular: regular, count: rows.count, observedMonths: monthCount, lastDate: last.date)
        }.sorted { $0.amount * $0.cadence.paymentsPerYear > $1.amount * $1.cadence.paymentsPerYear }
        recurringExpenseCache = (value.key, day, items); return items
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
    var fixedOverrun: Decimal = 0
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
