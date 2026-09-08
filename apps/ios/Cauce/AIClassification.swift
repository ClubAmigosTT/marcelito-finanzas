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
    static let maxBatchSize = 12
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
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let provider):
                return "Configura tu clave de \(provider.displayName) antes de clasificar."
            case .invalidModel:
                return "El modelo seleccionado no está disponible para este proveedor."
            case .provider(let message):
                return message
            case .invalidResponse:
                return "La respuesta de IA no tenía un formato reconocible."
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
    }

    private struct ResponseMessage: Decodable {
        let content: String?
    }

    private struct ProviderErrorEnvelope: Decodable {
        struct ProviderError: Decodable { let message: String? }
        let error: ProviderError?
        let message: String?
    }

    private struct ClassificationPayload: Decodable {
        let id: String
        let category: String
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
    }

    private struct ClassificationWrapper: Decodable {
        let classifications: [ClassificationPayload]
    }

    static func classify(
        movements: [Movement],
        apiKey: String,
        model: String,
        provider: ExpenseAIProvider
    ) async throws -> [AIClassification] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClassificationError.missingAPIKey(provider)
        }
        guard models(for: provider).contains(where: { $0.id == model }) else {
            throw ClassificationError.invalidModel
        }
        guard !movements.isEmpty else { return [] }
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
            throw ClassificationError.invalidResponse
        }

        var classifications: [AIClassification] = []
        var start = 0
        while start < movements.count {
            let end = min(start + maxBatchSize, movements.count)
            classifications.append(contentsOf: try await classifyBatch(
                movements: Array(movements[start..<end]),
                apiKey: apiKey,
                model: model,
                provider: provider
            ))
            start = end
        }

        // A provider may repeat an item when a batch contains similar rows.
        // Keep the first answer for each requested movement and never allow
        // an unknown ID to mutate the local ledger.
        var seen = Set<UUID>()
        let requested = Set(movements.map(\.id))
        return classifications.filter { requested.contains($0.movementID) && seen.insert($0.movementID).inserted }
    }

    private static func classifyBatch(
        movements: [Movement],
        apiKey: String,
        model: String,
        provider: ExpenseAIProvider
    ) async throws -> [AIClassification] {
        guard !movements.isEmpty else { return [] }

        let input = movements.map { movement in
            [
                "id": movement.id.uuidString,
                "comercio": String(movement.title.prefix(240)),
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
        Eres el clasificador de gastos de una app financiera. Clasifica cada movimiento usando solo estas categorías: \(categories). Usa únicamente estas etiquetas secundarias, sin duplicarlas: \(tags). Club Amigos / Proyectos tiene prioridad si el concepto identifica un proyecto. No clasifiques ingresos, reembolsos, pagos de tarjeta, transferencias ni MSI: esos movimientos no deben enviarse a esta función. No recibes ni debes solicitar PDFs, cuentas, números de tarjeta, saldos o metadatos del estado. Identifica si pertenece a un viaje. Conserva exactamente cada id. Responde únicamente un objeto JSON sin markdown, con la propiedad \"classifications\" que contenga un objeto por movimiento de la forma {\"id\":\"UUID\",\"category\":\"Categoría\",\"tags\":[\"personal\",\"variable\",\"ordinario\"],\"travelRelated\":true|false,\"confidence\":0.0,"reason":"evidencia breve","requires_review":false}.
        """
        let user = "Clasifica estos movimientos pendientes:\n\(inputJSON)"
        let usesDeterministicOptions = provider == .nvidia || provider == .gemini
        let requestBody = Request(
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
            maxTokens: usesDeterministicOptions ? 2048 : nil,
            stream: usesDeterministicOptions ? false : nil,
            chatTemplateKwargs: provider == .nvidia && model == nvidiaDefaultModel ? ChatTemplateKwargs(thinking: false) : nil,
            responseFormat: provider == .gemini ? ResponseFormat(type: "json_object") : nil,
            reasoningEffort: provider == .nvidia && model == "moonshotai/kimi-k3" ? "low" : nil
        )
        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(requestBody)

        let (data, response) = try await perform(request: request, provider: provider)
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
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let content = decoded.choices.first?.message.content,
              let json = extractJSON(from: content) else {
            throw ClassificationError.invalidResponse
        }
        let payloads: [ClassificationPayload]
        if let array = try? JSONDecoder().decode([ClassificationPayload].self, from: Data(json.utf8)) {
            payloads = array
        } else if let wrapper = try? JSONDecoder().decode(ClassificationWrapper.self, from: Data(json.utf8)) {
            payloads = wrapper.classifications
        } else {
            throw ClassificationError.invalidResponse
        }

        let requested = Set(movements.map(\.id))
        var seen = Set<UUID>()
        let parsed = payloads.compactMap { (payload: ClassificationPayload) -> AIClassification? in
            guard let movementID = UUID(uuidString: payload.id),
                  requested.contains(movementID),
                  seen.insert(movementID).inserted,
                  let category = canonicalCategory(payload.category),
                  let validTags = normalizedTags(payload.tags ?? []),
                  let confidence = payload.confidence,
                  confidence >= 0, confidence <= 1 else { return nil }
            return AIClassification(
                movementID: movementID,
                category: category,
                travelRelated: payload.travelRelated ?? (category == "Viajes"),
                tags: validTags,
                confidence: confidence,
                requiresReview: payload.requiresReview ?? (confidence < 0.8),
                reason: payload.reason
            )
        }
        // A partial answer is not safe to apply: it makes the UI look as if
        // every pending expense was classified while silently leaving gaps.
        // Require exactly one valid result for every requested movement.
        guard parsed.count == movements.count, seen.count == movements.count else {
            throw ClassificationError.invalidResponse
        }
        return parsed
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

    private static func canonicalCategory(_ raw: String) -> String? {
        let normalized = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return allowedCategories.first {
            $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) == normalized
        }
    }

    private static func normalizedTags(_ raw: [String]) -> [String]? {
        var seen = Set<String>()
        for tag in raw {
            guard allowedTags.contains(tag), seen.insert(tag).inserted else { return nil }
        }
        return raw
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
