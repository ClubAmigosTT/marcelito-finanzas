import Foundation
import JavaScriptCore

/// Neutral input passed from PDFKit/Vision to the shared Rappi interpreter.
/// The extractor owns pixels and coordinates; the JavaScript engine owns the
/// deterministic meaning of a Rappi row.
private struct RappiEngineInput: Encodable {
    let source = "Rappi"
    let fileName: String
    let mode: String
    let text: String
    let layout: RappiEngineLayout?
    let pageConfidences: [Double]?
}

private struct RappiEngineLayout: Encodable {
    let pages: [RappiEnginePage]
}

private struct RappiEnginePage: Encodable {
    let page: Int
    let lines: [RappiEngineLine]
}

private struct RappiEngineLine: Encodable {
    let page: Int
    let words: [RappiEngineWord]
}

private struct RappiEngineWord: Encodable {
    let x: Double
    let text: String
    let confidence: Double
}

private struct RappiEngineResult: Decodable {
    let parserId: String
    let sourceSection: String
    let transactions: [RappiEngineTransaction]
    let reconciliation: RappiEngineReconciliation?
    let rejectedRowCount: Int
    let rejectedRows: [String]?
}

private struct RappiEngineReconciliation: Decodable {
    let status: String?
}

private struct RappiEngineTransaction: Decodable {
    let date: String
    let description: String
    let account: String
    let category: String
    let amount: Decimal
    let flow: String
    let kind: String?
    let foreignCurrency: Bool?
    let confidence: Double?
    let rawDescription: String?
    let normalizedMerchant: String?
    let displayMerchant: String?
    let merchantConfidence: Double?
    let merchantReviewReason: String?
    let extractionEvidence: RappiEngineEvidence?
}

private struct RappiEngineEvidence: Decodable {
    let method: String?
    let page: Int?
    let confidence: Double?
    let sourceText: String?
    let bounds: RappiEngineBounds?
    let sameVisualRow: Bool?
    let reviewReason: String?
    let selectionReason: String?
}

private struct RappiEngineBounds: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// Executes the same pure Rappi parser that powers the web reader. It is
/// intentionally not a PDF.js runtime: JavaScriptCore receives only the
/// bounded text/layout contract emitted locally by PDFKit or Vision.
final class RappiSharedEngine: @unchecked Sendable {
    static let version = "rappi-shared-engine-2026.09.23.1"
    static let shared = RappiSharedEngine()

    private let context: JSContext?
    private let lock = NSLock()

    private init() {
        let context = JSContext()
        context?.exceptionHandler = { _, exception in
            // The caller verifies the result and falls back to the native
            // recovery reader if the embedded asset cannot be evaluated.
            if let exception {
                NSLog("Rappi shared engine exception: %@", exception)
            }
        }
        self.context = context
        guard let context,
              let resourceURL = RappiSharedEngine.resourceURL,
              let script = try? String(contentsOf: resourceURL, encoding: .utf8) else {
            return
        }
        context.evaluateScript(script)
    }

    private static var resourceURL: URL? {
        let bundles = [Bundle.main, Bundle(for: RappiSharedEngine.self)]
        return bundles.compactMap { $0.url(forResource: "rappi-engine", withExtension: "js") }.first
    }

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let context else { return false }
        guard let engine = context.objectForKeyedSubscript("MarcelitoRappiEngine"),
              engine.isObject,
              let version = engine.objectForKeyedSubscript("version")?.toString() else {
            return false
        }
        return version == Self.version
    }

    /// Returns nil only when the embedded asset/runtime cannot execute. A
    /// valid parser result with zero rows is still returned, so a malformed
    /// document cannot silently switch readers.
    func parseMovements(
        text: String,
        fileName: String,
        evidenceMethod: String,
        confidenceByPage: [Int: Double] = [:]
    ) -> [Movement]? {
        guard let result = parseResult(
            text: text,
            fileName: fileName,
            evidenceMethod: evidenceMethod,
            confidenceByPage: confidenceByPage
        ) else {
            return nil
        }
        // The native reader still owns PDFKit/Vision extraction and candidate
        // selection. Use the shared interpretation only when its complete
        // stream proves the independent Rappi controls. For a malformed or
        // extraction-specific fixture, returning nil deliberately hands the
        // stream to the native recovery parser instead of exposing a partial
        // shared result or mixing rows from both readers.
        guard result.reconciliation?.status == "valid" else { return nil }
        return result.transactions.compactMap {
            Self.makeMovement(from: $0, evidenceMethod: evidenceMethod)
        }
    }

    private func parseResult(
        text: String,
        fileName: String,
        evidenceMethod: String,
        confidenceByPage: [Int: Double] = [:]
    ) -> RappiEngineResult? {
        guard let context else { return nil }
        let mode = evidenceMethod == "vision-ocr" ? "ocr" : "text"
        let pageConfidences = confidenceByPage
            .sorted { $0.key < $1.key }
            .reduce(into: [Double]()) { result, item in
                while result.count < item.key { result.append(0) }
                result[item.key - 1] = item.value
            }
        let input = RappiEngineInput(
            fileName: fileName,
            mode: mode,
            text: text,
            layout: nil,
            pageConfidences: pageConfidences.isEmpty ? nil : pageConfidences
        )
        guard let inputData = try? JSONEncoder().encode(input),
              let inputObject = try? JSONSerialization.jsonObject(with: inputData) else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }
        guard let jsonValue = JSValue(object: inputObject, in: context),
              let engine = context.objectForKeyedSubscript("MarcelitoRappiEngine"),
              let parse = engine.objectForKeyedSubscript("parse") else {
            return nil
        }
        context.exception = nil
        guard let output = parse.call(withArguments: [jsonValue]),
              context.exception == nil,
              let json = context.objectForKeyedSubscript("JSON")?
                .invokeMethod("stringify", withArguments: [output])?
                .toString(),
              let outputData = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RappiEngineResult.self, from: outputData) else {
            return nil
        }
        return decoded
    }

    /// Native `Movement` uses a positive amount and `.transfer` for a Rappi
    /// card payment. The shared engine keeps the web ledger convention; this
    /// adapter translates only that platform-model difference and never
    /// changes purchase/refund amounts or their printed sign.
    private static func makeMovement(
        from transaction: RappiEngineTransaction,
        evidenceMethod: String
    ) -> Movement? {
        guard let date = date(from: transaction.date) else { return nil }
        let kind = movementKind(from: transaction.kind)
        let amount: Decimal = kind == .cardPayment ? abs(transaction.amount) : transaction.amount
        let flow: FlowKind = kind == .cardPayment
            ? .transfer
            : transaction.flow == "income" ? .income
            : transaction.flow == "transfer" ? .transfer
            : transaction.flow == "debt" ? .debt
            : .expense
        let evidence = transaction.extractionEvidence.map { source in
            MovementExtractionEvidence(
                method: evidenceMethod,
                page: source.page,
                confidence: max(0, min(1, source.confidence ?? transaction.confidence ?? 0)),
                sourceText: source.sourceText,
                bounds: source.bounds.map {
                    MovementExtractionBounds(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                },
                selectedColumn: evidenceMethod == "vision-ocr" ? "MONTO MXN" : nil,
                selectedAmount: abs(transaction.amount),
                selectionReason: source.selectionReason
                    ?? "Motor Rappi compartido; importe seleccionado por la fila y conciliado contra controles",
                reviewReason: source.reviewReason ?? transaction.merchantReviewReason,
                sameVisualRow: source.sameVisualRow
            )
        }
        let rawDescription = transaction.rawDescription ?? transaction.description
        let title = legacyRappiTitle(transaction.description)
        return Movement(
            date: date,
            title: title,
            account: transaction.account,
            category: transaction.category,
            amount: amount,
            flow: flow,
            kind: kind,
            foreignCurrency: transaction.foreignCurrency ?? false,
            extractionEvidence: evidence,
            rawDescription: rawDescription,
            normalizedMerchant: transaction.normalizedMerchant,
            displayMerchant: transaction.displayMerchant,
            merchantConfidence: transaction.merchantConfidence,
            merchantReviewReason: transaction.merchantReviewReason
        )
    }

    private static func date(from value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              parts[0] >= 1900, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        guard let date = calendar.date(from: components),
              calendar.component(.year, from: date) == parts[0],
              calendar.component(.month, from: date) == parts[1],
              calendar.component(.day, from: date) == parts[2] else {
            return nil
        }
        return date
    }

    private static func legacyRappiTitle(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_MX"))
            .lowercased()
            .replacingOccurrences(
                of: #"(?i);?\s*\bRFC\s*:\s*[A-Z0-9&Ñ]+"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"[;,:]+\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func movementKind(from value: String?) -> MovementKind {
        switch value {
        case "cardPayment": return .cardPayment
        case "bankTransfer": return .bankTransfer
        case "income": return .income
        case "credit": return .credit
        case "refund": return .refund
        case "msi": return .msi
        case "interest": return .interest
        case "fee": return .fee
        case "other": return .other
        default: return .purchase
        }
    }
}
