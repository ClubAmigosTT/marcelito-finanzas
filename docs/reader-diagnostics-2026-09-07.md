# Santander correction and private Amex trace

Reader: `ios-reader-deterministic-2026.09.07.6`.

## Santander

The device export from reader `.5` isolated two failure mechanisms:

- A real transfer description ending in a dangling `RFC` label was rejected by
  the generic administrative-title check. Santander's fixed-table path now
  strips only that trailing label before the same check. Date, movement column,
  printed balance, adjacent balance equation and official totals remain required.
- A missing balance triggered re-OCR of all three cells. An ambiguous crop of an
  already readable withdrawal aborted the retry before the balance was read.
  Retries now target missing cells independently; failures do not abort other
  targeted cells. Equation failures still retry all three. No value is invented
  from balance differences and no statement can bypass the reconciliation gate.

Private row exports now include `cellRetryTexts` alongside the selected cells,
row rectangle, page and row ordinal. This distinguishes original extraction,
crop failure and downstream balance-link failure.

## Amex: diagnosis only, no accounting change

Amex still uses native PDF text exclusively. The private diagnostic export adds:

- every reconstructed date-anchored candidate, including rejected rows;
- section (`NACIONALES_PAGOS_CREDITOS`, `MONEDA_EXTRANJERA`, `MSI`);
- source fragment (up to 500 characters), candidate numeric tokens, selected
  amount and rejection stage;
- candidate `kind`, `flow`, `foreignCurrency`, signed amount and selection reason;
- `declaredControls` and `reconciliation`, including extracted control buckets.

`accepted` on a diagnostic row means **candidate extracted**, not a reconciled
statement. Always check the enclosing statement status. Section names describe
the current parser's decision, not an independently verified PDF classification.
Lines not reconstructed as date anchors are not covered by this trace; compare
the PDF when investigating missing rows. Foreign amounts and exchange-rate
tokens are evidence only and must never be summed as MXN charges.

Use **Certificar lector > Compartir diagnostico por fila** after reading the
original PDFs. Match files by fingerprint, compare declared/extracted buckets,
then inspect affected candidates by page/section, especially payments, credits,
foreign amounts and MSI. The redacted publication export is unchanged and does
not carry this private evidence. Do not upload bank PDFs or diagnostic JSON to
the public repository or CI.

## Verification boundary

Synthetic regression tests cover dangling RFC, preserved administrative and
balance guards, independent native cell retry, and the private Amex export.
These are not certification of the real PDFs. Re-run all four Santander PDFs on
the native reader and require cent-exact totals plus zero rejected rows before
claiming that the closed corpus is fixed. BBVA parsing is unchanged.
