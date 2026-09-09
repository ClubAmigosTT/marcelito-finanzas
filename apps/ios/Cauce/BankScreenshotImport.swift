import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UIKit
import Vision

let bankScreenshotCaptureStorageKey = "marcelito.bankScreenshotCaptures.v1"

var bankScreenshotFilesDirectoryURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ImportedBankScreenshots", isDirectory: true)
}

enum BankScreenshotSource: String, Codable, CaseIterable, Hashable, Sendable {
    case bbva = "BBVA"
    case santander = "Santander"
    case amex = "Amex"

    var kind: StatementKind { self == .amex ? .card : .bank }

    static func identify(_ value: String) -> BankScreenshotSource? {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        if folded.contains("american express") || folded.contains("platinum credit card") || folded.contains("amex") { return .amex }
        if folded.contains("santander") || folded.contains("super nomina") { return .santander }
        if folded.contains("bbva") || folded.contains("movimiento bbva") { return .bbva }
        return nil
    }
}

struct BankScreenshotMovement: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let title: String
    /// Amount as displayed by the bank application.
    let displayedAmount: Decimal
    /// Ledger-compatible sign used only for matching an official movement.
    let normalizedAmount: Decimal
    let pending: Bool
    let confidence: Double
    let imageFingerprint: String
    let evidence: MovementExtractionEvidence
    var duplicateOf: UUID?
    var matchedOfficialMovementID: UUID?

    init(
        id: UUID = UUID(),
        date: Date,
        title: String,
        displayedAmount: Decimal,
        normalizedAmount: Decimal,
        pending: Bool,
        confidence: Double,
        imageFingerprint: String,
        evidence: MovementExtractionEvidence,
        duplicateOf: UUID? = nil,
        matchedOfficialMovementID: UUID? = nil
    ) {
        self.id = id
        self.date = date
        self.title = title
        self.displayedAmount = displayedAmount
        self.normalizedAmount = normalizedAmount
        self.pending = pending
        self.confidence = confidence
        self.imageFingerprint = imageFingerprint
        self.evidence = evidence
        self.duplicateOf = duplicateOf
        self.matchedOfficialMovementID = matchedOfficialMovementID
    }
}

struct BankScreenshotCapture: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let source: BankScreenshotSource
    let accountKey: String?
    let importedAt: Date
    let imageFingerprints: [String]
    let localImageNames: [String]
    var movements: [BankScreenshotMovement]
    let warnings: [String]

    var uniqueMovements: [BankScreenshotMovement] { movements.filter { $0.duplicateOf == nil } }
    var confirmedCount: Int { uniqueMovements.filter { $0.matchedOfficialMovementID != nil }.count }
    var pendingCount: Int { uniqueMovements.filter(\.pending).count }
    var unconfirmedCount: Int { uniqueMovements.filter { $0.matchedOfficialMovementID == nil }.count }

    var coverageLabel: String {
        let dates = uniqueMovements.map(\.date)
        guard let first = dates.min(), let last = dates.max() else { return "Sin fechas reconocidas" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_MX")
        formatter.dateFormat = Calendar.current.isDate(first, inSameDayAs: last) ? "d MMM yyyy" : "d MMM – "
        if Calendar.current.isDate(first, inSameDayAs: last) { return formatter.string(from: first) }
        let start = formatter.string(from: first)
        formatter.dateFormat = "d MMM yyyy"
        return start + formatter.string(from: last)
    }
}

struct BankScreenshotInput: @unchecked Sendable {
    let data: Data
    let fileName: String
}

struct BankScreenshotImportResult: @unchecked Sendable {
    let source: BankScreenshotSource
    let accountKey: String?
    let importedAt: Date
    let inputs: [BankScreenshotInput]
    let imageFingerprints: [String]
    var movements: [BankScreenshotMovement]
    var warnings: [String]
}

struct BankScreenshotImportReceipt: Identifiable, Sendable {
    let id = UUID()
    let source: BankScreenshotSource
    let imageCount: Int
    let movementCount: Int
    let duplicateCount: Int
    let confirmedCount: Int
    let pendingCount: Int
}

enum BankScreenshotImportError: LocalizedError {
    case unreadableImage
    case unknownSource
    case mixedSources
    case noRows
    case alreadyImported
    case tooManyImages
    case imageTooLarge

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "No pudimos abrir una de las capturas. Prueba con la imagen original."
        case .unknownSource: "No pudimos identificar BBVA, Santander o American Express en las capturas."
        case .mixedSources: "Cada lote debe contener capturas de un solo banco o tarjeta."
        case .noRows: "No encontramos movimientos con fecha, concepto e importe. Usa capturas completas y nítidas."
        case .alreadyImported: "Estas capturas ya estaban guardadas; no se duplicó ningún movimiento."
        case .tooManyImages: "Puedes seleccionar hasta 20 capturas por lote."
        case .imageTooLarge: "Cada captura debe pesar menos de 12 MB."
        }
    }
}

struct BankScreenshotRecognizedLine: @unchecked Sendable {
    let text: String
    let bounds: CGRect
    let confidence: Double
    let imageIndex: Int
}

enum BankScreenshotReader {
    private static let maximumImageBytes = 12 * 1024 * 1024
    private static let monthNumbers: [String: Int] = [
        "enero": 1, "ene": 1, "febrero": 2, "feb": 2, "marzo": 3, "mar": 3,
        "abril": 4, "abr": 4, "mayo": 5, "may": 5, "junio": 6, "jun": 6,
        "julio": 7, "jul": 7, "agosto": 8, "ago": 8, "septiembre": 9, "setiembre": 9, "sep": 9,
        "octubre": 10, "oct": 10, "noviembre": 11, "nov": 11, "diciembre": 12, "dic": 12,
    ]

    static func inspect(
        _ inputs: [BankScreenshotInput],
        sourceHint: String?,
        accountKey: String?,
        capturedAt: Date = .now
    ) throws -> BankScreenshotImportResult {
        guard !inputs.isEmpty else { throw BankScreenshotImportError.noRows }
        guard inputs.count <= 20 else { throw BankScreenshotImportError.tooManyImages }
        guard inputs.allSatisfy({ $0.data.count <= maximumImageBytes }) else { throw BankScreenshotImportError.imageTooLarge }

        let hintedSource = sourceHint.flatMap(BankScreenshotSource.identify)
        var detectedSources = Set<BankScreenshotSource>()
        var parsedMovements: [BankScreenshotMovement] = []
        var warnings: [String] = []
        var fingerprints: [String] = []
        var inferredAccountKey = accountKey

        for (imageIndex, input) in inputs.enumerated() {
            let fingerprint = fingerprint(input.data)
            fingerprints.append(fingerprint)
            let lines = try recognizeLines(in: input.data, imageIndex: imageIndex)
            let joined = lines.map(\.text).joined(separator: "\n")
            let detected = BankScreenshotSource.identify(joined) ?? hintedSource
            guard let source = detected else { throw BankScreenshotImportError.unknownSource }
            detectedSources.insert(source)
            if let hintedSource, hintedSource != source { throw BankScreenshotImportError.mixedSources }
            inferredAccountKey = inferredAccountKey ?? detectAccountKey(in: joined, source: source)
            let rows = parse(lines: lines, source: source, fingerprint: fingerprint, capturedAt: capturedAt)
            if rows.isEmpty { warnings.append("\(input.fileName): no se reconocieron filas completas.") }
            parsedMovements.append(contentsOf: rows)
        }

        guard detectedSources.count == 1, let source = detectedSources.first else { throw BankScreenshotImportError.mixedSources }
        guard !parsedMovements.isEmpty else { throw BankScreenshotImportError.noRows }
        return BankScreenshotImportResult(
            source: source,
            accountKey: inferredAccountKey,
            importedAt: capturedAt,
            inputs: inputs,
            imageFingerprints: fingerprints,
            movements: parsedMovements,
            warnings: Array(Set(warnings)).sorted()
        )
    }

    static func parseTextForTesting(
        _ textLines: [String],
        source: BankScreenshotSource,
        capturedAt: Date,
        accountKey: String? = nil
    ) throws -> BankScreenshotImportResult {
        let fingerprint = "fixture"
        let lines = textLines.enumerated().map { index, text in
            BankScreenshotRecognizedLine(
                text: text,
                bounds: CGRect(x: 0.05, y: CGFloat(1 - Double(index + 1) * 0.04), width: 0.9, height: 0.025),
                confidence: 0.95,
                imageIndex: 0
            )
        }
        let rows = parse(lines: lines, source: source, fingerprint: fingerprint, capturedAt: capturedAt)
        guard !rows.isEmpty else { throw BankScreenshotImportError.noRows }
        return BankScreenshotImportResult(
            source: source,
            accountKey: accountKey,
            importedAt: capturedAt,
            inputs: [],
            imageFingerprints: [fingerprint],
            movements: rows,
            warnings: []
        )
    }

    private static func recognizeLines(in data: Data, imageIndex: Int) throws -> [BankScreenshotRecognizedLine] {
        guard let image = UIImage(data: data), let cgImage = image.cgImage else {
            throw BankScreenshotImportError.unreadableImage
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: cgOrientation(for: image.imageOrientation))
        func perform(languages: [String]?) throws -> [VNRecognizedTextObservation] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if let languages { request.recognitionLanguages = languages }
            try handler.perform([request])
            return request.results ?? []
        }
        let recognized: [VNRecognizedTextObservation]
        do {
            recognized = try perform(languages: ["es-MX", "en-US"])
        } catch {
            // Vision language catalogs vary by iOS/device. The same local OCR
            // must remain available when a regional language tag is rejected.
            recognized = try perform(languages: nil)
        }
        let observations = recognized.compactMap { observation -> (String, CGRect, Double)? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let value = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return (value, observation.boundingBox, Double(candidate.confidence))
        }.sorted { left, right in
            let verticalDistance = abs(left.1.midY - right.1.midY)
            return verticalDistance > 0.014 ? left.1.midY > right.1.midY : left.1.minX < right.1.minX
        }

        var groups: [[(String, CGRect, Double)]] = []
        for observation in observations {
            if let last = groups.indices.last {
                let averageY = groups[last].map { $0.1.midY }.reduce(0, +) / CGFloat(groups[last].count)
                if abs(averageY - observation.1.midY) <= 0.018 {
                    groups[last].append(observation)
                    continue
                }
            }
            groups.append([observation])
        }
        return groups.map { group in
            let ordered = group.sorted { $0.1.minX < $1.1.minX }
            let bounds = ordered.dropFirst().reduce(ordered[0].1) { $0.union($1.1) }
            return BankScreenshotRecognizedLine(
                text: ordered.map(\.0).joined(separator: " "),
                bounds: bounds,
                confidence: ordered.map(\.2).reduce(0, +) / Double(ordered.count),
                imageIndex: imageIndex
            )
        }
    }

    private static func parse(
        lines: [BankScreenshotRecognizedLine],
        source: BankScreenshotSource,
        fingerprint: String,
        capturedAt: Date
    ) -> [BankScreenshotMovement] {
        var date: Date?
        var titleParts: [String] = []
        var result: [BankScreenshotMovement] = []

        for line in lines {
            let compact = compact(line.text)
            guard !compact.isEmpty else { continue }
            if let parsedDate = parseDate(compact, capturedAt: capturedAt) {
                date = parsedDate
                titleParts.removeAll()
                continue
            }
            let folded = fold(compact)
            if folded == "pendiente", !result.isEmpty {
                let previous = result.removeLast()
                result.append(BankScreenshotMovement(
                    id: previous.id, date: previous.date, title: previous.title,
                    displayedAmount: previous.displayedAmount, normalizedAmount: previous.normalizedAmount,
                    pending: true, confidence: min(previous.confidence, line.confidence),
                    imageFingerprint: previous.imageFingerprint, evidence: previous.evidence,
                    duplicateOf: previous.duplicateOf, matchedOfficialMovementID: previous.matchedOfficialMovementID
                ))
                continue
            }
            if isNoise(folded, source: source) { continue }
            guard let currentDate = date else { continue }

            if let amount = lastAmount(in: compact) {
                if folded.contains("por referir") || folded.contains("cashback") { continue }
                let prefix = String(compact[..<amount.range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let inlineTitle = cleanTitle(prefix)
                let combinedTitle = (titleParts.suffix(2) + [inlineTitle])
                    .filter { !$0.isEmpty && !isNoise(fold($0), source: source) }
                    .joined(separator: " ")
                titleParts.removeAll()
                guard combinedTitle.count >= 2, combinedTitle.rangeOfCharacter(from: .letters) != nil else { continue }
                let isPending = folded.contains("pendiente")
                let normalizedAmount = normalizeAmount(amount.value, title: combinedTitle, source: source)
                result.append(BankScreenshotMovement(
                    date: currentDate,
                    title: combinedTitle,
                    displayedAmount: amount.value,
                    normalizedAmount: normalizedAmount,
                    pending: isPending,
                    confidence: line.confidence,
                    imageFingerprint: fingerprint,
                    evidence: MovementExtractionEvidence(
                        method: "screenshot-vision",
                        page: line.imageIndex + 1,
                        confidence: line.confidence,
                        sourceText: String(compact.prefix(300)),
                        bounds: MovementExtractionBounds(rect: line.bounds),
                        selectedColumn: "IMPORTE VISIBLE",
                        selectedAmount: amount.value,
                        selectionReason: "Último importe monetario de la fila móvil"
                    )
                ))
            } else if isLikelyTitle(compact, folded: folded) {
                titleParts.append(compact)
                if titleParts.count > 3 { titleParts.removeFirst() }
            }
        }
        return result
    }

    private static func normalizeAmount(_ displayed: Decimal, title: String, source: BankScreenshotSource) -> Decimal {
        guard source == .amex else { return displayed }
        let foldedTitle = fold(title)
        // Amex displays purchases as positive card charges and payments as a
        // negative visual amount; the canonical ledger uses the opposite sign.
        if displayed < 0 || foldedTitle.contains("gracias por su pago") || foldedTitle.contains("pago en linea") {
            return abs(displayed)
        }
        return -abs(displayed)
    }

    private static func parseDate(_ value: String, capturedAt: Date) -> Date? {
        let folded = fold(value)
        let fullPattern = #"\b(\d{1,2})\s+(?:de\s+)?(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre)\s+(?:de\s+)?(\d{4})\b"#
        if let captures = captures(fullPattern, in: folded), captures.count == 3,
           let day = Int(captures[0]), let month = monthNumbers[captures[1]], let year = Int(captures[2]) {
            return calendarDate(day: day, month: month, year: year)
        }
        let shortPattern = #"^\s*(\d{1,2})\s+(ene|feb|mar|abr|may|jun|jul|ago|sep|oct|nov|dic)\b"#
        if let captures = captures(shortPattern, in: folded), captures.count == 2,
           let day = Int(captures[0]), let month = monthNumbers[captures[1]] {
            let calendar = Calendar(identifier: .gregorian)
            let currentMonth = calendar.component(.month, from: capturedAt)
            var year = calendar.component(.year, from: capturedAt)
            if month > currentMonth + 1 { year -= 1 }
            return calendarDate(day: day, month: month, year: year)
        }
        return nil
    }

    private static func calendarDate(day: Int, month: Int, year: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Mexico_City") ?? .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }

    private static func lastAmount(in value: String) -> (value: Decimal, range: Range<String.Index>)? {
        let pattern = #"(?:[\-−]\s*\$\s*|\$\s*[\-−]?\s*|[\-−]\s*)?\d{1,3}(?:,\d{3})*(?:\.\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value))
        guard let match = matches.last, let range = Range(match.range, in: value) else { return nil }
        let token = String(value[range])
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: " ", with: "")
        guard let amount = Decimal(string: token, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return (amount, range)
    }

    private static func detectAccountKey(in text: String, source: BankScreenshotSource) -> String? {
        let header = text.components(separatedBy: .newlines).prefix(18).joined(separator: " ")
        let patterns = source == .santander
            ? [#"\d{2}\*{2}(\d{4})"#, #"(?:\*|•|·|\.){2,}\s*(\d{4})"#]
            : [#"(?:\*|•|·|\.){2,}\s*\d?(\d{4})"#]
        for pattern in patterns {
            if let match = captures(pattern, in: header).first, match.count == 4 {
                return "\(source.rawValue.lowercased()):\(match)"
            }
        }
        return nil
    }

    private static func isNoise(_ folded: String, source: BankScreenshotSource) -> Bool {
        let common = [
            "movimientos", "saldo actual", "tarjeta asociada", "todos pagos gastos", "inicio membresia promociones mi cuenta",
            "volver", "ayuda", "transferencia interbancaria enviada", "transferencia interbancaria recibida", "movimiento bbva",
            "refiere amigos", "podras recibir", "por cada amigo", "cuenta opcional", "buscar", "super nomina",
        ]
        if common.contains(where: { folded == $0 || folded.hasPrefix($0) }) { return true }
        if folded.contains("platinum credit card american express") || folded == "american express" { return true }
        if folded.range(of: #"^(lunes|martes|miercoles|jueves|viernes|sabado|domingo)\b"#, options: .regularExpression) != nil { return true }
        if source == .amex && ["pendiente", "mexico df", "ciudad de mexico"].contains(folded) { return true }
        return false
    }

    private static func isLikelyTitle(_ value: String, folded: String) -> Bool {
        guard value.count >= 2, value.count <= 90, value.rangeOfCharacter(from: .letters) != nil else { return false }
        if folded.contains("saldo") || folded.contains("mxn") || folded.contains("m.n.") { return false }
        if folded.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil { return false }
        return true
    }

    private static func cleanTitle(_ value: String) -> String {
        compact(value)
            .replacingOccurrences(of: #"(?i)\bpendiente\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compact(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fold(_ value: String) -> String {
        compact(value).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
    }

    private static func captures(_ pattern: String, in value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let swiftRange = Range(match.range(at: index), in: value) else { return nil }
            return String(value[swiftRange])
        }
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func cgOrientation(for orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}

extension FinanceStore {
    var canonicalScreenshotMovements: [BankScreenshotMovement] {
        screenshotCaptures.flatMap(\.movements).filter { $0.duplicateOf == nil }
    }

    func screenshotCaptures(for source: String, accountKey: String?) -> [BankScreenshotCapture] {
        guard let expectedSource = BankScreenshotSource.identify(source) else { return [] }
        return screenshotCaptures.filter { capture in
            guard capture.source == expectedSource else { return false }
            if let accountKey, let captureKey = capture.accountKey { return accountKey == captureKey }
            return true
        }.sorted { $0.importedAt > $1.importedAt }
    }

    @discardableResult
    func saveBankScreenshotImport(_ result: BankScreenshotImportResult) throws -> BankScreenshotImportReceipt {
        let existingFingerprints = Set(screenshotCaptures.flatMap(\.imageFingerprints))
        let newIndices = result.imageFingerprints.indices.filter { !existingFingerprints.contains(result.imageFingerprints[$0]) }
        guard !newIndices.isEmpty else { throw BankScreenshotImportError.alreadyImported }
        let newFingerprints = Set(newIndices.map { result.imageFingerprints[$0] })
        var rows = result.movements.filter { newFingerprints.contains($0.imageFingerprint) }
        var knownRows = canonicalScreenshotMovements
        var duplicateCount = 0
        for index in rows.indices {
            if let duplicate = knownRows.first(where: {
                $0.imageFingerprint != rows[index].imageFingerprint
                    && screenshotIdentity($0, source: result.source, accountKey: result.accountKey) == screenshotIdentity(rows[index], source: result.source, accountKey: result.accountKey)
            }) {
                rows[index].duplicateOf = duplicate.id
                duplicateCount += 1
            } else {
                knownRows.append(rows[index])
            }
        }

        try FileManager.default.createDirectory(at: bankScreenshotFilesDirectoryURL, withIntermediateDirectories: true)
        var localNames: [String] = []
        for index in newIndices {
            let name = "\(result.imageFingerprints[index]).image"
            try result.inputs[index].data.write(to: bankScreenshotFilesDirectoryURL.appendingPathComponent(name), options: [.atomic])
            localNames.append(name)
        }
        var capture = BankScreenshotCapture(
            id: UUID(), source: result.source, accountKey: result.accountKey, importedAt: result.importedAt,
            imageFingerprints: newIndices.map { result.imageFingerprints[$0] },
            localImageNames: localNames, movements: rows, warnings: result.warnings
        )
        screenshotCaptures.insert(capture, at: 0)
        reconcileBankScreenshotsAgainstOfficialLedger()
        capture = screenshotCaptures.first(where: { $0.id == capture.id }) ?? capture
        persistBankScreenshotCaptures()
        DiagnosticsRecorder.record(
            stage: "screenshots.import",
            message: "\(capture.source.rawValue): \(capture.uniqueMovements.count) observación(es), \(duplicateCount) solapada(s), \(capture.confirmedCount) confirmada(s)."
        )
        return BankScreenshotImportReceipt(
            source: capture.source,
            imageCount: capture.imageFingerprints.count,
            movementCount: capture.uniqueMovements.count,
            duplicateCount: duplicateCount,
            confirmedCount: capture.confirmedCount,
            pendingCount: capture.pendingCount
        )
    }

    func deleteBankScreenshotCapture(_ capture: BankScreenshotCapture) {
        screenshotCaptures.removeAll { $0.id == capture.id }
        for name in capture.localImageNames {
            let safeName = URL(fileURLWithPath: name).lastPathComponent
            try? FileManager.default.removeItem(at: bankScreenshotFilesDirectoryURL.appendingPathComponent(safeName))
        }
        persistBankScreenshotCaptures()
    }

    func reconcileBankScreenshotsAgainstOfficialLedger() {
        guard !screenshotCaptures.isEmpty else { return }
        let official = canonicalMovements.compactMap { movement -> (Movement, StatementRecord)? in
            guard let statementID = movement.statementId,
                  let statement = statements.first(where: { $0.id == statementID }) else { return nil }
            return (movement, statement)
        }
        var usedOfficialIDs = Set<UUID>()
        var next = screenshotCaptures
        for captureIndex in next.indices {
            for rowIndex in next[captureIndex].movements.indices {
                guard next[captureIndex].movements[rowIndex].duplicateOf == nil else {
                    next[captureIndex].movements[rowIndex].matchedOfficialMovementID = nil
                    continue
                }
                let row = next[captureIndex].movements[rowIndex]
                let candidates = official.compactMap { pair -> (UUID, Int)? in
                    let movement = pair.0
                    let statement = pair.1
                    guard !usedOfficialIDs.contains(movement.id),
                          BankScreenshotSource.identify(statement.source) == next[captureIndex].source else { return nil }
                    if let captureKey = next[captureIndex].accountKey,
                       let statementKey = statement.accountKey,
                       captureKey != statementKey { return nil }
                    guard abs(movement.amount - row.normalizedAmount) < Decimal(string: "0.005")! else { return nil }
                    let days = abs(Calendar.current.dateComponents([.day], from: row.date, to: movement.date).day ?? 99)
                    guard days <= 3 else { return nil }
                    let descriptionScore = tokenSimilarity(row.title, movement.title)
                    let score = 70 + max(0, 18 - days * 6) + Int(descriptionScore * 20)
                    return score >= 82 ? (movement.id, score) : nil
                }.sorted { $0.1 > $1.1 }
                let match = candidates.first?.0
                next[captureIndex].movements[rowIndex].matchedOfficialMovementID = match
                if let match { usedOfficialIDs.insert(match) }
            }
        }
        if next != screenshotCaptures {
            screenshotCaptures = next
            persistBankScreenshotCaptures()
        }
    }

    private func persistBankScreenshotCaptures() {
        guard let data = try? JSONEncoder().encode(screenshotCaptures) else { return }
        UserDefaults.standard.set(data, forKey: bankScreenshotCaptureStorageKey)
    }

    private func screenshotIdentity(_ row: BankScreenshotMovement, source: BankScreenshotSource, accountKey: String?) -> String {
        let day = ISO8601DateFormatter().string(from: row.date).prefix(10)
        return "\(source.rawValue)|\(accountKey ?? "default")|\(day)|\(row.displayedAmount)|\(normalizedDescription(row.title))"
    }

    private func tokenSimilarity(_ left: String, _ right: String) -> Double {
        let leftTokens = Set(normalizedDescription(left).split(separator: " ").filter { $0.count > 2 })
        let rightTokens = Set(normalizedDescription(right).split(separator: " ").filter { $0.count > 2 })
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return 0 }
        return Double(leftTokens.intersection(rightTokens).count) / Double(leftTokens.union(rightTokens).count)
    }

    private func normalizedDescription(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct BankScreenshotImportReceiptView: View {
    @Environment(\.dismiss) private var dismiss
    let receipt: BankScreenshotImportReceipt

    var body: some View {
        NavigationStack {
            List {
                Section("Importación provisional") {
                    LabeledContent("Origen", value: receipt.source.rawValue)
                    LabeledContent("Capturas nuevas", value: "\(receipt.imageCount)")
                    LabeledContent("Movimientos nuevos", value: "\(receipt.movementCount)")
                    LabeledContent("Solapamientos", value: "\(receipt.duplicateCount)")
                    LabeledContent("Pendientes del banco", value: "\(receipt.pendingCount)")
                    LabeledContent("Confirmados por estado", value: "\(receipt.confirmedCount)")
                }
                Section {
                    Text("Las capturas quedan separadas del libro financiero. Un estado de cuenta oficial confirma o corrige esas observaciones sin duplicar tus movimientos ni alterar los KPI antes de tiempo.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Capturas guardadas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
    }
}
