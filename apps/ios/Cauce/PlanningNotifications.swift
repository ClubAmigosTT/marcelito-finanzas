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
    /// Day on which a "pay in three days" reminder fires at 09:00. Comparing
    /// midnight of due − 3 with the current time skipped the 09:00 reminder
    /// on that same morning, and a statement imported less than three days
    /// before the due date never produced one. Then remind at the next 09:00,
    /// as long as it is not after the due date.
    static func paymentReminderDay(due: Date, now: Date = .now, calendar c: Calendar = .current) -> Date? {
        guard let ideal = c.date(byAdding: .day, value: -3, to: c.startOfDay(for: due)),
              let idealAtNine = c.date(bySettingHour: 9, minute: 0, second: 0, of: ideal) else { return nil }
        if idealAtNine > now { return ideal }
        guard let todayAtNine = c.date(bySettingHour: 9, minute: 0, second: 0, of: now),
              let next = todayAtNine > now ? todayAtNine : c.date(byAdding: .day, value: 1, to: todayAtNine),
              c.startOfDay(for: next) <= c.startOfDay(for: due) else { return nil }
        return c.startOfDay(for: next)
    }

    /// "vence hoy" / "vence mañana" / "vence en N días", measured from the day
    /// the reminder fires.
    static func dueLabel(due: Date, reminderDay: Date, calendar c: Calendar = .current) -> String {
        let days = c.dateComponents([.day], from: c.startOfDay(for: reminderDay), to: c.startOfDay(for: due)).day ?? 3
        return days <= 0 ? "vence hoy" : days == 1 ? "vence mañana" : "vence en \(days) días"
    }

    /// Issuers usually publish the PDF one to two days after the cutoff.
    static func statementReadyDay(cutoff: Date, calendar c: Calendar = .current) -> Date? {
        c.date(byAdding: .day, value: 2, to: c.startOfDay(for: cutoff))
    }

    @MainActor static func refresh(store: FinanceStore, planning: FinancialPlanningStore) async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.pendingNotificationRequests()
        guard planning.state.remindersEnabled else {
            center.removePendingNotificationRequests(withIdentifiers: existing.map(\.identifier).filter { $0.hasPrefix(prefix) }); return
        }
        center.removePendingNotificationRequests(withIdentifiers: existing.map(\.identifier).filter { $0.hasPrefix(prefix + "cutoff.") || $0.hasPrefix(prefix + "payment.") || $0.hasPrefix(prefix + "loan.") })
        let c = Calendar.current
        let grouped = Dictionary(grouping: store.statements, by: { $0.accountKey ?? $0.source })
        var requests: [(Date, String, String, String)] = []
        for (key, statements) in grouped {
            guard let statement = statements.max(by: { (store.statementCutoffDate(for: $0.id) ?? .distantPast) < (store.statementCutoffDate(for: $1.id) ?? .distantPast) }) else { continue }
            let kind = statement.kind ?? .unknown
            let status = store.accountStatementStatus(for: statement.source, kind: kind, accountKey: statement.accountKey)
            if let cutoff = status.nextCutoff, let date = statementReadyDay(cutoff: cutoff) {
                if let fireAt = c.date(bySettingHour: 9, minute: 0, second: 0, of: date), fireAt > .now {
                    let label = statement.accountKey.flatMap { $0.split(separator: ":").last.map { " ••" + $0 } } ?? ""
                    requests.append((date, "cutoff.\(key)", "Ya cortó tu \(statement.source)\(label)", "Sube el PDF del nuevo estado para que tus gastos y tu disponible estén completos."))
                } else if status.state == .due {
                    let sentKey = prefix + "cutoff.\(key).\(cutoff.timeIntervalSince1970).sent"
                    if !UserDefaults.standard.bool(forKey: sentKey) {
                        let content = UNMutableNotificationContent(); content.title = "Actualiza tu cuenta"; content.body = "Sube el nuevo estado de \(statement.source); ya pasó su fecha de corte."; content.userInfo = ["destination": "accounts"]
                        do { try await center.add(UNNotificationRequest(identifier: prefix + "overdue.\(key)", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))); UserDefaults.standard.set(true, forKey: sentKey) } catch {}
                    }
                }
            }
            let terms = planning.state.cardTerms[key].flatMap { $0.statementID == statement.id ? $0 : nil }
            if kind == .card, let due = terms?.dueDate ?? statement.summary?.paymentDueDate,
               let date = paymentReminderDay(due: due) {
                let payment = store.cyclePayment(statement, planning: planning)
                if payment?.remaining == 0 { continue }
                let amount = payment.map { planningMoney($0.remaining) } ?? statement.summary?.paymentForNoInterest.map(planningMoney) ?? "el importe de tu estado"
                requests.append((date, "payment.\(key)", "Tu pago \(dueLabel(due: due, reminderDay: date))", "Revisa \(statement.source): paga \(amount) antes de la fecha límite para no generar intereses. Si ya pagaste, confirma en tu banco."))
            }
        }
        for account in store.loanLedger.state.accounts {
            guard let statement = account.latest else { continue }
            for item in statement.installments where statement.remaining(item) > Decimal(string: "0.05")! {
                guard let reminder = paymentReminderDay(due: item.dueDate) else { continue }
                let amount = store.loanLedger.quote().map { "~" + planningMoney(statement.remaining(item) * $0.value) } ?? "\(statement.remaining(item)) UDIS"
                requests.append((reminder, "loan.\(account.id).\(item.number)", "Tu préstamo \(dueLabel(due: item.dueDate, reminderDay: reminder))", "\(account.name) · cuota \(item.number): \(amount). Revisa el estado y los abonos confirmados."))
            }
        }
        for (date, id, title, body) in requests.sorted(by: { $0.0 < $1.0 }).prefix(40) {
            let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
            content.userInfo = ["destination": id.hasPrefix("cutoff.") ? "accounts" : "payments"]
            var components = c.dateComponents([.year, .month, .day], from: date); components.hour = 9
            try? await center.add(UNNotificationRequest(identifier: prefix + id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
        }
        // Day 1, 09:00: the previous month's summary is ready on Inicio.
        if let nextMonth = c.date(byAdding: .month, value: 1, to: FinancePeriod.month(.now).start) {
            var components = c.dateComponents([.year, .month, .day], from: nextMonth)
            components.hour = 9
            let content = UNMutableNotificationContent()
            content.title = "Tu resumen de \(monthName(.now)) está listo"
            content.body = "Ingreso, gasto, ahorro y las 3 categorías que más cambiaron. Ábrelo en Inicio."
            content.sound = .default; content.userInfo = ["destination": "home"]
            try? await center.add(UNNotificationRequest(identifier: prefix + "summary." + planning.monthKey(nextMonth), content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
        }
        // New unusual charges: one notification per batch, never repeated.
        let unseen = store.unusualCharges().filter { !UserDefaults.standard.bool(forKey: prefix + "unusual." + $0.id + ".sent") }
        if let first = unseen.first {
            let content = UNMutableNotificationContent()
            content.title = unseen.count == 1 ? "Un cargo para revisar" : "\(unseen.count) cargos para revisar"
            content.body = unseen.count == 1 ? "\(first.movement.title): \(first.message)" : "Posibles duplicados, aumentos de precio o comisiones nuevas. Revísalos en Inicio."
            content.sound = .default; content.userInfo = ["destination": "home"]
            do {
                try await center.add(UNNotificationRequest(identifier: prefix + "unusual." + first.id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)))
                for charge in unseen { UserDefaults.standard.set(true, forKey: prefix + "unusual." + charge.id + ".sent") }
            } catch { /* retry on the next refresh */ }
        }
        let limits = planning.limits(store, month: .now)
        let actual = planning.budgetCategoryTotals(store, period: .month(.now), fixed: false)
        // Pace: once per category and month, when a category runs well ahead
        // of how it is usually spent by today.
        let today = c.component(.day, from: .now)
        let daysInMonth = c.range(of: .day, in: .month, for: .now)?.count ?? 30
        if today >= 5, planning.plan(for: .now).limits.values.contains(where: { $0 > 0 }) || planning.carriesPreviousPlan(.now) {
            let alerts = planning.monthPlanAdvice(store, month: .now).paceAlerts(limits: limits, spent: actual, day: today, daysInMonth: daysInMonth)
            for alert in alerts where alert.spent >= alert.expected * Decimal(string: "1.25")! && alert.spent - alert.expected >= 500 {
                let digest = SHA256.hash(data: Data(alert.category.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
                let id = prefix + "pace.\(planning.monthKey(.now)).\(digest)"
                guard !UserDefaults.standard.bool(forKey: id + ".sent") else { continue }
                let content = UNMutableNotificationContent(); content.title = "Vas adelantado en \(alert.category.lowercased())"; content.body = alert.message(day: today); content.sound = .default; content.userInfo = ["destination": "budget"]
                do {
                    try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)))
                    UserDefaults.standard.set(true, forKey: id + ".sent")
                } catch { /* retry on the next refresh */ }
                break
            }
        }
        guard today < 20 else { return }
        for (category, limit) in limits where limit > 0 && actual[category, default: 0] >= limit * Decimal(string: "0.8")! {
            let digest = SHA256.hash(data: Data(category.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            let id = prefix + "budget.\(planning.monthKey(.now)).\(digest)"
            let sentKey = id + ".sent"
            guard !UserDefaults.standard.bool(forKey: sentKey) else { continue }
            let content = UNMutableNotificationContent(); content.title = "Revisa tu ritmo de gasto"; content.body = "\(category): usaste al menos el 80% antes del día 20."; content.sound = .default; content.userInfo = ["destination": "budget"]
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

final class PlanningNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PlanningNotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let destination = response.notification.request.content.userInfo["destination"] as? String ?? "payments"
        UserDefaults.standard.set(destination, forKey: "marcelito.navigation.pending")
        DispatchQueue.main.async { NotificationCenter.default.post(name: Notification.Name("marcelito.notification.route"), object: nil) }
        completionHandler()
    }
}
