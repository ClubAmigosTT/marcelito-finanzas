import CryptoKit
import Foundation
import LocalAuthentication
import Observation
import PDFKit
import Security
import SwiftUI

enum FlowKind: String, CaseIterable, Identifiable, Codable, Hashable {
    case income = "Ingreso"
    case transfer = "Transferencia"
    case expense = "Gasto"
    case debt = "Deuda"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .income: .marcelitoNavyMid
        case .transfer: .marcelitoNavySoft
        case .expense: .marcelitoNavy
        case .debt: .marcelitoNavy
        }
    }

    var symbol: String {
        switch self {
        case .income: "arrow.down.circle.fill"
        case .transfer: "arrow.left.arrow.right.circle.fill"
        case .expense: "receipt.fill"
        case .debt: "creditcard.fill"
        }
    }
}

struct Movement: Identifiable, Codable {
    var id: UUID
    var date: Date
    var title: String
    var account: String
    var category: String
    var amount: Decimal
    var flow: FlowKind
    var statementId: UUID?

    init(
        id: UUID = UUID(),
        date: Date,
        title: String,
        account: String,
        category: String,
        amount: Decimal,
        flow: FlowKind,
        statementId: UUID? = nil
    ) {
        self.id = id
        self.date = date
        self.title = title
        self.account = account
        self.category = category
        self.amount = amount
        self.flow = flow
        self.statementId = statementId
    }
}

struct StatementRecord: Identifiable, Codable {
    var id: UUID
    var source: String
    var period: String
    var fileName: String
    var importedAt: Date
    var transactionCount: Int
    var requiresReview: Bool
}

struct ImportSummary {
    let source: String
    let period: String
    let fileName: String
    let imported: Int
    let skipped: Int
    let requiresReview: Bool
}

enum FinanceImportError: LocalizedError {
    case unreadableDocument
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case .unreadableDocument:
            "No pudimos leer este PDF. Verifica que sea un estado de cuenta válido."
        case .emptyDocument:
            "El PDF no contiene movimientos reconocibles. Ve a Movimientos y usa + para agregarlos manualmente."
        }
    }
}

@Observable
final class FinanceStore {
    private let movementKey = "marcelito.movements.v2"
    private let statementKey = "marcelito.statements.v1"
    private let importKey = "marcelito.lastImport"

    var movements: [Movement]
    var statements: [StatementRecord]

    private(set) var lastImportedFile: String?

    var totalIncome: Decimal { movements.filter { $0.flow == .income }.reduce(0) { $0 + abs($1.amount) } }
    var totalTransfers: Decimal { movements.filter { $0.flow == .transfer }.reduce(0) { $0 + abs($1.amount) } }
    var totalExpenses: Decimal { movements.filter { $0.flow == .expense }.reduce(0) { $0 + abs($1.amount) } }

    var monthlyExpense: Decimal {
        let monthStart = Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month], from: .now)
        ) ?? .now
        return movements
            .filter { $0.flow == .expense && $0.date >= monthStart }
            .reduce(0) { $0 + abs($1.amount) }
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: movementKey),
           let saved = try? JSONDecoder().decode([Movement].self, from: data) {
            movements = saved
        } else {
            movements = []
        }
        if let data = defaults.data(forKey: statementKey),
           let saved = try? JSONDecoder().decode([StatementRecord].self, from: data) {
            statements = saved
        } else {
            statements = []
        }
        lastImportedFile = defaults.string(forKey: importKey)
    }

    func updateCategory(for movement: Movement, to category: String) {
        guard let index = movements.firstIndex(where: { $0.id == movement.id }) else { return }
        movements[index].category = category
        persist()
    }

    func addMovement(
        title: String,
        account: String,
        category: String,
        amount: Decimal,
        flow: FlowKind,
        date: Date
    ) {
        let signedAmount = flow == .income ? abs(amount) : -abs(amount)
        movements.insert(
            Movement(
                date: date,
                title: title,
                account: account,
                category: category,
                amount: signedAmount,
                flow: flow,
                statementId: nil
            ),
            at: 0
        )
        persist()
    }

    func clearLocalData() {
        movements = []
        statements = []
        lastImportedFile = nil
        persist()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: movementKey)
        defaults.removeObject(forKey: statementKey)
        defaults.removeObject(forKey: importKey)
    }

    func importPDF(from url: URL) throws -> ImportSummary {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let document = PDFDocument(url: url) else {
            throw FinanceImportError.unreadableDocument
        }

        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
        let candidates = Self.parse(text: text, fileName: url.lastPathComponent)
        let source = Self.accountName(from: url.lastPathComponent) == "Importado"
            ? Self.accountName(from: text)
            : Self.accountName(from: url.lastPathComponent)
        let period = Self.periodLabel(from: text, fileName: url.lastPathComponent)
        let existingStatement = statements.first(where: { $0.fileName == url.lastPathComponent })
        let statementId = existingStatement?.id ?? UUID()
        let existingKeys = Set(movements.filter { $0.statementId != statementId }.map(Self.identityKey))
        let fresh = candidates.compactMap { candidate -> Movement? in
            let keyed = Self.identityKey(candidate)
            guard !existingKeys.contains(keyed) else { return nil }
            var imported = candidate
            imported.statementId = statementId
            return imported
        }

        movements.removeAll { $0.statementId == statementId }
        movements.insert(contentsOf: fresh.reversed(), at: 0)
        let statement = StatementRecord(
            id: statementId,
            source: source,
            period: period,
            fileName: url.lastPathComponent,
            importedAt: .now,
            transactionCount: fresh.count,
            requiresReview: fresh.isEmpty
        )
        if let index = statements.firstIndex(where: { $0.id == statementId }) {
            statements[index] = statement
        } else {
            statements.insert(statement, at: 0)
        }
        lastImportedFile = url.lastPathComponent
        persist()
        UserDefaults.standard.set(lastImportedFile, forKey: importKey)

        return ImportSummary(
            source: source,
            period: period,
            fileName: url.lastPathComponent,
            imported: fresh.count,
            skipped: candidates.count - fresh.count,
            requiresReview: fresh.isEmpty
        )
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(movements) else { return }
        UserDefaults.standard.set(data, forKey: movementKey)
        if let data = try? JSONEncoder().encode(statements) {
            UserDefaults.standard.set(data, forKey: statementKey)
        }
    }

    private static func identityKey(_ movement: Movement) -> String {
        "\(Calendar.current.startOfDay(for: movement.date).timeIntervalSince1970)|\(movement.title.lowercased())|\(movement.account.lowercased())|\(movement.amount)"
    }

    private static let demoMovements: [Movement] = [/*
        Movement(date: .now, title: "Nómina mensual", account: "Santander", category: "Ingresos", amount: 48_200, flow: .income),
        Movement(date: .now.addingTimeInterval(-86_400), title: "Pago de tarjeta", account: "Santander a Amex", category: "Transferencia", amount: -19_405, flow: .transfer),
        Movement(date: .now.addingTimeInterval(-172_800), title: "Supermercado", account: "Amex", category: "Alimentos", amount: -1_842.70, flow: .expense),
        Movement(date: .now.addingTimeInterval(-259_200), title: "Reserva de viaje", account: "Amex", category: "Viajes", amount: -6_270, flow: .expense)
    */]

    private struct TextMatch {
        let range: NSRange
        let text: String
    }

    private static func parse(text: String, fileName: String) -> [Movement] {
        let dateRegex = try? NSRegularExpression(
            pattern: #"(?<!\d)(\d{1,2})[\/\-.](\d{1,2})[\/\-.](\d{2,4})(?!\d)"#
        )
        let textDateRegex = try? NSRegularExpression(
            pattern: #"(?i)(?<!\d)(\d{1,2})\s+de\s+([A-Za-zÁÉÍÓÚáéíóú]+)(?:\s+de\s+(\d{4}))?"#
        )
        let amountRegex = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9])[-+]?\s*\$?\s*(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?(?![A-Za-z0-9])"#
        )
        let filenameAccount = accountName(from: fileName)
        let documentNormalized = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        let account = filenameAccount == "Importado"
            ? accountName(from: documentNormalized)
            : filenameAccount
        let ignoredPhrases = [
            "saldo anterior", "saldo al corte", "pago minimo",
            "limite de credito", "tasa anual", "numero de cuenta",
            "fecha de corte", "fecha limite", "total a pagar",
            "periodo de facturacion", "este no es un documento",
            "total de las transacciones", "el estado de cuenta incluye",
            "estimado cliente", "en caso de que la fecha"
        ]

        // Amex puts the merchant, RFC and amount on separate PDF text lines.
        // Group each date-started row before extracting the amount.
        var rows: [String] = []
        var pendingRow = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count > 1 else { continue }
            let hasDate = (dateRegex.flatMap { firstMatch(in: line, regex: $0) } != nil)
                || (textDateRegex.flatMap { firstMatch(in: line, regex: $0) } != nil)
            if hasDate {
                if !pendingRow.isEmpty { rows.append(pendingRow) }
                pendingRow = line
            } else if !pendingRow.isEmpty {
                pendingRow += " " + line
            }
        }
        if !pendingRow.isEmpty { rows.append(pendingRow) }

        return rows.compactMap { row in
            let original = row.trimmingCharacters(in: .whitespacesAndNewlines)
            guard original.count > 3 else { return nil }

            let normalized = original.folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: .current
            )
            guard !ignoredPhrases.contains(where: { normalized.contains($0) }) else { return nil }

            var working = original
            var date = Date()
            let dateMatch = dateRegex.flatMap { firstMatch(in: working, regex: $0) }
                ?? textDateRegex.flatMap { firstMatch(in: working, regex: $0) }
            if let dateMatch {
                date = parseDate(dateMatch.text) ?? date
                working = working.replacingCharacters(in: Range(dateMatch.range, in: working)!, with: " ")
            }

            guard let amountRegex,
                  let amountMatch = allMatches(in: working, regex: amountRegex).last,
                  let parsedAmount = parseAmount(amountMatch.text),
                  parsedAmount != 0,
                  abs(parsedAmount) < 10_000_000 else {
                return nil
            }
            working = working.replacingCharacters(in: Range(amountMatch.range, in: working)!, with: " ")

            let title = working
                .replacingOccurrences(of: #"\bRFC[A-Z0-9]+\b"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"/REF[A-Z0-9_]+\b"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\bCR\b"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count >= 3 else { return nil }
            guard title.rangeOfCharacter(from: .letters) != nil else { return nil }

            let titleNormalized = title.folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: .current
            )
            let flow: FlowKind
            if titleNormalized.contains("nomina")
                || titleNormalized.contains("sueldo")
                || titleNormalized.contains("deposito")
                || titleNormalized.contains("abono")
                || titleNormalized.contains("transferencia recibida") {
                flow = .income
            } else if titleNormalized.contains("pago")
                        && account.localizedCaseInsensitiveContains("Amex") {
                flow = .debt
            } else if titleNormalized.contains("transfer")
                        || titleNormalized.contains("traspaso")
                        || titleNormalized.contains("pago de tarjeta") {
                flow = .transfer
            } else {
                flow = .expense
            }

            let signedAmount = flow == .income ? abs(parsedAmount) : -abs(parsedAmount)
            let displayAccount = flow == .transfer && titleNormalized.contains("amex")
                ? "Santander a Amex"
                : account
            let category = category(for: titleNormalized, flow: flow)

            return Movement(
                date: date,
                title: title,
                account: displayAccount,
                category: category,
                amount: signedAmount,
                flow: flow
            )
        }
    }

    private static func firstMatch(in string: String, regex: NSRegularExpression) -> TextMatch? {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let result = regex.firstMatch(in: string, range: range),
              let swiftRange = Range(result.range, in: string) else {
            return nil
        }
        return TextMatch(range: result.range, text: String(string[swiftRange]))
    }

    private static func allMatches(in string: String, regex: NSRegularExpression) -> [TextMatch] {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.matches(in: string, range: range).compactMap { result in
            guard let swiftRange = Range(result.range, in: string) else { return nil }
            return TextMatch(range: result.range, text: String(string[swiftRange]))
        }
    }

    private static func parseAmount(_ value: String) -> Decimal? {
        let cleaned = value
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: "")
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func parseDate(_ value: String) -> Date? {
        let normalized = value.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        let parts = normalized.split(whereSeparator: { character in
            character == "/" || character == "-" || character == "." || character == " "
        })
        guard let day = parts.first.flatMap({ Int($0) }) else { return nil }
        let monthToken = parts.dropFirst().first(where: {
            Int($0) != nil || monthNumber(String($0)) != nil
        })
        guard let monthToken else { return nil }
        let month = Int(monthToken) ?? monthNumber(String(monthToken))!
        let year = parts.dropFirst()
            .compactMap { Int($0) }
            .last(where: { $0 >= 100 })
            ?? Calendar.current.component(.year, from: .now)
        var dateComponents = DateComponents()
        dateComponents.day = day
        dateComponents.month = month
        dateComponents.year = year < 100 ? year + 2_000 : year
        return Calendar(identifier: .gregorian).date(from: dateComponents)
    }

    private static func monthNumber(_ value: String) -> Int? {
        switch value {
        case let month where month.hasPrefix("ene"): return 1
        case let month where month.hasPrefix("feb"): return 2
        case let month where month.hasPrefix("mar"): return 3
        case let month where month.hasPrefix("abr"): return 4
        case let month where month.hasPrefix("may"): return 5
        case let month where month.hasPrefix("jun"): return 6
        case let month where month.hasPrefix("jul"): return 7
        case let month where month.hasPrefix("ago"): return 8
        case let month where month.hasPrefix("sep") || month.hasPrefix("set"): return 9
        case let month where month.hasPrefix("oct"): return 10
        case let month where month.hasPrefix("nov"): return 11
        case let month where month.hasPrefix("dic"): return 12
        default: return nil
        }
    }

    private static func periodLabel(from text: String, fileName: String) -> String {
        let normalized = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        if let regex = try? NSRegularExpression(pattern: #"period(?:o|os)\s*(?:de\s+facturacion)?\s*[:-]?\s*([^\n]{8,80})"#),
           let match = regex.firstMatch(in: normalized, range: range),
           let valueRange = Range(match.range(at: 1), in: normalized) {
            return String(normalized[valueRange]).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fileName
            .replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func accountName(from fileName: String) -> String {
        let normalized = fileName.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        if normalized.contains("amex") || normalized.contains("american express") {
            return "Amex"
        }
        if normalized.contains("bbva") {
            return "BBVA"
        }
        if normalized.contains("santander") {
            return "Santander"
        }
        return "Importado"
    }

    private static func category(for title: String, flow: FlowKind) -> String {
        if flow == .income { return "Ingresos" }
        if flow == .transfer { return "Transferencia" }
        if title.contains("super")
            || title.contains("costco")
            || title.contains("walmart")
            || title.contains("soriana") {
            return "Alimentos"
        }
        if title.contains("hotel")
            || title.contains("vuelo")
            || title.contains("aeromexico")
            || title.contains("aerobus")
            || title.contains("airbnb")
            || title.contains("volaris")
            || title.contains("uber") {
            return "Viajes"
        }
        if flow == .debt { return "Pago de tarjeta" }
        return "Por revisar"
    }
}

private enum SecureAccountStore {
    private static let service = "mx.marcelito.personal.account"

    static func string(for account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String) {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func deleteAll() {
        SecItemDelete(baseQuery(account: "username") as CFDictionary)
        SecItemDelete(baseQuery(account: "passwordHash") as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

@Observable
final class AuthenticationModel {
    var isAuthenticated = false
    var message: String?

    private let usernameAccount = "username"
    private let passwordHashAccount = "passwordHash"
    private let deletedKey = "marcelito.account.deleted"
    private let seedUsername = "Marcelodiazs"
    private let seedPasswordHash = "ed6357244f855d10e821359702d859df700ba81431a98b88ba1de5156a1e9f61"

    init() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: deletedKey) else { return }

        if SecureAccountStore.string(for: usernameAccount) == nil
            || SecureAccountStore.string(for: passwordHashAccount) == nil {
            SecureAccountStore.deleteAll()
            SecureAccountStore.save(seedUsername, account: usernameAccount)
            SecureAccountStore.save(seedPasswordHash, account: passwordHashAccount)
        }
    }

    func signIn(username: String, password: String) {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanUsername.count >= 3, password.count >= 6 else {
            isAuthenticated = false
            message = "Revisa tu usuario y contraseña."
            return
        }

        let savedUsername = SecureAccountStore.string(for: usernameAccount)
        let savedHash = SecureAccountStore.string(for: passwordHashAccount)
        let hash = Self.passwordHash(username: savedUsername ?? cleanUsername, password: password)
        guard savedUsername?.caseInsensitiveCompare(cleanUsername) == .orderedSame,
              savedHash == hash else {
            isAuthenticated = false
            message = "Usuario o contraseña no válidos."
            return
        }

        isAuthenticated = true
        message = nil
    }

    func createAccount(username: String, password: String) {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanUsername.count >= 3, password.count >= 6 else {
            isAuthenticated = false
            message = "Usa un usuario de al menos 3 caracteres y una contraseña de 6 o más."
            return
        }
        guard SecureAccountStore.string(for: usernameAccount) == nil else {
            isAuthenticated = false
            message = "Ya existe un usuario en este dispositivo. Entra con él o elimina la cuenta desde tu perfil."
            return
        }

        SecureAccountStore.save(cleanUsername, account: usernameAccount)
        SecureAccountStore.save(Self.passwordHash(username: cleanUsername, password: password), account: passwordHashAccount)
        UserDefaults.standard.set(false, forKey: deletedKey)
        isAuthenticated = true
        message = nil
    }

    func deleteAccount() {
        SecureAccountStore.deleteAll()
        UserDefaults.standard.set(true, forKey: deletedKey)
        isAuthenticated = false
        message = nil
    }

    func unlockWithFaceID() async {
        guard SecureAccountStore.string(for: usernameAccount) != nil else {
            await MainActor.run { message = "Primero crea un usuario en este dispositivo." }
            return
        }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            await MainActor.run { message = "Face ID no está disponible en este dispositivo." }
            return
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Desbloquea tu panorama financiero"
            )
            await MainActor.run {
                isAuthenticated = success
                message = success ? nil : "No pudimos confirmar tu identidad."
            }
        } catch {
            await MainActor.run { message = "No pudimos confirmar tu identidad." }
        }
    }

    private static func passwordHash(username: String, password: String) -> String {
        let digest = SHA256.hash(data: Data("\(username):\(password)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
