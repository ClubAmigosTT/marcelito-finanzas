import Foundation
import PDFKit

/// Reconstruct selectable text in printed reading order. PDF content-stream
/// order can differ from the row/column order visible on the page.
enum SelectablePDFLayout {
    struct Fragment {
        let text: String
        let bounds: CGRect
    }

    static func orderedText(_ fragments: [Fragment], lineTolerance: CGFloat? = nil) -> String {
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
               abs(anchor.bounds.midY - fragment.bounds.midY) <= (lineTolerance ?? min(2.2, min(anchor.bounds.height, fragment.bounds.height) * 0.3)) {
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

    static func text(from document: PDFDocument, rappiColumns: Bool = false) -> String {
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
                let text: String
                if rappiColumns && index == 0 {
                    // Rappi's cover has two independent financial panels.
                    let middle = page.bounds(for: .mediaBox).midX
                    let left = fragments.filter { $0.bounds.midX < middle }
                    let right = fragments.filter { $0.bounds.midX >= middle }
                    // Include superscript footnotes in their label's line.
                    text = [left, right].map { orderedText($0, lineTolerance: 4.5) }.joined(separator: "\n")
                } else {
                    text = orderedText(fragments)
                }
                guard !text.isEmpty else { return nil }
                return "__PDF_PAGE_\(index + 1)__\n\(text)"
            }
        }.joined(separator: "\n")
    }

    /// Reconstructs Rappi's native text layer from the printed column
    /// geometry. Some exports contain all words, but PDFKit returns them in
    /// content-stream order; that order is not sufficient to tell a merchant
    /// number from the amount column. This reader emits one complete row only
    /// when it can prove two dates and one right-column amount belong to the
    /// same visual line. OCR remains the recovery path when this stream does
    /// not reconcile with the issuer controls.
    static func rappiText(from document: PDFDocument) -> String {
        guard let tokenRegex = try? NSRegularExpression(pattern: #"\S+"#),
              let dateRegex = try? NSRegularExpression(
                  pattern: #"(?i)(?<![A-Za-z0-9.,])(?:\d{4}\s*[/.-]\s*\d{1,2}\s*[/.-]\s*\d{1,2}|\d{1,2}\s*[/.-]\s*(?:\d{1,2}|[A-Za-zÁÉÍÓÚáéíóú]{3,12})\s*[/.-]\s*(?:20)?\d{2}|\d{1,2}\s+(?:de\s+)?[A-Za-zÁÉÍÓÚáéíóú]{3,12}\s+(?:de\s+)?\d{2,4})(?![A-Za-z0-9.,])"#),
              let amountRegex = try? NSRegularExpression(
                  pattern: #"(?<![A-Za-z0-9.,])[-+−–—]\s*\$?\s*(?:\d{1,3}(?:[,. ]\d{3})+|\d+)[.,]\d{2}(?![A-Za-z0-9.,])"#) else {
            return ""
        }

        func folded(_ value: String) -> String {
            value.folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: Locale(identifier: "es_MX")
            ).lowercased()
        }

        func lineGroups(_ fragments: [Fragment]) -> [[Fragment]] {
            let sorted = fragments.sorted {
                if abs($0.bounds.midY - $1.bounds.midY) > 0.5 {
                    return $0.bounds.midY > $1.bounds.midY
                }
                return $0.bounds.minX < $1.bounds.minX
            }
            var groups: [[Fragment]] = []
            for fragment in sorted {
                if let index = groups.indices.last,
                   let anchor = groups[index].first,
                   abs(anchor.bounds.midY - fragment.bounds.midY)
                    <= max(4.5, min(10.0, min(anchor.bounds.height, fragment.bounds.height) * 1.25)) {
                    groups[index].append(fragment)
                } else {
                    groups.append([fragment])
                }
            }
            return groups
        }

        func fragmentsForPage(_ page: PDFPage) -> [Fragment] {
            guard let pageText = page.string,
                  (pageText as NSString).length <= 200_000 else { return [] }
            let matches = tokenRegex.matches(
                in: pageText,
                range: NSRange(location: 0, length: (pageText as NSString).length)
            )
            guard matches.count <= 20_000 else { return [] }
            let original = pageText as NSString
            return matches.compactMap { match in
                guard let selection = page.selection(for: match.range) else { return nil }
                return Fragment(
                    text: original.substring(with: match.range),
                    bounds: selection.bounds(for: page)
                )
            }
        }

        func unionBounds(of fragments: [Fragment]) -> CGRect? {
            guard let first = fragments.first else { return nil }
            return fragments.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        }

        func rowBoundsMarker(page: Int, bounds: CGRect, pageBounds: CGRect) -> String? {
            guard !bounds.isEmpty, !bounds.isInfinite, !bounds.isNull,
                  pageBounds.width > 0, pageBounds.height > 0 else { return nil }
            let x = max(0, min(1, (bounds.minX - pageBounds.minX) / pageBounds.width))
            let y = max(0, min(1, (bounds.minY - pageBounds.minY) / pageBounds.height))
            let maxX = max(x, min(1, (bounds.maxX - pageBounds.minX) / pageBounds.width))
            let maxY = max(y, min(1, (bounds.maxY - pageBounds.minY) / pageBounds.height))
            let locale = Locale(identifier: "en_US_POSIX")
            let values = [
                String(page),
                String(format: "%.6f", locale: locale, x),
                String(format: "%.6f", locale: locale, y),
                String(format: "%.6f", locale: locale, max(0.001, maxX - x)),
                String(format: "%.6f", locale: locale, max(0.001, maxY - y)),
            ]
            return "__RAPPI_ROW_BOUNDS__ " + values.joined(separator: " ")
        }

        let pageTexts = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        var firstMovementPage: Int?
        var lastMovementPage: Int?
        for (index, pageText) in pageTexts.enumerated() {
            let normalized = folded(pageText)
            let compact = normalized.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
            if (normalized.contains("cargos, abonos y compras regulares")
                || compact.contains("cargosabonosycomprasregulares")) && firstMovementPage == nil {
                firstMovementPage = index
            }
            if firstMovementPage != nil,
               (normalized.contains("total de cargos") || compact.contains("totaldecargos")) {
                lastMovementPage = index
            }
        }
        let movementPageRange: ClosedRange<Int>? = {
            guard let firstMovementPage else { return nil }
            let last = max(firstMovementPage, lastMovementPage ?? document.pageCount - 1)
            return firstMovementPage...last
        }()

        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let fragments = fragmentsForPage(page)
            guard !fragments.isEmpty else { continue }
            let pageWidth = page.bounds(for: .mediaBox).width
            guard pageWidth.isFinite, pageWidth > 0 else { continue }
            let groups = lineGroups(fragments)
            var output = ["__PDF_PAGE_\(index + 1)__"]

            // The cover contains the independent issuer controls. Preserve it
            // as ordered text; no movement row may be inferred from it.
            if index == 0 {
                let middle = page.bounds(for: .mediaBox).midX
                let left = fragments.filter { $0.bounds.midX < middle }
                let right = fragments.filter { $0.bounds.midX >= middle }
                output.append([
                    orderedText(left, lineTolerance: 4.5),
                    orderedText(right, lineTolerance: 4.5)
                ].joined(separator: "\n"))
                pages.append(output.joined(separator: "\n"))
                continue
            }

            var active = movementPageRange?.contains(index) == true
            var emittedRows: [(text: String, bounds: CGRect?)] = []
            var pendingDescription: String?
            var pendingBounds: CGRect?
            var emittedSection = false
            if active {
                output.append("CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)")
                emittedSection = true
            }

            for group in groups {
                let ordered = group.sorted { $0.bounds.minX < $1.bounds.minX }
                let line = ordered.map { $0.text }.joined(separator: " ")
                let normalized = folded(line)
                let lower = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
                let compact = lower.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)

                if lower.contains("cargos, abonos y compras regulares")
                    || compact.contains("cargosabonosycomprasregulares") {
                    if let pendingDescription {
                        emittedRows.append((pendingDescription, pendingBounds))
                    }
                    pendingDescription = nil
                    pendingBounds = nil
                    let wasActive = active
                    active = true
                    // A page can contain two physical card tables. The first
                    // `total de cargos` closes the first table; a later
                    // section heading must reopen the parser and be emitted
                    // again so the shared engine does not discard the second
                    // table as post-summary text.
                    if !wasActive || !emittedSection {
                        output.append("CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)")
                        emittedSection = true
                    }
                    continue
                }
                if lower.range(of: #"^total\s+de\s+(?:cargos|abonos)\b"#, options: .regularExpression) != nil
                    || lower.range(of: #"^(?:cargos\s+no\s+reconocidos|atenci[oó]n\s+de\s+quejas|notas\s+aclaratorias)\b"#, options: .regularExpression) != nil {
                    if let pendingDescription {
                        emittedRows.append((pendingDescription, pendingBounds))
                    }
                    pendingDescription = nil
                    pendingBounds = nil
                    active = false
                    continue
                }
                guard active else { continue }

                let dateFragments = ordered.filter { fragment in
                    let center = fragment.bounds.midX / pageWidth
                    return center < 0.30
                }
                let amountFragments = ordered.filter { fragment in
                    let center = fragment.bounds.midX / pageWidth
                    return center >= 0.76
                }
                let dateCell = dateFragments.map { $0.text }.joined(separator: " ")
                let dateMatches = dateRegex.matches(
                    in: dateCell,
                    range: NSRange(dateCell.startIndex..<dateCell.endIndex, in: dateCell)
                )
                let amountCell = amountFragments.map { $0.text }.joined()
                let amountMatch = amountRegex.firstMatch(
                    in: amountCell,
                    range: NSRange(amountCell.startIndex..<amountCell.endIndex, in: amountCell)
                )
                if dateMatches.count >= 2, let amountMatch,
                   let amountRange = Range(amountMatch.range, in: amountCell) {
                    if let pendingDescription {
                        emittedRows.append((pendingDescription, pendingBounds))
                    }
                    let dates = dateMatches.prefix(2).compactMap { match in
                        Range(match.range, in: dateCell).map { String(dateCell[$0]) }
                    }
                    let amount = String(amountCell[amountRange])
                        .replacingOccurrences(of: "−", with: "-")
                        .replacingOccurrences(of: "–", with: "-")
                        .replacingOccurrences(of: "—", with: "-")
                    let description = ordered
                        .filter {
                            let center = $0.bounds.midX / pageWidth
                            return center >= 0.26 && center < 0.76
                        }
                        .map { $0.text }
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    pendingDescription = (dates + [description, amount])
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    pendingBounds = unionBounds(of: ordered)
                } else if pendingDescription != nil {
                    // Foreign-purchase details such as USD and the exchange
                    // rate sit below the row but remain inside the description
                    // band. Keep those words as evidence without allowing a
                    // middle-column number to become a second amount.
                    let continuationFragments = ordered
                        .filter {
                            let center = $0.bounds.midX / pageWidth
                            return center >= 0.26 && center < 0.76
                        }
                    let continuation = continuationFragments
                        .map { $0.text }
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !continuation.isEmpty {
                        pendingDescription = "\(pendingDescription!) \(continuation)"
                        if let continuationBounds = unionBounds(of: continuationFragments) {
                            pendingBounds = pendingBounds?.union(continuationBounds) ?? continuationBounds
                        }
                    }
                }
            }
            if let pendingDescription {
                emittedRows.append((pendingDescription, pendingBounds))
            }

            if emittedRows.isEmpty {
                output.append(orderedText(fragments, lineTolerance: 4.5))
            } else {
                let pageBounds = page.bounds(for: .mediaBox)
                for row in emittedRows {
                    if let bounds = row.bounds,
                       let marker = rowBoundsMarker(page: index + 1, bounds: bounds, pageBounds: pageBounds) {
                        output.append(marker)
                    }
                    output.append(row.text)
                }
            }
            pages.append(output.joined(separator: "\n"))
        }
        return pages.joined(separator: "\n")
    }
}
