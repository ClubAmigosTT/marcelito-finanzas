import Foundation
import Security
import SwiftUI

struct AIClassification: Identifiable {
    let movementID: UUID
    let category: String
    let travelRelated: Bool
    let tags: [String]
    let confidence: Double
    let requiresReview: Bool
    let reason: String?

    var id: UUID { movementID }
}

struct AIClassificationRunResult {
    let classifications: [AIClassification]
    let provider: ExpenseAIProvider
    let model: String
    let requestedCount: Int
    let receivedCount: Int
    let acceptedCount: Int
    let unresolvedCount: Int
    let retryCount: Int
    let finishReasons: [String]
    let issues: [String]

    var diagnosticSummary: String {
        let finishes = finishReasons.isEmpty ? "sin-dato" : finishReasons.joined(separator: ",")
        let issueText = issues.isEmpty ? "ninguna" : issues.joined(separator: ",")
        return "Proveedor \(provider.displayName); modelo \(model); solicitados \(requestedCount); recibidos \(receivedCount); aceptados \(acceptedCount); por resolver \(unresolvedCount); reintentos \(retryCount); finish_reason \(finishes); incidencias \(issueText)."
    }
}

enum ExpenseAIProvider: String, CaseIterable, Identifiable {
    case gemini
    case openCodeZen
    case nvidia

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .openCodeZen: return "OpenCode Zen"
        case .nvidia: return "NVIDIA"
        }
    }

    var endpoint: URL {
        switch self {
        case .gemini:
            return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
        case .openCodeZen:
            return URL(string: "https://opencode.ai/zen/v1/chat/completions")!
        case .nvidia:
            return URL(string: "https://integrate.api.nvidia.com/v1/chat/completions")!
        }
    }
}

enum ExpenseAIClassifier {
    struct ModelOption: Identifiable, Hashable {
        let id: String
        let name: String
    }

    static let geminiDefaultModel = "gemini-3.1-flash-lite"
    static let zenDefaultModel = "mimo-v2.5-free"
    static let nvidiaDefaultModel = "deepseek-ai/deepseek-v4-flash-0731"
    /// Keep each response comfortably below the output limit. A long list of
    /// pending movements must be split instead of silently truncating the
    /// JSON returned by the provider.
    static let maxBatchSize = 5
    static let zenModels: [ModelOption] = [
        ModelOption(id: "mimo-v2.5-free", name: "MiMo V2.5 Free"),
        ModelOption(id: "ling-3.0-flash-fin-free", name: "Ling 3.0 Flash Fin Free"),
        ModelOption(id: "nemotron-3-ultra-free", name: "Nemotron 3 Ultra Free"),
        ModelOption(id: "nemotron-3.5-lightning-free", name: "Nemotron 3.5 Lightning Free"),
        ModelOption(id: "big-pickle", name: "Big Pickle")
    ]
    static let nvidiaModels: [ModelOption] = [
        ModelOption(id: nvidiaDefaultModel, name: "DeepSeek V4 Flash 0731"),
        ModelOption(id: "moonshotai/kimi-k3", name: "Kimi K3")
    ]
    static let geminiModels: [ModelOption] = [
        ModelOption(id: geminiDefaultModel, name: "Gemini 3.1 Flash-Lite"),
        ModelOption(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash")
    ]

    static func models(for provider: ExpenseAIProvider) -> [ModelOption] {
        switch provider {
        case .gemini: return geminiModels
        case .openCodeZen: return zenModels
        case .nvidia: return nvidiaModels
        }
    }

    static func defaultModel(for provider: ExpenseAIProvider) -> String {
        switch provider {
        case .gemini: return geminiDefaultModel
        case .openCodeZen: return zenDefaultModel
        case .nvidia: return nvidiaDefaultModel
        }
    }
    static let allowedCategories = [
        "Restaurantes y bares", "Tiendita", "Despensa / supermercado", "Entretenimiento",
        "Viajes", "Transporte", "Deporte", "Compras personales", "Software y suscripciones",
        "Salud", "Club Amigos / Proyectos", "Comisiones y finanzas", "Otros / Por revisar"
    ]
    static let allowedTags = ["viaje", "ordinario", "extraordinario", "fijo", "variable", "personal", "proyecto"]

    enum ClassificationError: LocalizedError {
        case missingAPIKey(ExpenseAIProvider)
        case invalidModel
        case provider(String)
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let provider):
                return "Configura tu clave de \(provider.displayName) antes de clasificar."
            case .invalidModel:
                return "El modelo seleccionado no está disponible para este proveedor."
            case .provider(let message):
                return message
            case .invalidResponse(let diagnostic):
                return "La respuesta de IA no tenía un formato reconocible. \(diagnostic)"
            }
        }
    }

    private struct Request: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double?
        let topP: Double?
        let maxTokens: Int?
        let stream: Bool?
        let chatTemplateKwargs: ChatTemplateKwargs?
        let responseFormat: ResponseFormat?
        let reasoningEffort: String?

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream
            case topP = "top_p"
            case maxTokens = "max_tokens"
            case chatTemplateKwargs = "chat_template_kwargs"
            case responseFormat = "response_format"
            case reasoningEffort = "reasoning_effort"
        }
    }

    private struct ResponseFormat: Encodable {
        let type: String
        let jsonSchema: JSONSchema?

        enum CodingKeys: String, CodingKey {
            case type
            case jsonSchema = "json_schema"
        }
    }

    private struct JSONSchema: Encodable {
        let name: String
        let strict: Bool
        let schema: ClassificationSchema
    }

    private struct ClassificationSchema: Encodable {
        struct RootProperties: Encodable {
            let classifications = ClassificationArray()
        }

        struct ClassificationArray: Encodable {
            let type = "array"
            let items = ClassificationItem()
        }

        struct ClassificationItem: Encodable {
            let type = "object"
            let properties = ClassificationProperties()
            let required = ["id", "category", "tags", "travelRelated", "confidence", "reason", "requires_review"]
            let additionalProperties = false

            enum CodingKeys: String, CodingKey {
                case type, properties, required
                case additionalProperties = "additionalProperties"
            }
        }

        struct ClassificationProperties: Encodable {
            let id = StringProperty()
            let category = CategoryProperty()
            let tags = TagsProperty()
            let travelRelated = BooleanProperty()
            let confidence = NumberProperty()
            let reason = StringProperty()
            let requiresReview = BooleanProperty()

            enum CodingKeys: String, CodingKey {
                case id, category, tags, confidence, reason, travelRelated
                case requiresReview = "requires_review"
            }
        }

        struct StringProperty: Encodable { let type = "string" }
        struct BooleanProperty: Encodable { let type = "boolean" }
        struct NumberProperty: Encodable {
            let type = "number"
            let minimum = 0.0
            let maximum = 1.0
        }
        struct CategoryProperty: Encodable {
            let type = "string"
            let values = ExpenseAIClassifier.allowedCategories

            enum CodingKeys: String, CodingKey {
                case type
                case values = "enum"
            }
        }
        struct TagsProperty: Encodable {
            struct Items: Encodable {
                let type = "string"
                let values = ExpenseAIClassifier.allowedTags

                enum CodingKeys: String, CodingKey {
                    case type
                    case values = "enum"
                }
            }

            let type = "array"
            let items = Items()
            let uniqueItems = true

            enum CodingKeys: String, CodingKey {
                case type, items
                case uniqueItems = "uniqueItems"
            }
        }

        let type = "object"
        let properties = RootProperties()
        let required = ["classifications"]
        let additionalProperties = false

        enum CodingKeys: String, CodingKey {
            case type, properties, required
            case additionalProperties = "additionalProperties"
        }
    }

    private struct ChatTemplateKwargs: Encodable {
        let thinking: Bool
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    private struct Response: Decodable {
        let choices: [Choice]
    }

    private struct Choice: Decodable {
        let message: ResponseMessage
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    private struct ResponseMessage: Decodable {
        let content: String?

        private struct ContentBlock: Decodable {
            let text: String?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let text = try? container.decode(String.self, forKey: .content) {
                content = text
            } else if let blocks = try? container.decode([ContentBlock].self, forKey: .content) {
                let joined = blocks.compactMap(\.text).joined(separator: "\n")
                content = joined.isEmpty ? nil : joined
            } else {
                content = nil
            }
        }

        private enum CodingKeys: String, CodingKey { case content }
    }

    private struct ProviderErrorEnvelope: Decodable {
        struct ProviderError: Decodable { let message: String? }
        let error: ProviderError?
        let message: String?
    }

    private struct ClassificationPayload: Decodable {
        let id: String?
        let category: String?
        let travelRelated: Bool?
        let tags: [String]?
        let confidence: Double?
        let reason: String?
        let requiresReview: Bool?

        enum CodingKeys: String, CodingKey {
            case id, category, tags, confidence, reason
            case travelRelated = "travelRelated"
            case requiresReview = "requires_review"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decode(String.self, forKey: .id)
            category = try? container.decode(String.self, forKey: .category)
            reason = try? container.decode(String.self, forKey: .reason)

            if let values = try? container.decode([String].self, forKey: .tags) {
                tags = values
            } else if let value = try? container.decode(String.self, forKey: .tags) {
                tags = value.split(separator: ",").map(String.init)
            } else {
                tags = nil
            }

            if let value = try? container.decode(Double.self, forKey: .confidence) {
                confidence = value
            } else if let value = try? container.decode(String.self, forKey: .confidence) {
                confidence = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                confidence = nil
            }

            travelRelated = Self.decodeFlexibleBool(container, key: .travelRelated)
            requiresReview = Self.decodeFlexibleBool(container, key: .requiresReview)
        }

        private static func decodeFlexibleBool(
            _ container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) -> Bool? {
            if let value = try? container.decode(Bool.self, forKey: key) { return value }
            if let value = try? container.decode(String.self, forKey: key) {
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "si", "sí", "1": return true
                case "false", "no", "0": return false
                default: return nil
                }
            }
            return nil
        }
    }

    private struct ClassificationWrapper: Decodable {
        let classifications: [ClassificationPayload]
    }

    private struct BatchResult {
        let classifications: [AIClassification]
        let receivedCount: Int
        let finishReason: String?
        let issues: [String]
    }

    static func classify(
        movements: [Movement],
        apiKey: String,
        model: String,
        provider: ExpenseAIProvider
    ) async throws -> AIClassificationRunResult {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClassificationError.missingAPIKey(provider)
        }
        guard models(for: provider).contains(where: { $0.id == model }) else {
            throw ClassificationError.invalidModel
        }
        guard !movements.isEmpty else {
            return AIClassificationRunResult(
                classifications: [], provider: provider, model: model,
                requestedCount: 0, receivedCount: 0, acceptedCount: 0,
                unresolvedCount: 0, retryCount: 0, finishReasons: [], issues: []
            )
        }
        // This API is deliberately narrower than the UI's pending list. If a
        // caller accidentally passes a quarantined row, income, refund, card
        // payment or own-account transfer, fail closed before any description
        // leaves the device.
        guard movements.allSatisfy({ movement in
            guard movement.flow == .expense else { return false }
            switch movement.kind {
            case .cardPayment?, .bankTransfer?, .refund?, .credit?, .msi?:
                return false
            default:
                return true
            }
        }) else {
            throw ClassificationError.invalidResponse("Se rechazó un movimiento que no era un gasto canónico elegible.")
        }

        var classificationsByID: [UUID: AIClassification] = [:]
        var receivedCount = 0
        var retryCount = 0
        var finishReasons = Set<String>()
        var issues: [String] = []
        var consecutiveEmptyBatches = 0
        var start = 0
        while start < movements.count {
            let end = min(start + maxBatchSize, movements.count)
            let batch = Array(movements[start..<end])
            let batchResult: BatchResult
            do {
                batchResult = try await classifyBatch(
                    movements: batch,
                    apiKey: apiKey,
                    model: model,
                    provider: provider
                )
            } catch {
                issues.append("provider-error")
                if classificationsByID.isEmpty { throw error }
                break
            }

            receivedCount += batchResult.receivedCount
            issues.append(contentsOf: batchResult.issues)
            if let finish = batchResult.finishReason { finishReasons.insert(finish) }
            for classification in batchResult.classifications where classificationsByID[classification.movementID] == nil {
                classificationsByID[classification.movementID] = classification
            }

            var unresolved = batch.filter { classificationsByID[$0.id] == nil }
            if unresolved.isEmpty {
                consecutiveEmptyBatches = 0
                start = end
                continue
            }

            // Recover only the missing rows. If an entire batch has an
            // unrecognizable shape, probe one row first so a provider outage
            // cannot fan out into dozens of futile requests.
            let firstPass = batchResult.classifications.isEmpty ? Array(unresolved.prefix(1)) : unresolved
            var probeSucceeded = !batchResult.classifications.isEmpty
            for movement in firstPass {
                retryCount += 1
                do {
                    let retry = try await classifyBatch(
                        movements: [movement], apiKey: apiKey, model: model, provider: provider
                    )
                    receivedCount += retry.receivedCount
                    issues.append(contentsOf: retry.issues)
                    if let finish = retry.finishReason { finishReasons.insert(finish) }
                    if let classification = retry.classifications.first {
                        classificationsByID[classification.movementID] = classification
                        probeSucceeded = true
                    }
                } catch {
                    issues.append("retry-provider-error")
                }
            }

            unresolved = batch.filter { classificationsByID[$0.id] == nil }
            if batchResult.classifications.isEmpty && probeSucceeded {
                for movement in unresolved {
                    retryCount += 1
                    do {
                        let retry = try await classifyBatch(
                            movements: [movement], apiKey: apiKey, model: model, provider: provider
                        )
                        receivedCount += retry.receivedCount
                        issues.append(contentsOf: retry.issues)
                        if let finish = retry.finishReason { finishReasons.insert(finish) }
                        if let classification = retry.classifications.first {
                            classificationsByID[classification.movementID] = classification
                        }
                    } catch {
                        issues.append("retry-provider-error")
                    }
                }
            }

            if batchResult.classifications.isEmpty && !probeSucceeded {
                consecutiveEmptyBatches += 1
                if consecutiveEmptyBatches >= 2 {
                    issues.append("provider-format-stopped")
                    break
                }
            } else {
                consecutiveEmptyBatches = 0
            }
            start = end
        }

        let classifications = movements.compactMap { classificationsByID[$0.id] }
        let autoApplicable = classifications.filter {
            !$0.requiresReview && $0.confidence >= 0.8 && $0.category != "Otros / Por revisar"
        }.count
        let result = AIClassificationRunResult(
            classifications: classifications,
            provider: provider,
            model: model,
            requestedCount: movements.count,
            receivedCount: receivedCount,
            acceptedCount: classifications.count,
            unresolvedCount: max(movements.count - autoApplicable, 0),
            retryCount: retryCount,
            finishReasons: finishReasons.sorted(),
            issues: Array(Set(issues)).sorted()
        )
        guard !classifications.isEmpty else {
            throw ClassificationError.invalidResponse(result.diagnosticSummary)
        }
        return result
    }

    private static func classifyBatch(
        movements: [Movement],
        apiKey: String,
        model: String,
        provider: ExpenseAIProvider
    ) async throws -> BatchResult {
        guard !movements.isEmpty else {
            return BatchResult(classifications: [], receivedCount: 0, finishReason: nil, issues: [])
        }

        let input = movements.map { movement in
            [
                "id": movement.id.uuidString,
                "comercio": String(movement.title.prefix(180)),
                "importe_mxn": NSDecimalNumber(decimal: movement.amount < 0 ? -movement.amount : movement.amount).stringValue,
                "fecha": ISO8601DateFormatter().string(from: movement.date)
            ]
        }
        let encoder = JSONEncoder()
        let inputData = try encoder.encode(input)
        let inputJSON = String(data: inputData, encoding: .utf8) ?? "[]"
        let categories = allowedCategories.joined(separator: ", ")
        let tags = allowedTags.joined(separator: ", ")
        let system = """
        Eres el clasificador de gastos de una app financiera. Clasifica cada movimiento usando solo estas categorías: \(categories). Usa únicamente estas etiquetas secundarias, sin duplicarlas: \(tags). Club Amigos / Proyectos tiene prioridad si el concepto identifica un proyecto. No clasifiques ingresos, reembolsos, pagos de tarjeta, transferencias ni MSI: esos movimientos no deben enviarse a esta función. No recibes ni debes solicitar PDFs, cuentas, números de tarjeta, saldos o metadatos del estado. Identifica si pertenece a un viaje. Conserva exactamente cada id. Devuelve una clasificación por cada id recibido. confidence debe ser un número entre 0 y 1. Si no hay evidencia suficiente usa Otros / Por revisar y requires_review=true. Responde únicamente un objeto JSON sin markdown, con la propiedad \"classifications\" que contenga objetos de la forma {\"id\":\"UUID\",\"category\":\"Categoría\",\"tags\":[\"personal\",\"variable\",\"ordinario\"],\"travelRelated\":true,\"confidence\":0.9,\"reason\":\"evidencia breve\",\"requires_review\":false}.
        """
        let user = "Clasifica estos movimientos pendientes:\n\(inputJSON)"
        let usesDeterministicOptions = provider == .nvidia || provider == .gemini
        var requestBody = Request(
            model: model,
            messages: [
                Message(role: "system", content: system),
                Message(role: "user", content: user)
            ],
            // Zen rejects several OpenAI-compatible tuning fields, so its
            // established request remains minimal. NVIDIA receives an
            // explicit deterministic JSON-oriented configuration.
            temperature: usesDeterministicOptions ? 0 : nil,
            topP: usesDeterministicOptions ? 1 : nil,
            maxTokens: usesDeterministicOptions ? 4096 : nil,
            stream: usesDeterministicOptions ? false : nil,
            chatTemplateKwargs: provider == .nvidia && model == nvidiaDefaultModel ? ChatTemplateKwargs(thinking: false) : nil,
            responseFormat: responseFormat(for: provider),
            reasoningEffort: provider == .nvidia && model == "moonshotai/kimi-k3" ? "low" : nil
        )
        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(requestBody)

        var requestIssues: [String] = []
        var networkResult = try await perform(request: request, provider: provider)
        if provider == .nvidia,
           let status = (networkResult.1 as? HTTPURLResponse)?.statusCode,
           [400, 422].contains(status),
           requestBody.responseFormat != nil {
            // Some NIM deployments expose Chat Completions but not JSON mode.
            // Retry the same narrow prompt without that optional capability.
            requestIssues.append("structured-output-fallback")
            requestBody = Request(
                model: model,
                messages: requestBody.messages,
                temperature: requestBody.temperature,
                topP: requestBody.topP,
                maxTokens: requestBody.maxTokens,
                stream: requestBody.stream,
                chatTemplateKwargs: requestBody.chatTemplateKwargs,
                responseFormat: nil,
                reasoningEffort: requestBody.reasoningEffort
            )
            request.httpBody = try encoder.encode(requestBody)
            networkResult = try await perform(request: request, provider: provider)
        }
        let (data, response) = networkResult
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClassificationError.provider("No pudimos conectar con \(provider.displayName).")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let providerMessage = (try? JSONDecoder().decode(ProviderErrorEnvelope.self, from: data))
                .flatMap { $0.error?.message ?? $0.message }
                .map { String($0.prefix(220)) }
            let detail = providerMessage.map { ": \($0)" } ?? "."
            throw ClassificationError.provider("\(provider.displayName) devolvió un error (\(httpResponse.statusCode))\(detail)")
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let choice = decoded.choices.first else {
            return BatchResult(
                classifications: [], receivedCount: 0, finishReason: nil,
                issues: requestIssues + ["response-envelope-invalid"]
            )
        }
        guard let content = choice.message.content, !content.isEmpty,
              let payloads = decodePayloads(from: content) else {
            let issue = choice.finishReason == "length" ? "response-truncated" : "response-json-invalid"
            return BatchResult(
                classifications: [], receivedCount: 0, finishReason: choice.finishReason,
                issues: requestIssues + [issue]
            )
        }

        let requested = Set(movements.map(\.id))
        var seen = Set<UUID>()
        var parsed: [AIClassification] = []
        var issues = requestIssues
        for payload in payloads {
            guard let rawID = payload.id,
                  let movementID = UUID(uuidString: rawID) else {
                issues.append("id-invalid")
                continue
            }
            guard requested.contains(movementID) else {
                issues.append("id-out-of-scope")
                continue
            }
            guard seen.insert(movementID).inserted else {
                issues.append("id-duplicate")
                continue
            }
            guard let rawCategory = payload.category,
                  let category = canonicalCategory(rawCategory) else {
                issues.append("category-invalid")
                continue
            }
            guard let confidence = payload.confidence,
                  confidence >= 0, confidence <= 1 else {
                issues.append("confidence-invalid")
                continue
            }
            let validTags = normalizedTags(payload.tags ?? [])
            let mustReview = payload.requiresReview ?? (confidence < 0.8 || category == "Otros / Por revisar")
            parsed.append(AIClassification(
                movementID: movementID,
                category: category,
                travelRelated: payload.travelRelated ?? (category == "Viajes"),
                tags: validTags,
                confidence: confidence,
                requiresReview: mustReview || category == "Otros / Por revisar",
                reason: payload.reason.map { String($0.prefix(160)) }
            ))
        }
        if parsed.count < movements.count {
            issues.append(choice.finishReason == "length" ? "response-truncated" : "rows-missing")
        }
        return BatchResult(
            classifications: parsed,
            receivedCount: payloads.count,
            finishReason: choice.finishReason,
            issues: Array(Set(issues)).sorted()
        )
    }

    private static func responseFormat(for provider: ExpenseAIProvider) -> ResponseFormat? {
        switch provider {
        case .gemini:
            return ResponseFormat(
                type: "json_schema",
                jsonSchema: JSONSchema(
                    name: "expense_classifications",
                    strict: true,
                    schema: ClassificationSchema()
                )
            )
        case .nvidia:
            return ResponseFormat(type: "json_object", jsonSchema: nil)
        case .openCodeZen:
            // The free Zen gateway rejects structured-output fields for some
            // hosted models, so it receives the minimal compatible request.
            return nil
        }
    }

    private static func perform(request: URLRequest, provider: ExpenseAIProvider) async throws -> (Data, URLResponse) {
        let retryableStatusCodes = Set([408, 425, 429, 500, 502, 503, 504, 529])
        let retryableURLErrors: Set<URLError.Code> = [.timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet]
        let delays: [UInt64] = [1_000_000_000, 3_000_000_000]

        for attempt in 0...delays.count {
            do {
                let result = try await URLSession.shared.data(for: request)
                if let response = result.1 as? HTTPURLResponse,
                   retryableStatusCodes.contains(response.statusCode),
                   attempt < delays.count {
                    try await Task.sleep(nanoseconds: delays[attempt])
                    continue
                }
                return result
            } catch let error as URLError {
                guard retryableURLErrors.contains(error.code), attempt < delays.count else {
                    throw ClassificationError.provider("\(provider.displayName) no respondió: \(error.localizedDescription)")
                }
                try await Task.sleep(nanoseconds: delays[attempt])
            }
        }
        throw ClassificationError.provider("\(provider.displayName) no respondió después de varios intentos.")
    }

    private static func extractJSON(from content: String) -> String? {
        let cleaned = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = cleaned.firstIndex(of: "["),
           let end = cleaned.lastIndex(of: "]"),
           start <= end {
            return String(cleaned[start...end])
        }
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}"),
           start <= end {
            return String(cleaned[start...end])
        }
        return nil
    }

    private static func decodePayloads(from content: String) -> [ClassificationPayload]? {
        let cleaned = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [cleaned]
        if let extracted = extractJSON(from: cleaned), extracted != cleaned {
            candidates.append(extracted)
        }
        for candidate in candidates {
            let data = Data(candidate.utf8)
            if let wrapper = try? JSONDecoder().decode(ClassificationWrapper.self, from: data) {
                return wrapper.classifications
            }
            if let array = try? JSONDecoder().decode([ClassificationPayload].self, from: data) {
                return array
            }
        }
        return nil
    }

    private static func canonicalCategory(_ raw: String) -> String? {
        let normalized = normalizedLabel(raw)
        let aliases: [String: String] = [
            "restaurante": "Restaurantes y bares",
            "restaurantes": "Restaurantes y bares",
            "restaurantes bares": "Restaurantes y bares",
            "bares restaurantes": "Restaurantes y bares",
            "cafeteria": "Restaurantes y bares",
            "delivery": "Restaurantes y bares",
            "tienda de conveniencia": "Tiendita",
            "tiendas de conveniencia": "Tiendita",
            "minisuper": "Tiendita",
            "despensa": "Despensa / supermercado",
            "supermercado": "Despensa / supermercado",
            "compras": "Compras personales",
            "compra personal": "Compras personales",
            "software": "Software y suscripciones",
            "suscripciones": "Software y suscripciones",
            "club amigos": "Club Amigos / Proyectos",
            "proyectos": "Club Amigos / Proyectos",
            "comisiones": "Comisiones y finanzas",
            "finanzas": "Comisiones y finanzas",
            "otro": "Otros / Por revisar",
            "otros": "Otros / Por revisar",
            "por revisar": "Otros / Por revisar",
            "viaje": "Viajes"
        ]
        if let alias = aliases[normalized] { return alias }
        return allowedCategories.first {
            normalizedLabel($0) == normalized
        }
    }

    private static func normalizedTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in raw {
            let normalized = normalizedLabel(tag)
            guard let canonical = allowedTags.first(where: { normalizedLabel($0) == normalized }),
                  seen.insert(canonical).inserted else { continue }
            result.append(canonical)
        }
        return result
    }

    private static func normalizedLabel(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_MX"))
            .replacingOccurrences(of: "&", with: " y ")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

enum ExpenseAISettingsStore {
    private static let service = "mx.marcelito.personal.expense-ai"
    private static let legacyZenService = "mx.marcelito.personal.zen"
    private static let legacyZenAccount = "api-key"
    private static let selectedProviderKey = "marcelito.expense-ai.provider"

    static var selectedProvider: ExpenseAIProvider {
        guard let raw = UserDefaults.standard.string(forKey: selectedProviderKey),
              let provider = ExpenseAIProvider(rawValue: raw) else { return .gemini }
        return provider
    }

    static func apiKey(for provider: ExpenseAIProvider) -> String? {
        if let current = read(query: baseQuery(for: provider)) { return current }
        // Existing users keep their Zen configuration after this migration.
        guard provider == .openCodeZen else { return nil }
        return read(query: legacyZenQuery())
    }

    static func selectedModel(for provider: ExpenseAIProvider) -> String {
        let saved = UserDefaults.standard.string(forKey: selectedModelKey(for: provider))
        return ExpenseAIClassifier.models(for: provider).contains(where: { $0.id == saved })
            ? saved!
            : ExpenseAIClassifier.defaultModel(for: provider)
    }

    static func save(provider: ExpenseAIProvider, apiKey: String, model: String) throws {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { throw ExpenseAIClassifier.ClassificationError.missingAPIKey(provider) }
        guard ExpenseAIClassifier.models(for: provider).contains(where: { $0.id == model }) else {
            throw ExpenseAIClassifier.ClassificationError.invalidModel
        }
        let query = baseQuery(for: provider)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(cleanKey.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw ExpenseAIClassifier.ClassificationError.provider("No pudimos guardar la clave de forma segura.")
        }
        UserDefaults.standard.set(provider.rawValue, forKey: selectedProviderKey)
        UserDefaults.standard.set(model, forKey: selectedModelKey(for: provider))
    }

    static func delete(provider: ExpenseAIProvider) {
        SecItemDelete(baseQuery(for: provider) as CFDictionary)
        if provider == .openCodeZen {
            SecItemDelete(legacyZenQuery() as CFDictionary)
        }
        UserDefaults.standard.removeObject(forKey: selectedModelKey(for: provider))
    }

    private static func read(query original: [String: Any]) -> String? {
        var query = original
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func selectedModelKey(for provider: ExpenseAIProvider) -> String {
        "marcelito.expense-ai.model.\(provider.rawValue)"
    }

    private static func baseQuery(for provider: ExpenseAIProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(provider.rawValue)-api-key"
        ]
    }

    private static func legacyZenQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyZenService,
            kSecAttrAccount as String: legacyZenAccount
        ]
    }
}

struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProvider = ExpenseAISettingsStore.selectedProvider
    @State private var apiKey = ExpenseAISettingsStore.apiKey(for: ExpenseAISettingsStore.selectedProvider) ?? ""
    @State private var selectedModel = ExpenseAISettingsStore.selectedModel(for: ExpenseAISettingsStore.selectedProvider)
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Proveedor") {
                    Picker("Servicio de IA", selection: $selectedProvider) {
                        ForEach(ExpenseAIProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section(selectedProvider.displayName) {
                    SecureField("Clave API", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Modelo", selection: $selectedModel) {
                        ForEach(ExpenseAIClassifier.models(for: selectedProvider)) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    Text("La clave de \(selectedProvider.displayName) se guarda únicamente en el llavero de este iPhone. El proveedor solo recibe descripciones, importes y fechas de gastos ya conciliados para sugerir su categoría y etiquetas. Nunca recibe PDFs, cuentas ni saldos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Guardar configuración") {
                        do {
                            try ExpenseAISettingsStore.save(provider: selectedProvider, apiKey: apiKey, model: selectedModel)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .frame(maxWidth: .infinity)
                    if ExpenseAISettingsStore.apiKey(for: selectedProvider) != nil {
                        Button("Eliminar clave", role: .destructive) {
                            ExpenseAISettingsStore.delete(provider: selectedProvider)
                            apiKey = ""
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                Section("Privacidad") {
                    Text("La clasificación es opcional. Gemini, OpenCode Zen y NVIDIA son servicios externos: evita enviar descripciones que contengan información sensible que no quieras compartir.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("La IA nunca aprueba cifras por sí sola: cada resultado debe conciliar contra los totales impresos antes de alimentar los KPI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Clasificación IA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .onChange(of: selectedProvider) { _, provider in
                apiKey = ExpenseAISettingsStore.apiKey(for: provider) ?? ""
                selectedModel = ExpenseAISettingsStore.selectedModel(for: provider)
            }
            .alert("No se guardó la configuración", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("Aceptar", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .scrollContentBackground(.hidden)
            .background(MarcelitoAmbientBackground())
            .foregroundStyle(Color.marcelitoNavy)
        }
    }
}
