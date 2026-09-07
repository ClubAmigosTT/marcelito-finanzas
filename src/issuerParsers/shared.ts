import type { ImportResult, StatementReconciliation, StatementSummary, Transaction, TransactionKind } from "../types.ts";
import type { DocumentLayout, DocumentLayoutLine } from "./types.ts";

export function fold(value: string) {
  return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/\s+/g, " ").trim();
}

export function cents(value: string | number | undefined) {
  if (value === undefined) return undefined;
  if (typeof value === "number") return Number.isFinite(value) ? Math.round(value * 100) : undefined;
  const clean = value.replace(/[$\s]/g, "").replace(/^\(/, "").replace(/\)$/, "").replace(/,/g, "");
  if (!/^-?\d+(?:\.\d{2})?$/.test(clean)) return undefined;
  const parsed = Number(clean);
  return Number.isFinite(parsed) ? Math.round(parsed * 100) : undefined;
}

export function money(value: string | number | undefined) {
  const parsed = cents(value);
  return parsed === undefined ? undefined : parsed / 100;
}

export const moneyToken = /(?<![A-Za-z0-9])\$?(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2}(?![A-Za-z0-9])/g;

export function lastMoney(line: string) {
  const matches = Array.from(line.matchAll(moneyToken));
  return matches.at(-1)?.[0];
}

export function moneyAfterLabel(text: string, label: RegExp, options: { before?: RegExp; after?: RegExp; last?: boolean } = {}) {
  let scope = text;
  if (options.after) {
    const index = scope.search(options.after);
    if (index >= 0) scope = scope.slice(index);
  }
  if (options.before) {
    const index = scope.search(options.before);
    if (index >= 0) scope = scope.slice(0, index);
  }
  const matches = scope.split(/\r?\n/).filter((line) => label.test(fold(line))).map(lastMoney).filter((value): value is string => Boolean(value));
  return money(options.last ? matches.at(-1) : matches[0]);
}

export function layoutLines(layout?: DocumentLayout) {
  return layout?.pages.flatMap((page) => page.lines.map((line) => ({ ...line, page: page.page }))) ?? [];
}

export function lineText(line: DocumentLayoutLine) {
  return line.words.map((word) => word.text).join(" ").replace(/\s+/g, " ").trim();
}

const months: Record<string, number> = {
  ene: 1, enero: 1, feb: 2, febrero: 2, mar: 3, marzo: 3, abr: 4, abril: 4,
  may: 5, mayo: 5, jun: 6, junio: 6, jul: 7, julio: 7, ago: 8, agosto: 8,
  sep: 9, septiembre: 9, setiembre: 9, oct: 10, octubre: 10, nov: 11, noviembre: 11, dic: 12, diciembre: 12,
};

function statementYear(text: string, fileName: string) {
  const years = Array.from(`${text}\n${fileName}`.matchAll(/\b(20\d{2})\b/g)).map((match) => Number(match[1]));
  return years.find((year) => year >= 2000 && year <= 2100) ?? new Date().getFullYear();
}

export function parseIssuerDate(token: string, text: string, fileName: string) {
  const normalized = fold(token).replace(/ag0/g, "ago").replace(/^o(?=\d)/, "0");
  const numeric = normalized.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](20\d{2})$/);
  if (numeric) return `${numeric[3]}-${numeric[2].padStart(2, "0")}-${numeric[1].padStart(2, "0")}`;
  const named = normalized.match(/^(\d{1,2})(?:\s+de\s+|[-/])([a-z]+)(?:\s+de\s+|[-/])?(20\d{2})?$/);
  if (!named) return undefined;
  const month = months[named[2]] ?? months[named[2].slice(0, 3)];
  const day = Number(named[1]);
  if (!month || day < 1 || day > 31) return undefined;
  const year = Number(named[3] ?? statementYear(text, fileName));
  const date = new Date(Date.UTC(year, month - 1, day));
  if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return undefined;
  return `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

export function makeTransaction(options: {
  parser: string;
  fileName: string;
  index: number;
  date: string;
  description: string;
  account: string;
  amountCents: number;
  kind: TransactionKind;
  page: number;
  mode: ImportResult["mode"];
  confidence: number;
  foreignCurrency?: boolean;
  sourceText: string;
}) : Transaction {
  const amount = options.amountCents / 100;
  const flow: Transaction["flow"] = options.kind === "cardPayment" ? "debt" : amount > 0 ? "income" : "expense";
  const key = options.fileName.normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9]+/gi, "-").replace(/^-|-$/g, "").slice(0, 32).toLowerCase() || "estado";
  return {
    id: `${options.parser}-${key}-${options.index + 1}`,
    date: options.date,
    description: options.description.replace(/\s+/g, " ").trim().slice(0, 120),
    account: options.account,
    category: options.kind === "cardPayment" || options.kind === "bankTransfer" ? "Transferencia" : "Sin categoría",
    amount,
    flow,
    kind: options.kind,
    foreignCurrency: options.foreignCurrency,
    confidence: options.confidence,
    extractionEvidence: {
      method: options.mode === "ocr" ? "ocr" : "pdf-text",
      page: options.page,
      confidence: options.confidence,
      sourceText: options.sourceText.slice(0, 240),
    },
  };
}

function totalCents(rows: Transaction[], predicate: (row: Transaction) => boolean) {
  return rows.filter(predicate).reduce((total, row) => total + Math.abs(cents(row.amount) ?? 0), 0);
}

export function reconcileExactly(kind: "bank" | "card", summary: StatementSummary | undefined, rows: Transaction[]): StatementReconciliation {
  const invalid = (reason: string, extra: Partial<StatementReconciliation> = {}): StatementReconciliation => ({
    status: "invalid", tolerance: 0, extractedMovementCount: rows.length, reason, ...extra,
  });
  if (!summary) return invalid("Faltan los controles oficiales del estado");
  if (kind === "bank") {
    const depositCents = totalCents(rows, (row) => row.amount > 0);
    const withdrawalCents = totalCents(rows, (row) => row.amount < 0);
    const expectedDeposits = cents(summary.depositTotal);
    const expectedWithdrawals = cents(summary.withdrawalTotal);
    const opening = cents(summary.previousBalance);
    const closing = cents(summary.cashBalance);
    const extra = {
      extractedDepositTotal: depositCents / 100,
      extractedWithdrawalTotal: withdrawalCents / 100,
      expectedMovementCount: summary.depositCount !== undefined && summary.withdrawalCount !== undefined ? summary.depositCount + summary.withdrawalCount : undefined,
    };
    if (expectedDeposits === undefined || expectedWithdrawals === undefined || opening === undefined || closing === undefined) {
      return invalid("Faltan saldo inicial, depósitos, retiros o saldo final oficiales", extra);
    }
    const depositCount = rows.filter((row) => row.amount > 0).length;
    const withdrawalCount = rows.filter((row) => row.amount < 0).length;
    const errors = [
      ...(depositCents !== expectedDeposits ? [`depósitos ${(depositCents - expectedDeposits) / 100}`] : []),
      ...(withdrawalCents !== expectedWithdrawals ? [`retiros ${(withdrawalCents - expectedWithdrawals) / 100}`] : []),
      ...(opening + depositCents - withdrawalCents !== closing ? [`saldo final ${(opening + depositCents - withdrawalCents - closing) / 100}`] : []),
      ...(summary.depositCount !== undefined && depositCount !== summary.depositCount ? [`conteo abonos ${depositCount}/${summary.depositCount}`] : []),
      ...(summary.withdrawalCount !== undefined && withdrawalCount !== summary.withdrawalCount ? [`conteo cargos ${withdrawalCount}/${summary.withdrawalCount}`] : []),
    ];
    return errors.length ? invalid(`No concilia al centavo: ${errors.join(", ")}`, extra) : { status: "valid", tolerance: 0, extractedMovementCount: rows.length, ...extra };
  }

  const purchaseKinds = new Set<TransactionKind>(["purchase", "interest", "fee"]);
  const chargeCents = totalCents(rows, (row) => row.amount < 0 && purchaseKinds.has(row.kind ?? "other"));
  const msiCents = totalCents(rows, (row) => row.amount < 0 && row.kind === "msi");
  const paymentCents = totalCents(rows, (row) => row.kind === "cardPayment");
  const creditCents = totalCents(rows, (row) => row.amount > 0 && (row.kind === "credit" || row.kind === "refund"));
  const domesticChargeCents = totalCents(rows, (row) => row.amount < 0 && purchaseKinds.has(row.kind ?? "other") && !row.foreignCurrency);
  const foreignChargeCents = totalCents(rows, (row) => row.amount < 0 && purchaseKinds.has(row.kind ?? "other") && Boolean(row.foreignCurrency));
  const domesticCreditCents = totalCents(rows, (row) => row.amount > 0 && (row.kind === "credit" || row.kind === "refund") && !row.foreignCurrency);
  const foreignCreditCents = totalCents(rows, (row) => row.amount > 0 && (row.kind === "credit" || row.kind === "refund") && Boolean(row.foreignCurrency));
  const expectedCharges = cents(summary.newTransactions);
  const extra = {
    extractedChargeTotal: chargeCents / 100,
    extractedDomesticChargeTotal: domesticChargeCents / 100,
    extractedForeignChargeTotal: foreignChargeCents / 100,
    extractedCreditTotal: creditCents / 100,
    extractedPaymentTotal: paymentCents / 100,
    extractedMsiTotal: msiCents / 100,
    creditIdentityDifference: summary.creditLimit !== undefined && summary.creditAvailable !== undefined && summary.debtBalance !== undefined
      ? ((cents(summary.creditLimit) ?? 0) - (cents(summary.creditAvailable) ?? 0) - (cents(summary.debtBalance) ?? 0)) / 100
      : undefined,
  };
  if (expectedCharges === undefined) return invalid("Falta el total oficial de Nuevas transacciones", extra);
  const errors: string[] = [];
  if (chargeCents !== expectedCharges) errors.push(`nuevas transacciones ${(chargeCents - expectedCharges) / 100}`);
  const expectedPaymentsCredits = cents(summary.paymentsCredits);
  if (expectedPaymentsCredits !== undefined && paymentCents + creditCents !== expectedPaymentsCredits) errors.push(`pagos y créditos ${(paymentCents + creditCents - expectedPaymentsCredits) / 100}`);
  const expectedNewCharges = cents(summary.newCharges);
  if (expectedNewCharges !== undefined && chargeCents + msiCents !== expectedNewCharges) errors.push(`nuevos cargos ${(chargeCents + msiCents - expectedNewCharges) / 100}`);
  const expectedDomestic = cents(summary.domesticTransactionTotal);
  if (expectedDomestic !== undefined) {
    const actualDomestic = domesticChargeCents - domesticCreditCents;
    const matchesDomestic = summary.domesticTransactionTotalIsCredit
      ? actualDomestic === -expectedDomestic
      : Math.abs(actualDomestic) === expectedDomestic;
    if (!matchesDomestic) errors.push(`sección nacional ${(Math.abs(actualDomestic) - expectedDomestic) / 100}`);
  }
  const expectedForeign = cents(summary.foreignTransactionTotal);
  if (expectedForeign !== undefined && foreignChargeCents - foreignCreditCents !== expectedForeign) errors.push(`moneda extranjera ${(foreignChargeCents - foreignCreditCents - expectedForeign) / 100}`);
  const limit = cents(summary.creditLimit);
  const available = cents(summary.creditAvailable);
  const debt = cents(summary.debtBalance);
  if (limit !== undefined && available !== undefined && debt !== undefined && limit - available !== debt) errors.push(`deuda utilizada ${(limit - available - debt) / 100}`);
  const statementBalance = cents(summary.statementBalance);
  const msiPending = cents(summary.msiPending);
  if (statementBalance !== undefined && msiPending !== undefined && debt !== undefined && statementBalance + msiPending !== debt) errors.push(`saldo más MSI ${(statementBalance + msiPending - debt) / 100}`);
  const paymentForNoInterest = cents(summary.paymentForNoInterest);
  if (paymentForNoInterest !== undefined && statementBalance !== undefined && paymentForNoInterest !== statementBalance) errors.push("pago para no generar intereses no coincide con saldo actual");
  return errors.length ? invalid(`No concilia al centavo: ${errors.join(", ")}`, extra) : { status: "valid", tolerance: 0, extractedMovementCount: rows.length, ...extra };
}
