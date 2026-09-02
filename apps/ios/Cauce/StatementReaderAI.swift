import Foundation

/// Explicit opt-in for sending a statement to the user's configured Zen
/// account when the private PDFKit/Vision pass cannot reconcile it. The API
/// key remains in Keychain through `ZenAPIKeyStore`; it is never compiled into
/// the application bundle.
enum ZenStatementReaderSettings {
    private static let enabledKey = "marcelito.zen.statement-reader.enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

struct ZenStatementSummaryPayload: Decodable, Sendable {
    let previousBalanceCents: Int64?
    let statementBalanceCents: Int64?
    let debtBalanceCents: Int64?
    let newTransactionsCents: Int64?
    let paymentsCents: Int64?
    let creditsCents: Int64?
    let paymentsCreditsCents: Int64?
    let newChargesCents: Int64?
    let interestCents: Int64?
    let feesCents: Int64?
    let creditLimitCents: Int64?
    let creditAvailableCents: Int64?
    let minimumPaymentCents: Int64?
    let minimumPlusMsiCents: Int64?
    let paymentForNoInterestCents: Int64?
    let cashBalanceCents: Int64?
    let msiOriginalDeferredCents: Int64?
    let msiPendingCents: Int64?
    let revolvingBalanceCents: Int64?
    let msiInstallments: Int?
    let msiMonthlyLoadCents: Int64?
    let domesticTransactionTotalCents: Int64?
    let domesticTransactionTotalIsCredit: Bool?
    let foreignTransactionTotalCents: Int64?
    let depositTotalCents: Int64?
    let withdrawalTotalCents: Int64?
    let depositCount: Int?
    let withdrawalCount: Int?

    enum CodingKeys: String, CodingKey {
        case previousBalanceCents = "previous_balance_cents"
        case statementBalanceCents = "statement_balance_cents"
        case debtBalanceCents = "debt_balance_cents"
        case newTransactionsCents = "new_transactions_cents"
        case paymentsCents = "payments_cents"
        case creditsCents = "credits_cents"
        case paymentsCreditsCents = "payments_credits_cents"
        case newChargesCents = "new_charges_cents"
        case interestCents = "interest_cents"
        case feesCents = "fees_cents"
        case creditLimitCents = "credit_limit_cents"
        case creditAvailableCents = "credit_available_cents"
        case minimumPaymentCents = "minimum_payment_cents"
        case minimumPlusMsiCents = "minimum_plus_msi_cents"
        case paymentForNoInterestCents = "payment_for_no_interest_cents"
        case cashBalanceCents = "cash_balance_cents"
        case msiOriginalDeferredCents = "msi_original_deferred_cents"
        case msiPendingCents = "msi_pending_cents"
        case revolvingBalanceCents = "revolving_balance_cents"
        case msiInstallments = "msi_installments"
        case msiMonthlyLoadCents = "msi_monthly_load_cents"
        case domesticTransactionTotalCents = "domestic_transaction_total_cents"
        case domesticTransactionTotalIsCredit = "domestic_transaction_total_is_credit"
        case foreignTransactionTotalCents = "foreign_transaction_total_cents"
        case depositTotalCents = "deposit_total_cents"
        case withdrawalTotalCents = "withdrawal_total_cents"
        case depositCount = "deposit_count"
        case withdrawalCount = "withdrawal_count"
    }

    private func amount(_ cents: Int64?) -> Decimal? {
        cents.map { Decimal($0) / Decimal(100) }
    }

    var statementSummary: StatementSummaryRecord {
        var result = StatementSummaryRecord()
        result.previousBalance = amount(previousBalanceCents)
        result.statementBalance = amount(statementBalanceCents)
        result.debtBalance = amount(debtBalanceCents)
        result.newTransactions = amount(newTransactionsCents)
        if let paymentsCents {
            result.payments = amount(paymentsCents)
        } else if let combined = paymentsCreditsCents, let credits = creditsCents, combined >= credits {
            result.payments = amount(combined - credits)
        }
        result.credits = amount(creditsCents)
        result.newCharges = amount(newChargesCents)
        result.interest = amount(interestCents)
        result.fees = amount(feesCents)
        result.creditLimit = amount(creditLimitCents)
        result.creditAvailable = amount(creditAvailableCents)
        result.minimumPayment = amount(minimumPaymentCents)
        result.minimumPlusMsi = amount(minimumPlusMsiCents)
        result.paymentForNoInterest = amount(paymentForNoInterestCents)
        result.cashBalance = amount(cashBalanceCents)
        result.msiOriginalDeferred = amount(msiOriginalDeferredCents)
        result.msiPending = amount(msiPendingCents)
        result.revolvingBalance = amount(revolvingBalanceCents)
        result.msiInstallments = msiInstallments
        result.msiMonthlyLoad = amount(msiMonthlyLoadCents)
        result.domesticTransactionTotal = amount(domesticTransactionTotalCents)
        result.domesticTransactionTotalIsCredit = domesticTransactionTotalIsCredit
        result.foreignTransactionTotal = amount(foreignTransactionTotalCents)
        result.depositTotal = amount(depositTotalCents)
        result.withdrawalTotal = amount(withdrawalTotalCents)
        result.depositCount = depositCount
        result.withdrawalCount = withdrawalCount
        if result.debtBalance == nil,
           let limit = result.creditLimit,
           let available = result.creditAvailable {
            result.debtBalance = max(Decimal(0), limit - available)
        }
        return result
    }
}

struct ZenStatementRowPayload: Decodable, Sendable {
    let date: String
    let description: String
    let amountCents: Int64
    let direction: String
    let kind: String
    let foreignCurrency: Bool
    let page: Int
    let evidence: String
    let confidence: Double

    enum CodingKeys: String, CodingKey {
        case date, description, direction, kind, page, evidence, confidence
        case amountCents = "amount_cents"
        case foreignCurrency = "foreign_currency"
    }
}

struct ZenStatementExtraction: Decodable, Sendable {
    let source: String
    let kind: String
    let accountLast4: String?
    let periodStart: String?
    let periodEnd: String?
    let cutoffDate: String?
    let pageCount: Int
    let summary: ZenStatementSummaryPayload
    let rows: [ZenStatementRowPayload]

    enum CodingKeys: String, CodingKey {
        case source, kind, summary, rows
        case accountLast4 = "account_last4"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case cutoffDate = "cutoff_date"
        case pageCount = "page_count"
    }

    var statementKind: StatementKind {
        StatementKind(rawValue: kind) ?? .unknown
    }

    var normalizedSource: String {
        let value = source.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if value.contains("american express") || value.contains("amex") { return "Amex" }
        if value.contains("bbva") { return "BBVA" }
        if value.contains("santander") { return "Santander" }
        return source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var periodLabel: String {
        if let start = periodStart, let end = periodEnd { return "\(start) – \(end)" }
        return periodEnd ?? cutoffDate ?? periodStart ?? "Periodo por revisar"
    }

    var averageConfidence: Double {
        guard !rows.isEmpty else { return 0 }
        return rows.map(\.confidence).reduce(0, +) / Double(rows.count)
    }

    var pageConfidences: [Double] {
        Dictionary(grouping: rows, by: \.page)
            .sorted { $0.key < $1.key }
            .map { _, values in values.map(\.confidence).reduce(0, +) / Double(values.count) }
    }

    func movements(account: String) throws -> [Movement] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        var seen = Set<String>()
        return try rows.compactMap { row in
            let identity = "\(row.date)|\(row.amountCents)|\(row.direction)|\(ZenStatementReader.normalized(row.description))|\(row.kind)"
            guard seen.insert(identity).inserted else { return nil }
            guard let date = formatter.date(from: row.date) else { throw ZenStatementReader.ReaderError.invalidResponse }
            let movementKind = ZenStatementReader.movementKind(row.kind)
            let amount = Decimal(row.amountCents) / Decimal(100) * (row.direction == "in" ? 1 : -1)
            let flow: FlowKind
            switch movementKind {
            case .bankTransfer: flow = .transfer
            case .cardPayment: flow = .debt
            case .income, .credit, .refund: flow = .income
            default: flow = .expense
            }
            let category: String
            switch movementKind {
            case .refund: category = "Reembolsos"
            case .income: category = "Ingresos"
            case .cardPayment: category = "Pago de tarjeta"
            case .bankTransfer: category = "Transferencia interna"
            default: category = "Sin categoría"
            }
            return Movement(
                date: date,
                title: row.description.trimmingCharacters(in: .whitespacesAndNewlines),
                account: account,
                category: category,
                amount: amount,
                flow: flow,
                kind: movementKind,
                foreignCurrency: row.foreignCurrency,
                extractionEvidence: MovementExtractionEvidence(
                    method: "multimodal-ai",
                    page: row.page,
                    confidence: row.confidence,
                    sourceText: String(row.evidence.prefix(500))
                )
            )
        }
    }
}

enum ZenStatementReader {
    static let endpoint = URL(string: "https://opencode.ai/zen/v1/responses")!
    static let model = "muse-spark-1.2-contributor-free"
    static let maximumFileBytes = 20 * 1024 * 1024
    static let minimumAverageConfidence = 0.88
    static let minimumPageConfidence = 0.78
    static let minimumRowConfidence = 0.80

    enum ReaderError: LocalizedError {
        case missingAPIKey
        case fileTooLarge
        case invalidPDF
        case provider(Int)
        case invalidResponse
        case lowConfidence

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: "Configura tu clave de OpenCode Zen para usar el lector con IA."
            case .fileTooLarge: "El lector con IA admite PDFs de hasta 20 MB."
            case .invalidPDF: "El archivo seleccionado no es un PDF válido."
            case .provider(let status): "OpenCode Zen no pudo leer el estado (HTTP \(status))."
            case .invalidResponse: "La IA devolvió información incompleta o no verificable."
            case .lowConfidence: "La lectura con IA no alcanzó la calidad visual mínima y quedó bloqueada."
            }
        }
    }

    private static let prompt = """
    Eres un extractor documental financiero. Lee el PDF completo y devuelve exclusivamente un objeto JSON, sin Markdown ni explicaciones.

    El objeto raíz debe contener exactamente: source, kind, account_last4, period_start, period_end, cutoff_date, page_count, summary y rows. kind solo puede ser bank, card o unknown. Las fechas usan YYYY-MM-DD. Todos los importes terminados en _cents son centavos enteros absolutos y direction determina el signo.

    summary debe contener siempre estas propiedades, usando null cuando no estén impresas: previous_balance_cents, statement_balance_cents, debt_balance_cents, new_transactions_cents, payments_cents, credits_cents, payments_credits_cents, new_charges_cents, interest_cents, fees_cents, credit_limit_cents, credit_available_cents, minimum_payment_cents, minimum_plus_msi_cents, payment_for_no_interest_cents, cash_balance_cents, msi_original_deferred_cents, msi_pending_cents, revolving_balance_cents, msi_installments, msi_monthly_load_cents, domestic_transaction_total_cents, domestic_transaction_total_is_credit, foreign_transaction_total_cents, deposit_total_cents, withdrawal_total_cents, deposit_count y withdrawal_count.

    Cada elemento de rows debe contener exactamente: date, description, amount_cents, direction, kind, foreign_currency, page, evidence y confidence. kind solo puede ser purchase, cardPayment, bankTransfer, income, credit, refund, msi, interest, fee u other. evidence debe ser un fragmento literal corto de la fila que incluya descripción e importe.

    Reglas obligatorias:
    - Identifica el emisor únicamente por encabezado, razón social, dominio o logotipo institucional; una contraparte mencionada en un movimiento no es el emisor.
    - Extrae solo filas de la tabla de movimientos. Cada fila requiere fecha, descripción comercial, importe y dirección claros.
    - Excluye encabezados, pies, referencias, cuentas, CLABE, RFC, certificados, folios, autorizaciones, fechas de corte, saldos, subtotales y totales.
    - Primero ubica visualmente las tablas; después reconstruye filas y comprueba sumas y conteos contra los controles impresos. Nunca inventes una fila para cerrar una diferencia.
    - En BBVA no confundas deposit_count o withdrawal_count con los montos deposit_total_cents y withdrawal_total_cents.
    - En Amex separa compras nacionales, moneda extranjera, pagos, créditos, reembolsos y MSI; no conviertas los resúmenes de sección en compras.
    - En Santander conserva por separado depósito, retiro y saldo de cada fila.
    - Devuelve las filas ordenadas, sin duplicados. Si algo no puede probarse, omítelo para que la conciliación local lo bloquee.
    """

    static func extract(pdf data: Data, fileName: String, apiKey: String) async throws -> ZenStatementExtraction {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { throw ReaderError.missingAPIKey }
        guard data.count <= maximumFileBytes else { throw ReaderError.fileTooLarge }
        guard data.starts(with: Data("%PDF-".utf8)) else { throw ReaderError.invalidPDF }

        let requestBody: [String: Any] = [
            "model": model,
            "store": false,
            "max_output_tokens": 32_768,
            "input": [[
                "role": "user",
                "content": [
                    [
                        "type": "input_file",
                        "filename": String(fileName.prefix(240)),
                        "file_data": "data:application/pdf;base64,\(data.base64EncodedString())"
                    ],
                    ["type": "input_text", "text": prompt]
                ]
            ]]
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReaderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ReaderError.provider(http.statusCode) }
        guard let text = outputText(from: responseData),
              let jsonData = jsonObjectData(from: text) else { throw ReaderError.invalidResponse }
        let extraction = try JSONDecoder().decode(ZenStatementExtraction.self, from: jsonData)
        try validate(extraction)
        return extraction
    }

    private static func outputText(from data: Data) -> String? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let text = body["output_text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        var chunks: [String] = []
        for item in body["output"] as? [[String: Any]] ?? [] {
            for content in item["content"] as? [[String: Any]] ?? [] {
                if let text = content["text"] as? String { chunks.append(text) }
            }
        }
        for choice in body["choices"] as? [[String: Any]] ?? [] {
            guard let message = choice["message"] as? [String: Any] else { continue }
            if let text = message["content"] as? String { chunks.append(text) }
            for part in message["content"] as? [[String: Any]] ?? [] {
                if let text = part["text"] as? String { chunks.append(text) }
            }
        }
        let joined = chunks.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private static func jsonObjectData(from text: String) -> Data? {
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}"),
              start <= end else { return nil }
        return String(cleaned[start...end]).data(using: .utf8)
    }

    private static func validate(_ extraction: ZenStatementExtraction) throws {
        guard !extraction.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              extraction.source.count <= 80,
              extraction.statementKind != .unknown,
              extraction.pageCount > 0,
              extraction.pageCount <= 200,
              extraction.rows.count <= 2_500 else { throw ReaderError.invalidResponse }
        if let last4 = extraction.accountLast4, last4.range(of: #"^\d{4}$"#, options: .regularExpression) == nil {
            throw ReaderError.invalidResponse
        }
        if let start = extraction.periodStart, let end = extraction.periodEnd, start > end {
            throw ReaderError.invalidResponse
        }
        guard !extraction.rows.isEmpty else { throw ReaderError.invalidResponse }

        for row in extraction.rows {
            guard row.date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                  row.description.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3,
                  !isAdministrative(row.description),
                  row.amountCents > 0,
                  row.amountCents <= 1_000_000_000_000,
                  ["in", "out"].contains(row.direction),
                  ["purchase", "cardPayment", "bankTransfer", "income", "credit", "refund", "msi", "interest", "fee", "other"].contains(row.kind),
                  row.page > 0,
                  row.page <= extraction.pageCount,
                  row.confidence.isFinite,
                  row.confidence >= minimumRowConfidence,
                  row.confidence <= 1,
                  evidenceContainsDescription(row.description, evidence: row.evidence),
                  evidenceContainsAmount(row.amountCents, evidence: row.evidence) else {
                throw ReaderError.invalidResponse
            }
            let kind = movementKind(row.kind)
            if [.income, .credit, .refund].contains(kind), row.direction != "in" { throw ReaderError.invalidResponse }
            if [.purchase, .msi, .interest, .fee].contains(kind), row.direction != "out" { throw ReaderError.invalidResponse }
            if let start = extraction.periodStart, row.date < start { throw ReaderError.invalidResponse }
            if let end = extraction.periodEnd, row.date > end { throw ReaderError.invalidResponse }
        }
        guard extraction.averageConfidence >= minimumAverageConfidence,
              extraction.pageConfidences.min() ?? 0 >= minimumPageConfidence else {
            throw ReaderError.lowConfidence
        }
    }

    static func movementKind(_ raw: String) -> MovementKind {
        switch raw {
        case "purchase": .purchase
        case "cardPayment": .cardPayment
        case "bankTransfer": .bankTransfer
        case "income": .income
        case "credit": .credit
        case "refund": .refund
        case "msi": .msi
        case "interest": .interest
        case "fee": .fee
        default: .other
        }
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAdministrative(_ value: String) -> Bool {
        normalized(value).range(
            of: #"(?:ciudad de mexico|serie del certificado|total importe|fecha de corte|numero de cuenta|cuenta clabe|\brfc\b|saldo (?:inicial|anterior|final|disponible)|periodo de facturacion)"#,
            options: .regularExpression
        ) != nil
    }

    private static func evidenceContainsDescription(_ description: String, evidence: String) -> Bool {
        let generic = Set(["pago", "cargo", "compra", "abono", "credito", "debito", "total", "saldo", "movimiento", "transaccion"])
        let evidenceText = normalized(evidence)
        let tokens = normalized(description).split(separator: " ").map(String.init)
            .filter { $0.count >= 3 && !generic.contains($0) }
        return tokens.contains { evidenceText.contains($0) }
    }

    private static func evidenceContainsAmount(_ expectedCents: Int64, evidence: String) -> Bool {
        guard let expression = try? NSRegularExpression(
            pattern: #"\$?\s*-?(?:\d{1,3}(?:[ ,.\u00a0]\d{3})+|\d+)(?:[.,]\d{1,2})?"#,
            options: [.caseInsensitive]
        ) else { return false }
        let range = NSRange(evidence.startIndex..<evidence.endIndex, in: evidence)
        return expression.matches(in: evidence, range: range).contains { match in
            guard let swiftRange = Range(match.range, in: evidence) else { return false }
            return parsedMoneyCents(String(evidence[swiftRange])) == expectedCents
        }
    }

    private static func parsedMoneyCents(_ value: String) -> Int64? {
        var clean = value
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: "-", with: "")
        let comma = clean.lastIndex(of: ",")
        let dot = clean.lastIndex(of: ".")
        if let comma, let dot {
            if comma > dot {
                clean = clean.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                clean = clean.replacingOccurrences(of: ",", with: "")
            }
        } else if let comma {
            let decimals = clean.distance(from: clean.index(after: comma), to: clean.endIndex)
            clean = decimals <= 2 ? clean.replacingOccurrences(of: ",", with: ".") : clean.replacingOccurrences(of: ",", with: "")
        }
        guard let number = Decimal(string: clean, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return NSDecimalNumber(decimal: number * Decimal(100)).int64Value
    }
}
