import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Movements as a CSV that opens directly in Excel or Numbers (UTF-8 with a
/// byte-order mark so accents survive, comma separated, quoted fields).
enum MovementsExport {
    static func csv(_ rows: [Movement], statements: [StatementRecord]) -> String {
        let periods = Dictionary(statements.map { ($0.id, "\($0.source) · \($0.period)") }, uniquingKeysWith: { first, _ in first })
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        func field(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let header = ["Fecha", "Cuenta", "Concepto", "Comercio", "Categoría", "Tipo", "Flujo", "Importe", "Viaje", "Estado de cuenta", "Etiquetas"]
        let lines = rows.sorted { $0.date < $1.date }.map { row -> String in
            [
                day.string(from: row.date),
                row.account,
                row.title,
                row.displayMerchant ?? row.normalizedMerchant ?? "",
                row.category,
                row.kind?.rawValue ?? "",
                row.flow.rawValue,
                NSDecimalNumber(decimal: row.amount).stringValue,
                row.travelRelated ? "Sí" : "No",
                row.statementId.flatMap { periods[$0] } ?? "Manual o captura",
                row.classificationTags.joined(separator: " · "),
            ].map(field).joined(separator: ",")
        }
        return ([header.map(field).joined(separator: ",")] + lines).joined(separator: "\r\n")
    }

    static func data(_ rows: [Movement], statements: [StatementRecord]) -> Data {
        Data([0xEF, 0xBB, 0xBF]) + Data(csv(rows, statements: statements).utf8)
    }
}

struct MovementsCSVFile: Transferable {
    let rows: [Movement]
    let statements: [StatementRecord]
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.fileName)
            try MovementsExport.data(file.rows, statements: file.statements).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
