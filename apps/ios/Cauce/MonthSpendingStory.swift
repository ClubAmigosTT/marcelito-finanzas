import Foundation

/// Explains a month's spending the way a person would: trips found from the
/// city printed on each charge, transfers read by their concept, a short
/// summary and what deserves a second look. Pure and on-device.
struct MonthSpendingStory {
    struct Line: Identifiable, Hashable {
        let id: UUID
        let date: Date
        let title: String
        let amount: Decimal
    }

    struct Trip: Identifiable {
        var id: String { "\(city)-\(start.timeIntervalSince1970)" }
        let city: String
        let start: Date
        let end: Date
        /// Flights, buses and lodging attached to the trip by date.
        let travel: [Line]
        /// Charges made in the trip's city.
        let local: [Line]
        var total: Decimal { (travel + local).reduce(0) { $0 + $1.amount } }
    }

    struct Group: Identifiable {
        var id: String { name }
        let name: String
        let lines: [Line]
        var total: Decimal { lines.reduce(0) { $0 + $1.amount } }
    }

    struct Alert: Identifiable {
        let id: String
        let text: String
        let movementIDs: [UUID]
    }

    let total: Decimal
    let trips: [Trip]
    let groups: [Group]
    let summary: [String]
    let alerts: [Alert]

    var tripsTotal: Decimal { trips.reduce(0) { $0 + $1.total } }

    /// - Parameters:
    ///   - rows: the month's expense rows (refunds included, negative).
    ///   - history: recent expense rows used to find the home city.
    ///   - category: the category the app shows for a row.
    ///   - coverageNotes: accounts whose data stops before the month ends.
    static func build(
        rows: [Movement],
        history: [Movement],
        category: (Movement) -> String,
        coverageNotes: [String] = []
    ) -> MonthSpendingStory {
        let total = rows.reduce(Decimal(0)) { $0 + $1.expenseContribution }
        let home = homeCity(history.isEmpty ? rows : history)
        let calendar = Calendar.current

        // Trips: same non-home city on dates no more than three days apart.
        let located = rows.compactMap { row -> (Movement, String)? in
            guard row.expenseContribution > 0, let city = city(of: row), city != home else { return nil }
            return (row, city)
        }.sorted { $0.0.date < $1.0.date }
        var clusters: [(city: String, rows: [Movement])] = []
        for (row, city) in located {
            if let index = clusters.lastIndex(where: { $0.city == city }),
               let last = clusters[index].rows.last,
               calendar.dateComponents([.day], from: calendar.startOfDay(for: last.date), to: calendar.startOfDay(for: row.date)).day ?? 99 <= 3 {
                clusters[index].rows.append(row)
            } else {
                clusters.append((city, [row]))
            }
        }
        clusters = clusters.filter { cluster in
            cluster.rows.count >= 3 || cluster.rows.reduce(Decimal(0)) { $0 + $1.expenseContribution } >= 1_000
        }
        var used = Set(clusters.flatMap { $0.rows.map(\.id) })

        // Flights, buses and lodging go to the trip they most likely paid
        // for: one in progress that day, or the next one within three weeks.
        var travelByTrip: [Int: [Movement]] = [:]
        var unassignedTravel: [Movement] = []
        for row in rows where row.expenseContribution > 0 && !used.contains(row.id) && isTravelProvider(row) {
            let day = calendar.startOfDay(for: row.date)
            let candidates = clusters.indices.compactMap { index -> (Int, Int)? in
                let start = calendar.startOfDay(for: clusters[index].rows.first!.date)
                let end = calendar.startOfDay(for: clusters[index].rows.last!.date)
                if day >= start && day <= end { return (index, 0) }
                let lead = calendar.dateComponents([.day], from: day, to: start).day ?? 99
                return lead > 0 && lead <= 21 ? (index, lead) : nil
            }
            if let best = candidates.min(by: { $0.1 < $1.1 }) {
                travelByTrip[best.0, default: []].append(row)
            } else {
                unassignedTravel.append(row)
            }
            used.insert(row.id)
        }
        let trips = clusters.enumerated().map { index, cluster in
            Trip(city: cluster.city,
                 start: cluster.rows.first!.date,
                 end: cluster.rows.last!.date,
                 travel: (travelByTrip[index] ?? []).map(line).sorted { $0.amount > $1.amount },
                 local: cluster.rows.map(line).sorted { $0.amount > $1.amount })
        }.sorted { $0.total > $1.total }

        // Everything else, by what it was for. A transfer is read by its
        // concept ("TIGRES VS TOLUCA", "TOTAL PASS") instead of "terceros".
        var buckets: [String: [Line]] = [:]
        for row in rows where !used.contains(row.id) {
            buckets[bucket(for: row, category: category), default: []].append(line(row))
        }
        for row in unassignedTravel { buckets["Viajes", default: []].append(line(row)) }
        let groups = buckets.map { Group(name: $0.key, lines: $0.value.sorted { $0.amount > $1.amount }) }
            .filter { $0.total != 0 }
            .sorted { $0.total > $1.total }

        return MonthSpendingStory(
            total: total,
            trips: trips,
            groups: groups,
            summary: summary(total: total, trips: trips, groups: groups, partial: !coverageNotes.isEmpty),
            alerts: alerts(rows: rows, category: category) + coverageNotes.enumerated().map { Alert(id: "coverage-\($0.offset)", text: $0.element, movementIDs: []) }
        )
    }

    // MARK: - Reading a row

    static func line(_ row: Movement) -> Line {
        let title: String
        if isTransfer(row) {
            let concept = transferConcept(row)
            let recipient = transferRecipient(row)
            switch (concept, recipient) {
            case let (concept?, recipient?) where !concept.localizedCaseInsensitiveContains(recipient): title = "Transferencia: \(concept) · \(recipient)"
            case let (concept?, _): title = "Transferencia: \(concept)"
            case let (nil, recipient?): title = "Transferencia a \(recipient)"
            default: title = row.title
            }
        } else {
            title = cleanTitle(row.title)
        }
        return Line(id: row.id, date: row.date, title: title, amount: row.expenseContribution)
    }

    /// Bank card rows carry folios, card digits and RFCs around the merchant.
    static func cleanTitle(_ title: String) -> String {
        let folded = fold(title)
        if folded.contains("disp atm") || folded.contains("retiro en cajero") { return "Retiro en cajero" }
        if folded.contains("retiro sin tarjeta") || folded.contains("retiro efec") { return "Retiro sin tarjeta" }
        var text = title
        for (pattern, replacement) in [
            (#"^\d{5,}\s+"#, ""),
            (#"(?i)\bconsumo\s+(?:local|internacional)(?:\s+(?:ajeno|mc))?\s+terminacion\s+\d+\s+\S+\s*"#, ""),
            (#"(?i)\b[a-z&]{3,4}\s?\d{6}[a-z0-9]{3}\b"#, ""),
            (#"\b\d{6,}\b"#, ""),
            (#"(?i)\(moneda extranjera\)"#, ""),
            (#"\s+"#, " ")
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? title : text
    }

    static func bucket(for row: Movement, category: (Movement) -> String) -> String {
        if row.expenseContribution < 0 { return "Devoluciones y cashback" }
        let shown = category(row)
        if isTransfer(row) {
            let concept = transferConcept(row) ?? ""
            let fromConcept = concept.isEmpty ? "Otros / Por revisar" : FinanceStore.keywordCategory(for: concept)
            if !["Otros / Por revisar", "Transferencias a terceros"].contains(fromConcept) { return fromConcept }
            return shown == "Transferencias a terceros" || shown == "Otros / Por revisar" ? "Transferencias a personas" : shown
        }
        if shown == "Otros / Por revisar" {
            let guess = FinanceStore.keywordCategory(for: row.title)
            return guess == "Otros / Por revisar" ? "Sin clasificar" : guess
        }
        return shown
    }

    static func isTransfer(_ row: Movement) -> Bool {
        let text = fold(row.title + " " + (row.rawDescription ?? ""))
        return text.contains("spei") || text.contains("transferencia") || text.contains("transf rapida") || text.contains("cuenta de tercero")
    }

    /// The concept typed when the transfer was sent ("TIGRES VS TOLUCA").
    static func transferConcept(_ row: Movement) -> String? {
        let text = (row.rawDescription ?? row.title).replacingOccurrences(of: "\n", with: " ")
        var candidate: String?
        if let range = text.range(of: #"(?i)\bconcepto\s+(.+?)(?=\s+(?:rfc|ref|clave|iva|enviado|al cliente|a la cuenta|\d{2}-[a-z]{3}-\d{4})\b|$)"#, options: .regularExpression) {
            candidate = String(text[range]).replacingOccurrences(of: #"(?i)^concepto\s+"#, with: "", options: .regularExpression)
        } else if let range = text.range(of: #"(?i)transf(?:erencia)?\s+rapida\s+spei\s+(.+?)(?=\s+(?:rfc|rec|iva|ref)\b|$)"#, options: .regularExpression) {
            candidate = String(text[range]).replacingOccurrences(of: #"(?i)^transf(?:erencia)?\s+rapida\s+spei\s+"#, with: "", options: .regularExpression)
        }
        guard var concept = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !concept.isEmpty else { return nil }
        concept = concept.replacingOccurrences(of: #"(?i)^transferencia\s+a\s+"#, with: "", options: .regularExpression)
            .split(separator: " ").filter { !$0.contains(where: \.isNumber) }.joined(separator: " ")
            .replacingOccurrences(of: #"(?i)(?:\s+(?:de|a|la|el|y))+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard concept.count >= 2, fold(concept) != "transferencia" else { return nil }
        return titleCase(concept)
    }

    static func transferRecipient(_ row: Movement) -> String? {
        let text = (row.rawDescription ?? row.title).replacingOccurrences(of: "\n", with: " ")
        guard let range = text.range(of: #"(?i)\bal cliente\s+(.+?)(?=\s*\(|\s+(?:clave|ref|concepto|rfc)\b|$)"#, options: .regularExpression) else { return nil }
        let name = String(text[range]).replacingOccurrences(of: #"(?i)^al cliente\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : titleCase(name)
    }

    // MARK: - Places

    private static let cities: [(name: String, markers: [String])] = [
        ("Ciudad de México", ["ciudad de mex", "mexico df", "mexico city", "cdmx", "benito juarez", "cuauhtemoc", "miguel hidalg", "alvaro obregon", "coyoacan", "tlalpan", "azcapotzalco", "iztapalapa", "gustavo a madero", "venustiano", "cuajimalpa", "xochimilco", "iztacalco", "tlahuac", "magdalena contreras"]),
        ("Monterrey", ["monterrey", "sn nicolas", "san nicolas de", "guadalupe nvo", "san pedro garza", "apodaca", "escobedo"]),
        ("Guadalajara", ["guadalajara", "zapopan", "tlaquepaque", "tonala jal"]),
        ("Morelia", ["morelia"]),
        ("Querétaro", ["queretaro"]),
        ("Puebla", ["puebla"]),
        ("Oaxaca", ["oaxaca"]),
        ("Mérida", ["merida"]),
        ("Cancún y Riviera Maya", ["cancun", "playa del carmen", "tulum", "cozumel", "puerto morelos"]),
        ("Puerto Vallarta", ["puerto vallarta", "vallarta"]),
        ("Los Cabos", ["cabo san lucas", "san jose del cabo", "los cabos"]),
        ("Acapulco", ["acapulco"]),
        ("Tijuana", ["tijuana"]),
        ("León", ["leon gto", "leon guanajuato"]),
        ("Guanajuato", ["guanajuato", "san miguel de allende"]),
        ("Valle de Bravo", ["valle de bravo"]),
        ("Cuernavaca", ["cuernavaca"]),
        ("Veracruz", ["veracruz"]),
        ("Nueva York", ["new york", "brooklyn", "manhattan", "queens ny"]),
        ("Miami", ["miami"]),
        ("Los Ángeles", ["los angeles"]),
        ("Las Vegas", ["las vegas"]),
        ("Medellín", ["medellin"]),
        ("Bogotá", ["bogota"]),
        ("Madrid", ["madrid"]),
        ("Barcelona", ["barcelona"]),
        ("París", ["paris"]),
        ("Londres", ["london"])
    ]

    /// Online services print their billing city, not where you were.
    private static let onlineMarkers = ["http", "www", ".com", "cloudflare", "google", "apple", "uber", "airbnb", "booking", "netflix", "spotify", "amazon", "openai", "anthropic", "github", "canva", "playstation", "paypal", "steam", "microsoft", "adobe", "notion", "figma", "vercel", "shein", "temu", "aliexpress"]

    private static let travelMarkers = ["volaris", "vivaaerobus", "viva aerobus", "aeromexico", "aerobus", "interjet", "united airlines", "american airlines", "delta air", "avianca", "iberia", "flecha amarilla", "primera plus", "etn turistar", "autobuses", "omnibus", "estrella blanca", " ado ", "airbnb", "booking", "expedia", "hotel", "hostal", "hostel", "marriott", "hilton", "hyatt", "despegar", "vuelo", "flight"]

    static func city(of row: Movement) -> String? {
        guard !isTransfer(row), !isTravelProvider(row) else { return nil }
        let text = " " + fold(row.title + " " + (row.rawDescription ?? "")) + " "
        guard !onlineMarkers.contains(where: { text.contains($0) }) else { return nil }
        if let match = cities.first(where: { city in city.markers.contains { text.contains($0) } }) { return match.name }
        // Card terminals print the state at the end: "... MONTERREY NL".
        if text.range(of: #"\s(nl|n\.l\.)\s*$"#, options: .regularExpression) != nil { return "Monterrey" }
        if text.range(of: #"\s(df|d\.f\.)\s*$"#, options: .regularExpression) != nil { return "Ciudad de México" }
        return nil
    }

    static func isTravelProvider(_ row: Movement) -> Bool {
        let text = " " + fold(row.title) + " "
        return travelMarkers.contains { text.contains($0) }
    }

    static func homeCity(_ rows: [Movement]) -> String? {
        let counts = rows.compactMap(city(of:)).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }

    // MARK: - Words

    private static func summary(total: Decimal, trips: [Trip], groups: [Group], partial: Bool) -> [String] {
        guard total > 0 else { return ["Este mes no tiene gastos registrados."] }
        var sentences = [partial
            ? "Llevas \(money(total)) de gasto registrado con los datos que tienes cargados."
            : "Gastaste \(money(total)) este mes."]
        if !trips.isEmpty {
            let tripsTotal = trips.reduce(Decimal(0)) { $0 + $1.total }
            let share = Int((NSDecimalNumber(decimal: tripsTotal / total).doubleValue * 100).rounded())
            let names = trips.map { "\($0.city) (\(money($0.total)))" }
            sentences.append("\(share)% se fue en \(trips.count == 1 ? "un viaje" : "\(trips.count) viajes"): \(list(names)).")
        }
        let daily = groups.filter { $0.total > 0 && !["Devoluciones y cashback", "Sin clasificar"].contains($0.name) }
        if let first = daily.first {
            let second = daily.dropFirst().first
            sentences.append("En el día a día, lo que más pesa es \(first.name.lowercased()) (\(money(first.total)))" + (second.map { ", seguido de \($0.name.lowercased()) (\(money($0.total)))." } ?? "."))
        }
        if let biggest = groups.flatMap(\.lines).max(by: { $0.amount < $1.amount }), biggest.amount >= total / 10 {
            sentences.append("El cargo más grande fue \(biggest.title) por \(money(biggest.amount)) el \(day(biggest.date)).")
        }
        return sentences
    }

    private static let recurringServices: [(name: String, markers: [String])] = [
        ("TotalPass", ["total pass", "totalpass"]), ("Smart Fit", ["smart fit", "smartfit"]), ("Sport City", ["sport city"]),
        ("Netflix", ["netflix"]), ("Spotify", ["spotify"]), ("Disney+", ["disney"]), ("Max", ["hbo"]),
        ("Prime Video", ["prime video"]), ("ChatGPT", ["chatgpt", "openai"]), ("Claude", ["anthropic", "claude ai"])
    ]

    private static func alerts(rows: [Movement], category: (Movement) -> String) -> [Alert] {
        var result: [Alert] = []
        let charges = rows.filter { $0.expenseContribution > 0 }
        for service in recurringServices {
            let matches = charges.filter { row in
                let text = fold(row.title + " " + (row.rawDescription ?? ""))
                return service.markers.contains { text.contains($0) }
            }
            let sum = matches.reduce(Decimal(0)) { $0 + $1.expenseContribution }
            guard matches.count >= 2, Set(matches.map(\.account)).count >= 2 || matches.count >= 3 else { continue }
            result.append(Alert(id: "repeat-\(service.name)",
                text: "\(service.name) aparece \(matches.count) veces (\(money(sum))). ¿Alguno fue de otra persona o se pagó doble?",
                movementIDs: matches.map(\.id)))
        }
        for row in charges where isTransfer(row) && row.expenseContribution >= 1_000 {
            guard bucket(for: row, category: category) == "Transferencias a personas" else { continue }
            let who = line(row).title
            result.append(Alert(id: "transfer-\(row.id)",
                text: "\(who) por \(money(row.expenseContribution)) el \(day(row.date)): ¿qué fue? Si no fue gasto tuyo, ábrelo y elige quién lo gastó.",
                movementIDs: [row.id]))
        }
        return result
    }

    static func money(_ value: Decimal) -> String {
        value.formatted(.currency(code: "MXN").precision(.fractionLength(0)).locale(Locale(identifier: "es_MX")))
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "es_MX"); formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    static func range(_ start: Date, _ end: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(start, inSameDayAs: end) { return day(start) }
        if calendar.isDate(start, equalTo: end, toGranularity: .month) {
            return "\(calendar.component(.day, from: start))–\(day(end))"
        }
        return "\(day(start)) – \(day(end))"
    }

    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " y " + items.last!
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_MX")).lowercased()
    }

    private static func titleCase(_ text: String) -> String {
        text.lowercased().split(separator: " ").enumerated().map { index, word in
            index > 0 && ["de", "del", "la", "las", "los", "el", "y", "a"].contains(String(word)) ? String(word) : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}
