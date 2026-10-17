import SwiftUI

/// Horizontal intent must dominate vertical scrolling. Attach this to a
/// non-editing surface, never a budget slider or an account-card carousel.
struct PeriodSwipeNavigation: ViewModifier {
    let move: (Int) -> Void
    func body(content: Content) -> some View {
        content.simultaneousGesture(DragGesture(minimumDistance: 25).onEnded { value in
            if let direction = periodSwipeDirection(horizontal: Double(value.translation.width), vertical: Double(value.translation.height)) { move(direction) }
        })
    }
}
func periodSwipeDirection(horizontal: Double, vertical: Double) -> Int? {
    guard abs(horizontal) >= 70, abs(horizontal) > abs(vertical) * 2 else { return nil }
    return horizontal < 0 ? 1 : -1
}
struct PeriodNavigationBar: View {
    let label: String
    let move: (Int) -> Void
    let choose: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("Periodo anterior")
            Spacer(minLength: 0)
            Button(action: choose) { HStack(spacing: 6) { Text(label).font(.subheadline.weight(.semibold)); Image(systemName: "chevron.down").font(.caption2) } }
                .accessibilityLabel("Elegir periodo: " + label)
            Spacer(minLength: 0)
            Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("Periodo siguiente")
        }.buttonStyle(.plain).foregroundStyle(Color.marcelitoNavy)
            .contentShape(Rectangle()).modifier(PeriodSwipeNavigation(move: move))
            .accessibilityAction(named: "Periodo anterior") { move(-1) }
            .accessibilityAction(named: "Periodo siguiente") { move(1) }
    }
}
struct PeriodSelectionSheet: View {
    let mode: FinancePeriodMode
    let date: Date
    let choose: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedYear = Calendar.current.component(.year, from: .now)
    @State private var selectedDay = Date.now
    private var years: [Int] { Array((min(2000, selectedYear - 1))...max(Calendar.current.component(.year, from: .now) + 5, selectedYear + 1)) }
    var body: some View {
        NavigationStack {
            Form {
                if mode == .year || mode == .month {
                    Picker("Año", selection: $selectedYear) { ForEach(years.reversed(), id: \.self) { Text(String($0)).tag($0) } }
                    if mode == .month {
                        ForEach(1...12, id: \.self) { month in
                            let value = Calendar.current.date(from: DateComponents(year: selectedYear, month: month, day: 1))!
                            Button { choose(value); dismiss() } label: {
                                HStack { Text(monthName(value).capitalized); Spacer(); if Calendar.current.isDate(date, equalTo: value, toGranularity: .month) { Image(systemName: "checkmark") } }
                            }
                        }
                    } else {
                        Button("Ver \(String(selectedYear))") { choose(Calendar.current.date(from: DateComponents(year: selectedYear, month: 1, day: 1))!); dismiss() }
                    }
                } else {
                    DatePicker("Fecha", selection: $selectedDay, displayedComponents: .date).datePickerStyle(.graphical)
                    Button("Ver periodo") { choose(selectedDay); dismiss() }
                }
            }.navigationTitle("Elegir periodo").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cerrar") { dismiss() } } }
        }.onAppear { selectedYear = Calendar.current.component(.year, from: date); selectedDay = date }
            .environment(\.locale, Locale(identifier: "es_MX"))
    }
}
