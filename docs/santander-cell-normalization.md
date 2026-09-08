# Santander numeric-cell normalization — reader .8

The August device diagnostic rejected three adjacent withdrawals (500, 800,
100). The first balance lost its separators in OCR; the second acquired trailing
nonnumeric crop noise; the third failed because the preceding balance was missing.

Recovery now normalizes explicitly grouped monetary cell readings before comparing
their decimal values. It accepts missing punctuation only when thousands grouping
and exactly two cent digits are represented (including a final five-digit group).
An ungrouped integer never acquires an inferred decimal point. A trailing fragment
can be removed only if it starts with a dash and contains no digit or currency mark.
Administrative prefixes, extra numbers, malformed groups, and conflicting readable
values remain rejected. Two agreeing readings remain mandatory, followed by the
existing row-balance and full-statement reconciliation gates.

The native regression uses the three diagnostic readings for each disputed cell
and checks that the 500/800/100 withdrawal chain is accepted. Negative cases cover
ambiguous grouping, numeric suffixes, administrative text, and conflicting values.
This is a diagnostic replay, not certification of OCR on the original PDFs.

Native XCTest execution requires the existing macOS CI runner. No TestFlight
publication or original-PDF certification is claimed by this local change.

Local validation: all 227 JavaScript/contract tests passed. The added native
XCTest regressions have not been executed in this Windows environment.
