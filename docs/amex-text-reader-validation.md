# Amex independent native-text reader

Implemented locally, not yet compiled or certified with PDFKit on iOS.
No OCR fallback, PDF uploads, BBVA changes or manual reconciliation overrides.

## Root causes addressed

- The former Amex wrapper delegated to a generic numeric parser. Bare merchant
  identifiers and exchange-rate fragments could be selected as amounts.
- Generic payment detection classified merchant names containing `PAGO` as
  card payments. Only Amex's explicit payment description plus CR now does so.
- Page headers and advertising could contaminate the preceding operation.
- Prices embedded in merchant names are not the final MN amount cell.

The independent reader scopes rows to the printed movement sections, strips
explicit RFC/REF and source-currency/TC annotations, and requires a full
two-decimal closing MN cell. CR determines credits; the MSI section determines
installments. Page headers suspend row detection until the movement header
reopens it. Every rejected anchored row is recorded and blocks canonical entry,
even when aggregate differences might compensate.

## Local independent PDF text check

`scripts/audit-amex-native-text.py` uses pypdf, not the Swift parser or PDFKit.
It checks original PDFs without OCR and compares extracted totals to PDF labels.
These results support the correction but are NOT an iOS certification.

| Cut | Rows | New transactions | Foreign subtotal | Current MSI | Rejected |
| --- | ---: | ---: | ---: | ---: | ---: |
| May–June | 93 | 28,034.19 | 27,537.69 | 9,179.23 | 0 |
| June–July | 147 | 46,711.63 | 12,015.76 | 13,184.49 | 0 |
| July–August | 108 | 33,177.48 | 9,593.73 | 16,382.40 | 0 |

Domestic net totals also match (May–June is a net credit shown without a minus
in the printed subtotal). The existing reconciliation convention is unchanged.
227 JavaScript/contract tests pass. Native regression tests were added for
merchant prices, numeric references, source currency on either side of MXN,
page boundaries, missing MXN, payment semantics, MSI and rejected-row gating.

## Remaining release gate

Run native tests on macOS. Set MARCELITO_AMEX_PDF_DIR to the private directory
containing the three originals to run the new PDFKit golden test. It repeats
each cut three times and requires row counts, purchase totals, no rejected
anchors and statement reconciliation. Without that directory the test skips
explicitly: a green public CI run does not certify the private dataset.

Keep the PDFs and per-row financial evidence outside the public repository.
No TestFlight or website publication was performed for this change.
