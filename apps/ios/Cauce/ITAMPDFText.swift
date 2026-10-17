import Foundation
import CoreGraphics
import PDFKit

/// Reads individually positioned cells before PDFKit coalesces adjacent columns.
/// Only embedded two-byte ToUnicode fonts and explicitly positioned text are
/// accepted; unsupported documents fail the independent financial controls.
enum ITAMPDFText {
    final class Context {
        var fonts: [String: [UInt16: String]] = [:]
        var widths: [String: [UInt16: CGFloat]] = [:]
        var font = ""; var size: CGFloat = 0; var x: CGFloat = 0; var y: CGFloat = 0
        var cells: [(text: String, x: CGFloat, y: CGFloat, end: CGFloat)] = []
        var invalid = false
        func show(_ data: Data) {
            guard let map = fonts[font], data.count % 2 == 0 else { invalid = true; return }
            let bytes = [UInt8](data); let start = x; var output = ""
            for index in stride(from: 0, to: bytes.count, by: 2) {
                let code = UInt16(bytes[index]) * 256 + UInt16(bytes[index + 1])
                guard let text = map[code], let width = widths[font]?[code] else { invalid = true; return }
                output += text; x += width * size / 1000
            }
            if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cells.append((output, start, y, x)) }
        }
        func append(_ value: CGPDFStringRef) {
            guard let bytes = CGPDFStringGetBytePtr(value) else { invalid = true; return }
            show(Data(bytes: bytes, count: CGPDFStringGetLength(value)))
        }
    }
    static func context(_ info: UnsafeMutableRawPointer?) -> Context { Unmanaged<Context>.fromOpaque(info!).takeUnretainedValue() }
    static func text(_ document: PDFDocument) throws -> String {
        var pages: [String] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index)?.pageRef else { throw LoanError.invalid("Página de préstamo ilegible.") }
            let state = Context()
            var resources: CGPDFDictionaryRef?; var fonts: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(page.dictionary!, "Resources", &resources), let resources,
                  CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts else { throw LoanError.invalid("No se reconoció la tipografía del estado ITAM.") }
            for fontNumber in 1...32 {
                var format = CGPDFDataFormat.raw
                let name = "F\(fontNumber)"; var font: CGPDFDictionaryRef?; var stream: CGPDFStreamRef?
                guard CGPDFDictionaryGetDictionary(fonts, name, &font), let font,
                      CGPDFDictionaryGetStream(font, "ToUnicode", &stream), let stream,
                      let bytes = CGPDFStreamCopyData(stream, &format), let cmap = String(data: bytes as Data, encoding: .utf8),
                      let re = try? NSRegularExpression(pattern: #"<([0-9A-Fa-f]{4})>\s*<([0-9A-Fa-f]{4})>"#) else { continue }
                // Restrict pairs to bfchar blocks; never interpret codespace ranges as mappings.
                let blockRE = try NSRegularExpression(pattern: #"(?s)beginbfchar(.*?)endbfchar"#)
                var map: [UInt16: String] = [:]
                for block in blockRE.matches(in: cmap, range: NSRange(cmap.startIndex..., in: cmap)) {
                    let body = (cmap as NSString).substring(with: block.range(at: 1))
                    for match in re.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                        let source = (body as NSString).substring(with: match.range(at: 1)); let target = (body as NSString).substring(with: match.range(at: 2))
                        if let code = UInt16(source, radix: 16), let output = UInt16(target, radix: 16), let scalar = UnicodeScalar(output) { map[code] = String(scalar) }
                    }
                }
                var descendants: CGPDFArrayRef?; var descendant: CGPDFDictionaryRef?; var widths: CGPDFArrayRef?
                guard CGPDFDictionaryGetArray(font, "DescendantFonts", &descendants), let descendants,
                      CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant,
                      CGPDFDictionaryGetArray(descendant, "W", &widths), let widths else { continue }
                var decodedWidths: [UInt16: CGFloat] = [:]; var i = 0
                while i < CGPDFArrayGetCount(widths) {
                    var first: CGPDFInteger = 0; var last: CGPDFInteger = 0; var width: CGPDFReal = 0; var array: CGPDFArrayRef?
                    guard CGPDFArrayGetInteger(widths, i, &first), first >= 0, first <= 65535 else { break }
                    if CGPDFArrayGetArray(widths, i + 1, &array), let array {
                        for offset in 0..<CGPDFArrayGetCount(array) { if CGPDFArrayGetNumber(array, offset, &width), first + offset <= 65535 { decodedWidths[UInt16(first + offset)] = width } }; i += 2
                    } else if CGPDFArrayGetInteger(widths, i + 1, &last), last >= first, last <= 65535, CGPDFArrayGetNumber(widths, i + 2, &width) {
                        for code in first...last { decodedWidths[UInt16(code)] = width }; i += 3
                    } else { break }
                }
                if !map.isEmpty { state.fonts[name] = map; state.widths[name] = decodedWidths }
            }
            guard let table = CGPDFOperatorTableCreate() else { throw LoanError.invalid("No se pudo iniciar el lector del préstamo.") }
            defer { CGPDFOperatorTableRelease(table) }
            CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
                var size: CGPDFReal = 0; var name: UnsafePointer<CChar>?
                if CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &name), let name { ITAMPDFText.context(info).font = String(cString: name); ITAMPDFText.context(info).size = size }
            }
            CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
                var v = [CGPDFReal](repeating: 0, count: 6)
                for i in (0..<6).reversed() { if !CGPDFScannerPopNumber(scanner, &v[i]) { ITAMPDFText.context(info).invalid = true; return } }
                ITAMPDFText.context(info).x = v[4]; ITAMPDFText.context(info).y = v[5]
            }
            CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
                var string: CGPDFStringRef?
                if CGPDFScannerPopString(scanner, &string), let string { ITAMPDFText.context(info).append(string) }
            }
            CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
                var array: CGPDFArrayRef?
                guard CGPDFScannerPopArray(scanner, &array), let array else { return }
                let state = ITAMPDFText.context(info)
                var pending = Data()
                for i in 0..<CGPDFArrayGetCount(array) {
                    var string: CGPDFStringRef?; var adjustment: CGPDFReal = 0
                    if CGPDFArrayGetString(array, i, &string), let string, let ptr = CGPDFStringGetBytePtr(string) {
                        pending.append(ptr, count: CGPDFStringGetLength(string))
                    } else if CGPDFArrayGetNumber(array, i, &adjustment) {
                        state.show(pending); pending.removeAll(keepingCapacity: true)
                        state.x -= adjustment * state.size / 1000
                    }
                }
                state.show(pending)
            }
            let content = CGPDFContentStreamCreateWithPage(page)
            defer { CGPDFContentStreamRelease(content) }
            let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(state).toOpaque())
            defer { CGPDFScannerRelease(scanner) }
            guard CGPDFScannerScan(scanner), !state.invalid else { throw LoanError.invalid("Este formato ITAM requiere otra lectura. Tus datos se conservan.") }
            let sorted = state.cells.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
            var rows: [[(text: String, x: CGFloat, y: CGFloat, end: CGFloat)]] = []
            for cell in sorted {
                if let anchor = rows.last?.first, abs(anchor.y - cell.y) < 1.5 { rows[rows.count - 1].append(cell) }
                else { rows.append([cell]) }
            }
            pages.append(rows.map { row in
                let cells = row.sorted { $0.x < $1.x }; var result = ""; var end: CGFloat?
                for cell in cells {
                    if let end, cell.x - end > 1.5 { result += " " }
                    result += cell.text
                    end = cell.end
                }
                return result
            }.joined(separator: "\n"))
        }
        return pages.joined(separator: "\n")
    }
}
