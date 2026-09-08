# Santander cell recovery — reader .7

Status: implemented locally; NOT certified on the private corpus or published.

Only the Santander numeric-cell recovery path changes. BBVA and Amex parsing,
statement reconciliation, canonical admission and UI are unchanged.

The existing fixed-column crop is read at 1x, 1.5x and 2x with white padding.
The crop never extends into a neighbouring column or continuation line. Each
reading must contain one complete monetary token, or be explicitly blank.
Two matching readings are required. A conflicting readable amount (or blank)
rejects recovery even if two other readings agree. Totals never select a value.
Unreadable retries clear the disputed cell rather than retaining stale data.
All three raw readings are retained in private cellRetryTexts with scale labels.
This is agreement between OCR variants, not proof of independent accuracy;
existing printed-balance and statement-total gates remain mandatory.

Local validation: 227 JavaScript/contract tests passed; git diff --check passed.
Added native consensus regressions and three repeated PDFKit/Vision reads of a
synthetic PDF. These native tests have NOT been executed on Windows.

Before release:

1. Execute native tests on the existing macOS CI runner.
2. Run all four original Santander PDFs three times using the native reader.
3. Require identical ordered movements and cent-exact totals on all runs.
4. August must recover 43 real rows, deposits 36,187.42, withdrawals 64,161.11
   and closing balance 27,654.24 with no rejected rows.
5. Keep the original PDFs and row evidence private; do not upload to public CI.
6. Do not label synthetic tests as closed-corpus certification. Amex remains
   unresolved and requires a separate native-text correction.

If the August balance remains ambiguous, inspect the three private crop texts
and the source cell. Do not add filename-specific values, inferred balancing
transactions, manual acceptance or broader numeric searches.
