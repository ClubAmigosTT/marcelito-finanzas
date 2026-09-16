import type { StatementSummary, Transaction, TransactionKind } from "../types.ts";
import type { DeterministicParseInput, DeterministicParseResult } from "./types.ts";
import { cents, fold, layoutLines, lineText, makeTransaction, money, parseIssuerDate, reconcileExactly } from "./shared.ts";
import { normalizeRappiMerchant } from "../merchantNormalization.ts";

const sectionTitle = "Cargos, abonos y compras regulares (no a meses)";
const pageMarker = /^__pdf_page_(\d+)__$/;
const rowStart = /^(\d{4}-\d{2}-\d{2})\s+(\d{4}-\d{2}-\d{2})\s+(.+)$/;
const signedMoney = /([+-])\s*\$?\s*((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})/g;

function amountAfter(text: string, label: RegExp) {
  const match = text.match(new RegExp(`${label.source}[^$\\n]{0,100}\\$\\s*([\\d,]+\\.\\d{2})`, "i"));
  return money(match?.[1]);
}

function parseSummary(text: string): StatementSummary {
  const regularCharges = amountAfter(text, /cargos\s+regulares\s*\(no\s+a\s+meses\)/i);
  const msiCharges = amountAfter(text, /cargos\s+compras\s+a\s+meses\s*\(capital\)/i) ?? 0;
  const paymentsCredits = amountAfter(text, /pagos\s+y\s+abonos/i);
  const previousBalance = amountAfter(text, /adeudo\s+del\s+periodo\s+anterior/i);
  const paymentForNoInterest = amountAfter(text, /pago\s+para\s+no\s+generar\s+intereses/i);
  const statementBalance = amountAfter(text, /saldo\s+deudor\s+total/i) ?? paymentForNoInterest;
  const creditLimit = amountAfter(text, /l[ií]mite\s+de\s+cr[eé]dito/i);
  const creditAvailable = amountAfter(text, /cr[eé]dito\s+disponible(?!\s+para)/i);
  const minimumPlusMsi = amountAfter(text, /pago\s+m[ií]nimo\s*\+\s*compras\s+y\s+cargos\s+diferidos/i);
  const minimumPayment = amountAfter(text, /pago\s+m[ií]nimo(?!\s*\+)/i);

  return {
    previousBalance,
    statementBalance,
    debtBalance: statementBalance,
    newTransactions: regularCharges,
    // Rappi's regular table is the auditable current-period section. MSI
    // capital is a future obligation and is intentionally not promoted to a
    // regular purchase row; reconcileExactly still validates the regular
    // total and the independent payment/credit controls.
    paymentsCredits,
    paymentForNoInterest,
    newCharges: msiCharges === 0 && regularCharges !== undefined ? regularCharges : undefined,
    msiMonthlyLoad: msiCharges,
    msiPending: 0,
    creditLimit,
    creditAvailable,
    minimumPlusMsi,
    minimumPayment,
  };
}

type PendingRow = { raw: string; page: number; foreignCurrency: boolean };

function parseMoneyRows(input: DeterministicParseInput) {
  const rows: Transaction[] = [];
  const rejectedRows: string[] = [];
  let page = 1;
  let active = false;
  let pending: PendingRow | undefined;

  const finish = () => {
    if (!pending) return;
    const rowPage = pending.page;
    const rowForeignCurrency = pending.foreignCurrency;
    const raw = pending.raw.replace(/\s+/g, " ").trim();
    pending = undefined;
    const match = raw.match(rowStart);
    if (!match) {
      rejectedRows.push(raw.slice(0, 240));
      return;
    }
    const moneyMatches = [...raw.matchAll(signedMoney)];
    const selected = moneyMatches.at(-1);
    if (!selected) {
      rejectedRows.push(raw.slice(0, 240));
      return;
    }
    const amountCents = cents(selected[2]);
    if (amountCents === undefined || amountCents <= 0) {
      rejectedRows.push(raw.slice(0, 240));
      return;
    }

    const signedValue = selected[1] === "-" ? -amountCents : amountCents;
    const descriptionEnd = selected.index ?? raw.length;
    const description = raw
      .slice(match[0].length - match[3].length, descriptionEnd)
      .replace(/compra\s+en\s+el\s+extranjero/ig, "")
      .replace(/tasa\s+de\s+conversi[oó]n\s+[^ ]+/ig, "")
      .replace(/usd\s+\$?\s*[\d,.]+/ig, "")
      .replace(/\s+/g, " ")
      .trim();
    if (!description) {
      rejectedRows.push(raw.slice(0, 240));
      return;
    }

    const normalizedDescription = fold(description);
    const merchant = normalizeRappiMerchant(description);
    const isPayment = /^pago\s+por\s+spei\b/.test(normalizedDescription);
    const isRefund = !isPayment && signedValue < 0;
    let kind: TransactionKind = "purchase";
    let ledgerAmountCents = -Math.abs(signedValue);
    if (isPayment) {
      kind = "cardPayment";
      ledgerAmountCents = -Math.abs(signedValue);
    } else if (isRefund) {
      kind = /bonificaci[oó]n|cashback|devoluci[oó]n|reembolso/.test(normalizedDescription) ? "refund" : "credit";
      ledgerAmountCents = Math.abs(signedValue);
    }
    rows.push(makeTransaction({
      parser: "rappicard-operations-v1",
      fileName: input.fileName,
      index: rows.length,
      date: match[1],
      description,
      account: "Rappi",
      amountCents: ledgerAmountCents,
      kind,
      page: rowPage,
      mode: input.mode,
      confidence: input.mode === "ocr" ? 0.9 : 1,
      foreignCurrency: rowForeignCurrency,
      sourceText: raw,
      rawDescription: merchant.rawDescription,
      normalizedMerchant: merchant.normalizedMerchant,
      displayMerchant: merchant.displayMerchant,
      merchantConfidence: merchant.confidence,
      merchantReviewReason: merchant.reviewReason,
    }));
  };

  for (const rawLine of input.text.split(/\r?\n/)) {
    const line = rawLine.replace(/\s+/g, " ").trim();
    if (!line) continue;
    const normalized = fold(line);
    const marker = normalized.match(pageMarker);
    if (marker) {
      finish();
      page = Number(marker[1]);
      // The regular-movements table continues across page breaks.  A PDF
      // page marker is metadata for evidence/diagnostics, not a section
      // boundary; resetting `active` here silently discarded every movement
      // on continuation pages and left only the first/last page to reconcile.
      continue;
    }
    if (normalized.includes(fold(sectionTitle))) {
      finish();
      active = true;
      continue;
    }
    if (/^total\s+de\s+(?:cargos|abonos)\b|^cargos\s+no\s+reconocidos|^atenci[oó]n\s+de\s+quejas|^notas\s+aclaratorias/.test(normalized)) {
      finish();
      active = false;
      continue;
    }
    if (!active) continue;
    if (rowStart.test(line)) {
      finish();
      pending = { raw: line, page, foreignCurrency: false };
      continue;
    }
    if (!pending) continue;
    if (/compra\s+en\s+el\s+extranjero/.test(normalized)) pending.foreignCurrency = true;
    pending.raw += ` ${line}`;
  }
  finish();
  return { rows, rejectedRows };
}

function parseLayoutRows(input: DeterministicParseInput) {
  const lines = layoutLines(input.layout);
  if (!lines.length) return undefined;
  let active = false;
  let amountStart = 0.78;
  let descriptionStart = 0.28;
  const selectedRows: Array<{ page: number; text: string }> = [];
  let pending: { page: number; dates: string[]; description: string; amount?: string } | undefined;
  const normalizeDate = (token: string) => {
    const iso = token.match(/^(20\d{2})[-/.](\d{1,2})[-/.](\d{1,2})$/);
    return iso
      ? `${iso[1]}-${iso[2].padStart(2, "0")}-${iso[3].padStart(2, "0")}`
      : parseIssuerDate(token, input.text, input.fileName);
  };

  const finish = () => {
    if (!pending || !pending.amount || !pending.dates.length || !pending.description.trim()) {
      pending = undefined;
      return;
    }
    const firstDate = normalizeDate(pending.dates[0]);
    const secondDate = normalizeDate(pending.dates[1] ?? pending.dates[0]);
    if (!firstDate || !secondDate) {
      pending = undefined;
      return;
    }
    // Serialize only the calibrated cells. The downstream parser still owns
    // signs/kinds/reconciliation, but it can no longer mistake a reference
    // number in the description for the amount column.
    selectedRows.push({
      page: pending.page,
      text: `${firstDate} ${secondDate} ${pending.description.trim()} ${pending.amount}`,
    });
    pending = undefined;
  };

  const datePattern = /^(?:\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.][a-z]{3,12}[-/.]20\d{2}|\d{1,2}\s+(?:de\s+)?[a-z]{3,12}\s+20\d{2})$/i;
  for (const line of lines) {
    const raw = lineText(line);
    const normalized = fold(raw);
    if (!active && normalized.includes(fold(sectionTitle))) {
      active = true;
      continue;
    }
    if (!active) continue;
    if (/^total\s+de\s+(?:cargos|abonos)\b|^cargos\s+no\s+reconocidos|^atenci[oó]n\s+de\s+quejas|^notas\s+aclaratorias/.test(normalized)) {
      finish();
      active = false;
      continue;
    }
    const headerAmount = line.words.find((word) => /^(?:monto|importe|cantidad)$/i.test(fold(word.text)));
    const headerDescription = line.words.find((word) => /^(?:descripci[oó]n|concepto)$/i.test(fold(word.text)));
    if (headerAmount) amountStart = Math.max(0.6, headerAmount.x - 0.06);
    if (headerDescription) descriptionStart = Math.max(0.16, headerDescription.x - 0.02);

    const dateWords = line.words
      .filter((word) => word.x < descriptionStart && datePattern.test(word.text.replace(/\s+/g, "").trim()))
      .map((word) => word.text.replace(/\s+/g, "").trim());
    const amountCell = line.words.filter((word) => word.x >= amountStart).map((word) => word.text).join("").replace(/\s+/g, "");
    const amountMatch = amountCell.match(/[+-]\$?(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2}/);
    if (dateWords.length) {
      finish();
      const description = line.words.filter((word) => word.x >= descriptionStart && word.x < amountStart).map((word) => word.text).join(" ");
      pending = { page: line.page, dates: dateWords.slice(0, 2), description, amount: amountMatch?.[0] };
      continue;
    }
    if (pending && !amountMatch) {
      const continuation = line.words.filter((word) => word.x >= descriptionStart && word.x < amountStart).map((word) => word.text).join(" ").trim();
      if (continuation) pending.description = `${pending.description} ${continuation}`.trim();
    }
  }
  finish();
  if (!selectedRows.length) return undefined;
  return parseMoneyRows({ ...input, text: `${sectionTitle}\n${selectedRows.map((row) => `__PDF_PAGE_${row.page}__\n${row.text}`).join("\n")}` });
}

export function parseRappi(input: DeterministicParseInput): DeterministicParseResult {
  const summary = parseSummary(input.text);
  const layoutParsed = input.mode === "ocr" ? parseLayoutRows(input) : undefined;
  const layoutReconciliation = layoutParsed ? reconcileExactly("card", summary, layoutParsed.rows) : undefined;
  // OCR rows are accepted as a complete set only when the calibrated-column
  // result itself reconciles. Otherwise retain the text fallback as one set;
  // rows are never mixed across extraction strategies.
  const parsed = layoutParsed && layoutReconciliation?.status === "valid" ? layoutParsed : parseMoneyRows(input);
  const reconciliation = reconcileExactly("card", summary, parsed.rows);
  return {
    parserId: "rappicard-operations-v1",
    sourceSection: sectionTitle,
    transactions: parsed.rows,
    summary,
    reconciliation,
    rejectedRowCount: parsed.rejectedRows.length,
    rejectedRows: parsed.rejectedRows,
  };
}
