import Foundation
import Security
import SwiftUI

struct AIClassification: Identifiable {
    let movementID: UUID
    let category: String
    let travelRelated: Bool

    var id: UUID { movementID }
}

enum ZenExpenseClassifier {
    struct FreeModel: Identifiable, Hashable {
        let id: String
        let name: String
    }

    static let endpoint = URL(string: "https://opencode.ai/zen/v1/chat/completions")!
    static let defaultFreeModel = "mimo-v2.5-free"
    static let freeModels: [FreeModel] = [
        FreeModel(id: "mimo-v2.5-free", name: "MiMo V2.5 Free"),
        FreeModel(id: "deepseek-v4-flash-free", name: "DeepSeek V4 Flash Free"),
        FreeModel(id: "north-mini-code-free", name: "North Mini Code Free"),
        FreeModel(id: "nemotron-3-ultra-free", name: "Nemotron 3 Ultra Free"),
        FreeModel(id: "big-pickle", name: "Big Pickle")
    ]
    static let allowedCategories = [
        "Alimentos", "Viajes", "Comidas", "Servicios", "Transporte", "Salud",
        "Compras", "Entretenimiento", "Educación", "Hogar", "Mascotas", "Finanzas",
        "Sin categoría"
    ]

    enum ClassificationError: LocalizedError {
        case missingAPIKey
        case invalidModel
        case provider(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Configura tu clave de OpenCode Zen antes de clasificar."
            case .invalidModel:
                return "El modelo seleccionado no es gratuito o ya no está disponible."
            case .provider(let message):
                return message
            case .invalidResponse:
                return "La respuesta de IA no tenía un formato reconocible."
            }
        }
    }

    private struct Request: Encodable {
        let model: String
        let temperature: Double
        let maxTokens: Int
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model, temperature
            case maxTokens = "max_tokens"
            case messages
        }
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

    private struct ClassificationPayload: Decodable {
        let id: String
        let category: String
        let travelRelated: Bool?

        enum CodingKeys: String, CodingKey {
            case id, category
            case travelRelated = "travelRelated"
        }
    }

    private struct ClassificationWrapper: Decodable {
        let classifications: [ClassificationPayload]
    }

    static func classify(
        movements: [Movement],
        apiKey: String,
        model: String
    ) async throws -> [AIClassification] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClassificationError.missingAPIKey
        }
        guard freeModels.contains(where: { $0.id == model }) else {
            throw ClassificationError.invalidModel
        }
        guard !movements.isEmpty else { return [] }

        let input = movements.map { movement in
            [
                "id": movement.id.uuidString,
                "comercio": movement.title,
                "cuenta": movement.account,
                "importe_mxn": NSDecimalNumber(decimal: movement.amount).stringValue,
                "fecha": ISO8601DateFormatter().string(from: movement.date)
            ]
        }
        let encoder = JSONEncoder()
        let inputData = try encoder.encode(input)
        let inputJSON = String(data: inputData, encoding: .utf8) ?? "[]"
        let categories = allowedCategories.joined(separator: ", ")
        let system = """
        Eres el clasificador de gastos de una app financiera. Clasifica cada movimiento usando solo estas categorías: (categories). No clasifiques ingresos ni transferencias: esos movimientos no deben enviarse a esta función. Identifica si pertenece a un viaje. Conserva exactamente cada id. Responde únicamente un arreglo JSON, sin markdown, con objetos de la forma {\"id\":\"UUID\",\"category\":\"Categoría\",\"travelRelated\":true|false}.
        """
        let user = "Clasifica estos movimientos pendientes:\n(inputJSON)"
        let requestBody = Request(
            model: model,
            temperature: 0,
            maxTokens: 1400,
            messages: [
                Message(role: "system", content: system),
                Message(role: "user", content: user)
            ]
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClassificationError.provider("No pudimos conectar con OpenCode Zen.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ClassificationError.provider("OpenCode Zen devolvió un error (\(httpResponse.statusCode)). Revisa tu clave y vuelve a intentar.")
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

        return payloads.compactMap { payload in
            guard let movementID = UUID(uuidString: payload.id),
                  let category = canonicalCategory(payload.category) else { return nil }
            return AIClassification(
                movementID: movementID,
                category: category,
                travelRelated: payload.travelRelated ?? category == "Viajes"
            )
        }
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
}

enum ZenAPIKeyStore {
    private static let service = "mx.marcelito.personal.zen"
    private static let account = "api-key"
    private static let selectedModelKey = "marcelito.zen.model"

    static var apiKey: String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static var selectedModel: String {
        let saved = UserDefaults.standard.string(forKey: selectedModelKey)
        return ZenExpenseClassifier.freeModels.contains(where: { $0.id == saved })
            ? saved!
            : ZenExpenseClassifier.defaultFreeModel
    }

    static func save(apiKey: String, model: String) throws {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { throw ZenExpenseClassifier.ClassificationError.missingAPIKey }
        let query = baseQuery()
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(cleanKey.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw ZenExpenseClassifier.ClassificationError.provider("No pudimos guardar la clave de forma segura.")
        }
        UserDefaults.standard.set(model, forKey: selectedModelKey)
    }

    static func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
        UserDefaults.standard.removeObject(forKey: selectedModelKey)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ZenAPIKeyStore.apiKey ?? ""
    @State private var selectedModel = ZenAPIKeyStore.selectedModel
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("OpenCode Zen") {
                    SecureField("Clave API", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Modelo gratuito", selection: $selectedModel) {
                        ForEach(ZenExpenseClassifier.freeModels) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    Text("La clave se guarda en el llavero de este iPhone. Solo se envían los movimientos que marques para clasificar y únicamente cuando lo confirmes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Guardar configuración") {
                        do {
                            try ZenAPIKeyStore.save(apiKey: apiKey, model: selectedModel)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .frame(maxWidth: .infinity)
                    if ZenAPIKeyStore.apiKey != nil {
                        Button("Eliminar clave", role: .destructive) {
                            ZenAPIKeyStore.delete()
                            apiKey = ""
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                Section("Privacidad") {
                    Text("La clasificación es opcional. Los modelos gratuitos de Zen son externos: evita enviar descripciones que contengan información sensible que no quieras compartir.")
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
            .alert("No se guardó la configuración", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("Aceptar", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .scrollContentBackground(.hidden)
            .background(Color.marcelitoCream)
            .foregroundStyle(Color.marcelitoNavy)
        }
    }
}
