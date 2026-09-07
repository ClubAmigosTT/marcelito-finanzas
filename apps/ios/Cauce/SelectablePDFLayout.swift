import Foundation
import PDFKit

/// Reconstruct selectable text in printed reading order. PDF content-stream
/// order can differ from the row/column order visible on the page.
enum SelectablePDFLayout {
    struct Fragment {
        let text: String
        let bounds: CGRect
    }

    static func orderedText(_ fragments: [Fragment]) -> String {
        let fragments = fragments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.bounds.isEmpty && !$0.bounds.isInfinite && !$0.bounds.isNull
                && $0.bounds.midY.isFinite && $0.bounds.minX.isFinite
        }.sorted {
            if $0.bounds.midY != $1.bounds.midY { return $0.bounds.midY > $1.bounds.midY }
            return $0.bounds.minX < $1.bounds.minX
        }
        var lines: [[Fragment]] = []
        for fragment in fragments {
            if let anchor = lines.last?.first,
               abs(anchor.bounds.midY - fragment.bounds.midY) <= min(2.2, min(anchor.bounds.height, fragment.bounds.height) * 0.3) {
                lines[lines.count - 1].append(fragment)
            } else {
                lines.append([fragment])
            }
        }
        return lines.map { line in
            line.sorted { $0.bounds.minX < $1.bounds.minX }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " ")
        }.joined(separator: "\n")
    }

    static func text(from document: PDFDocument) -> String {
        guard let tokens = try? NSRegularExpression(pattern: #"\S+"#) else { return "" }
        return (0..<document.pageCount).compactMap { index -> String? in
            autoreleasepool {
                guard let page = document.page(at: index), page.rotation == 0,
                      let pageText = page.string, (pageText as NSString).length <= 200_000 else { return nil }
                let original = pageText as NSString
                let matches = tokens.matches(in: pageText, range: NSRange(location: 0, length: original.length))
                guard matches.count <= 20_000 else { return nil }
                // Use word selections: a whole-line selection can itself keep
                // content-stream order even when the columns are reversed.
                let fragments = matches.compactMap { match -> Fragment? in
                    guard let selection = page.selection(for: match.range) else { return nil }
                    return Fragment(text: original.substring(with: match.range), bounds: selection.bounds(for: page))
                }
                let text = orderedText(fragments)
                guard !text.isEmpty else { return nil }
                return "__PDF_PAGE_\(index + 1)__\n\(text)"
            }
        }.joined(separator: "\n")
    }
}
