import type {
  Statement,
  StatementKind,
  StatementSource,
  StatementSummary,
  Transaction,
  TransactionKind,
} from "./types.ts";
import { normalizeConcept, parseDate, periodKeyFromLabel, runTransactionPipeline, statementPeriodEndTimestamp, transactionPeriodKey, type PipelineAudit, type PipelineResult } from "./reconciliation.ts";

const OCR_MIN_AVERAGE_CONFIDENCE = 0.88;
const OCR_MIN_PAGE_CONFIDENCE = 0.78;

/**
 * OCR quality is part of statement eligibility, not merely a review hint.
 * Persisted data can outlive the import dialog and may have been edited by an
 * older build, so every KPI boundary must re-check the same thresholds.
 */
function hasSufficientOcrQuality(statement: Statement) {
  if (statement.mode !== "ocr") return true;
  const average = statement.ocrConfidence;
  const pages = statement.ocrPageConfidences;
  if (average === undefined || !Number.isFinite(average) || average < OCR_MIN_AVERAGE_CONFIDENCE) return false;
  if (!pages?.length || pages.some((page) => !Number.isFinite(page) || page < OCR_MIN_PAGE_CONFIDENCE)) return false;
  return true;
}

export type PeriodMetrics = {
  key: string;
  label: string;
  source: StatementSource;
  statementId: string;
  kind: StatementKind;
  newTransactions: number;
  msiInstallments: number;
  interest: number;
  fees: number;
  newCharges: number;
  realPayments: number;
  credits: number;
  refunds: number;
  difference: number;
  accumulatedBalance: number;
  paidPercent: number | null;
  pendingPercent: number | null;
  travelSpend: number;
  ordinarySpend: number;
  creditLimit?: number;
  creditAvailable?: number;
  creditUsed?: number;
  creditUtilizationRate?: number;
  paymentForNoInterest?: number;
  minimumPayment?: number;
  minimumPlusMsi?: number;
  msiOriginalDeferred?: number;
  msiPending?: number;
  revolvingBalance?: number;
  msiInstallmentsCount?: number;
  msiMonthlyLoad?: number;
  cashBalance?: number;
  debtBalance?: number;
  /** Used for latest-cutoff selection; never inferred from array order. */
  statementEndTimestamp: number;
  importedAt: string;
};

export type AnalyticsPeriod = {
  key: string;
  label: string;
  spend: number;
  ordinarySpend: number;
  extraordinarySpend: number;
  travelSpend: number;
  paymentTotal: number;
  income: number;
  netFlow: number;
  variationPercent: number | null;
  movingAverage3: number;
  cashAvailable?: number;
  debtTotal?: number;
  liquidPatrimony?: number;
  cashVariationPercent: number | null;
  debtVariationPercent: number | null;
  patrimonyVariationPercent: number | null;
};

export type CashFlowPoint = {
  key: string;
  date: string;
  income: number;
  expense: number;
  balance: number;
};

export type ProjectionMonth = {
  key: string;
  label: string;
  monthOffset: number;
  expectedIncome: number;
  fixedSpend: number;
  projectedSpend: number;
  projectedPayments: number;
  projectedMsi: number;
  projectedSavings: number;
  projectedDebt: number | undefined;
  projectedLiquidity: number | undefined;
  projectedPatrimony: number | undefined;
  isEstimate: true;
};

export type ProjectionSummary = {
  months: ProjectionMonth[];
  next90Days: ProjectionMonth[];
  horizon3: ProjectionMonth;
  horizon6: ProjectionMonth;
  horizon12: ProjectionMonth;
  assumption: string;
};

export type ExecutiveAlert = {
  id: string;
  severity: "high" | "medium" | "info";
  title: string;
  body: string;
  action: string;
};

export type CategorySpend = {
  name: string;
  total: number;
  share: number;
};

export type MerchantSpend = {
  name: string;
  total: number;
  count: number;
  share: number;
};

export type MovementSpend = {
  id: string;
  description: string;
  amount: number;
  date: string;
  category: string;
  account: string;
  share: number;
};

export type TravelTrip = {
  id: string;
  name: string;
  total: number;
  startDate: string;
  endDate: string;
  movements: MovementSpend[];
};

export type DataQualityMetrics = {
  classifiedPercent: number;
  classifiedCount: number;
  totalCount: number;
  reviewCount: number;
  relevantReviewCount: number;
  reconciledPercent: number;
  evidencePercent: number;
  missingEvidenceCount: number;
  invalidCount: number;
  duplicateCount: number;
  critical: boolean;
};

export type FinancialConsistencyCheck = {
  id: string;
  label: string;
  expected: number | undefined;
  actual: number | undefined;
  difference: number | undefined;
  tolerance: number;
  passed: boolean;
};

export type PrimaryCause = {
  label: string;
  delta: number;
  current: number;
  previous: number;
};

export type FinanceMetrics = {
  periods: PeriodMetrics[];
  cardPeriods: PeriodMetrics[];
  periodCount: number;
  totalNewTransactions: number;
  averageMonthlySpend: number;
  totalNewCharges: number;
  totalRealPayments: number;
  totalCredits: number;
  totalRefunds: number;
  accumulatedBalance: number;
  latestDifference: number;
  paidPercent: number | null;
  pendingPercent: number | null;
  travelSpend: number;
  travelPercent: number | null;
  ordinarySpend: number;
  ordinaryAverageMonthly: number;
  latestMsiMonthlyLoad?: number;
  latestMsiOriginalDeferred?: number;
  latestMsiPending?: number;
  latestRevolvingDebt?: number;
  latestMsiInstallmentsCount?: number;
  latestPaymentForNoInterest?: number;
  latestMinimumPayment?: number;
  latestPaymentDue?: number;
  latestInterest?: number;
  cardSpend: number;
  directBankSpend: number;
  rawExpense: number;
  excludedCardPayments: number;
  excludedInternalTransfers: number;
  consolidatedRealSpend: number;
  realIncome: number;
  netFlow: number;
  savingsRate: number | null;
  cashAvailable?: number;
  debtTotal?: number;
  liquidPatrimony?: number;
  liquidPatrimonyChangePercent: number | null;
  currentMonthSpend: number;
  currentMonthNetFlow: number;
  analyticsPeriods: AnalyticsPeriod[];
  cashFlowHistory: CashFlowPoint[];
  categoryDistribution: CategorySpend[];
  topMerchants: MerchantSpend[];
  topMovements: MovementSpend[];
  travelTrips: TravelTrip[];
  dataQuality: DataQualityMetrics;
  audit: PipelineAudit;
  consistencyChecks: FinancialConsistencyCheck[];
  isProvisional: boolean;
  primaryCause?: PrimaryCause;
  projection: ProjectionSummary;
  executiveAlerts: ExecutiveAlert[];
  creditLimit?: number;
  creditAvailable?: number;
  creditUsed?: number;
  creditUtilizationRate?: number;
};

function normalize(value: string) {
  return value
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase();
}

function absolute(value: number | undefined) {
  return typeof value === "number" && Number.isFinite(value) ? Math.abs(value) : 0;
}

function hasNumber(value: number | undefined): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function sum(values: number[]) {
  return values.reduce((total, value) => total + value, 0);
}

function sumKnown(values: Array<number | undefined>) {
  const known = values.filter(hasNumber);
  return known.length ? sum(known) : undefined;
}

export function defaultStatementKind(source: StatementSource): StatementKind {
  if (source === "Amex") return "card";
  const normalized = normalize(source);
  const bankNames = [
    "santander", "bbva", "bancomer", "banorte", "hsbc", "scotiabank",
    "citibanamex", "banamex", "inbursa", "banco azteca", "banco del bajio",
    "mifel", "invex", "hey banco", "nu", "klar", "rappi", "uala",
  ];
  return bankNames.some((name) => normalized.includes(name)) ? "bank" : "unknown";
}

export function inferTransactionKind(transaction: Transaction): TransactionKind {
  if (transaction.kind) return transaction.kind;
  const text = normalize(`${transaction.description} ${transaction.category}`);
  if (/monto a diferir/.test(text) && (transaction.amount > 0 || transaction.flow === "income")) return "credit";
  if (/msi|meses sin intereses|meses en automatico|monto a diferir|diferir|diferid/.test(text)) return "msi";
  if (/interes|interes moratorio|interest/.test(text)) return "interest";
  if (/comision|comision anual|anualidad|fee/.test(text)) return "fee";
  if (/devolucion|reembolso|refund|bonificacion/.test(text)) return "refund";
  if (transaction.flow === "transfer") {
    return /pago.*(tarjeta|amex|credito)|tarjeta.*pago|american express/.test(text) ? "cardPayment" : "bankTransfer";
  }
  if (transaction.flow === "income") {
    return /credito|abono/.test(text) ? "credit" : "income";
  }
  if (transaction.flow === "expense") return "purchase";
  return "other";
}

export function isCardStatement(statement: Statement) {
  return (statement.kind ?? defaultStatementKind(statement.source)) === "card";
}

function isRealIncomeTransaction(transaction: Transaction, statements: Statement[]) {
  if (transaction.flow !== "income") return false;
  const kind = inferTransactionKind(transaction);
  if (kind === "credit" || kind === "refund") return false;
  const statement = transaction.statementId ? statements.find((item) => item.id === transaction.statementId) : undefined;
  return !statement || !isCardStatement(statement);
}

export function isSpendTransaction(transaction: Transaction) {
  const kind = inferTransactionKind(transaction);
  return transaction.flow === "expense" && !["cardPayment", "bankTransfer", "refund"].includes(kind);
}

function isTravelTransaction(transaction: Transaction) {
  if (transaction.travelRelated) return true;
  const text = normalize(`${transaction.description} ${transaction.category}`);
  return /viaje|hotel|hospedaje|aerolinea|vuelo|avion|transporte|uber|taxi|metro|renta de auto|destino|equipaje/.test(text);
}

function isExtraordinaryTransaction(transaction: Transaction) {
  if (isTravelTransaction(transaction)) return true;
  const text = normalize(`${transaction.description} ${transaction.category}`);
  return /evento|boda|fiesta|concierto|festival|mueble|electrodomestico|reparacion|hospital|impuesto|seguro|regalo|celebracion|mudanza|matricula|colegiatura|anualidad|emergencia|atipic/.test(text);
}

function merchantLabel(description: string) {
  return description
    .replace(/\s+/g, " ")
    .replace(/\b(?:aut\.?|ref\.?|folio|no\.?|num\.?)[\s:#-]*[a-z0-9-]+/gi, "")
    .trim()
    .slice(0, 46) || "Sin descripción";
}

function dateValue(value: string, fallbackPeriod?: string) {
  return parseDate(value, fallbackPeriod);
}

function metricVariation(current: number | undefined, previous: number | undefined) {
  return current !== undefined && previous !== undefined && previous !== 0
    ? (current - previous) / Math.abs(previous)
    : null;
}

function average(values: number[]) {
  return values.length ? sum(values) / values.length : 0;
}

function parsePeriodDate(key?: string) {
  const match = key?.match(/^(20\d{2})-(\d{1,2})$/);
  return match ? new Date(Number(match[1]), Number(match[2]) - 1, 1) : new Date();
}

function addMonths(date: Date, months: number) {
  return new Date(date.getFullYear(), date.getMonth() + months, 1);
}

function projectionLabel(date: Date) {
  return new Intl.DateTimeFormat("es-MX", { month: "short", year: "numeric" }).format(date).replace(".", "");
}

function buildProjection(
  analyticsPeriods: AnalyticsPeriod[],
  cardPeriods: PeriodMetrics[],
  currentPeriodKey: string | undefined,
  cashAvailable: number | undefined,
  debtTotal: number | undefined,
  currentMonthSpend: number,
  realIncome: number,
  periodCount: number,
  cardSpend: number,
  consolidatedRealSpend: number,
  directBankSpend: number,
  manualSpend: number,
  latestMsiMonthlyLoad: number | undefined,
  latestPaymentForNoInterest: number | undefined,
): ProjectionSummary {
  const recent = analyticsPeriods.slice(0, 3);
  const recentSpend = recent.map((period) => period.spend).filter((value) => value > 0);
  const recentIncome = recent.map((period) => period.income).filter((value) => value > 0);
  const recentFixedSpend = recent.map((period) => period.ordinarySpend).filter((value) => value > 0);
  const recentPayments = recent.map((period) => period.paymentTotal).filter((value) => value > 0);
  const recentMsi = cardPeriods.slice(0, 3).map((period) => period.msiMonthlyLoad).filter(hasNumber);
  const monthlySpend = average(recentSpend) || currentMonthSpend;
  const incomePeriodCount = analyticsPeriods.length || periodCount;
  const monthlyIncome = average(recentIncome) || (incomePeriodCount ? realIncome / incomePeriodCount : realIncome);
  const fixedSpend = average(recentFixedSpend) || monthlySpend;
  const monthlyPayments = average(recentPayments) || latestPaymentForNoInterest || 0;
  const monthlyMsi = average(recentMsi) || latestMsiMonthlyLoad || 0;
  const cardShare = consolidatedRealSpend > 0 ? Math.min(1, Math.max(0, cardSpend / consolidatedRealSpend)) : 0;
  const cashSpendShare = consolidatedRealSpend > 0 ? Math.min(1, Math.max(0, (directBankSpend + manualSpend) / consolidatedRealSpend)) : 1 - cardShare;
  const baseDate = parsePeriodDate(currentPeriodKey);
  let projectedDebt = debtTotal;
  let projectedLiquidity = cashAvailable;
  const months: ProjectionMonth[] = Array.from({ length: 12 }, (_, index) => {
    const monthOffset = index + 1;
    const projectedSpend = monthlySpend;
    const projectedPayments = monthlyPayments;
    const expectedIncome = monthlyIncome;
    const cardCharges = projectedSpend * cardShare;
    const cashSpend = projectedSpend * cashSpendShare;
    if (projectedDebt !== undefined) projectedDebt = Math.max(0, projectedDebt + cardCharges - projectedPayments);
    if (projectedLiquidity !== undefined) projectedLiquidity += expectedIncome - cashSpend - projectedPayments;
    const projectedPatrimony = projectedLiquidity !== undefined && projectedDebt !== undefined
      ? projectedLiquidity - projectedDebt
      : undefined;
    const date = addMonths(baseDate, monthOffset);
    return {
      key: `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`,
      label: projectionLabel(date),
      monthOffset,
      expectedIncome,
      fixedSpend,
      projectedSpend,
      projectedPayments,
      projectedMsi: monthlyMsi,
      projectedSavings: expectedIncome - projectedSpend,
      projectedDebt,
      projectedLiquidity,
      projectedPatrimony,
      isEstimate: true,
    };
  });
  return {
    months,
    next90Days: months.slice(0, 3),
    horizon3: months[2],
    horizon6: months[5],
    horizon12: months[11],
    assumption: "Estimación basada en el promedio de los últimos 3 periodos disponibles; no anticipa cambios futuros.",
  };
}

function buildExecutiveAlerts(
  analyticsPeriods: AnalyticsPeriod[],
  categoryDistribution: CategorySpend[],
  latestMsiMonthlyLoad: number | undefined,
  previousMsiMonthlyLoad: number | undefined,
  projection: ProjectionSummary,
  currentMonthNetFlow: number,
): ExecutiveAlert[] {
  const current = analyticsPeriods[0];
  const previous = analyticsPeriods[1];
  const alerts: ExecutiveAlert[] = [];
  const priorSpend = analyticsPeriods.slice(1, 4).map((period) => period.spend).filter((value) => value > 0);
  const averagePriorSpend = average(priorSpend);
  if (current && averagePriorSpend > 0 && current.spend > averagePriorSpend * 1.25) {
    alerts.push({ id: "spend-above-average", severity: "medium", title: "Gasto por encima de tu ritmo", body: `Este periodo superó en ${Math.round((current.spend / averagePriorSpend - 1) * 100)}% el promedio reciente.`, action: "Revisa las categorías que más crecieron." });
  }
  if (current?.debtTotal !== undefined && previous?.debtTotal !== undefined && current.debtTotal > previous.debtTotal * 1.1) {
    alerts.push({ id: "debt-growth", severity: "high", title: "La deuda está creciendo", body: `Subió ${Math.round((current.debtTotal / Math.max(previous.debtTotal, 1) - 1) * 100)}% frente al periodo anterior.`, action: "Prioriza un pago mayor al mínimo." });
  }
  if (current?.cashAvailable !== undefined && previous?.cashAvailable !== undefined && current.cashAvailable < previous.cashAvailable * 0.85) {
    alerts.push({ id: "liquidity-drop", severity: "high", title: "Cayó tu liquidez", body: `El efectivo disponible bajó ${Math.round((1 - current.cashAvailable / Math.max(previous.cashAvailable, 1)) * 100)}% frente al periodo anterior.`, action: "Protege efectivo antes de asumir nuevos gastos." });
  }
  const topCategory = categoryDistribution[0];
  if (topCategory && topCategory.share >= 0.4) {
    alerts.push({ id: "category-concentration", severity: "medium", title: "Gasto concentrado en una categoría", body: `${topCategory.name} representa ${Math.round(topCategory.share * 100)}% del gasto del periodo.`, action: "Valida si ese nivel es intencional o temporal." });
  }
  if (latestMsiMonthlyLoad !== undefined && previousMsiMonthlyLoad !== undefined && previousMsiMonthlyLoad > 0 && latestMsiMonthlyLoad > previousMsiMonthlyLoad * 1.15) {
    alerts.push({ id: "msi-growth", severity: "medium", title: "Aumentó la carga MSI", body: `La mensualidad estimada creció ${Math.round((latestMsiMonthlyLoad / previousMsiMonthlyLoad - 1) * 100)}% frente al periodo anterior.`, action: "Evita sumar nuevas compras a meses." });
  }
  if (currentMonthNetFlow < 0) {
    alerts.push({ id: "negative-flow", severity: "high", title: "Flujo neto negativo", body: "Este periodo salió más efectivo del que entró.", action: "Reduce gasto variable o ajusta el pago de deuda." });
  }
  if (projection.horizon3.projectedLiquidity !== undefined && projection.horizon3.projectedLiquidity < (current?.cashAvailable ?? 0) * 0.8) {
    alerts.push({ id: "projected-liquidity", severity: "medium", title: "La liquidez podría estrecharse", body: "El escenario base proyecta menos efectivo disponible en 90 días.", action: "Reserva liquidez y compara un pago de deuda más conservador." });
  }
  const severityRank = { high: 0, medium: 1, info: 2 };
  return alerts.sort((left, right) => severityRank[left.severity] - severityRank[right.severity]);
}

function periodKey(period: string) {
  const detected = periodKeyFromLabel(period);
  return detected ?? (normalize(period).replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "sin-periodo");
}

function statementPeriodKeys(period: string) {
  const normalized = normalize(period);
  const matches = Array.from(normalized.matchAll(/(?:\b(20\d{2})[-/.](\d{1,2})[-/.]\d{1,2}\b|\b\d{1,2}[-/.](\d{1,2})[-/.](20\d{2})\b)/g));
  const keys = matches.map((match) => match[1]
    ? `${match[1]}-${String(Number(match[2])).padStart(2, "0")}`
    : `${match[4]}-${String(Number(match[3])).padStart(2, "0")}`)
    .filter((key) => !key.endsWith("-00"));
  const key = periodKeyFromLabel(period);
  return keys.length ? Array.from(new Set(keys)) : key ? [key] : [periodKey(period)];
}

function linkedTransactions(statement: Statement, transactions: Transaction[]) {
  return transactions.filter((transaction) => transaction.statementId === statement.id);
}

function summaryValue(summary: StatementSummary | undefined, key: keyof StatementSummary, fallback: number) {
  const value = summary?.[key];
  return hasNumber(value as number | undefined) ? absolute(value as number) : fallback;
}

export function calculatePeriod(statement: Statement, transactions: Transaction[]): PeriodMetrics {
  const kind = statement.kind ?? defaultStatementKind(statement.source);
  const summary = statement.summary;
  const linked = linkedTransactions(statement, transactions);
  const spend = linked.filter(isSpendTransaction);
  const regularTransactions = spend.filter((transaction) => inferTransactionKind(transaction) === "purchase");
  const msiTransactions = spend.filter((transaction) => inferTransactionKind(transaction) === "msi");
  const interestTransactions = spend.filter((transaction) => inferTransactionKind(transaction) === "interest");
  const feeTransactions = spend.filter((transaction) => inferTransactionKind(transaction) === "fee");
  const paymentTransactions = linked.filter((transaction) => inferTransactionKind(transaction) === "cardPayment");
  const creditTransactions = linked.filter((transaction) => inferTransactionKind(transaction) === "credit");
  const refundTransactions = linked.filter((transaction) => inferTransactionKind(transaction) === "refund");
  const parsedCharges = sum(spend.map((transaction) => absolute(transaction.amount)));
  const hasParsedCharges = spend.length > 0;
  const newTransactions = hasParsedCharges
    ? sum(regularTransactions.map((transaction) => absolute(transaction.amount)))
    : summaryValue(summary, "newTransactions", 0);
  const msiFallback = hasNumber(summary?.msiOriginalDeferred) && hasNumber(summary?.msiInstallments) && summary.msiInstallments > 0
    ? absolute(summary.msiOriginalDeferred) / summary.msiInstallments
    : sum(msiTransactions.map((transaction) => absolute(transaction.amount)));
  const msiInstallments = hasParsedCharges
    ? sum(msiTransactions.map((transaction) => absolute(transaction.amount)))
    : summaryValue(summary, "msiMonthlyLoad", msiFallback);
  const interest = hasParsedCharges
    ? sum(interestTransactions.map((transaction) => absolute(transaction.amount)))
    : summaryValue(summary, "interest", 0);
  const fees = hasParsedCharges
    ? sum(feeTransactions.map((transaction) => absolute(transaction.amount)))
    : summaryValue(summary, "fees", 0);
  const newCharges = hasParsedCharges
    ? parsedCharges
    : summaryValue(summary, "newCharges", newTransactions + msiInstallments + interest + fees);
  const realPayments = paymentTransactions.length
    ? sum(paymentTransactions.map((transaction) => absolute(transaction.amount)))
    : summaryValue(summary, "payments", 0);
  const credits = creditTransactions.length
    ? sum(creditTransactions.map((transaction) => absolute(transaction.amount)))
    : summaryValue(summary, "credits", 0);
  const refunds = sum(refundTransactions.map((transaction) => absolute(transaction.amount)));
  const travelSpend = sum(spend.filter(isTravelTransaction).map((transaction) => absolute(transaction.amount)));
  const ordinarySpend = Math.max(0, newCharges - travelSpend - refunds);
  const previousBalance = hasNumber(summary?.previousBalance) ? absolute(summary.previousBalance) : undefined;
  const paymentForNoInterest = hasNumber(summary?.paymentForNoInterest)
    ? absolute(summary.paymentForNoInterest)
    : hasNumber(previousBalance)
      ? Math.max(0, previousBalance - realPayments - credits - refunds + newCharges)
      : hasNumber(summary?.statementBalance) ? absolute(summary.statementBalance) : undefined;
  const creditLimit = hasNumber(summary?.creditLimit) ? absolute(summary.creditLimit) : undefined;
  const creditAvailable = hasNumber(summary?.creditAvailable) ? absolute(summary.creditAvailable) : undefined;
  const creditUsed = creditLimit !== undefined && creditAvailable !== undefined ? Math.max(0, creditLimit - creditAvailable) : undefined;
  const creditUtilizationRate = creditUsed !== undefined && creditLimit ? creditUsed / creditLimit : undefined;
  // For cards, the issuer's limit/disponible pair captures the committed
  // balance including future MSI. Prefer it over the statement balance,
  // which usually excludes installments that have not yet posted.
  const debtBalance = kind === "card" && creditUsed !== undefined
    ? creditUsed
    : hasNumber(summary?.debtBalance)
      ? absolute(summary.debtBalance)
      : kind === "card" && hasNumber(summary?.statementBalance) ? absolute(summary.statementBalance) : undefined;
  const msiPending = hasNumber(summary?.msiPending)
    ? absolute(summary.msiPending)
    : hasNumber(summary?.msiOriginalDeferred)
      ? absolute(summary.msiOriginalDeferred)
      : hasNumber(summary?.msiMonthlyLoad) && hasNumber(summary?.msiInstallments)
        ? absolute(summary.msiMonthlyLoad) * Math.max(0, Math.round(summary.msiInstallments))
        : undefined;
  const revolvingBalance = hasNumber(summary?.revolvingBalance)
    ? absolute(summary.revolvingBalance)
    : debtBalance !== undefined && msiPending !== undefined ? Math.max(0, debtBalance - msiPending) : debtBalance;

  return {
    key: periodKey(statement.period),
    label: statement.period,
    source: statement.source,
    statementId: statement.id,
    kind,
    newTransactions,
    msiInstallments,
    interest,
    fees,
    newCharges,
    realPayments,
    credits,
    refunds,
    difference: newCharges - realPayments - credits - refunds,
    accumulatedBalance: newCharges - realPayments - credits - refunds,
    paidPercent: newCharges ? realPayments / newCharges : null,
    pendingPercent: newCharges ? Math.max(0, newCharges - realPayments - credits - refunds) / newCharges : null,
    travelSpend,
    ordinarySpend,
    creditLimit,
    creditAvailable,
    creditUsed,
    creditUtilizationRate,
    paymentForNoInterest,
    minimumPayment: hasNumber(summary?.minimumPayment) ? absolute(summary.minimumPayment) : undefined,
    minimumPlusMsi: hasNumber(summary?.minimumPlusMsi) ? absolute(summary.minimumPlusMsi) : undefined,
    msiOriginalDeferred: hasNumber(summary?.msiOriginalDeferred) ? absolute(summary.msiOriginalDeferred) : undefined,
    msiPending,
    revolvingBalance,
    msiInstallmentsCount: hasNumber(summary?.msiInstallments) ? Math.max(0, Math.round(summary.msiInstallments)) : undefined,
    msiMonthlyLoad: hasNumber(summary?.msiMonthlyLoad) ? absolute(summary.msiMonthlyLoad) : msiInstallments || undefined,
    cashBalance: hasNumber(summary?.cashBalance) ? summary.cashBalance : undefined,
    debtBalance,
    statementEndTimestamp: statementPeriodEndTimestamp(statement.period, statement.importedAt),
    importedAt: statement.importedAt,
  };
}

function distinctPeriodCount(periods: PeriodMetrics[]) {
  return new Set(periods.map((period) => period.key)).size;
}

function lastDefined(periods: PeriodMetrics[], selector: (period: PeriodMetrics) => number | undefined) {
  return periods.map(selector).find(hasNumber);
}

function latestBySource(periods: PeriodMetrics[]) {
  const latest = new Map<string, PeriodMetrics>();
  periods.forEach((period) => {
    // Keep a bank account and a card from the same issuer independent. The
    // issuer name alone is not an account identity (e.g. Santander checking
    // plus a Santander credit card can both be present).
    const accountKey = `${period.source}|${period.kind}`;
    const current = latest.get(accountKey);
    if (!current
      || period.statementEndTimestamp > current.statementEndTimestamp
      || (period.statementEndTimestamp === current.statementEndTimestamp && period.importedAt > current.importedAt)
      || (period.statementEndTimestamp === current.statementEndTimestamp && period.importedAt === current.importedAt && period.statementId > current.statementId)) {
      latest.set(accountKey, period);
    }
  });
  return Array.from(latest.values());
}

function periodPatrimony(periods: PeriodMetrics[]) {
  const latest = latestBySource(periods);
  const cash = sumKnown(latest.filter((period) => period.kind === "bank").map((period) => period.cashBalance));
  const debt = sumKnown(latest.filter((period) => period.kind === "card").map((period) => period.debtBalance ?? period.creditUsed));
  return cash !== undefined && debt !== undefined ? cash - debt : undefined;
}

function buildConsistencyCheck(id: string, label: string, expected: number | undefined, actual: number | undefined): FinancialConsistencyCheck {
  const difference = expected !== undefined && actual !== undefined ? actual - expected : undefined;
  const tolerance = expected === undefined || actual === undefined ? 0 : Math.max(1, Math.abs(expected) * 0.01);
  return { id, label, expected, actual, difference, tolerance, passed: difference === undefined || Math.abs(difference) <= tolerance };
}

export function buildFinanceMetrics(inputTransactions: Transaction[], statements: Statement[], providedPipeline?: PipelineResult): FinanceMetrics {
  // Never aggregate raw imports directly. This is the single point where
  // invalid rows, overlapping statements, own transfers and card payments
  // are removed or linked before any KPI is calculated.
  const pipeline = providedPipeline ?? runTransactionPipeline(inputTransactions, statements);
  const blockedForReconciliation = statements
    .filter((statement) => statement.reconciliationStatus && statement.reconciliationStatus !== "valid")
    .map((statement) => statement.id);
  const blockedForReview = statements
    .filter((statement) => statement.status === "review")
    .map((statement) => statement.id);
  const blockedForOcrQuality = statements
    .filter((statement) => !hasSufficientOcrQuality(statement))
    .map((statement) => statement.id);
  const blockedStatementIds = new Set([...blockedForReconciliation, ...blockedForReview, ...blockedForOcrQuality]);
  if (blockedForReconciliation.length > 0 && !pipeline.audit.criticalIssues.some((issue) => issue.includes("conciliación de estado"))) {
    pipeline.audit.criticalIssues.push(`${blockedForReconciliation.length} estado(s) quedaron fuera de los KPI por conciliación de estado`);
  }
  if (blockedForReview.length > 0 && !pipeline.audit.criticalIssues.some((issue) => issue.includes("revisión"))) {
    pipeline.audit.criticalIssues.push(`${blockedForReview.length} estado(s) quedaron fuera de los KPI por revisión pendiente`);
  }
  if (blockedForOcrQuality.length > 0 && !pipeline.audit.criticalIssues.some((issue) => issue.includes("calidad OCR"))) {
    pipeline.audit.criticalIssues.push(`${blockedForOcrQuality.length} estado(s) quedaron fuera de los KPI por calidad OCR insuficiente`);
  }
  // A document that failed issuer-total reconciliation can remain visible in
  // the audit screen, but none of its rows or summary values may feed an
  // executive KPI. The UI migrates legacy records without a status to
  // `pending` before this point; direct callers may still opt into legacy
  // behavior explicitly by omitting the status.
  const transactions = pipeline.transactions.filter((transaction) => !transaction.statementId || !blockedStatementIds.has(transaction.statementId));
  const eligibleStatements = statements.filter((statement) => !blockedStatementIds.has(statement.id));
  const statementsWithoutRows = eligibleStatements.filter((statement) => {
    const hasRows = transactions.some((transaction) => transaction.statementId === statement.id);
    const summaryHasFinancialValue = statement.summary && [statement.summary.newCharges, statement.summary.newTransactions, statement.summary.cashBalance, statement.summary.debtBalance, statement.summary.statementBalance].some((value) => value !== undefined);
    return !hasRows && (statement.transactionCount > 0 || Boolean(summaryHasFinancialValue));
  });
  if (statementsWithoutRows.length > 0 && !pipeline.audit.criticalIssues.some((issue) => issue.includes("sin filas válidas"))) {
    pipeline.audit.criticalIssues.push(`${statementsWithoutRows.length} estado(s) tienen resumen pero no filas válidas; los KPI son provisionales`);
  }
  const periods = eligibleStatements.map((statement) => calculatePeriod(statement, transactions));
  periods.sort((left, right) => {
    const byPeriod = right.key.localeCompare(left.key);
    if (byPeriod) return byPeriod;
    const rightImported = statements.find((statement) => statement.id === right.statementId)?.importedAt ?? "";
    const leftImported = statements.find((statement) => statement.id === left.statementId)?.importedAt ?? "";
    return rightImported.localeCompare(leftImported) || right.statementId.localeCompare(left.statementId);
  });
  const cardPeriods = periods.filter((period) => period.kind === "card");
  const periodCount = distinctPeriodCount(cardPeriods);
  // Totals come from unique canonical movements, never from every PDF
  // summary. This prevents overlapping card statements from multiplying a
  // month of spending.
  const cardSpendTransactions = transactions.filter((transaction) => {
    const statement = transaction.statementId ? statements.find((item) => item.id === transaction.statementId) : undefined;
    return statement && (statement.kind ?? defaultStatementKind(statement.source)) === "card" && isSpendTransaction(transaction);
  });
  const cardPurchaseTransactions = cardSpendTransactions.filter((transaction) => inferTransactionKind(transaction) === "purchase");
  const cardPaymentTransactions = transactions.filter((transaction) => {
    const statement = transaction.statementId ? statements.find((item) => item.id === transaction.statementId) : undefined;
    return statement && (statement.kind ?? defaultStatementKind(statement.source)) === "card" && inferTransactionKind(transaction) === "cardPayment";
  });
  const cardCreditTransactions = transactions.filter((transaction) => {
    const statement = transaction.statementId ? statements.find((item) => item.id === transaction.statementId) : undefined;
    return statement && (statement.kind ?? defaultStatementKind(statement.source)) === "card" && inferTransactionKind(transaction) === "credit";
  });
  const cardRefundTransactions = transactions.filter((transaction) => {
    const statement = transaction.statementId ? statements.find((item) => item.id === transaction.statementId) : undefined;
    return statement && (statement.kind ?? defaultStatementKind(statement.source)) === "card" && inferTransactionKind(transaction) === "refund";
  });
  const latestCardPeriodsForFallback = latestBySource(cardPeriods);
  const parsedCardStatementIds = new Set(cardSpendTransactions.map((transaction) => transaction.statementId));
  const fallbackCardPeriods = latestCardPeriodsForFallback.filter((period) => !parsedCardStatementIds.has(period.statementId));
  const parsedPaymentStatementIds = new Set(cardPaymentTransactions.map((transaction) => transaction.statementId));
  const parsedCreditStatementIds = new Set(cardCreditTransactions.map((transaction) => transaction.statementId));
  const totalNewTransactions = sum(cardPurchaseTransactions.map((transaction) => absolute(transaction.amount))) + sum(fallbackCardPeriods.map((period) => period.newTransactions));
  const totalNewCharges = sum(cardSpendTransactions.map((transaction) => absolute(transaction.amount))) + sum(fallbackCardPeriods.map((period) => period.newCharges));
  const totalRealPayments = sum(cardPaymentTransactions.map((transaction) => absolute(transaction.amount))) + sum(latestCardPeriodsForFallback.filter((period) => !parsedPaymentStatementIds.has(period.statementId)).map((period) => period.realPayments));
  const totalCredits = sum(cardCreditTransactions.map((transaction) => absolute(transaction.amount))) + sum(latestCardPeriodsForFallback.filter((period) => !parsedCreditStatementIds.has(period.statementId)).map((period) => period.credits));
  const totalRefunds = sum(cardRefundTransactions.map((transaction) => absolute(transaction.amount)));
  const accumulatedBalance = totalNewCharges - totalRealPayments - totalCredits - totalRefunds;
  const latest = cardPeriods[0];
  const travelSpend = sum(cardSpendTransactions.filter(isTravelTransaction).map((transaction) => absolute(transaction.amount))) + sum(transactions.filter((transaction) => transaction.statementId === undefined && isSpendTransaction(transaction) && isTravelTransaction(transaction)).map((transaction) => absolute(transaction.amount))) + sum(transactions.filter((transaction) => {
    if (!isSpendTransaction(transaction) || transaction.statementId === undefined) return false;
    const statement = statements.find((item) => item.id === transaction.statementId);
    return statement && (statement.kind ?? defaultStatementKind(statement.source)) === "bank" && isTravelTransaction(transaction);
  }).map((transaction) => absolute(transaction.amount)));

  const rawExpense = sum(transactions.filter((transaction) => transaction.flow === "expense").map((transaction) => absolute(transaction.amount)));
  const excludedCardPayments = sum(transactions.filter((transaction) => {
    if (inferTransactionKind(transaction) !== "cardPayment") return false;
    const statement = transaction.statementId ? statements.find((item) => item.id === transaction.statementId) : undefined;
    return !statement || (statement.kind ?? defaultStatementKind(statement.source)) === "bank";
  }).map((transaction) => absolute(transaction.amount)));
  const excludedInternalTransfers = sum(transactions.filter((transaction) => inferTransactionKind(transaction) === "bankTransfer" && transaction.amount < 0).map((transaction) => absolute(transaction.amount)));
  const refunds = sum(transactions.filter((transaction) => inferTransactionKind(transaction) === "refund").map((transaction) => absolute(transaction.amount)));
  const manualSpend = sum(transactions.filter((transaction) => transaction.statementId === undefined && isSpendTransaction(transaction)).map((transaction) => absolute(transaction.amount)));
  const cardSpend = totalNewCharges;
  const directBankSpend = sum(transactions.filter((transaction) => {
    if (!isSpendTransaction(transaction)) return false;
    const statement = statements.find((item) => item.id === transaction.statementId);
    const kind = statement ? statement.kind ?? defaultStatementKind(statement.source) : "unknown";
    return kind === "bank";
  }).map((transaction) => absolute(transaction.amount)));
  const consolidatedRealSpend = Math.max(0, cardSpend + directBankSpend + manualSpend - refunds);
  const canonicalGrossSpend = sum(transactions.filter(isSpendTransaction).map((transaction) => absolute(transaction.amount)));
  const canonicalNetSpend = Math.max(0, canonicalGrossSpend - refunds);
  const spendExceedsCanonical = consolidatedRealSpend > canonicalNetSpend + Math.max(1, canonicalNetSpend * 0.01);
  const realIncome = sum(transactions.filter((transaction) => isRealIncomeTransaction(transaction, statements)).map((transaction) => absolute(transaction.amount)));
  const netFlow = realIncome - consolidatedRealSpend;
  const latestBankPeriods = latestBySource(periods.filter((period) => period.kind === "bank"));
  const latestCardPeriods = latestBySource(cardPeriods);
  const latestCardPaymentForNoInterest = sumKnown(latestCardPeriods.map((period) => period.paymentForNoInterest));
  const latestCardMinimumPayment = sumKnown(latestCardPeriods.map((period) => period.minimumPlusMsi ?? period.minimumPayment));
  const latestCardInterest = sumKnown(latestCardPeriods.map((period) => period.interest));
  const cashAvailable = sumKnown(latestBankPeriods.map((period) => period.cashBalance));
  // Coalesce per card before summing so one issuer with a statement balance
  // and another with only limit/available values are both represented.
  const debtTotal = sumKnown(latestCardPeriods.map((period) => period.debtBalance ?? period.creditUsed));
  const latestMsiPending = sumKnown(latestCardPeriods.map((period) => period.msiPending ?? period.msiOriginalDeferred));
  const latestRevolvingDebt = debtTotal !== undefined && latestMsiPending !== undefined ? Math.max(0, debtTotal - latestMsiPending) : debtTotal;
  const liquidPatrimony = cashAvailable !== undefined && debtTotal !== undefined ? cashAvailable - debtTotal : undefined;
  const creditLimit = sumKnown(latestCardPeriods.map((period) => period.creditLimit));
  const creditAvailable = sumKnown(latestCardPeriods.map((period) => period.creditAvailable));
  const creditUsed = sumKnown(latestCardPeriods.map((period) => (
    period.creditLimit !== undefined && period.creditAvailable !== undefined
      ? Math.max(0, period.creditLimit - period.creditAvailable)
      : undefined
  )));
  const creditUtilizationRate = creditUsed !== undefined && creditLimit ? creditUsed / creditLimit : undefined;
  const ordinarySpend = Math.max(0, consolidatedRealSpend - travelSpend);
  const transactionPeriodKeys = transactions
    .map((transaction) => transactionPeriodKey(transaction, statements))
    .filter((key): key is string => Boolean(key));
  const currentPeriodKey = periods[0]?.key
    ?? transactionPeriodKeys.sort((left, right) => right.localeCompare(left))[0];
  const currentStatementIds = new Set(periods.filter((period) => period.key === currentPeriodKey).map((period) => period.statementId));
  // A dated movement belongs to the month of its own date.  Statement-level
  // fallback is allowed only when a legacy row has no parseable date; this
  // prevents a statement containing an adjacent period from inflating the
  // selected month's KPI.
  const currentMonthTransactions = currentPeriodKey
    ? transactions.filter((transaction) => {
      const key = transactionPeriodKey(transaction, statements);
      return key === currentPeriodKey || (key === undefined && transaction.statementId !== undefined && currentStatementIds.has(transaction.statementId));
    })
    : transactions;
  const currentMonthSpendFromMovements = Math.max(0, sum(currentMonthTransactions.filter(isSpendTransaction).map((transaction) => absolute(transaction.amount))) - sum(currentMonthTransactions.filter((transaction) => inferTransactionKind(transaction) === "refund").map((transaction) => absolute(transaction.amount))));
  const currentMonthIncome = sum(currentMonthTransactions.filter((transaction) => isRealIncomeTransaction(transaction, statements)).map((transaction) => absolute(transaction.amount)));
  const periodGroups = new Map<string, PeriodMetrics[]>();
  periods.forEach((period) => periodGroups.set(period.key, [...(periodGroups.get(period.key) ?? []), period]));
  const periodKeys = Array.from(periodGroups.keys());
  const spendTransactions = transactions.filter(isSpendTransaction);
  const periodByStatement = new Map(periods.map((period) => [period.statementId, period.key]));

  function transactionsForPeriod(key: string) {
    return transactions.filter((transaction) => {
      const transactionKey = transactionPeriodKey(transaction, statements);
      if (transactionKey === key) return true;
      if (transaction.statementId) {
        const statement = statements.find((item) => item.id === transaction.statementId);
        return transactionKey === undefined && (periodByStatement.get(transaction.statementId) === key || (statement ? statementPeriodKeys(statement.period).includes(key) : false));
      }
      return transactionKey === undefined && key === currentPeriodKey;
    });
  }

  const analyticsBase = periodKeys.map((key) => {
    const group = periodGroups.get(key) ?? [];
    const periodTransactions = transactionsForPeriod(key);
    const linkedSpend = periodTransactions.filter(isSpendTransaction);
    const refundsForPeriod = sum(periodTransactions.filter((transaction) => inferTransactionKind(transaction) === "refund").map((transaction) => absolute(transaction.amount)));
    // Summary-only documents can overlap the same source/period. Use the
    // latest statement per source for fallback analytics, just as for debt
    // and cash, so a repeated PDF cannot multiply the period's spend.
    const statementSpendFallback = sum(latestBySource(group).map((period) => period.newCharges));
    const parsedGrossSpend = sum(linkedSpend.map((transaction) => absolute(transaction.amount)));
    // A refund can be the only parsed row while the statement summary still
    // carries the gross charges. Prefer parsed rows when they exist, but keep
    // the summary as a transparent fallback instead of turning the period to
    // zero merely because a refund was recognized.
    const spend = linkedSpend.length
      ? Math.max(0, parsedGrossSpend - refundsForPeriod)
      : Math.max(0, statementSpendFallback - refundsForPeriod);
    const income = sum(periodTransactions.filter((transaction) => isRealIncomeTransaction(transaction, statements)).map((transaction) => absolute(transaction.amount)));
    const extraordinarySpend = Math.min(spend, sum(linkedSpend.filter(isExtraordinaryTransaction).map((transaction) => absolute(transaction.amount))));
    const travelSpendForPeriod = Math.min(spend, sum(linkedSpend.filter(isTravelTransaction).map((transaction) => absolute(transaction.amount))));
    const bankPeriods = latestBySource(group.filter((period) => period.kind === "bank"));
    const cardPeriodsForKey = latestBySource(group.filter((period) => period.kind === "card"));
    const cash = sumKnown(bankPeriods.map((period) => period.cashBalance));
    const debt = sumKnown(cardPeriodsForKey.map((period) => period.debtBalance ?? period.creditUsed));
    return {
      key,
      label: group[0]?.label ?? key,
      spend,
      ordinarySpend: Math.max(0, spend - extraordinarySpend),
      extraordinarySpend,
      travelSpend: travelSpendForPeriod,
      paymentTotal: sum(periodTransactions.filter((transaction) => inferTransactionKind(transaction) === "cardPayment" && transaction.statementId && cardPeriods.some((period) => period.statementId === transaction.statementId)).map((transaction) => absolute(transaction.amount))),
      income,
      netFlow: income - spend,
      cashAvailable: cash,
      debtTotal: debt,
      liquidPatrimony: cash !== undefined && debt !== undefined ? cash - debt : undefined,
    };
  });

  const analyticsPeriods = analyticsBase.map((period, index) => {
    const previous = analyticsBase[index + 1];
    const window = analyticsBase.slice(index, index + 3).map((item) => item.spend);
    return {
      ...period,
      variationPercent: metricVariation(period.spend, previous?.spend),
      movingAverage3: window.length ? sum(window) / window.length : period.spend,
      cashVariationPercent: metricVariation(period.cashAvailable, previous?.cashAvailable),
      debtVariationPercent: metricVariation(period.debtTotal, previous?.debtTotal),
      patrimonyVariationPercent: metricVariation(period.liquidPatrimony, previous?.liquidPatrimony),
    } satisfies AnalyticsPeriod;
  });

  const currentSpendTransactions = currentPeriodKey ? transactionsForPeriod(currentPeriodKey).filter(isSpendTransaction) : spendTransactions;
  const currentSpendTotal = sum(currentSpendTransactions.map((transaction) => absolute(transaction.amount)));
  const categoryMap = new Map<string, { name: string; total: number }>();
  currentSpendTransactions.forEach((transaction) => {
    const name = transaction.category.trim() || "Sin categoría";
    const key = normalizeConcept(name) || normalize(name);
    const previous = categoryMap.get(key);
    categoryMap.set(key, { name: previous?.name ?? name, total: (previous?.total ?? 0) + absolute(transaction.amount) });
  });
  const categoryDistribution = Array.from(categoryMap.values())
    .sort((left, right) => right.total - left.total)
    .map((item) => ({ ...item, share: currentSpendTotal ? item.total / currentSpendTotal : 0 } satisfies CategorySpend));

  const merchantMap = new Map<string, { name: string; total: number; count: number }>();
  currentSpendTransactions.forEach((transaction) => {
    const name = merchantLabel(transaction.description);
    const key = normalizeConcept(name) || normalize(name);
    const previous = merchantMap.get(key);
    merchantMap.set(key, { name: previous?.name ?? name, total: (previous?.total ?? 0) + absolute(transaction.amount), count: (previous?.count ?? 0) + 1 });
  });
  const topMerchants = Array.from(merchantMap.values())
    .sort((left, right) => right.total - left.total)
    .slice(0, 5)
    .map((item) => ({ ...item, share: currentSpendTotal ? item.total / currentSpendTotal : 0 } satisfies MerchantSpend));

  const topMovements = currentSpendTransactions
    .slice()
    .sort((left, right) => absolute(right.amount) - absolute(left.amount))
    .slice(0, 5)
    .map((transaction) => ({
      id: transaction.id,
      description: merchantLabel(transaction.description),
      amount: transaction.amount,
      date: transaction.date,
      category: transaction.category,
      account: transaction.account,
      share: currentSpendTotal ? absolute(transaction.amount) / currentSpendTotal : 0,
    } satisfies MovementSpend));

  const travelTransactions = currentSpendTransactions
    .filter(isTravelTransaction)
    .slice()
    .sort((left, right) => (dateValue(left.date) ?? Number.MAX_SAFE_INTEGER) - (dateValue(right.date) ?? Number.MAX_SAFE_INTEGER));
  const travelGroups: Transaction[][] = [];
  travelTransactions.forEach((transaction) => {
    const currentGroup = travelGroups.at(-1);
    const previousDate = currentGroup?.at(-1)?.date ? dateValue(currentGroup.at(-1)!.date) : undefined;
    const currentDate = dateValue(transaction.date);
    const withinSameTrip = !currentGroup || previousDate === undefined || currentDate === undefined || currentDate - previousDate <= 8 * 24 * 60 * 60 * 1000;
    if (withinSameTrip) {
      if (currentGroup) currentGroup.push(transaction);
      else travelGroups.push([transaction]);
    } else {
      travelGroups.push([transaction]);
    }
  });
  const travelTrips = travelGroups.map((group, index) => {
    const movements = group.map((transaction) => ({
      id: transaction.id,
      description: merchantLabel(transaction.description),
      amount: transaction.amount,
      date: transaction.date,
      category: transaction.category,
      account: transaction.account,
      share: sum(group.map((item) => absolute(item.amount))) ? absolute(transaction.amount) / sum(group.map((item) => absolute(item.amount))) : 0,
    } satisfies MovementSpend));
    const dates = group.map((transaction) => transaction.date).filter((date) => date !== "Sin fecha");
    const firstMerchant = merchantLabel(group[0]?.description ?? "");
    return {
      id: `travel-${currentPeriodKey ?? "manual"}-${index}`,
      name: firstMerchant && firstMerchant !== "Sin descripción" ? `Viaje · ${firstMerchant}` : `Viaje ${index + 1}`,
      total: sum(group.map((transaction) => absolute(transaction.amount))),
      startDate: dates[0] ?? "Sin fecha",
      endDate: dates.at(-1) ?? "Sin fecha",
      movements,
    } satisfies TravelTrip;
  });

  const previousSpendTransactions = periodKeys[1] ? transactionsForPeriod(periodKeys[1]).filter(isSpendTransaction) : [];
  const previousCategoryMap = new Map<string, number>();
  previousSpendTransactions.forEach((transaction) => {
    const key = normalizeConcept(transaction.category.trim() || "Sin categoría") || normalize(transaction.category.trim() || "Sin categoría");
    previousCategoryMap.set(key, (previousCategoryMap.get(key) ?? 0) + absolute(transaction.amount));
  });
  const causeCandidates = Array.from(categoryMap.entries()).map(([key, item]) => ({
    label: item.name,
    current: item.total,
    previous: previousCategoryMap.get(key) ?? 0,
    delta: item.total - (previousCategoryMap.get(key) ?? 0),
  })).filter((item) => item.delta > 0 && normalize(item.label) !== normalize("Sin categoría"));
  const bestCategoryCause = causeCandidates.sort((left, right) => right.delta - left.delta)[0];
  const currentExtraordinary = analyticsBase[0]?.extraordinarySpend ?? 0;
  const previousExtraordinary = analyticsBase[1]?.extraordinarySpend ?? 0;
  const extraordinaryCause = currentExtraordinary > previousExtraordinary
    ? { label: "Gasto extraordinario", current: currentExtraordinary, previous: previousExtraordinary, delta: currentExtraordinary - previousExtraordinary }
    : undefined;
  const primaryCause = bestCategoryCause && extraordinaryCause && extraordinaryCause.delta > bestCategoryCause.delta ? extraordinaryCause : bestCategoryCause ?? extraordinaryCause;
  const reviewItems = transactions.filter((transaction) => transaction.category === "Sin categoría" || (transaction.confidence ?? 1) < 0.75 || transaction.validationStatus === "review");
  const dataQuality: DataQualityMetrics = {
    classifiedPercent: pipeline.audit.classifiedPercent,
    classifiedCount: Math.max(0, pipeline.audit.validCount - reviewItems.length),
    totalCount: pipeline.audit.importedCount,
    reviewCount: reviewItems.length,
    relevantReviewCount: pipeline.audit.relevantReviewCount,
    // A row-level reconciliation percentage can be 100% even when every row
    // belongs to an OCR statement that is still provisional. Cap it with the
    // statement-level eligibility rate so the visible quality indicator cannot
    // report a healthy book while an entire document is blocked.
    reconciledPercent: Math.min(
      pipeline.audit.reconciledPercent,
      statements.length ? ((statements.length - blockedStatementIds.size) / statements.length) * 100 : 100,
    ),
    evidencePercent: pipeline.audit.evidencePercent,
    missingEvidenceCount: pipeline.audit.missingEvidenceCount,
    invalidCount: pipeline.audit.invalidCount,
    duplicateCount: pipeline.audit.duplicateCount,
    critical: pipeline.audit.criticalIssues.length > 0,
  };
  if (spendExceedsCanonical) {
    const issue = "El gasto consolidado supera la suma de movimientos canónicos; KPI bloqueado";
    if (!pipeline.audit.criticalIssues.includes(issue)) pipeline.audit.criticalIssues.push(issue);
    dataQuality.critical = true;
  }
  const currentPatrimony = currentPeriodKey ? periodPatrimony(periodGroups.get(currentPeriodKey) ?? []) : undefined;
  const previousPatrimony = periodKeys[1] ? periodPatrimony(periodGroups.get(periodKeys[1]) ?? []) : undefined;
  const liquidPatrimonyChangePercent = currentPatrimony !== undefined && previousPatrimony !== undefined && previousPatrimony !== 0
    ? (currentPatrimony - previousPatrimony) / Math.abs(previousPatrimony)
    : null;
  const consistencyChecks: FinancialConsistencyCheck[] = [];
  consistencyChecks.push(buildConsistencyCheck("flow", "Ingresos − gasto real = flujo neto", realIncome - consolidatedRealSpend, netFlow));
  consistencyChecks.push(buildConsistencyCheck("patrimony", "Efectivo − deuda = patrimonio líquido", cashAvailable !== undefined && debtTotal !== undefined ? cashAvailable - debtTotal : undefined, liquidPatrimony));
  consistencyChecks.push(buildConsistencyCheck("credit", "Límite − crédito disponible = deuda utilizada", creditLimit !== undefined && creditAvailable !== undefined ? creditLimit - creditAvailable : undefined, creditUsed));
  latestBankPeriods.forEach((period) => {
    const statement = statements.find((item) => item.id === period.statementId);
    const opening = statement?.summary?.previousBalance;
    const closing = period.cashBalance;
    const linked = transactions.filter((transaction) => transaction.statementId === period.statementId);
    const cashDelta = linked.reduce((total, transaction) => total + transaction.amount, 0);
    consistencyChecks.push(buildConsistencyCheck(`cash-${period.statementId}`, `Saldo inicial + movimientos = saldo final (${period.source})`, hasNumber(opening) && closing !== undefined ? opening + cashDelta : undefined, closing));
  });

  const currentMonthSpend = currentPeriodKey
    ? (currentMonthTransactions.some(isSpendTransaction)
      || currentMonthTransactions.some((transaction) => inferTransactionKind(transaction) === "refund")
      ? currentMonthSpendFromMovements
      : analyticsPeriods.find((period) => period.key === currentPeriodKey)?.spend ?? currentMonthSpendFromMovements)
    : currentMonthSpendFromMovements;
  const failedConsistencyChecks = consistencyChecks.filter((check) => !check.passed);
  if (failedConsistencyChecks.length) {
    dataQuality.critical = true;
    failedConsistencyChecks.forEach((check) => {
      const issue = `Inconsistencia: ${check.label}`;
      if (!pipeline.audit.criticalIssues.includes(issue)) pipeline.audit.criticalIssues.push(issue);
    });
  }
  const isProvisional = dataQuality.critical || failedConsistencyChecks.length > 0;
  const projection = buildProjection(
    analyticsPeriods,
    cardPeriods,
    currentPeriodKey,
    cashAvailable,
    debtTotal,
    currentMonthSpend,
    realIncome,
    periodCount,
    cardSpend,
    consolidatedRealSpend,
    directBankSpend,
    manualSpend,
    lastDefined(cardPeriods, (period) => period.msiMonthlyLoad),
    latestCardPaymentForNoInterest,
  );
  const executiveAlerts = buildExecutiveAlerts(
    analyticsPeriods,
    categoryDistribution,
    lastDefined(cardPeriods, (period) => period.msiMonthlyLoad),
    cardPeriods[1]?.msiMonthlyLoad,
    projection,
    currentMonthIncome - currentMonthSpend,
  );

  const cashFlowByDay = new Map<string, { timestamp: number; income: number; expense: number }>();
  transactions.forEach((transaction) => {
    const timestamp = dateValue(transaction.date);
    if (timestamp === undefined) return;
    const date = new Date(timestamp);
    const key = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
    const isIncome = isRealIncomeTransaction(transaction, statements);
    const isExpense = isSpendTransaction(transaction);
    if (!isIncome && !isExpense) return;
    const current = cashFlowByDay.get(key) ?? { timestamp, income: 0, expense: 0 };
    if (isIncome) current.income += absolute(transaction.amount);
    else if (isExpense) current.expense += absolute(transaction.amount);
    cashFlowByDay.set(key, current);
  });
  let runningBalance = 0;
  const cashFlowHistory = Array.from(cashFlowByDay.entries())
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, point]) => {
      runningBalance += point.income - point.expense;
      return {
        key,
        date: new Intl.DateTimeFormat("es-MX", { day: "2-digit", month: "short", year: "numeric" }).format(new Date(point.timestamp)).replace(".", ""),
        income: point.income,
        expense: point.expense,
        balance: runningBalance,
      } satisfies CashFlowPoint;
    });

  return {
    periods,
    cardPeriods,
    periodCount,
    totalNewTransactions,
    averageMonthlySpend: periodCount ? totalNewTransactions / periodCount : 0,
    totalNewCharges,
    totalRealPayments,
    totalCredits,
    totalRefunds,
    accumulatedBalance,
    latestDifference: latest?.difference ?? 0,
    paidPercent: totalNewCharges ? totalRealPayments / totalNewCharges : null,
    pendingPercent: totalNewCharges ? Math.max(0, accumulatedBalance) / totalNewCharges : null,
    travelSpend,
    travelPercent: consolidatedRealSpend ? travelSpend / consolidatedRealSpend : null,
    ordinarySpend,
    ordinaryAverageMonthly: periodCount ? ordinarySpend / periodCount : 0,
    latestMsiMonthlyLoad: lastDefined(cardPeriods, (period) => period.msiMonthlyLoad),
    latestMsiOriginalDeferred: lastDefined(cardPeriods, (period) => period.msiOriginalDeferred),
    latestMsiPending,
    latestRevolvingDebt,
    latestMsiInstallmentsCount: lastDefined(cardPeriods, (period) => period.msiInstallmentsCount),
    latestPaymentForNoInterest: latestCardPaymentForNoInterest,
    latestMinimumPayment: latestCardMinimumPayment,
    latestPaymentDue: latestCardMinimumPayment,
    latestInterest: latestCardInterest,
    cardSpend,
    directBankSpend,
    rawExpense,
    excludedCardPayments,
    excludedInternalTransfers,
    consolidatedRealSpend,
    realIncome,
    netFlow,
    savingsRate: realIncome ? netFlow / realIncome : null,
    cashAvailable,
    debtTotal,
    liquidPatrimony,
    liquidPatrimonyChangePercent,
    currentMonthSpend,
    currentMonthNetFlow: currentMonthIncome - currentMonthSpend,
    analyticsPeriods,
    cashFlowHistory,
    categoryDistribution,
    topMerchants,
    topMovements,
    travelTrips,
    dataQuality,
    audit: pipeline.audit,
    consistencyChecks,
    isProvisional,
    primaryCause,
    projection,
    executiveAlerts,
    creditLimit,
    creditAvailable,
    creditUsed,
    creditUtilizationRate,
  };
}
