import type {
  ReconciliationType,
  Statement,
  StatementKind,
  Transaction,
  TransactionKind,
  TransactionValidationStatus,
} from "./types.ts";

/**
 * The import pipeline deliberately lives outside the UI and the metric
 * builder.  Every consumer can therefore use the same canonical ledger:
 * extract -> validate -> normalize -> deduplicate -> match -> classify ->
 * reconcile -> calculate.
 */

export type AuditPeriod = {
  key: string;
  label: string;
  importedCount: number;
  importedAmount: number;
  validCount: number;
  validAmount: number;
  invalidCount: number;
  invalidAmount: number;
  duplicateCount: number;
  duplicateAmount: number;
  internalTransferCount: number;
  internalTransferAmount: number;
  cardPaymentCount: number;
  cardPaymentAmount: number;
  incomeCount: number;
  incomeAmount: number;
  expenseCount: number;
  expenseAmount: number;
  refundCount: number;
  refundAmount: number;
  reviewCount: number;
  reviewAmount: number;
};

export type PipelineAudit = {
  stages: string[];
  importedCount: number;
  importedAmount: number;
  validCount: number;
  validAmount: number;
  invalidCount: number;
  invalidAmount: number;
  duplicateCount: number;
  duplicateAmount: number;
  internalTransferCount: number;
  internalTransferAmount: number;
  cardPaymentCount: number;
  cardPaymentAmount: number;
  incomeCount: number;
  incomeAmount: number;
  expenseCount: number;
  expenseAmount: number;
  refundCount: number;
  refundAmount: number;
  reviewCount: number;
  relevantReviewCount: number;
  classifiedPercent: number;
  reconciledPercent: number;
  /** Percentage of imported PDF rows that retain reconstructable provenance. */
  evidencePercent: number;
  missingEvidenceCount: number;
  criticalIssues: string[];
  periods: AuditPeriod[];
};

export type PipelineResult = {
  transactions: Transaction[];
  audit: PipelineAudit;
  invalidTransactions: Transaction[];
  duplicateTransactions: Transaction[];
};

const monthLookup: Record<string, number> = {
  enero: 1, ene: 1, febrero: 2, feb: 2, marzo: 3, mar: 3, abril: 4, abr: 4,
  mayo: 5, may: 5, junio: 6, jun: 6, julio: 7, jul: 7, agosto: 8, ago: 8,
  septiembre: 9, setiembre: 9, sep: 9, set: 9, octubre: 10, oct: 10,
  noviembre: 11, nov: 11, diciembre: 12, dic: 12,
};

function fold(value: string) {
  return value
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase();
}

/** Canonical concept used by deduplication and merchant grouping. */
export function normalizeConcept(value: string) {
  return fold(value)
    .replace(/\b(?:rfc|ref(?:erencia)?|folio|aut(?:orizacion)?|operacion)\s*[:#./_-]*\s*[a-z0-9-]+/g, " ")
    .replace(/\b(?:rfc|ref(?:erencia)?|folio|aut(?:orizacion)?)\b/g, " ")
    .replace(/\b\d{2,}\b/g, " ")
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 120);
}

const administrativePhrases = [
  "ciudad de mexico", "no de serie del certificado", "serie del certificado",
  "total importe cargos", "total importe abonos", "total de cargos", "total de abonos",
  "del al", "fecha de corte", "fecha y detalle", "numero de cuenta", "no de cuenta",
  "numero de cliente", "no de cliente", "cuenta clabe", "cuenta clave", "rfc",
  "estado de cuenta", "estado de cue", "estado de cta", "resumen de cuenta", "periodo de facturacion", "periodo",
  "saldo inicial", "saldo anterior", "saldo final", "saldo al corte", "saldo disponible",
  "saldo", "total de movimientos", "total de transacciones", "total", "pagina",
  "informacion al cliente", "titular de la cuenta", "fecha limite", "pago minimo",
];

/** Returns true for PDF headings, administrative metadata and table totals. */
export function isAdministrativeDescription(value: string) {
  const normalized = normalizeConcept(value);
  if (!normalized || normalized.length < 3) return true;
  if (administrativePhrases.some((phrase) => normalized === phrase || normalized.includes(` ${phrase} `) || normalized.startsWith(`${phrase} `) || normalized.endsWith(` ${phrase}`))) return true;
  if (/^(del|al|no|n|rfc|clabe|fecha|periodo|saldo|total)(?:\s|$)/.test(normalized)) return true;
  const words = normalized.split(" ");
  const numericWords = words.filter((word) => /^\d+$/.test(word)).length;
  return numericWords >= Math.max(2, words.length - 1) || !/[a-z]{2}/.test(normalized);
}

function statementKind(statement: Statement | undefined): StatementKind {
  if (!statement) return "unknown";
  if (statement.kind) return statement.kind;
  const source = fold(statement.source);
  if (source.includes("amex") || source.includes("american express")) return "card";
  if (source.includes("desconocido") || source.includes("importado") || source.includes("unknown")) return "unknown";
  return "bank";
}

function kindFromText(transaction: Transaction): TransactionKind {
  if (transaction.kind) return transaction.kind;
  const text = normalizeConcept(`${transaction.description} ${transaction.category}`);
  // Amex uses “monto a diferir … CR” for a credit that moves a purchase into
  // an MSI plan. It reduces the card balance and must never be counted as a
  // new expense or as an MSI installment itself.
  if (/monto a diferir/.test(text) && (transaction.amount > 0 || transaction.flow === "income")) return "credit";
  if (/msi|meses sin intereses|meses en automatico|diferid/.test(text)) return "msi";
  if (/interes/.test(text)) return "interest";
  if (/comision|anualidad/.test(text)) return "fee";
  if (/devolucion|reembolso|bonificacion|refund/.test(text)) return "refund";
  if (/pago.*(?:tarjeta|amex|credito|recibido)|tarjeta.*pago|gracias por su pago|abono.*(?:tarjeta|credito|recibido)/.test(text)) return "cardPayment";
  if (/transfer|traspaso|spei|entre cuentas/.test(text)) return "bankTransfer";
  if (transaction.flow === "income") return "income";
  if (transaction.flow === "expense") return "purchase";
  return "other";
}

function hasTransferHint(transaction: Transaction) {
  return /transfer|traspaso|spei|entre cuentas|cuenta propia|clabe/.test(normalizeConcept(transaction.description));
}

/**
 * A same-amount/date pair is not enough to prove an own-account transfer:
 * an external deposit can coincidentally mirror a purchase.  Require a
 * positive signal in the row text (explicit own-account language or the
 * known counterpart account/issuer name) before removing both rows from the
 * income and spend KPIs.
 */
function hasOwnAccountTransferEvidence(outflow: Transaction, inflow: Transaction, statements: Statement[]) {
  const combined = normalizeConcept(`${outflow.description} ${inflow.description}`);
  if (/entre cuentas|cuenta propia|mismo titular|traspaso interno|autotransferencia/.test(combined)) return true;
  // A bank name appearing in a generic merchant/payment description is not
  // sufficient by itself. At least one side must also carry transfer
  // semantics (SPEI, traspaso, transferencia, CLABE, ...).
  if (!hasTransferHint(outflow) && !hasTransferHint(inflow)) return false;
  const outAccount = normalizeConcept(outflow.account);
  const inAccount = normalizeConcept(inflow.account);
  if (!outAccount || !inAccount || outAccount === inAccount) return false;
  const counterpartMentioned = (movement: Transaction, counterpart: string) => {
    const text = normalizeConcept(movement.description);
    return counterpart.length >= 3 && text.includes(counterpart);
  };
  // Prefer the account labels already identified from institutional evidence;
  // this prevents a counterparty mentioned in a SPEI description from being
  // mistaken for the issuer or for an own account.
  const knownAccountLabels = new Set(
    statements
      .filter((statement) => statementKind(statement) === "bank")
      .map((statement) => normalizeConcept(statement.source))
      .filter((source) => source.length >= 3),
  );
  const outLabelKnown = knownAccountLabels.has(outAccount);
  const inLabelKnown = knownAccountLabels.has(inAccount);
  return (outLabelKnown && counterpartMentioned(outflow, inAccount))
    || (inLabelKnown && counterpartMentioned(inflow, outAccount));
}

function hasCardPaymentHint(transaction: Transaction) {
  return /pago.*(?:tarjeta|amex|credito|recibido)|tarjeta.*pago|gracias por su pago|abono.*(?:tarjeta|credito|recibido)|american express/.test(normalizeConcept(transaction.description));
}

function hasIncomeHint(transaction: Transaction) {
  return /nomina|sueldo|salario|deposito|abono|ingreso|recibid|transferencia recibida|spei recibido|pago de nomina/.test(normalizeConcept(transaction.description));
}

function hasRefundHint(transaction: Transaction) {
  return /devolucion|reembolso|bonificacion|refund|cashback/.test(normalizeConcept(transaction.description));
}

const monthPattern = "enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre|ene|feb|mar|abr|may|jun|jul|ago|ag0|sep|set|oct|nov|dic";

function monthNumber(value: string) {
  const month = monthLookup[fold(value).replace(/^ag0?$/, "ago")];
  return month;
}

function periodKeyFromParts(year: number, month: number) {
  return `${year}-${String(month).padStart(2, "0")}`;
}

/** Returns the month of the last explicit date in a statement period label. */
export function periodKeyFromLabel(value: string) {
  const normalized = fold(value);
  const fullDatePattern = new RegExp(
    `(?:\\b(20\\d{2})[-/.](\\d{1,2})[-/.](\\d{1,2})\\b|\\b(\\d{1,2})[-/.](\\d{1,2})[-/.](20\\d{2})\\b|\\b(\\d{1,2})[-/](\\w+)[-/](20\\d{2})\\b)`,
    "gi",
  );
  const dateMatches = Array.from(normalized.matchAll(fullDatePattern));
  const lastDate = dateMatches.at(-1);
  if (lastDate) {
    if (lastDate[1] && lastDate[2]) return periodKeyFromParts(Number(lastDate[1]), Number(lastDate[2]));
    if (lastDate[4] && lastDate[5]) return periodKeyFromParts(Number(lastDate[6]), Number(lastDate[5]));
    if (lastDate[7] && lastDate[8]) {
      const month = monthNumber(lastDate[8]);
      if (month) return periodKeyFromParts(Number(lastDate[9]), month);
    }
  }

  const matches = Array.from(normalized.matchAll(new RegExp(`(${monthPattern})[^0-9]{0,20}(20\\d{2})`, "gi")));
  const match = matches.at(-1);
  if (match) return periodKeyFromParts(Number(match[2]), monthNumber(match[1]) ?? 1);
  const numeric = normalized.match(/\b(20\d{2})[-/. ](\d{1,2})\b/);
  if (numeric && Number(numeric[2]) >= 1 && Number(numeric[2]) <= 12) return periodKeyFromParts(Number(numeric[1]), Number(numeric[2]));
  return undefined;
}

/** Timestamp of the statement cutoff, used to choose the latest account state. */
export function statementPeriodEndTimestamp(value: string, importedAt?: string) {
  const normalized = fold(value);
  const fullDatePattern = new RegExp(
    `(?:\\b(20\\d{2})[-/.](\\d{1,2})[-/.](\\d{1,2})\\b|\\b(\\d{1,2})[-/.](\\d{1,2})[-/.](20\\d{2})\\b|\\b(\\d{1,2})[-/](\\w+)[-/](20\\d{2})\\b)`,
    "gi",
  );
  const matches = Array.from(normalized.matchAll(fullDatePattern));
  const last = matches.at(-1);
  if (last) {
    const year = last[1] ? Number(last[1]) : last[6] ? Number(last[6]) : Number(last[9]);
    const month = last[2] ? Number(last[2]) : last[5] ? Number(last[5]) : monthNumber(last[8]) ?? 0;
    const day = last[3] ? Number(last[3]) : last[4] ? Number(last[4]) : Number(last[7]);
    const date = new Date(year, month - 1, day);
    if (date.getFullYear() === year && date.getMonth() === month - 1 && date.getDate() === day) return date.getTime();
  }
  const key = periodKeyFromLabel(value);
  if (key) {
    const [year, month] = key.split("-").map(Number);
    return new Date(year, month, 0, 23, 59, 59, 999).getTime();
  }
  const imported = importedAt ? Date.parse(importedAt) : Number.NaN;
  return Number.isFinite(imported) ? imported : 0;
}

/** Parses all date formats emitted by bank/card PDF text and OCR. */
export function parseDate(value: string, fallbackPeriod?: string) {
  const normalized = fold(value).trim();
  const calendarDate = (year: number, month: number, day: number) => {
    const date = new Date(year, month - 1, day);
    return date.getFullYear() === year && date.getMonth() === month - 1 && date.getDate() === day
      ? date.getTime()
      : undefined;
  };
  let match = normalized.match(/^(20\d{2})[-/.](\d{1,2})[-/.](\d{1,2})$/);
  if (match) return calendarDate(Number(match[1]), Number(match[2]), Number(match[3]));
  match = normalized.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](20\d{2})$/);
  if (match) return calendarDate(Number(match[3]), Number(match[2]), Number(match[1]));
  match = normalized.match(new RegExp(`^(\\d{1,2})[-/\\.](${monthPattern})(?:[-/\\.](20\\d{2}|\\d{2}))?$`, "i"));
  if (match) {
    const fallbackKey = fallbackPeriod ? periodKeyFromLabel(fallbackPeriod) : undefined;
    const year = match[3] ? Number(match[3]) : fallbackKey ? Number(fallbackKey.slice(0, 4)) : undefined;
    const month = monthNumber(match[2]);
    if (month && year !== undefined) return calendarDate(year < 100 ? 2000 + year : year, month, Number(match[1]));
    return undefined;
  }
  match = normalized.match(new RegExp(`^(\\d{1,2})\\s+(?:de\\s*)?(${monthPattern})(?:\\s*(?:de\\s*)?(20\\d{2}|\\d{2}))?$`, "i"));
  if (!match) return undefined;
  const month = monthNumber(match[2]);
  const fallbackKey = fallbackPeriod ? periodKeyFromLabel(fallbackPeriod) : undefined;
  const year = match[3] ? Number(match[3]) : fallbackKey ? Number(fallbackKey.slice(0, 4)) : undefined;
  if (!month || year === undefined) return undefined;
  return calendarDate(year < 100 ? 2000 + year : year, month, Number(match[1]));
}

export function transactionPeriodKey(transaction: Transaction, statements: Statement[] = []) {
  const statement = transaction.statementId ? statements.find((item) => item.id === transaction.statementId) : undefined;
  const timestamp = parseDate(transaction.date, statement?.period);
  if (timestamp !== undefined) {
    const date = new Date(timestamp);
    return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`;
  }
  return statement ? periodKeyFromLabel(statement.period) : undefined;
}

function periodLabelFor(transaction: Transaction, statements: Statement[]) {
  const statement = transaction.statementId ? statements.find((item) => item.id === transaction.statementId) : undefined;
  return statement?.period ?? transaction.date;
}

function isValidDirection(transaction: Transaction, statement: Statement | undefined) {
  // The signed amount is the final direction signal once extraction has
  // identified the row.  Still require a supported flow so malformed legacy
  // JSON cannot enter the canonical ledger as an unclassified event.
  const supportedFlow = ["income", "expense", "transfer", "debt"].includes(transaction.flow);
  if (!supportedFlow || !Number.isFinite(transaction.amount) || transaction.amount === 0) return false;
  // A signed amount is part of the direction contract. Card rows may use
  // `debt` for issuer-side payments, while bank rows use income/expense;
  // transfers are the only flow allowed to have either sign because both
  // counterpart rows are retained.
  if (transaction.flow === "income") return transaction.amount > 0;
  if (transaction.flow === "expense" || transaction.flow === "debt") return transaction.amount < 0;
  return statementKind(statement) === "card" || transaction.flow === "transfer";
}

function validateTransaction(transaction: Transaction, statements: Statement[]) {
  const statement = transaction.statementId ? statements.find((item) => item.id === transaction.statementId) : undefined;
  const description = transaction.description.trim();
  const declaredDirectionTotal = statement && statementKind(statement) === "bank"
    ? transaction.amount > 0 ? statement.summary?.depositTotal : statement.summary?.withdrawalTotal
    : undefined;
  // A single movement cannot exceed the issuer's declared total for that
  // direction. This catches OCR tokens that merge separators (for example a
  // balance misread as 1,633,480) before they can reach any aggregate.
  const withinDeclaredDirectionTotal = declaredDirectionTotal === undefined
    || Math.abs(transaction.amount) <= Math.abs(declaredDirectionTotal) + 0.05;
  const validAmount = Number.isFinite(transaction.amount)
    && transaction.amount !== 0
    // Numeric fragments from PDF headers (account numbers, certificate IDs,
    // running balances) must never enter the canonical ledger.
    && Math.abs(transaction.amount) < 10_000_000
    && withinDeclaredDirectionTotal;
  const validDescription = description.length >= 3 && !isAdministrativeDescription(description);
  const validDate = parseDate(transaction.date, statement?.period) !== undefined;
  const validDirection = isValidDirection(transaction, statement);
  const invalid = !validAmount || !validDescription || !validDate || !validDirection;
  const reason = !withinDeclaredDirectionTotal
    ? "importe individual supera el total declarado del estado"
    : !validAmount ? "importe inválido o fuera de rango" : !validDescription ? "descripción administrativa o vacía" : !validDate ? "fecha inválida" : !validDirection ? "dirección no clara" : undefined;
  const status: TransactionValidationStatus = invalid ? "invalid" : transaction.category === "Sin categoría" || (transaction.confidence ?? 1) < 0.75 ? "review" : "valid";
  return { status, reason };
}

/** Stable identity shared by overlapping periods and repeated uploads. */
export function buildDeduplicationKey(transaction: Transaction) {
  const account = normalizeConcept(transaction.account) || "cuenta-desconocida";
  const timestamp = parseDate(transaction.date);
  const date = timestamp === undefined
    ? fold(transaction.date).replace(/\s+/g, " ").trim()
    : new Intl.DateTimeFormat("en-CA", { year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(timestamp));
  const amount = Math.round(Math.abs(transaction.amount) * 100).toString();
  const description = transaction.normalizedDescription || normalizeConcept(transaction.description);
  const kind = kindFromText(transaction);
  // Keep the signed flow in the identity as a final guard for legacy rows
  // whose free text does not reveal whether an operation is a transfer,
  // income or purchase yet.
  return [account, date, amount, description, kind, transaction.flow].join("|");
}

function absolute(value: number) {
  return Math.abs(Number.isFinite(value) ? value : 0);
}

function isBankTransaction(transaction: Transaction, statements: Statement[]) {
  return statementKind(transaction.statementId ? statements.find((item) => item.id === transaction.statementId) : undefined) === "bank";
}

function isCardTransaction(transaction: Transaction, statements: Statement[]) {
  return statementKind(transaction.statementId ? statements.find((item) => item.id === transaction.statementId) : undefined) === "card";
}

function isOutflow(transaction: Transaction) {
  return transaction.amount < 0 || transaction.flow === "expense" || transaction.flow === "debt";
}

function isInflow(transaction: Transaction) {
  return transaction.amount > 0 || transaction.flow === "income";
}

function withinTwoDays(left: Transaction, right: Transaction, statements: Statement[]) {
  const leftTime = parseDate(left.date, left.statementId ? statements.find((item) => item.id === left.statementId)?.period : undefined);
  const rightTime = parseDate(right.date, right.statementId ? statements.find((item) => item.id === right.statementId)?.period : undefined);
  return leftTime !== undefined && rightTime !== undefined && Math.abs(leftTime - rightTime) <= 2 * 24 * 60 * 60 * 1000;
}

function sameAmount(left: Transaction, right: Transaction) {
  return Math.abs(absolute(left.amount) - absolute(right.amount)) <= 0.01;
}

function reconcilePair(left: Transaction, right: Transaction, type: ReconciliationType, id: string) {
  const nextLeft: Transaction = {
    ...left,
    reconciliationId: id,
    reconciledAs: type,
    kind: type === "cardPayment" ? "cardPayment" : "bankTransfer",
    category: "Transferencia",
    flow: type === "cardPayment" && left.flow === "income" ? "debt" : type === "internalTransfer" ? "transfer" : left.flow,
    validationStatus: left.validationStatus ?? "valid",
  };
  const nextRight: Transaction = {
    ...right,
    reconciliationId: id,
    reconciledAs: type,
    kind: type === "cardPayment" ? "cardPayment" : "bankTransfer",
    category: "Transferencia",
    flow: type === "cardPayment" && right.flow === "income" ? "debt" : type === "internalTransfer" ? "transfer" : right.flow,
    validationStatus: right.validationStatus ?? "valid",
  };
  return [nextLeft, nextRight] as const;
}

function emptyAuditPeriod(key: string, label: string): AuditPeriod {
  return {
    key, label, importedCount: 0, validCount: 0, invalidCount: 0, duplicateCount: 0,
    importedAmount: 0, validAmount: 0, invalidAmount: 0, duplicateAmount: 0, internalTransferCount: 0, internalTransferAmount: 0, cardPaymentCount: 0, cardPaymentAmount: 0,
    incomeCount: 0, incomeAmount: 0, expenseCount: 0, expenseAmount: 0, refundCount: 0, refundAmount: 0,
    reviewCount: 0, reviewAmount: 0,
  };
}

function isSpend(transaction: Transaction) {
  const kind = kindFromText(transaction);
  return transaction.flow === "expense" && !["cardPayment", "bankTransfer", "refund"].includes(kind);
}

function isIncome(transaction: Transaction, statements: Statement[]) {
  const kind = kindFromText(transaction);
  if (transaction.flow !== "income" || ["credit", "refund"].includes(kind)) return false;
  return !isCardTransaction(transaction, statements);
}

function isRefund(transaction: Transaction) {
  return kindFromText(transaction) === "refund";
}

export function hasTraceableEvidence(transaction: Transaction) {
  // Manual rows are intentionally evidence-complete without a PDF page. They
  // are user-entered events and must not lower the import quality score.
  if (transaction.extractionEvidence?.method === "manual") return true;
  const evidence = transaction.extractionEvidence;
  return Boolean(evidence
    && Number.isFinite(evidence.confidence)
    && Number.isInteger(evidence.page)
    && (evidence.page ?? 0) >= 1
    && evidence.method
    && evidence.sourceText?.trim());
}

/** Runs the full canonical ledger pipeline and emits period-level audit facts. */
export function runTransactionPipeline(input: Transaction[], statements: Statement[]): PipelineResult {
  const stages = ["extraer", "validar", "normalizar", "deduplicar", "matching entre cuentas", "clasificar", "conciliar", "calcular"];
  const periods = new Map<string, AuditPeriod>();
  const ensurePeriod = (transaction: Transaction) => {
    const key = transactionPeriodKey(transaction, statements) ?? "sin-periodo";
    const current = periods.get(key) ?? emptyAuditPeriod(key, periodLabelFor(transaction, statements));
    periods.set(key, current);
    return current;
  };

  // Keep empty statement periods in the diagnostic view as well. A scanned or
  // malformed PDF with zero accepted rows is still an import event that must
  // be visible (and marked provisional by the metric builder).
  statements.forEach((statement) => {
    const key = periodKeyFromLabel(statement.period) ?? "sin-periodo";
    if (!periods.has(key)) periods.set(key, emptyAuditPeriod(key, statement.period));
  });

  // The base hash intentionally omits the statement id so an overlapping
  // period can be recognised as the same movement.  Add an occurrence ordinal
  // per statement, however, so two legitimate identical purchases are not
  // collapsed when one statement contains one copy and the next contains two.
  // (Issuer PDFs do not expose a stable transaction id for this edge case.)
  const occurrenceByStatement = new Map<string, number>();
  const normalized = input.map((transaction) => {
    const description = transaction.description.replace(/\s+/g, " ").trim();
    const normalizedDescription = normalizeConcept(description);
    const status = validateTransaction({ ...transaction, description }, statements);
    const baseDeduplicationKey = buildDeduplicationKey({ ...transaction, description, normalizedDescription });
    const occurrenceScope = `${transaction.statementId ?? "manual"}|${baseDeduplicationKey}`;
    const occurrence = status.status === "invalid" ? -1 : occurrenceByStatement.get(occurrenceScope) ?? 0;
    if (occurrence >= 0) occurrenceByStatement.set(occurrenceScope, occurrence + 1);
    const next: Transaction = {
      ...transaction,
      description,
      normalizedDescription,
      deduplicationKey: `${baseDeduplicationKey}|ocurrencia:${occurrence}`,
      validationStatus: status.status,
    };
    const auditPeriod = ensurePeriod(next);
    auditPeriod.importedCount += 1;
    auditPeriod.importedAmount += absolute(next.amount);
    if (status.status === "invalid") {
      auditPeriod.invalidCount += 1;
      auditPeriod.invalidAmount += absolute(next.amount);
    }
    else {
      auditPeriod.validCount += 1;
      auditPeriod.validAmount += absolute(next.amount);
      if (status.status === "review") {
        auditPeriod.reviewCount += 1;
        auditPeriod.reviewAmount += absolute(next.amount);
      }
    }
    return next;
  });

  const invalidTransactions = normalized.filter((transaction) => transaction.validationStatus === "invalid");
  const valid = normalized.filter((transaction) => transaction.validationStatus !== "invalid");
  const seen = new Map<string, Transaction[]>();
  const canonical: Transaction[] = [];
  const duplicateTransactions: Transaction[] = [];
  valid.forEach((transaction) => {
    const key = transaction.deduplicationKey ?? buildDeduplicationKey(transaction);
    const previous = seen.get(key) ?? [];
    const hasDifferentStatement = Boolean(transaction.statementId && previous.some((item) => item.statementId && item.statementId !== transaction.statementId));
    if (hasDifferentStatement) {
      duplicateTransactions.push(transaction);
      const auditPeriod = ensurePeriod(transaction);
      auditPeriod.duplicateCount += 1;
      auditPeriod.duplicateAmount += absolute(transaction.amount);
      return;
    }
    seen.set(key, [...previous, transaction]);
    canonical.push(transaction);
  });

  const byId = new Map(canonical.map((transaction) => [transaction.id, transaction]));
  const consumed = new Set<string>();
  let internalTransferCount = 0;
  let internalTransferAmount = 0;
  let cardPaymentCount = 0;
  let cardPaymentAmount = 0;

  const candidates = canonical.slice();
  const replacePair = (left: Transaction, right: Transaction, type: ReconciliationType) => {
    const id = `recon-${[left.id, right.id].sort().join("-")}`;
    const [nextLeft, nextRight] = reconcilePair(left, right, type, id);
    byId.set(nextLeft.id, nextLeft);
    byId.set(nextRight.id, nextRight);
    consumed.add(nextLeft.id);
    consumed.add(nextRight.id);
    const period = ensurePeriod(left);
    if (type === "internalTransfer") {
      internalTransferCount += 1;
      internalTransferAmount += absolute(left.amount);
      period.internalTransferCount += 1;
      period.internalTransferAmount += absolute(left.amount);
    } else {
      cardPaymentCount += 1;
      cardPaymentAmount += absolute(left.amount);
      period.cardPaymentCount += 1;
      period.cardPaymentAmount += absolute(left.amount);
    }
  };

  // Match bank -> card payments first, so they can never be mistaken for a
  // bank-to-bank transfer when several accounts share the same amount.
  candidates.forEach((bank) => {
    if (consumed.has(bank.id) || !isBankTransaction(bank, statements) || !isOutflow(bank)) return;
    const partner = candidates
      .filter((card) => !consumed.has(card.id)
        && card.id !== bank.id
        && isCardTransaction(card, statements)
        && !isRefund(card)
        && sameAmount(bank, card)
        && withinTwoDays(bank, card, statements)
        // Some issuers label the receiving side only as “pago recibido” or
        // “abono”, so an explicit payment hint or card-payment kind is enough.
        // A positive card row alone is not sufficient: it may be a credit or
        // issuer adjustment with the same amount as an unrelated bank charge.
        && (kindFromText(card) === "cardPayment"
          || hasCardPaymentHint(card)
          || hasCardPaymentHint(bank)
          || (card.flow === "debt" && /pago|abono|credito|recib/.test(normalizeConcept(card.description)))))
      .sort((left, right) => absolute((parseDate(left.date) ?? 0) - (parseDate(bank.date) ?? 0)) - absolute((parseDate(right.date) ?? 0) - (parseDate(bank.date) ?? 0)))[0];
    if (partner) replacePair(bank, partner, "cardPayment");
  });

  // Match own-account transfers by account, direction, amount and date. The
  // amount/date gate narrows candidates, but an explicit own-account signal
  // is also mandatory: account identity alone cannot distinguish a transfer
  // from an unrelated external deposit of the same amount.
  const ambiguousTransferReviewIds = new Set<string>();
  const ambiguousTransferReviewCountIds = new Set<string>();
  candidates.forEach((outflow) => {
    if (consumed.has(outflow.id) || !isBankTransaction(outflow, statements) || !isOutflow(outflow)) return;
    const possiblePartners = candidates
      .filter((inflow) => !consumed.has(inflow.id)
        && inflow.id !== outflow.id
        && isBankTransaction(inflow, statements)
        && isInflow(inflow)
        && normalizeConcept(inflow.account) !== normalizeConcept(outflow.account)
        && sameAmount(outflow, inflow)
        && withinTwoDays(outflow, inflow, statements))
      .sort((left, right) => absolute((parseDate(left.date) ?? 0) - (parseDate(outflow.date) ?? 0)) - absolute((parseDate(right.date) ?? 0) - (parseDate(outflow.date) ?? 0)));
    const partner = possiblePartners.find((inflow) => hasOwnAccountTransferEvidence(outflow, inflow, statements));
    if (partner) replacePair(outflow, partner, "internalTransfer");
    else if (possiblePartners[0]) {
      // Keep a coincident external pair visible as a review item rather than
      // silently deciding that it is internal. Relevant pairs will block the
      // executive KPIs through the normal data-quality gate.
      [outflow, possiblePartners[0]].forEach((row) => {
        ambiguousTransferReviewIds.add(row.id);
        // Validation may already have placed a row in review; only add the
        // newly introduced review status to its period diagnostic once.
        if (row.validationStatus !== "review") ambiguousTransferReviewCountIds.add(row.id);
      });
    }
  });

  const classified = canonical.map((transaction) => {
    const reconciled = byId.get(transaction.id) ?? transaction;
    if (reconciled.reconciledAs) return reconciled;
    const text = reconciled.normalizedDescription || normalizeConcept(reconciled.description);
    let kind = kindFromText(reconciled);
    let flow = reconciled.flow;
    if (hasRefundHint(reconciled)) {
      kind = "refund";
      flow = "income";
    } else if (hasCardPaymentHint(reconciled) || kind === "cardPayment") {
      kind = "cardPayment";
      flow = isCardTransaction(reconciled, statements) ? "debt" : "expense";
    } else if (hasTransferHint(reconciled) || kind === "bankTransfer") {
      const ownAccountMention = statements.some((statement) => {
        const source = normalizeConcept(statement.source);
        return source.length >= 3 && source !== normalizeConcept(reconciled.account) && text.includes(source);
      });
      const ownTransferText = /entre cuentas|cuenta propia|mismo titular|traspaso interno/.test(text) || ownAccountMention;
      // An unmatched incoming SPEI/transfer is external income. Only an
      // explicit own-account signal (or a matched pair above) is excluded.
      if (reconciled.amount > 0 && isBankTransaction(reconciled, statements) && !ownTransferText) {
        kind = "income";
        flow = "income";
      } else if (reconciled.amount < 0 && isBankTransaction(reconciled, statements) && !ownTransferText) {
        // A bank transfer to an external person or merchant is still a real
        // outflow. Only a matched own-account pair (handled above) or an
        // explicit internal-transfer label should be excluded from spend.
        kind = "purchase";
        flow = "expense";
      } else {
        kind = "bankTransfer";
        flow = "transfer";
      }
    } else if (hasIncomeHint(reconciled) || (reconciled.amount > 0 && isBankTransaction(reconciled, statements))) {
      kind = "income";
      flow = "income";
    } else if (reconciled.amount < 0) {
      kind = kind === "other" ? "purchase" : kind;
      flow = "expense";
    } else if (isCardTransaction(reconciled, statements)) {
      kind = kind === "other" ? "credit" : kind;
      flow = "income";
    }
    return {
      ...reconciled,
      kind,
      flow,
      normalizedDescription: text,
      validationStatus: ambiguousTransferReviewIds.has(reconciled.id) ? "review" : reconciled.validationStatus ?? "valid",
    };
  });

  // Keep period-level diagnostics in sync with review statuses introduced by
  // the conservative transfer matcher (normalization counters were filled
  // before matching ran).
  ambiguousTransferReviewCountIds.forEach((id) => {
    const transaction = classified.find((row) => row.id === id);
    if (!transaction) return;
    const auditPeriod = ensurePeriod(transaction);
    auditPeriod.reviewCount += 1;
    auditPeriod.reviewAmount += absolute(transaction.amount);
  });

  const totals = {
    incomeCount: 0, incomeAmount: 0, expenseCount: 0, expenseAmount: 0,
    refundCount: 0, refundAmount: 0,
  };
  classified.forEach((transaction) => {
    const auditPeriod = ensurePeriod(transaction);
    if (isIncome(transaction, statements)) {
      totals.incomeCount += 1;
      totals.incomeAmount += absolute(transaction.amount);
      auditPeriod.incomeCount += 1;
      auditPeriod.incomeAmount += absolute(transaction.amount);
    }
    if (isSpend(transaction)) {
      totals.expenseCount += 1;
      totals.expenseAmount += absolute(transaction.amount);
      auditPeriod.expenseCount += 1;
      auditPeriod.expenseAmount += absolute(transaction.amount);
    }
    if (isRefund(transaction)) {
      totals.refundCount += 1;
      totals.refundAmount += absolute(transaction.amount);
      auditPeriod.refundCount += 1;
      auditPeriod.refundAmount += absolute(transaction.amount);
    }
  });

  const reviewTransactions = classified.filter((transaction) => transaction.validationStatus === "review" || transaction.category === "Sin categoría" || (transaction.confidence ?? 1) < 0.75);
  const relevantReviewThreshold = 1000;
  // Only rows that are demonstrably imported from a statement participate in
  // provenance coverage. Legacy/manual entries without a statement id are
  // not silently treated as failed PDF evidence.
  const evidenceRows = input.filter((transaction) => Boolean(transaction.statementId)
    || transaction.extractionEvidence?.method === "pdf-text"
    || transaction.extractionEvidence?.method === "ocr");
  const missingEvidenceCount = evidenceRows.filter((transaction) => !hasTraceableEvidence(transaction)).length;
  const audit: PipelineAudit = {
    stages,
    importedCount: input.length,
    importedAmount: normalized.reduce((total, transaction) => total + absolute(transaction.amount), 0),
    validCount: valid.length,
    validAmount: valid.reduce((total, transaction) => total + absolute(transaction.amount), 0),
    invalidCount: invalidTransactions.length,
    invalidAmount: invalidTransactions.reduce((total, transaction) => total + absolute(transaction.amount), 0),
    duplicateCount: duplicateTransactions.length,
    duplicateAmount: duplicateTransactions.reduce((total, transaction) => total + absolute(transaction.amount), 0),
    internalTransferCount,
    internalTransferAmount,
    cardPaymentCount,
    cardPaymentAmount,
    ...totals,
    reviewCount: reviewTransactions.length,
    relevantReviewCount: reviewTransactions.filter((transaction) => absolute(transaction.amount) >= relevantReviewThreshold).length,
    // Quality percentages use every imported row as the denominator.  This
    // keeps rejected/admin rows and cross-statement duplicates visible in the
    // score instead of silently making a bad import look healthy.
    classifiedPercent: input.length ? (Math.max(0, valid.length - reviewTransactions.length) / input.length) * 100 : 100,
    reconciledPercent: input.length ? (Math.max(0, valid.length - duplicateTransactions.length) / input.length) * 100 : 100,
    evidencePercent: evidenceRows.length ? ((evidenceRows.length - missingEvidenceCount) / evidenceRows.length) * 100 : 100,
    missingEvidenceCount,
    criticalIssues: [
      ...(invalidTransactions.length ? [`${invalidTransactions.length} movimiento(s) rechazado(s) por datos inválidos o administrativos`] : []),
      ...(reviewTransactions.some((transaction) => absolute(transaction.amount) >= relevantReviewThreshold) ? ["Hay movimientos relevantes pendientes de revisión"] : []),
      ...(missingEvidenceCount ? [`${missingEvidenceCount} movimiento(s) importado(s) sin evidencia completa`] : []),
    ],
    periods: Array.from(periods.values()).sort((left, right) => right.key.localeCompare(left.key)),
  };

  return { transactions: classified, audit, invalidTransactions, duplicateTransactions };
}
