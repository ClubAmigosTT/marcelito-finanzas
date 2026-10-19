import Foundation

/// Evidence for a suggestion, never a saved income or budget entry.
struct RecurringObservation: Hashable {
    let date: Date
    let amount: Decimal
}

enum RecurringCadence: String, CaseIterable {
    case weekly = "Semanal", biweekly = "Catorcenal", fortnightly = "Quincenal", monthly = "Mensual", annual = "Anual"
    var paymentsPerYear: Decimal {
        switch self { case .weekly: return 52; case .biweekly: return 26; case .fortnightly: return 24; case .monthly: return 12; case .annual: return 1 }
    }
    func monthlyAmount(_ amount: Decimal) -> Decimal {
        var value = amount * paymentsPerYear / 12; var rounded: Decimal = 0
        NSDecimalRound(&rounded, &value, 2, .plain)
        return rounded
    }
}

struct RecurringPatternMatch {
    let cadence: RecurringCadence
    let amount: Decimal
    let observations: [RecurringObservation]
}

enum RecurringPattern {
    /// A frequent shop is not a periodic commitment. Require both similar
    /// amounts and repeated intervals, retaining the actual observations.
    static func detect(_ observations: [RecurringObservation], calendar: Calendar = .current) -> RecurringPatternMatch? {
        let rows = observations.filter { $0.amount > 0 && !$0.amount.isNaN }.sorted { $0.date < $1.date }
        guard rows.count >= 3 else { return nil }
        let amounts = rows.map(\.amount).sorted()
        let midpoint = amounts.count / 2
        let median = amounts.count.isMultiple(of: 2) ? (amounts[midpoint - 1] + amounts[midpoint]) / 2 : amounts[midpoint]
        // A single bonus or exceptional charge must not erase an otherwise
        // supported pattern. At least 75% must agree on the typical amount.
        let matching = rows.filter { abs($0.amount - median) <= median / 10 }
        guard matching.count >= 3, matching.count * 4 >= rows.count * 3,
              Set(matching.map { calendar.startOfDay(for: $0.date) }).count == matching.count,
              Set(matching.map { calendar.dateComponents([.year, .month], from: $0.date) }).count >= 2 else { return nil }
        let gaps = zip(matching, matching.dropFirst()).map {
            calendar.dateComponents([.day], from: calendar.startOfDay(for: $0.date), to: calendar.startOfDay(for: $1.date)).day ?? 0
        }
        for cadence in [RecurringCadence.weekly, .biweekly, .fortnightly, .monthly, .annual] {
            if (cadence == .weekly || cadence == .biweekly || cadence == .fortnightly) && matching.count < 4 { continue }
            let direct: ClosedRange<Int>
            let missingOne: ClosedRange<Int>
            switch cadence {
            case .weekly: direct = 5...9; missingOne = 12...16
            // Every 14 days (26 a year) is not "quincenal" (the 15th and the
            // last day, 24 a year): treating it as quincenal undercounted a
            // catorcenal payroll by 7.7% a month.
            case .biweekly: direct = 13...14; missingOne = 27...29
            case .fortnightly: direct = 12...18; missingOne = 27...33
            case .monthly: direct = 25...35; missingOne = 56...66
            case .annual: direct = 350...380; missingOne = 715...745
            }
            let directCount = gaps.filter { direct.contains($0) }.count
            let compatible = gaps.filter { direct.contains($0) || missingOne.contains($0) }.count
            guard directCount * 2 >= gaps.count, compatible * 4 >= gaps.count * 3 else { continue }
            let values = matching.map(\.amount).sorted(); let mid = values.count / 2
            let amount = values.count.isMultiple(of: 2) ? (values[mid - 1] + values[mid]) / 2 : values[mid]
            return RecurringPatternMatch(cadence: cadence, amount: amount, observations: matching)
        }
        return nil
    }

    /// Well-known subscription merchants. These charge monthly (or yearly)
    /// but often in USD, so the amount moves with the exchange rate, and one
    /// merchant (Apple, Google) can bill several subscriptions with different
    /// amounts. The generic detector rejects both, so they are recognised by
    /// name instead.
    static func isKnownSubscription(_ text: String) -> Bool {
        let value = normalized(text)
        let pattern = #"\b(canva|apple\.com|apple com|itunes|icloud|google\s*\*\s*\w+|google one|google play|google storage|google workspace|youtube|spotify|netflix|disney|hbo|max\.com|prime video|amazon prime|amzn prime|amazon music|microsoft|xbox|playstation|adobe|openai|chatgpt|notion|dropbox|duolingo|uber one|rappi pro|paramount|crunchyroll|deezer|audible|linkedin|github|zoom|figma|anthropic|claude\.ai|vix|star plus|apple tv|apple music|strava|calm|headspace)\b"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    static func hasPayrollEvidence(_ texts: [String]) -> Bool {
        texts.contains {
            let text = normalized($0).replacingOccurrences(of: #"\b(super|(?:sub)?cuenta|tarjeta)\s+nomina\b"#, with: " ", options: .regularExpression)
            return text.range(of: #"\b(nomina|sueldo|salario|payroll)\b"#, options: .regularExpression) != nil
        }
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_MX"))
            .lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func payrollDescriptor(_ value: String) -> String {
        normalized(value)
            .replacingOccurrences(of: #"\b\d{1,2}[-/](?:ene|feb|mar|abr|may|jun|jul|ago|sep|sept|oct|nov|dic)(?:[-/]\d{2,4})?\b|\b(?:ene|feb|mar|abr|may|jun|jul|ago|sep|sept|oct|nov|dic)\.?\s+\d{2,4}\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(ref(?:erencia)?|folio)\s*[:#]?\s*[\w-]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b\w*\d\w*\b|\b(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|octubre|noviembre|diciembre|quincena|primera|segunda)\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
