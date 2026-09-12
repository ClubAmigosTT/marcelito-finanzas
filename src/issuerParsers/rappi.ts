import type { StatementSummary, Transaction, TransactionKind } from "../types.ts";
import type { DeterministicParseInput, DeterministicParseResult } from "./types.ts";
import { cents, fold, makeTransaction, money, reconcileExactly } from "./shared.ts";

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
      active = false;
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

export function parseRappi(input: DeterministicParseInput): DeterministicParseResult {
  const summary = parseSummary(input.text);
  const parsed = parseMoneyRows(input);
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
