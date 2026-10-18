import Foundation

/// Official UDI values as published daily in the Diario Oficial de la
/// Federación (SIDOF indicator 159, the series Banxico publishes). The request
/// carries only a public date range: no account, balance or statement data
/// leaves the device.
enum LoanUDIFeed {
    static let source = "DOF · UDIS publicadas por Banxico"
    private static let indicator = 159

    private static var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "dd-MM-yyyy"
        return formatter
    }

    static func url(from start: Date, to end: Date) -> URL {
        let formatter = dayFormatter
        return URL(string: "https://sidof.segob.gob.mx/dof/sidof/indicadores/\(indicator)/\(formatter.string(from: start))/\(formatter.string(from: end))")!
    }

    /// Parses `{"ListaIndicadores":[{"codTipoIndicador":159,"fecha":"01-09-2026","valor":"8.811040"}]}`.
    /// Rows of another indicator, or with an unreadable date or value, are dropped.
    static func parse(_ data: Data) throws -> [LoanUDIQuote] {
        struct Response: Decodable {
            struct Row: Decodable {
                let codTipoIndicador: Int
                let fecha: String
                let valor: String
            }
            let ListaIndicadores: [Row]?
        }
        let formatter = dayFormatter
        let calendar = Calendar.current
        return (try JSONDecoder().decode(Response.self, from: data).ListaIndicadores ?? []).compactMap { row in
            guard row.codTipoIndicador == indicator,
                  let date = formatter.date(from: row.fecha),
                  let value = Decimal(string: row.valor, locale: Locale(identifier: "en_US_POSIX")),
                  value > 0, value < 1000 else { return nil }
            return LoanUDIQuote(date: calendar.startOfDay(for: date), value: value, source: source)
        }
    }

    static func fetch(from start: Date, to end: Date, session: URLSession = .shared) async throws -> [LoanUDIQuote] {
        var request = URLRequest(url: url(from: start, to: end), timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try parse(data)
    }
}
