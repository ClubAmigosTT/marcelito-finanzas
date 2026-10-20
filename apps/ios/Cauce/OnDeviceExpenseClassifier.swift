import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Expense categories from Apple's on-device language model. Nothing leaves
/// the iPhone, there is no key to configure and it costs nothing; it needs
/// Apple Intelligence (iPhone 15 Pro or later, iOS 26+, turned on).
enum OnDeviceExpenseClassifier {
    static let modelID = "apple-on-device"

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static var statusText: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "Listo: clasifica dentro de este iPhone, sin enviar nada a internet."
            case .unavailable(.deviceNotEligible):
                return "Este iPhone no es compatible con Apple Intelligence. Usa un servicio externo."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Activa Apple Intelligence en Ajustes del iPhone para usarlo."
            case .unavailable(.modelNotReady):
                return "El modelo de Apple se está descargando. Intenta más tarde."
            default:
                return "Apple Intelligence no está disponible en este momento."
            }
        }
        #endif
        return "Requiere iOS 26 o posterior con Apple Intelligence."
    }

    static func classify(_ movements: [Movement], merchant: (Movement) -> String?) async throws -> [AIClassification] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isAvailable {
            return try await OnDeviceModelRunner.classify(movements, merchant: merchant)
        }
        #endif
        throw ExpenseAIClassifier.ClassificationError.provider(statusText)
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct OnDeviceCategoryGuess {
    @Guide(description: "Una categoría exacta de la lista permitida")
    var category: String
    @Guide(description: "true solo si el gasto forma parte de un viaje (vuelo, hotel o consumo fuera de la ciudad de residencia)")
    var travelRelated: Bool
    @Guide(description: "Confianza entre 0 y 1", .range(0...1))
    var confidence: Double
    @Guide(description: "Motivo breve en español")
    var reason: String
}

@available(iOS 26.0, *)
enum OnDeviceModelRunner {
    static func classify(_ movements: [Movement], merchant: (Movement) -> String?) async throws -> [AIClassification] {
        let categories = ExpenseAIClassifier.allowedCategories.joined(separator: "; ")
        let instructions = """
        Clasificas gastos de una persona en México a partir del texto del cargo en su estado de cuenta. \
        Categorías permitidas: \(categories). Responde con una sola categoría exactamente como aparece en la lista. \
        Los prefijos MERCADOPAGO*, BILLPOCKET*, BPK*, BZPAY*, CLIP*, TST*, SQ* y DLOCAL* son procesadores de pago: \
        clasifica el comercio que sigue. REST es restaurante, EST es estacionamiento, PELUQ es peluquería. \
        Si el texto es un nombre de persona o no permite saber qué se compró, usa Otros / Por revisar con confianza baja.
        """
        var results: [AIClassification] = []
        var firstError: Error?
        for movement in movements {
            guard let text = merchant(movement) else { continue }
            // A fresh session per movement keeps every request well inside
            // the on-device context window.
            let session = LanguageModelSession(instructions: instructions)
            let amount = NSDecimalNumber(decimal: movement.amount < 0 ? -movement.amount : movement.amount).stringValue
            do {
                let response = try await session.respond(
                    to: "Cargo: \(String(text.prefix(160)))\nImporte: \(amount) MXN",
                    generating: OnDeviceCategoryGuess.self
                )
                let guess = response.content
                guard let category = ExpenseAIClassifier.allowedCategories.first(where: {
                    $0.compare(guess.category, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }) else { continue }
                let confidence = min(max(guess.confidence, 0), 1)
                results.append(AIClassification(
                    movementID: movement.id,
                    category: category,
                    travelRelated: guess.travelRelated || category == "Viajes",
                    tags: [],
                    confidence: confidence,
                    // The small on-device model is often confidently wrong
                    // with names it does not know, so it only suggests.
                    requiresReview: true,
                    reason: String(guess.reason.prefix(160))
                ))
            } catch {
                firstError = firstError ?? error
            }
        }
        if results.isEmpty, let firstError {
            throw ExpenseAIClassifier.ClassificationError.provider("El modelo de Apple no pudo clasificar: \(firstError.localizedDescription)")
        }
        return results
    }
}
#endif
