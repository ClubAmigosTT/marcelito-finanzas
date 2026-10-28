import SwiftUI

/// "¿En qué se fue tu mes?": the month's spending told as trips, what each
/// group of charges was for, and what deserves a second look.
struct MonthStoryCard: View {
    @Environment(FinanceStore.self) private var store
    @Environment(FinancialPlanningStore.self) private var planning
    let rows: [Movement]
    let period: FinancePeriod
    let account: String?

    private var story: MonthSpendingStory {
        let historyStart = Calendar.current.date(byAdding: .day, value: -120, to: period.end) ?? period.start
        let history = store.netExpenseMovements.filter { $0.date >= historyStart && $0.date < period.end }
        return MonthSpendingStory.build(rows: rows, history: history, category: { planning.category($0) }, coverageNotes: coverageNotes)
    }

    /// Accounts whose statements stop before this month (or today) ends.
    private var coverageNotes: [String] {
        let calendar = Calendar.current
        let expectedEnd = calendar.startOfDay(for: min(Date.now, period.end.addingTimeInterval(-1)))
        let sources = Set(store.statements.map(\.source)).filter { account == nil || $0 == account }
        let graceEnd = calendar.date(byAdding: .day, value: -2, to: expectedEnd) ?? expectedEnd
        return sources.sorted().compactMap { source in
            let covered = store.spendingCoveredDays(account: source)
            // Some periods ("16-sep-2026 al 15-oct-2026") do not yield covered
            // days; the account's own rows still show how far its data goes.
            let lastRow = store.movements.lazy.filter { $0.account == source && self.period.contains($0.date) }.map(\.date).max()
            guard let last = covered.filter({ period.contains($0) }).max() ?? lastRow.map({ calendar.startOfDay(for: $0) }) else {
                let before = covered.contains { $0 < period.start && $0 >= (calendar.date(byAdding: .month, value: -1, to: period.start) ?? period.start) }
                return before ? "\(source): todavía no hay datos de este mes." : nil
            }
            guard last < graceEnd else { return nil }
            return "\(source): datos hasta el \(MonthSpendingStory.day(last)). Lo que gastaste después con esta cuenta aún no aparece."
        }
    }

    var body: some View {
        let story = story
        VStack(alignment: .leading, spacing: 14) {
            Text("¿En qué se fue tu mes?").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(story.summary, id: \.self) { Text($0).font(.subheadline).fixedSize(horizontal: false, vertical: true) }
            }
            if !story.trips.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Viajes y salidas · \(MonthSpendingStory.money(story.tripsTotal))").font(.subheadline.weight(.semibold))
                    ForEach(story.trips) { trip in
                        DisclosureGroup {
                            if !trip.travel.isEmpty { lineSection("Vuelo, autobús y hospedaje", trip.travel) }
                            lineSection("En \(trip.city)", trip.local)
                        } label: {
                            amountRow("\(trip.city) · \(MonthSpendingStory.range(trip.start, trip.end))", trip.total, bold: true)
                        }
                    }
                    if story.trips.contains(where: { !$0.travel.isEmpty }) {
                        Text("Los vuelos, autobuses y hospedajes se asignan al viaje más cercano por fecha.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(story.trips.isEmpty ? "Por tipo de gasto" : "El resto del mes").font(.subheadline.weight(.semibold))
                ForEach(story.groups) { group in
                    DisclosureGroup {
                        lineSection(nil, group.lines)
                    } label: {
                        amountRow("\(group.name) · \(group.lines.count)", group.total, bold: false)
                    }
                }
            }
            if !story.alerts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Para revisar").font(.subheadline.weight(.semibold))
                    ForEach(story.alerts) { alert in
                        if alert.movementIDs.count == 1, let movement = store.movements.first(where: { $0.id == alert.movementIDs[0] }) {
                            NavigationLink { MovementDetailView(movement: movement) } label: { alertLabel(alert.text) }
                                .buttonStyle(.plain)
                        } else {
                            alertLabel(alert.text)
                        }
                    }
                }
            }
            Text("Calculado en tu iPhone con tus estados y capturas; no se envía a ningún servicio.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .marcelitoCard(radius: 20, padding: 14)
    }

    private func amountRow(_ title: String, _ amount: Decimal, bold: Bool) -> some View {
        HStack {
            Text(title).font(bold ? .subheadline.weight(.semibold) : .subheadline).multilineTextAlignment(.leading)
            Spacer()
            Text(MonthSpendingStory.money(amount)).font(.subheadline).monospacedDigit()
        }
    }

    @ViewBuilder
    private func lineSection(_ title: String?, _ lines: [MonthSpendingStory.Line]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            ForEach(lines) { line in
                if let movement = store.movements.first(where: { $0.id == line.id }) {
                    NavigationLink { MovementDetailView(movement: movement) } label: { lineRow(line) }
                        .buttonStyle(.plain)
                } else {
                    lineRow(line)
                }
            }
        }
        .padding(.top, 4)
    }

    private func lineRow(_ line: MonthSpendingStory.Line) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(MonthSpendingStory.day(line.date)).font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            Text(line.title).font(.caption).lineLimit(2)
            Spacer()
            Text(MonthSpendingStory.money(line.amount)).font(.caption).monospacedDigit()
        }
    }

    private func alertLabel(_ text: String) -> some View {
        Label { Text(text).font(.caption).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Color.marcelitoAmber)
        }
    }
}
