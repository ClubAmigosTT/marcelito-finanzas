import Foundation
import PDFKit
import CryptoKit

/// This document's text stream interleaves columns and joins adjacent amounts.
/// Reconstruct its printed rows from glyph coordinates before validating totals.
enum LoanPDFReader {
    static func read(_ url: URL) throws -> LoanStatement {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 20_000_000 else { throw LoanError.invalid("Usa un PDF de préstamo de hasta 20 MB.") }
        let data = try Data(contentsOf: url)
        guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0, pdf.pageCount <= 30 else { throw LoanError.invalid("No se pudo abrir el PDF del préstamo. Revisa que no tenga contraseña.") }
        let text = try orderedText(pdf)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return try ITAMLoanReader.parse(text: text, fingerprint: hash, filename: url.lastPathComponent)
    }
    static func orderedText(_ document: PDFDocument) throws -> String {
        try ITAMPDFText.text(document)
    }
    static func directory() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw LoanError.invalid("No se encontró almacenamiento local.") }
        let directory = base.appendingPathComponent("MarcelitoLoans", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    static func preservePDF(_ url: URL, statement: LoanStatement) throws {
        let target = try directory().appendingPathComponent(statement.id + ".pdf")
        let data = try Data(contentsOf: url)
        guard data.count <= 20_000_000, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == statement.id else { throw LoanError.invalid("El archivo cambió durante la lectura. Vuelve a seleccionarlo; tus datos se conservan.") }
        if !FileManager.default.fileExists(atPath: target.path) { try data.write(to: target, options: [.atomic, .completeFileProtection]) }
    }
}
