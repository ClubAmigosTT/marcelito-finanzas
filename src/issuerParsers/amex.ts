import type { StatementSummary, Transaction, TransactionKind } from "../types.ts";
import type { DeterministicParseInput, DeterministicParseResult } from "./types.ts";
import { cents, fold, lastMoney, makeTransaction, money, moneyAfterLabel, moneyToken, parseIssuerDate, reconcileExactly } from "./shared.ts";

const sectionTitle = "Fecha y Detalle de las operaciones";

function parseSummary(text: string): StatementSummary {
  const beforeOperations = text.split(/fecha\s+y\s+detalle\s+de\s+las\s+operaciones/i)[0] ?? text;
  const equation = beforeOperations.match(/((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})\s*(?:\||\s)*-\s*((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})\s*(?:\||\s)*\+\s*((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})\s*(?:\||\s)*=\s*((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})\s+((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})/i);
  const summary: StatementSummary = {
    previousBalance: money(equation?.[1]),
    paymentsCredits: money(equation?.[2]),
    newCharges: money(equation?.[3]) ?? moneyAfterLabel(text, /total nuevos cargos/, { before: /fecha y detalle de las operaciones/i }),
    statementBalance: money(equation?.[4]),
    paymentForNoInterest: money(equation?.[4]),
    minimumPayment: money(equation?.[5]),
    newTransactions: moneyAfterLabel(beforeOperations, /nuevas transacciones/),
    minimumPlusMsi: moneyAfterLabel(beforeOperations, /pago minimo mas meses sin intereses/),
  };
  const lines = beforeOperations.split(/\r?\n/);
  const limitHeader = lines.findIndex((line) => /limite de credito limite disponible/i.test(fold(line)));
  if (limitHeader >= 0) {
    const values = lines.slice(limitHeader, limitHeader + 3)
      .map((line) => Array.from(line.matchAll(moneyToken)).map((match) => money(match[0])).filter((value): value is number => value !== undefined))
      .find((lineValues) => lineValues.length >= 2) ?? [];
    if (values.length >= 2) {
      summary.creditLimit = values.at(-2);
      summary.creditAvailable = values.at(-1);
      const limit = cents(summary.creditLimit);
      const available = cents(summary.creditAvailable);
      if (limit !== undefined && available !== undefined) summary.debtBalance = (limit - available) / 100;
    }
  }
  const msiLine = text.split(/\r?\n/).find((line) => /total de plan de meses sin intereses/i.test(fold(line)));
  if (msiLine) {
    const values = Array.from(msiLine.matchAll(moneyToken)).map((match) => money(match[0])).filter((value): value is number => value !== undefined);
    summary.msiPending = values[0];
    summary.msiOriginalDeferred = values[0];
    summary.msiMonthlyLoad = values[1];
  }
  const domesticLine = text.split(/\r?\n/).find((line) => /total de las transacciones en \$/i.test(fold(line)));
  if (domesticLine) {
    summary.domesticTransactionTotal = money(lastMoney(domesticLine));
    summary.domesticTransactionTotalIsCredit = /\bcr\b/i.test(domesticLine);
  }
  const foreignLine = text.split(/\r?\n/).find((line) => /total de transacciones en moneda extranjera/i.test(fold(line)));
  if (foreignLine) summary.foreignTransactionTotal = money(lastMoney(foreignLine));
  return summary;
}

type Pending = { raw: string; date: string; description: string; amountCents: number; page: number; mode: "domestic" | "foreign" | "msi"; credit: boolean };

export function parseAmex(input: DeterministicParseInput): DeterministicParseResult {
  const summary = parseSummary(input.text);
  const rows: Transaction[] = [];
  let page = 1;
  let active = false;
  let mode: Pending["mode"] = "domestic";
  let pending: Pending | undefined;
  let rejectedRowCount = 0;
  const finish = () => {
    if (!pending) return;
    const normalized = fold(pending.description);
    let kind: TransactionKind = pending.mode === "msi" ? "msi" : "purchase";
    let amountCents = -pending.amountCents;
    if (pending.credit) {
      if (/gracias por su pago/.test(normalized)) kind = "cardPayment";
      else kind = /devolucion|reembolso|bonificacion/.test(normalized) ? "refund" : "credit";
      amountCents = kind === "cardPayment" ? -pending.amountCents : pending.amountCents;
    }
    rows.push(makeTransaction({
      parser: "amex-operations-v1",
      fileName: input.fileName,
      index: rows.length,
      date: pending.date,
      description: pending.description,
      account: "Amex",
      amountCents,
      kind,
      page: pending.page,
      mode: input.mode,
      confidence: input.mode === "ocr" ? 0.9 : 1,
      foreignCurrency: pending.mode === "foreign",
      sourceText: pending.raw,
    }));
    pending = undefined;
  };

  for (const rawLine of input.text.split(/\r?\n/)) {
    const raw = rawLine.replace(/\s+/g, " ").trim();
    if (!raw) continue;
    const normalized = fold(raw);
    const pageMarker = normalized.match(/^__pdf_page_(\d+)__$/);
    if (pageMarker) {
      finish();
      page = Number(pageMarker[1]);
      active = false;
      continue;
    }
    if (normalized.includes(fold(sectionTitle))) {
      finish();
      active = true;
      continue;
    }
    if (/^total de las transacciones en \$/.test(normalized)) {
      finish();
      mode = "foreign";
      continue;
    }
    if (/^total de transacciones en moneda extranjera/.test(normalized)) {
      finish();
      active = false;
      continue;
    }
    if (/^transacciones de meses sin intereses/.test(normalized)) {
      finish();
      mode = "msi";
      active = true;
      continue;
    }
    if (/^total de meses sin intereses/.test(normalized) || /^resumen de meses sin intereses/.test(normalized)) {
      finish();
      active = false;
      continue;
    }
    if (/^este no es un documento|^paga desde los canales/.test(normalized)) {
      finish();
      active = false;
      continue;
    }
    if (!active) continue;
    if (/^cr$/.test(normalized)) {
      if (pending) pending.credit = true;
      continue;
    }
    const dateMatch = raw.match(/^(\d{1,2}\s+de\s+[A-Za-zÁÉÍÓÚÜÑáéíóúüñ]+(?:\s+de\s+20\d{2})?|\d{1,2}[-/.]\d{1,2}[-/.]20\d{2})\s+(.+)$/);
    if (!dateMatch) continue;
    finish();
    const date = parseIssuerDate(dateMatch[1], input.text, input.fileName);
    const amountRaw = lastMoney(dateMatch[2]);
    if (!date || !amountRaw) {
      rejectedRowCount += 1;
      continue;
    }
    const amountIndex = dateMatch[2].lastIndexOf(amountRaw);
    const description = dateMatch[2].slice(0, amountIndex).trim();
    const amountCents = cents(amountRaw);
    if (!description || amountCents === undefined || amountCents <= 0) {
      rejectedRowCount += 1;
      continue;
    }
    pending = { raw, date, description, amountCents, page, mode, credit: false };
  }
  finish();
  const reconciliation = reconcileExactly("card", summary, rows);
  return { parserId: "amex-operations-v1", sourceSection: sectionTitle, transactions: rows, summary, reconciliation, rejectedRowCount };
}
