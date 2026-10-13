import Foundation
import PDFKit

struct CardDocumentMetadata: Sendable {
    var dueDate: Date?
    var annualRate: Decimal?
    static func parse(_ text: String) -> Self {
        let normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_MX")).lowercased()
        var due: Date?
        let datePattern = #"fecha\s+limite\s+(?:de\s+)?pago\s*[:\-]?\s*(\d{1,2}[/-]\d{1,2}[/-]\d{4}|\d{1,2}\s+(?:de\s+)?[a-z]+\s+(?:de\s+)?\d{4})"#
        if let regex = try? NSRegularExpression(pattern: datePattern), let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)), let range = Range(match.range(at: 1), in: normalized) {
            let token = String(normalized[range])
            for pattern in ["d/M/yyyy", "d-M-yyyy", "d 'de' MMMM 'de' yyyy", "d MMMM yyyy", "d 'de' MMMM yyyy"] {
                let f = DateFormatter(); f.locale = Locale(identifier: "es_MX"); f.dateFormat = pattern; f.isLenient = false
                if let date = f.date(from: token) { due = date; break }
            }
        }
        var annual: Decimal?
        let ratePattern = #"tasa\s+(?:de\s+)?interes\s+(?:ordinaria\s+)?anual\s*(?:ordinaria\s*)?(?:nominal\s*)?[:\-]?\s*(\d{1,3}(?:[.,]\d{1,4})?)\s*%"#
        if let regex = try? NSRegularExpression(pattern: ratePattern), let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)), let range = Range(match.range(at: 1), in: normalized), let rate = Decimal(string: normalized[range].replacingOccurrences(of: ",", with: ".")), rate >= 0, rate <= 200 {
            annual = rate / 100
        }
        return Self(dueDate: due, annualRate: annual)
    }
    /// Only selectable header text. No OCR replay, no financial-row mutation.
    static func read(_ url: URL) -> Self {
        guard let document = PDFDocument(url: url) else { return Self() }
        let text = (0..<min(2, document.pageCount)).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        return parse(text)
    }
}
