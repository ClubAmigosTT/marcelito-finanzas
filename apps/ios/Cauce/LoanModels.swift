import Foundation
import CryptoKit

// Loan evidence has its own versioned book. A bank/PDF rebuild never replaces it.
// All amounts remain in the statement's native UDIS; MXN quotes are explicitly dated.
struct LoanInstallment: Sendable, Codable, Identifiable, Equatable {
    var id: Int { number }
    let number: Int
    let dueDate: Date
    let reportedStatus: String
    let total: Decimal
    let principal: Decimal
    let interest: Decimal
}
struct LoanAllocation: Sendable, Codable, Equatable {
    let installment: Int
    let date: Date
    let mxn: Decimal
    let udis: Decimal
    let principalMXN: Decimal
    let principalUDIS: Decimal
    let interestMXN: Decimal
    let interestUDIS: Decimal
    let folio: String
}
struct LoanReceipt: Sendable, Identifiable, Equatable {
    let id: String
    let date: Date
    let folio: String
    let allocations: [LoanAllocation]
    var total: Decimal { allocations.reduce(0) { $0 + $1.mxn } }
    var principal: Decimal { allocations.reduce(0) { $0 + $1.principalMXN } }
    var interest: Decimal { allocations.reduce(0) { $0 + $1.interestMXN } }
    var installments: [Int] { Array(Set(allocations.map(\.installment))).sorted() }
}
struct LoanStatement: Sendable, Codable, Identifiable, Equatable {
    var id: String // SHA256 of the original PDF, not its name
    let accountID: String
    let asOf: Date
    let filename: String
    let installments: [LoanInstallment]
    let allocations: [LoanAllocation]
    let principalRemaining: Decimal
    let scheduledInterestRemaining: Decimal
    let scheduledTotalRemaining: Decimal
    var receipts: [LoanReceipt] {
        // The issuer spreads ONE receipt over multiple installments. Generic
        // MOVIMIENTO rows are retained as individual evidence, not merged by name.
        let groups = Dictionary(grouping: allocations.enumerated().map { ($0.offset, $0.element) }) { pair in
            let row = pair.1
            return "\(LoanMath.dayKey(row.date))|\(row.folio)|\(row.folio == "MOVIMIENTO" ? String(pair.0) : "")"
        }
        return groups.map { key, rows in
            LoanReceipt(id: LoanMath.hash(accountID + "|" + key), date: rows[0].1.date, folio: rows[0].1.folio, allocations: rows.map(\.1))
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
    func paid(_ installment: LoanInstallment) -> Decimal {
        allocations.filter { $0.installment == installment.number }.reduce(0) { $0 + $1.udis }
    }
    func remaining(_ installment: LoanInstallment) -> Decimal { max(0, installment.total - paid(installment)) }
    var overdue: [LoanInstallment] { installments.filter { $0.reportedStatus == "Vencido" && remaining($0) > Decimal(string: "0.05")! } }
    var overdueTotal: Decimal { overdue.reduce(0) { $0 + remaining($1) } }
    var accruedUnpaidInterest: Decimal {
        installments.filter { $0.dueDate <= asOf }.reduce(0) { total, installment in
            let paid = allocations.filter { $0.installment == installment.number }.reduce(Decimal(0)) { $0 + $1.interestUDIS }
            return total + max(0, installment.interest - paid)
        }
    }
    var recognizedDebt: Decimal { principalRemaining + accruedUnpaidInterest }
    func status(_ installment: LoanInstallment, now: Date = .now) -> String {
        if remaining(installment) <= Decimal(string: "0.05")! {
            let lastPayment = allocations.filter { $0.installment == installment.number }.map(\.date).max()
            return lastPayment.map { $0 > installment.dueDate } == true ? "Pagada con atraso" : "Pagada"
        }
        if installment.reportedStatus == "Vencido" { return paid(installment) > 0 ? "Vencida · abono parcial" : "Vencida" }
        if installment.dueDate > asOf && installment.dueDate < Calendar.current.startOfDay(for: now) { return "Sin pago confirmado · actualiza el estado" }
        return paid(installment) > 0 ? "Abono parcial" : "Pendiente"
    }
}
struct LoanAccount: Sendable, Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var statements: [LoanStatement]
    var latest: LoanStatement? { statements.max { $0.asOf < $1.asOf } }
}
struct LoanUDIQuote: Sendable, Codable, Equatable {
    let date: Date
    let value: Decimal
    let source: String
}
struct LoanBankLink: Sendable, Codable, Equatable {
    let accountID: String
    let receiptID: String
    let movementID: UUID
    let identity: String
    let amount: Decimal
    let receiptPrincipal: Decimal
    let receiptInterest: Decimal
}
struct LoanState: Codable {
    var schema = 1
    var accounts: [LoanAccount] = []
    var quotes: [LoanUDIQuote] = []
    var links: [LoanBankLink] = []
    // A catch-up plan is an intention in MXN, never a payment or debt reduction.
    var catchUp: [String: Decimal] = [:]
}
struct LoanMonthlyReserve {
    let scheduled: Decimal?
    let extra: Decimal
    let paid: Decimal
    var reserved: Decimal? { scheduled.map { max($0 + extra, paid) } }
}
enum LoanError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
enum LoanMath {
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func day(_ value: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "es_MX"); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "dd/MM/yyyy"; f.isLenient = false
        return f.date(from: value)
    }
    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    static func monthKey(_ date: Date) -> String { String(dayKey(date).prefix(7)) }
    static func decimal(_ text: String) -> Decimal? { Decimal(string: text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: ""), locale: Locale(identifier: "en_US_POSIX")) }
    static func udiInput(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[0-9]{1,3}(?:[.,][0-9]{1,6})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: trimmed.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX"))
    }
    static func rounded(_ amount: Decimal) -> Decimal { var input = amount; var result = Decimal(); NSDecimalRound(&result, &input, 2, .plain); return result }
    static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern), let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
}

/// Strict text reader for the supplied ITAM amortization format. It refuses
/// partial/malformed schedules rather than importing a plausible-looking balance.
enum ITAMLoanReader {
    static func recognizes(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("SISTEMA DE AYUDAS FINANCIERAS") && text.localizedCaseInsensitiveContains("Amortización") && text.contains("UDIS")
    }
    static func parse(text: String, fingerprint: String, filename: String) throws -> LoanStatement {
        func fail(_ message: String) -> LoanError { .invalid(message) }
        guard recognizes(text), let dateText = LoanMath.captures(#"(?m)^\s*(\d{2}/\d{2}/\d{4})\s+\d{1,2}:\d{2}"#, text)?.first,
              let asOf = LoanMath.day(dateText), let key = LoanMath.captures(#"Clave\s+Única:\s*(\d+)"#, text)?.first,
              let totals = LoanMath.captures(#"Total\s+Pagos:\s*(\d+)\s+Pagados:\s*(\d+)"#, text),
              let expected = Int(totals[0]), expected > 0, expected <= 600 else { throw fail("No se reconoció un estado de préstamo ITAM completo en UDIS.") }
        guard let contract = LoanMath.captures(#"Fecha\s+de\s+Inicio:\s*(\d{2}/\d{2}/\d{4})\s+Fecha\s+de\s+Termino:\s*(\d{2}/\d{2}/\d{4})"#, text),
              LoanMath.day(contract[0]) != nil, LoanMath.day(contract[1]) != nil,
              let originalText = LoanMath.captures(#"Adeudo\s+Total\s+de\s+Capital:\s*([\d,]+\.\d{2})"#, text)?.first else { throw fail("Falta la identificación del contrato de préstamo. No se guardó una lectura parcial.") }
        // A student can have more than one loan. The student key alone is not a contract ID.
        let student = String(key.drop(while: { $0 == "0" }))
        let originalIdentity = LoanMath.decimal(originalText).map { NSDecimalNumber(decimal: $0).stringValue } ?? originalText
        let accountID = LoanMath.hash("ITAM|" + student + "|" + contract.joined(separator: "|") + "|" + originalIdentity)
        let number = #"([\d,]+\.\d{2})"#
        let installmentPattern = #"^\s*(\d+)\s+(\d{2}/\d{2}/\d{4})\s+(Pagado|Vencido|Por\s+Pagar)\s+"# + number + #"\s+"# + number + #"\s+"# + number + #"\s+\d+(?:\s|$)"#
        let paymentPattern = #"(\d{2}/\d{2}/\d{4})\s+\$"# + number + #"\s+"# + number + #"\s+\$"# + number + #"\s+"# + number + #"\s+\$"# + number + #"\s+"# + number + #"\s+(\d+|MOVIMIENTO)\s*$"#
        var installments: [LoanInstallment] = []; var allocations: [LoanAllocation] = []; var current: Int?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\u{00a0}", with: " ")
            if let row = LoanMath.captures(installmentPattern, line), let num = Int(row[0]), let date = LoanMath.day(row[1]), let total = LoanMath.decimal(row[3]), let capital = LoanMath.decimal(row[4]), let interest = LoanMath.decimal(row[5]) {
                guard abs(total - capital - interest) <= Decimal(string: "0.02")!, total > 0, capital >= 0, interest >= 0, !installments.contains(where: { $0.number == num }) else { throw fail("Una cuota no coincide con su capital e intereses. No se guardó el préstamo.") }
                installments.append(LoanInstallment(number: num, dueDate: date, reportedStatus: row[2].replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression), total: total, principal: capital, interest: interest)); current = num
            } else if LoanMath.captures(#"^\s*[1-9]\d*\s+\d{2}/\d{2}/\d{4}\s+(?:Pagado|Vencido|Por)"#, line) != nil {
                throw fail("No pudimos leer una cuota completa. Se conservaron tus datos anteriores.")
            }
            if let row = LoanMath.captures(paymentPattern, line), let installment = current, let date = LoanMath.day(row[0]) {
                let amounts = row[1...6].compactMap(LoanMath.decimal)
                guard amounts.count == 6, amounts.allSatisfy({ $0 >= 0 }), date <= asOf,
                      abs(amounts[0] - amounts[2] - amounts[4]) <= Decimal(string: "0.02")!,
                      abs(amounts[1] - amounts[3] - amounts[5]) <= Decimal(string: "0.02")! else { throw fail("Un abono no coincide con su desglose. No se guardó el préstamo.") }
                allocations.append(LoanAllocation(installment: installment, date: date, mxn: amounts[0], udis: amounts[1], principalMXN: amounts[2], principalUDIS: amounts[3], interestMXN: amounts[4], interestUDIS: amounts[5], folio: row[7]))
            } else if line.contains("$") && LoanMath.captures(#"^\s*\d+\s+\d{2}/\d{2}/\d{4}"#, line) != nil {
                throw fail("Hay un abono ilegible. No se guardó una lectura parcial.")
            }
        }
        let footerPattern = #"Total\s+Amortización\s*\(UDIS\)\s+"# + number + #"\s+"# + number + #"\s+"# + number
        let paidPattern = #"Menos\s+Pagos\s+Amortización\s+"# + number + #"\s+"# + number + #"\s+"# + number
        guard let footer = LoanMath.captures(footerPattern, text)?.compactMap(LoanMath.decimal), footer.count == 3,
              let paid = LoanMath.captures(paidPattern, text)?.compactMap(LoanMath.decimal), paid.count == 3,
              let original = LoanMath.captures(#"Adeudo\s+Total\s+de\s+Capital:\s*"# + number, text)?.first.flatMap(LoanMath.decimal),
              installments.count == expected, installments.map(\.number).sorted() == Array(1...expected),
              installments.filter({ $0.reportedStatus == "Pagado" }).count == Int(totals[1]) else { throw fail("Faltan cuotas o totales del documento. No se guardó una lectura parcial.") }
        let sumPrincipal = allocations.reduce(Decimal(0)) { $0 + $1.principalUDIS }
        let sumInterest = allocations.reduce(Decimal(0)) { $0 + $1.interestUDIS }
        guard abs(sumPrincipal - paid[1]) <= Decimal(string: "0.05")!, abs(sumInterest - paid[2]) <= Decimal(string: "0.05")!,
              abs(original - paid[1] - footer[1]) <= Decimal(string: "0.05")!,
              abs(installments.reduce(0, { $0 + $1.total }) - paid[0] - footer[0]) <= Decimal(string: "0.05")!,
              abs(footer[0] - footer[1] - footer[2]) <= Decimal(string: "0.02")! else { throw fail("Las cuotas y los abonos no concilian con el saldo del ITAM. Se conservaron tus datos anteriores.") }
        let mxnPattern = #"Total\s+de\s+Doctos\s*\(UDIS\)\s+"# + number + #"\s+"# + number + #"\s+"# + number + #"\s+\$"# + number + #"\s+"# + number + #"\s+\$"# + number + #"\s+"# + number + #"\s+\$"# + number + #"\s+"# + number
        guard let controls = LoanMath.captures(mxnPattern, text)?.compactMap(LoanMath.decimal), controls.count == 9,
              abs(allocations.reduce(0, { $0 + $1.mxn }) - controls[3]) <= Decimal(string: "0.05")!,
              abs(allocations.reduce(0, { $0 + $1.principalMXN }) - controls[5]) <= Decimal(string: "0.05")!,
              abs(allocations.reduce(0, { $0 + $1.interestMXN }) - controls[7]) <= Decimal(string: "0.05")! else { throw fail("Los abonos en pesos no coinciden con los totales del documento. No se guardó el préstamo.") }
        let result = LoanStatement(id: fingerprint, accountID: accountID, asOf: asOf, filename: filename, installments: installments, allocations: allocations, principalRemaining: footer[1], scheduledInterestRemaining: footer[2], scheduledTotalRemaining: footer[0])
        guard installments.allSatisfy({ result.paid($0) <= $0.total + Decimal(string: "0.05")! && ($0.reportedStatus != "Pagado" || result.remaining($0) <= Decimal(string: "0.05")!) }) else { throw fail("La aplicación de los abonos no coincide con las cuotas. No se guardó el préstamo.") }
        return result
    }
}
