import Foundation
import Observation

/// Local planning data is versioned separately from the audited ledger. It never
/// replaces an amount, beneficiary, category, or accounting decision in a PDF.
enum FinancePeriodMode: String, CaseIterable, Identifiable, Codable {
    case day = "Día", week = "Semana", month = "Mes", year = "Año", range = "Rango"
    var id: String { rawValue }
}
struct FinancePeriod: Hashable, Codable {
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
    var archived: Bool? = nil
    var entries: [SavingsEntry]? = nil
    var id = UUID()
    var name: String
    var target: Decimal
    var saved: Decimal
    var monthlyContribution: Decimal
    var estimatedMonths: Int? {
        guard monthlyContribution > 0 else { return nil }
        return Int(ceil(NSDecimalNumber(decimal: max(0, target - saved) / monthlyContribution).doubleValue))
    }
    /// Optional deadline ("terminar el ITAM antes de junio").
    var targetDate: Date? = nil
    /// What has to be set aside each month, from this month through the
    /// deadline's month, to reach the target on time.
    func requiredMonthly(now: Date = .now, calendar: Calendar = .current) -> Decimal? {
        guard let targetDate else { return nil }
        let remaining = max(0, target - saved)
        guard remaining > 0 else { return 0 }
        let start = FinancePeriod.month(now).start
        let months = (calendar.dateComponents([.month], from: start, to: FinancePeriod.month(targetDate).start).month ?? 0) + 1
        guard months > 0 else { return remaining }
        var value = remaining / Decimal(months), rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .up)
        return rounded
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
    var spendingLimit: Decimal? = nil
    var closing: BudgetClosing? = nil
    var legacyImported: Bool? = nil
    var legacySpendingLimit: Decimal? = nil
    var legacySavingsTarget: Decimal? = nil
    /// nil = the loan payment is part of the plan (default).
    var loanReserveIncluded: Bool? = nil
    /// The amount the user plans to pay toward loans this month; nil uses the
    /// scheduled installment (or what was already paid, if larger).
    var loanReserveAmount: Decimal? = nil
}
struct PlanningIncomeSource: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var amount: Decimal
    var cadence: String
    var account: String = ""
    var detectedKey: String? = nil
    var monthlyAmount: Decimal { RecurringCadence(rawValue: cadence)?.monthlyAmount(amount) ?? amount }
}

enum FixedExpenseCadence: String, CaseIterable, Codable, Identifiable {
    case monthly = "Mensual", biweekly = "Catorcenal", fortnightly = "Quincenal", weekly = "Semanal", annual = "Anual"
    var id: String { rawValue }
    var paymentsPerYear: Decimal {
        switch self { case .monthly: return 12; case .biweekly: return 26; case .fortnightly: return 24; case .weekly: return 52; case .annual: return 1 }
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
    var movements: [Movement] = []
}

struct PlanningState: Codable {
    var schema = 1
    var incomeAmount: Decimal? = nil
    var incomeCadence = "Mensual"
    // nil means a v1 total has not yet been split into sources. An explicit
    // empty array means the user removed every source, not a zero income.
    var incomeSources: [PlanningIncomeSource]? = nil
    var incomeHistory: [IncomeRevision]? = nil
    var incomeOnboardingCompleted = false
    var labels: [String: PersonalExpenseLabel] = [:]
    var installments: [InstallmentCommitment] = []
    var completeMSIAccounts: [String] = []
    var budgets: [String: MonthBudgetPlan] = [:]
    var goals: [SavingsGoal] = []
    var cardTerms: [String: CardPaymentTerms] = [:]
    var cardPaymentLinks: [CardPaymentLink]? = nil
    var remindersEnabled = false
    var fixedMerchantRules: [String: Bool] = [:]
    // Optional for backward-compatible decoding of existing planning records.
    var fixedExpenses: [PlanningFixedExpense]? = nil
    var dismissedRecurringExpenseKeys: [String]? = nil
}
@Observable final class FinancialPlanningStore {
    var state: PlanningState {
        didSet {
            snapshotCache.removeAll(); budgetGeneration = UUID()
            if state.labels != oldValue.labels || state.installments != oldValue.installments || state.fixedMerchantRules != oldValue.fixedMerchantRules || state.fixedExpenses != oldValue.fixedExpenses || state.dismissedRecurringExpenseKeys != oldValue.dismissedRecurringExpenseKeys {
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
    @ObservationIgnored private var incomeSuggestionCache: (key: String, items: [RecurringFinancialItem])?
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
        let consumptionRows = store.netExpenseMovements.filter { !excludedIDs.contains($0.id) }
        // Interest stays in consumption; the complete loan cash payment is reserved once below.
        let budgetRows = consumptionRows.filter { !$0.classificationTags.contains("loan-interest") }
        var expenses = consumptionRows
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
        migrateLegacyMonthlyPlans(defaults: defaults)
    }
    @discardableResult func save() -> Bool {
        // Never overwrite a future/corrupted schema with an empty plan.
        guard loadError == nil, state.schema == 1, let data = try? JSONEncoder().encode(state) else { return false }
        if let previous = defaults.data(forKey: key) { defaults.set(previous, forKey: key + ".backup") }
        defaults.set(data, forKey: key); revision = UUID(); hasUnsavedPlanChanges = false; return true
    }
    func clearLocalData() {
        state = PlanningState(); loadError = nil
        incomeSuggestionCache = nil
        defaults.removeObject(forKey: key); defaults.removeObject(forKey: key + ".backup")
        invalidateSpendingProjections(); hasUnsavedPlanChanges = false; revision = UUID()
    }
    private var legacyIncomeSources: [PlanningIncomeSource] {
        if let sources = state.incomeSources { return sources }
        guard let amount = state.incomeAmount else { return [] }
        return [PlanningIncomeSource(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Ingreso habitual", amount: amount, cadence: state.incomeCadence)]
    }
    func incomeSources(for month: Date) -> [PlanningIncomeSource] {
        guard let history = state.incomeHistory, !history.isEmpty else { return legacyIncomeSources }
        let start = FinancePeriod.month(month).start
        return history.filter { $0.effectiveMonth <= start }.max { $0.effectiveMonth < $1.effectiveMonth }?.sources ?? []
    }
    var incomeSources: [PlanningIncomeSource] { incomeSources(for: .now) }
    func monthlyIncome(for month: Date) -> Decimal? {
        let sources = incomeSources(for: month)
        return sources.isEmpty ? nil : sources.reduce(0) { $0 + $1.monthlyAmount }
    }
    var monthlyIncome: Decimal? { monthlyIncome(for: .now) }
    @discardableResult func setIncomeSources(_ sources: [PlanningIncomeSource], effectiveFrom month: Date = .now) -> Bool {
        guard sources.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.amount >= 0 && !$0.amount.isNaN && RecurringCadence(rawValue: $0.cadence) != nil }), Set(sources.map(\.id)).count == sources.count else { return false }
        let previous = state
        var history = state.incomeHistory ?? [IncomeRevision(effectiveMonth: .distantPast, sources: legacyIncomeSources)]
        let start = FinancePeriod.month(month).start
        // "From month X" must reach later revisions too: a raise entered from
        // September was lost in October when October already had its own
        // revision. Carry each added, edited or removed source forward; any
        // other difference a later revision already had is kept.
        let before = history.filter { $0.effectiveMonth <= start }.max { $0.effectiveMonth < $1.effectiveMonth }?.sources ?? []
        let beforeByID = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let afterByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in history.indices where history[index].effectiveMonth > start {
            var later = history[index].sources
            for source in sources where beforeByID[source.id] != source {
                if let position = later.firstIndex(where: { $0.id == source.id }) { later[position] = source }
                else if beforeByID[source.id] == nil { later.append(source) }
            }
            later.removeAll { beforeByID[$0.id] != nil && afterByID[$0.id] == nil }
            history[index] = IncomeRevision(effectiveMonth: history[index].effectiveMonth, sources: later)
        }
        history.removeAll { $0.effectiveMonth == start }
        history.append(IncomeRevision(effectiveMonth: start, sources: sources))
        state.incomeHistory = history.sorted { $0.effectiveMonth < $1.effectiveMonth }
        state.incomeSources = incomeSources
        state.incomeAmount = monthlyIncome
        state.incomeCadence = "Mensual"
        state.incomeOnboardingCompleted = true
        if save() { return true }
        state = previous; return false
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
    func incomeSuggestions(_ store: FinanceStore, now: Date = .now) -> [RecurringFinancialItem] {
        let key = "\(ObjectIdentifier(store))|\(store.analyticsGeneration)|\(store.ledgerVersion)|\(budgetGeneration)|\(store.manualDashboardUnlockEnabled)|\(store.hasCanonicalRebuildPending)|\(Calendar.current.startOfDay(for: now))"
        if let cached = incomeSuggestionCache, cached.key == key { return cached.items }
        let confirmedKeys = Set(incomeSources.compactMap(\.detectedKey))
        let from = Calendar.current.date(byAdding: .month, value: -12, to: now)!
        let rows = store.realIncomeMovements.filter { $0.date >= from && $0.date <= now && $0.amount > 0 }
        let items = recurring(rows, income: true).filter { !confirmedKeys.contains($0.id) }
        incomeSuggestionCache = (key, items); return items
    }
    func receivedIncomeOptions(_ store: FinanceStore, now: Date = .now) -> [Movement] {
        store.realIncomeMovements.filter { $0.amount > 0 && $0.date <= now }.sorted { $0.date > $1.date }
    }
    func incomeDraft(from movement: Movement, store: FinanceStore) -> PlanningIncomeSource {
        let suggestion = incomeSuggestions(store).first { $0.movements.contains(where: { $0.id == movement.id }) }
        return PlanningIncomeSource(name: suggestion?.name ?? movement.summaryDisplayTitle, amount: movement.amount,
            cadence: suggestion?.cadence ?? "Mensual", account: movement.account, detectedKey: recurrenceKey(movement, income: true))
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
        let result = value.budgetRows.filter { period.contains($0.date) && (fixed == nil || isFixed($0) == fixed) }.reduce(into: [String: Decimal]()) { result, row in result[budgetCategory(row), default: 0] += row.expenseContribution }
        if budgetCategoryCache.count >= 96 { budgetCategoryCache.removeAll() }
        budgetCategoryCache[key] = result; return result
    }
    /// Average monthly spend of one category over the last three calendar
    /// months that have movements, as a reference while setting a budget.
    /// Months without data are skipped instead of counted as zero.
    func categoryAverage(_ store: FinanceStore, category: String, before month: Date, fixed: Bool) -> Decimal? {
        let calendar = Calendar.current
        let start = FinancePeriod.month(month).start
        let totals: [Decimal] = (1...3).compactMap { offset in
            guard let previous = calendar.date(byAdding: .month, value: -offset, to: start) else { return nil }
            let period = FinancePeriod.month(previous)
            guard hasData(store, period: period) else { return nil }
            return budgetCategoryTotals(store, period: period, fixed: fixed)[category] ?? 0
        }
        guard !totals.isEmpty else { return nil }
        return totals.reduce(0, +) / Decimal(totals.count)
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
            return projection(store).budgetRows.filter { period.contains($0.date) && !isFixed($0, planningFor: month) }
                .reduce(into: [:]) { $0[category($1), default: 0] += $1.expenseContribution }
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
            return projection(store).budgetRows.filter { period.contains($0.date) && isFixed($0, planningFor: month) && !managed.contains(fixedExpenseKey($0)) }
                .reduce(into: [:]) { $0[category($1), default: 0] += $1.expenseContribution }
        }
        let previousFixed = observed(previous)
        var result = previousFixed.isEmpty ? observed(month) : previousFixed
        for item in configured { result[item.category, default: 0] += item.monthlyAmount }
        fixedCache[cacheKey] = result; return result
    }
    func plan(for date: Date) -> MonthBudgetPlan { state.budgets[monthKey(date)] ?? MonthBudgetPlan() }
    func setPlan(_ plan: MonthBudgetPlan, for date: Date, persist: Bool = true) {
        guard self.plan(for: date).closing == nil else { return }
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
        if let closing = plan(for: month).closing { return closing.snapshot(in: .month(month)) }
        _ = projection(store); _ = budgetGeneration
        let cacheKey = SnapshotKey(month: FinancePeriod.month(month).start, day: Calendar.current.startOfDay(for: now))
        if let cached = snapshotCache[cacheKey] { return cached }
        let period = FinancePeriod.month(month); let plan = plan(for: month)
        let fixedByCategory = fixedLimits(store, month: month)
        let fixedBudget = fixedByCategory.values.reduce(0, +)
        let fixedOverrun = budgetCategoryTotals(store, period: period, fixed: true).reduce(Decimal(0)) { $0 + max(0, $1.value - fixedByCategory[$1.key, default: 0]) }
        let variableSpent = budgetCategoryTotals(store, period: period, fixed: false).values.reduce(0, +)
        let monthlyMSI = commitments(store, month: month)
        let income = monthlyIncome(for: month)
        let loanReserve = store.loanLedger.reserve(month: month, paid: store.loanPaid(in: period))
        let loansIncluded = plan.loanReserveIncluded ?? true
        let plannedLoans: Decimal? = loansIncluded ? (plan.loanReserveAmount ?? loanReserve.reserved) : 0
        let unknownLoans = loansIncluded && plan.loanReserveAmount == nil
            && (loanReserve.reserved == nil || store.loanLedger.loadError != nil)
        let unknown = hasUnknownCommitments(store, month: month)
        let available = unknown || unknownLoans ? nil : income.map { min($0 + plan.carryIn - plan.savingsTarget, plan.spendingLimit ?? ($0 + plan.carryIn - plan.savingsTarget)) - fixedBudget - fixedOverrun - monthlyMSI - (plannedLoans ?? 0) }
        let remaining = available.map { $0 - variableSpent }
        let c = Calendar.current
        let today = c.startOfDay(for: now)
        let from = max(period.start, today)
        let days = from < period.end ? c.dateComponents([.day], from: from, to: period.end).day ?? 0 : 0
        let value = BudgetSnapshot(period: period, income: income, fixed: fixedBudget, msi: monthlyMSI, savings: plan.savingsTarget, variableSpent: variableSpent, available: available, remaining: remaining, remainingDays: days, hasData: hasData(store, period: period), hasUnknownCommitments: unknown, fixedOverrun: fixedOverrun, loans: plannedLoans, hasUnknownLoans: unknownLoans)
        if snapshotCache.count >= 24 { snapshotCache.removeAll() }
        snapshotCache[cacheKey] = value; return value
    }
    var fixedExpenses: [PlanningFixedExpense] { state.fixedExpenses ?? [] }
    @discardableResult func setDismissedRecurringExpenses(_ keys: [String]) -> Bool {
        let previous = state
        state.dismissedRecurringExpenseKeys = Array(Set(keys)).sorted()
        if save() { return true }
        state = previous; return false
    }
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
        guard !row.classificationTags.contains("loan-interest"), row.kind != .msi, row.kind != .bankTransfer, row.kind != .cardPayment, row.kind != .income, row.kind != .credit else { return false }
        // An unexpanded bank operation is not a reliable merchant identity.
        return fixedMerchantIdentity(row).linkable
    }
    func recurringExpenseSuggestions(_ store: FinanceStore, now: Date = .now) -> [RecurringExpenseSuggestion] {
        let value = projection(store); let day = Calendar.current.startOfDay(for: now)
        if let cache = recurringExpenseCache, cache.key == value.key, cache.day == day { return cache.items }
        let from = Calendar.current.date(byAdding: .month, value: -12, to: now)!
        let configured = Set(fixedExpenses.map(\.matchKey)).union(state.dismissedRecurringExpenseKeys ?? [])
        let rows = value.budgetRows.filter { $0.date >= from && $0.date <= now && $0.expenseContribution > 0 && isOrdinary($0) && label(for: $0).fixed != false && canLinkFixedExpense($0) }
        let latestByAccount = Dictionary(uniqueKeysWithValues: Set(rows.map(\.account)).compactMap { account in
            latestDataDate(store, account: account, now: now).map { (account, $0) }
        })
        let grouped = Dictionary(grouping: rows, by: fixedExpenseKey)
        let items = grouped.compactMap { key, rows -> RecurringExpenseSuggestion? in
            guard !configured.contains(key),
                  let pattern = RecurringPattern.detect(rows.map { RecurringObservation(date: $0.date, amount: $0.expenseContribution) }),
                  let cadence = FixedExpenseCadence(rawValue: pattern.cadence.rawValue) else { return nil }
            let observations = Set(pattern.observations)
            let evidence = rows.filter { observations.contains(RecurringObservation(date: $0.date, amount: $0.expenseContribution)) }.sorted { $0.date < $1.date }
            guard let last = evidence.last else { return nil }
            // Recommend patterns still present near the account's latest data,
            // not old habits from a year ago. Missing statements imply no cancellation.
            let recency = cadence == .weekly ? 18 : (cadence == .fortnightly || cadence == .biweekly) ? 36 : cadence == .monthly ? 45 : 400
            let latest = latestByAccount[last.account] ?? last.date
            guard (Calendar.current.dateComponents([.day], from: last.date, to: latest).day ?? 0) <= recency else { return nil }
            return RecurringExpenseSuggestion(id: key, name: merchantLabel(last), account: last.account, category: category(last), amount: pattern.amount, cadence: cadence, regular: true, count: evidence.count, observedMonths: Set(evidence.map { monthKey($0.date) }).count, lastDate: last.date, movements: evidence)
        }
        // Known subscriptions (Canva, Apple, Google, Spotify…) are suggested
        // from a single recent charge: they bill in USD or several plans per
        // merchant, which the amount-and-interval detector above rejects.
        let detected = Set(items.map(\.id))
        let calendar = Calendar.current
        let subscriptions = grouped.compactMap { key, rows -> RecurringExpenseSuggestion? in
            guard !configured.contains(key), !detected.contains(key),
                  let last = rows.max(by: { $0.date < $1.date }),
                  RecurringPattern.isKnownSubscription([last.normalizedMerchant, last.displayMerchant, last.title, last.rawDescription].compactMap { $0 }.joined(separator: " ")) else { return nil }
            let latest = latestByAccount[last.account] ?? last.date
            guard (calendar.dateComponents([.day], from: last.date, to: latest).day ?? 0) <= 45 else { return nil }
            // Every plan billed by the merchant in the last month adds up
            // (two Apple subscriptions on different days are one monthly cost).
            let lastMonth = rows.filter { (calendar.dateComponents([.day], from: $0.date, to: last.date).day ?? 99) < 31 }
            let amount = lastMonth.reduce(Decimal(0)) { $0 + $1.expenseContribution }
            let evidence = rows.sorted { $0.date < $1.date }
            return RecurringExpenseSuggestion(id: key, name: merchantLabel(last), account: last.account, category: "Software y suscripciones", amount: amount, cadence: .monthly, regular: evidence.count >= 2, count: evidence.count, observedMonths: Set(evidence.map { monthKey($0.date) }).count, lastDate: last.date, movements: evidence)
        }
        let sortedItems = (items + subscriptions).sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.lastDate != $1.lastDate { return $0.lastDate > $1.lastDate }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        recurringExpenseCache = (value.key, day, sortedItems); return sortedItems
    }
    private func recurrenceKey(_ row: Movement, income: Bool) -> String {
        let descriptor = row.transferRecipient ?? row.normalizedMerchant ?? row.title
        guard income else { return (row.account + "|" + descriptor).lowercased() }
        let evidence = [row.title, row.rawDescription, row.extractionEvidence?.sourceText].compactMap { $0 }
        // A normalized merchant can have lost the payroll marker. Inspect the
        // retained bank description as well, keeping employer names separate.
        if let payroll = evidence.first(where: { RecurringPattern.hasPayrollEvidence([$0]) }) {
            return RecurringPattern.normalized(row.account) + "|" + RecurringPattern.payrollDescriptor(payroll)
        }
        return RecurringPattern.normalized(row.account) + "|" + RecurringPattern.normalized(descriptor)
    }
    func recurring(_ rows: [Movement], income: Bool = false) -> [RecurringFinancialItem] {
        let grouped = Dictionary(grouping: rows) { recurrenceKey($0, income: income) }
        return grouped.compactMap { key, rows in
            guard let pattern = RecurringPattern.detect(rows.map { RecurringObservation(date: $0.date, amount: abs($0.amount)) }) else { return nil }
            let observations = Set(pattern.observations)
            let evidence = rows.filter { observations.contains(RecurringObservation(date: $0.date, amount: abs($0.amount))) }.sorted { $0.date < $1.date }
            guard let last = evidence.last else { return nil }
            let payroll = income && RecurringPattern.hasPayrollEvidence([last.title, last.rawDescription ?? "", last.extractionEvidence?.sourceText ?? ""])
            let payrollText = [last.title, last.rawDescription, last.extractionEvidence?.sourceText].compactMap { $0 }.first { RecurringPattern.hasPayrollEvidence([$0]) }
            let name = payroll ? RecurringPattern.payrollDescriptor(payrollText ?? last.title).capitalized : last.transferRecipient ?? last.displayMerchant ?? last.title
            return RecurringFinancialItem(id: key, name: name, amount: pattern.amount, cadence: pattern.cadence.rawValue, isIncome: income, movement: last, movements: evidence)
        }.sorted { $0.annualCost > $1.annualCost }
    }

}
struct BudgetSnapshot: Codable {
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
    var loans: Decimal? = 0
    var hasUnknownLoans = false
    var daily: Decimal? { guard let remaining, remainingDays > 0 else { return nil }; return remaining / Decimal(remainingDays) }
}
struct RecurringFinancialItem: Identifiable {
    let id: String, name: String
    let amount: Decimal
    let cadence: String
    let isIncome: Bool
    let movement: Movement
    var movements: [Movement] = []
    var annualCost: Decimal { amount * (RecurringCadence(rawValue: cadence)?.paymentsPerYear ?? 12) }
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
