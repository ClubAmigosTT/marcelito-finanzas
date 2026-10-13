import SwiftUI
import UserNotifications
import CryptoKit

enum PlanningNotifications {
    static let prefix = "marcelito.plan."
    @MainActor static func enable(store: FinanceStore, planning: FinancialPlanningStore) async -> Bool {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            planning.state.remindersEnabled = allowed; planning.save()
            if allowed { await refresh(store: store, planning: planning) }
            return allowed
        } catch { return false }
    }
    @MainActor static func refresh(store: FinanceStore, planning: FinancialPlanningStore) async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.pendingNotificationRequests()
        guard planning.state.remindersEnabled else {
            center.removePendingNotificationRequests(withIdentifiers: existing.map(\.identifier).filter { $0.hasPrefix(prefix) }); return
        }
        center.removePendingNotificationRequests(withIdentifiers: existing.map(\.identifier).filter { $0.hasPrefix(prefix + "cutoff.") || $0.hasPrefix(prefix + "payment.") })
        let c = Calendar.current
        let grouped = Dictionary(grouping: store.statements, by: { $0.accountKey ?? $0.source })
        var requests: [(Date, String, String, String)] = []
        for (key, statements) in grouped {
            guard let statement = statements.first else { continue }
            let kind = statement.kind ?? .unknown
            let status = store.accountStatementStatus(for: statement.source, kind: kind, accountKey: statement.accountKey)
            if let cutoff = status.nextCutoff, let date = c.date(byAdding: .day, value: 1, to: cutoff) {
                if date > .now {
                    requests.append((date, "cutoff.\(key)", "Sube tu nuevo estado", "Ya pasó el corte de \(statement.source). Actualiza sus movimientos para revisar tu disponible."))
                } else if status.state == .due {
                    let sentKey = prefix + "cutoff.\(key).\(cutoff.timeIntervalSince1970).sent"
                    if !UserDefaults.standard.bool(forKey: sentKey) {
                        let content = UNMutableNotificationContent(); content.title = "Actualiza tu cuenta"; content.body = "Sube el nuevo estado de \(statement.source); ya pasó su fecha de corte."
                        do { try await center.add(UNNotificationRequest(identifier: prefix + "overdue.\(key)", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))); UserDefaults.standard.set(true, forKey: sentKey) } catch {}
                    }
                }
            }
            let terms = planning.state.cardTerms[key].flatMap { $0.statementID == statement.id ? $0 : nil }
            if kind == .card, let due = terms?.dueDate ?? statement.summary?.paymentDueDate,
               let date = c.date(byAdding: .day, value: -3, to: due), date > .now {
                let amount = statement.summary?.paymentForNoInterest.map(planningMoney) ?? "el importe de tu estado"
                requests.append((date, "payment.\(key)", "Tu pago vence en tres días", "Revisa \(statement.source): paga \(amount) antes de la fecha límite para no generar intereses. Si ya pagaste, confirma en tu banco."))
            }
        }
        for (date, id, title, body) in requests.sorted(by: { $0.0 < $1.0 }).prefix(40) {
            let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
            var components = c.dateComponents([.year, .month, .day], from: date); components.hour = 9
            try? await center.add(UNNotificationRequest(identifier: prefix + id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
        }
        let limits = planning.limits(store, month: .now)
        let actual = planning.budgetCategoryTotals(store, period: .month(.now), fixed: false)
        guard c.component(.day, from: .now) < 20 else { return }
        for (category, limit) in limits where limit > 0 && actual[category, default: 0] >= limit * Decimal(string: "0.8")! {
            let digest = SHA256.hash(data: Data(category.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            let id = prefix + "budget.\(planning.monthKey(.now)).\(digest)"
            let sentKey = id + ".sent"
            guard !UserDefaults.standard.bool(forKey: sentKey) else { continue }
            let content = UNMutableNotificationContent(); content.title = "Revisa tu ritmo de gasto"; content.body = "\(category): usaste al menos el 80% antes del día 20."; content.sound = .default
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)))
                UserDefaults.standard.set(true, forKey: sentKey)
            } catch { /* preserve unsent state for a subsequent retry */ }
        }
    }
}
struct PlanningReminderToggle: View {
    @Environment(FinancialPlanningStore.self) private var planning
    @Environment(FinanceStore.self) private var store
    @State private var denied = false
    var body: some View {
        Toggle("Recordatorios de corte, pago y presupuesto", isOn: Binding(get: { planning.state.remindersEnabled }, set: { enabled in
            if enabled { Task { denied = !(await PlanningNotifications.enable(store: store, planning: planning)) } }
            else { planning.state.remindersEnabled = false; planning.save(); Task { await PlanningNotifications.refresh(store: store, planning: planning) } }
        })).font(.caption)
            .alert("Activa las notificaciones", isPresented: $denied) { Button("Aceptar", role: .cancel) {} } message: { Text("Permite notificaciones para Marcelito en Ajustes del iPhone para recibir recordatorios.") }
    }
}
