import type {
  Statement,
  StatementKind,
  StatementSource,
  StatementSummary,
  Transaction,
  TransactionKind,
} from "./types";

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
  msiOriginalDeferred?: number;
  msiInstallmentsCount?: number;
  msiMonthlyLoad?: number;
  cashBalance?: number;
  debtBalance?: number;
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
  latestMsiInstallmentsCount?: number;
  latestPaymentForNoInterest?: number;
  latestMinimumPayment?: number;
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
  primaryCause?: PrimaryCause;
  projection: ProjectionSummary;
  executiveAlerts: ExecutiveAlert[];
  creditLimit?: number;
  creditAvailable?: number;
  creditUsed?: number;
  creditUtilizationRate?: number;
};

const monthNames = [
  "ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic",
];

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

function dateValue(value: string) {
  const normalized = normalize(value);
  const iso = normalized.match(/^(20\d{2})[-/.](\d{1,2})[-/.](\d{1,2})$/);
  if (iso) return new Date(Number(iso[1]), Number(iso[2]) - 1, Number(iso[3])).getTime();
  const numeric = normalized.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](20\d{2})$/);
  if (numeric) return new Date(Number(numeric[3]), Number(numeric[2]) - 1, Number(numeric[1])).getTime();
  const match = normalized.match(/(\d{1,2})\s+(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre|ene|feb|mar|abr|may|jun|jul|ago|sep|set|oct|nov|dic)\s+(\d{2,4})/);
  if (!match) return undefined;
  const fullMonthNames = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"];
  const month = match[2].startsWith("set") || match[2].startsWith("sep")
    ? 8
    : fullMonthNames.findIndex((name) => name.startsWith(match[2]) || match[2].startsWith(name.slice(0, 3)));
  if (month < 0) return undefined;
  const year = Number(match[3]);
  return new Date(year < 100 ? 2000 + year : year, month, Number(match[1])).getTime();
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
  const normalized = normalize(period);
  const matches = Array.from(normalized.matchAll(/(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre|ene|feb|mar|abr|may|jun|jul|ago|sep|set|oct|nov|dic)[^0-9]{0,8}(20\d{2})/g));
  const last = matches.at(-1);
  if (last) {
    const month = monthNames.findIndex((name) => last[1].startsWith(name));
    return `${last[2]}-${String(month + 1).padStart(2, "0")}`;
  }
  return normalized.replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "sin-periodo";
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
  const newTransactions = summaryValue(summary, "newTransactions", sum(regularTransactions.map((transaction) => absolute(transaction.amount))));
  const msiFallback = hasNumber(summary?.msiOriginalDeferred) && hasNumber(summary?.msiInstallments) && summary.msiInstallments > 0
    ? absolute(summary.msiOriginalDeferred) / summary.msiInstallments
    : sum(msiTransactions.map((transaction) => absolute(transaction.amount)));
  const msiInstallments = summaryValue(summary, "msiMonthlyLoad", msiFallback);
  const interest = summaryValue(summary, "interest", sum(interestTransactions.map((transaction) => absolute(transaction.amount))));
  const fees = summaryValue(summary, "fees", sum(feeTransactions.map((transaction) => absolute(transaction.amount))));
  const newCharges = summaryValue(summary, "newCharges", newTransactions + msiInstallments + interest + fees);
  const realPayments = summaryValue(summary, "payments", sum(paymentTransactions.map((transaction) => absolute(transaction.amount))));
  const credits = summaryValue(summary, "credits", sum(creditTransactions.map((transaction) => absolute(transaction.amount))));
  const refunds = sum(refundTransactions.map((transaction) => absolute(transaction.amount)));
  const travelSpend = sum(spend.filter(isTravelTransaction).map((transaction) => absolute(transaction.amount)));
  const ordinarySpend = Math.max(0, newCharges - travelSpend);
  const previousBalance = hasNumber(summary?.previousBalance) ? absolute(summary.previousBalance) : undefined;
  const paymentForNoInterest = hasNumber(summary?.paymentForNoInterest)
    ? absolute(summary.paymentForNoInterest)
    : hasNumber(previousBalance)
      ? Math.max(0, previousBalance - realPayments - credits + newCharges)
      : hasNumber(summary?.statementBalance) ? absolute(summary.statementBalance) : undefined;
  const creditLimit = hasNumber(summary?.creditLimit) ? absolute(summary.creditLimit) : undefined;
  const creditAvailable = hasNumber(summary?.creditAvailable) ? absolute(summary.creditAvailable) : undefined;
  const creditUsed = creditLimit !== undefined && creditAvailable !== undefined ? Math.max(0, creditLimit - creditAvailable) : undefined;
  const creditUtilizationRate = creditUsed !== undefined && creditLimit ? creditUsed / creditLimit : undefined;
  const debtBalance = hasNumber(summary?.debtBalance)
    ? absolute(summary.debtBalance)
    : kind === "card" && hasNumber(summary?.statementBalance) ? absolute(summary.statementBalance) : undefined;

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
    difference: newCharges - realPayments,
    accumulatedBalance: newCharges - realPayments - credits,
    paidPercent: newCharges ? realPayments / newCharges : null,
    pendingPercent: newCharges ? Math.max(0, newCharges - realPayments - credits) / newCharges : null,
    travelSpend,
    ordinarySpend,
    creditLimit,
    creditAvailable,
    creditUsed,
    creditUtilizationRate,
    paymentForNoInterest,
    minimumPayment: hasNumber(summary?.minimumPayment) ? absolute(summary.minimumPayment) : undefined,
    msiOriginalDeferred: hasNumber(summary?.msiOriginalDeferred) ? absolute(summary.msiOriginalDeferred) : undefined,
    msiInstallmentsCount: hasNumber(summary?.msiInstallments) ? Math.max(0, Math.round(summary.msiInstallments)) : undefined,
    msiMonthlyLoad: hasNumber(summary?.msiMonthlyLoad) ? absolute(summary.msiMonthlyLoad) : msiInstallments || undefined,
    cashBalance: hasNumber(summary?.cashBalance) ? summary.cashBalance : undefined,
    debtBalance,
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
    if (!latest.has(period.source)) latest.set(period.source, period);
  });
  return Array.from(latest.values());
}

function periodPatrimony(periods: PeriodMetrics[]) {
  const latest = latestBySource(periods);
  const cash = sumKnown(latest.filter((period) => period.kind === "bank").map((period) => period.cashBalance));
  const debt = sumKnown(latest.filter((period) => period.kind === "card").map((period) => period.debtBalance));
  return cash !== undefined && debt !== undefined ? cash - debt : undefined;
}

export function buildFinanceMetrics(transactions: Transaction[], statements: Statement[]): FinanceMetrics {
 const periods = statements.map((statement) => calculatePeriod(statement, transactions));
  periods.sort((left, right) => right.key.localeCompare(left.key) || right.statementId.localeCompare(left.statementId));
 const cardPeriods = periods.filter((period) => period.kind === "card");
  const periodCount = distinctPeriodCount(cardPeriods);
  const totalNewTransactions = sum(cardPeriods.map((period) => period.newTransactions));
  const totalNewCharges = sum(cardPeriods.map((period) => period.newCharges));
  const totalRealPayments = sum(cardPeriods.map((period) => period.realPayments));
  const totalCredits = sum(cardPeriods.map((period) => period.credits));
  const totalRefunds = sum(cardPeriods.map((period) => period.refunds));
  const accumulatedBalance = totalNewCharges - totalRealPayments - totalCredits;
  const latest = cardPeriods[0];
  const travelSpend = sum(periods.map((period) => period.travelSpend)) + sum(transactions.filter((transaction) => transaction.statementId === undefined && isSpendTransaction(transaction) && isTravelTransaction(transaction)).map((transaction) => absolute(transaction.amount)));

  const rawExpense = sum(transactions.filter((transaction) => transaction.flow === "expense").map((transaction) => absolute(transaction.amount)));
  const excludedCardPayments = sum(transactions.filter((transaction) => inferTransactionKind(transaction) === "cardPayment").map((transaction) => absolute(transaction.amount)));
  const excludedInternalTransfers = sum(transactions.filter((transaction) => inferTransactionKind(transaction) === "bankTransfer").map((transaction) => absolute(transaction.amount)));
  const refunds = sum(transactions.filter((transaction) => inferTransactionKind(transaction) === "refund").map((transaction) => absolute(transaction.amount)));
  const manualSpend = sum(transactions.filter((transaction) => transaction.statementId === undefined && isSpendTransaction(transaction)).map((transaction) => absolute(transaction.amount)));
  const cardSpend = sum(cardPeriods.map((period) => period.newCharges));
  const directBankSpend = sum(transactions.filter((transaction) => {
    if (!isSpendTransaction(transaction)) return false;
    const statement = statements.find((item) => item.id === transaction.statementId);
    const kind = statement ? statement.kind ?? defaultStatementKind(statement.source) : "unknown";
    return kind === "bank";
  }).map((transaction) => absolute(transaction.amount)));
  const consolidatedRealSpend = Math.max(0, cardSpend + directBankSpend + manualSpend - refunds);
  const realIncome = sum(transactions.filter((transaction) => isRealIncomeTransaction(transaction, statements)).map((transaction) => absolute(transaction.amount)));
  const netFlow = realIncome - consolidatedRealSpend;
  const latestBankPeriods = latestBySource(periods.filter((period) => period.kind === "bank"));
  const latestCardPeriods = latestBySource(cardPeriods);
  const latestCardPaymentForNoInterest = sumKnown(latestCardPeriods.map((period) => period.paymentForNoInterest));
  const latestCardMinimumPayment = sumKnown(latestCardPeriods.map((period) => period.minimumPayment));
  const latestCardInterest = sumKnown(latestCardPeriods.map((period) => period.interest));
  const cashAvailable = sumKnown(latestBankPeriods.map((period) => period.cashBalance));
  const debtTotal = sumKnown(latestCardPeriods.map((period) => period.debtBalance));
  const liquidPatrimony = cashAvailable !== undefined && debtTotal !== undefined ? cashAvailable - debtTotal : undefined;
  const creditLimit = sumKnown(latestCardPeriods.map((period) => period.creditLimit));
  const creditAvailable = sumKnown(latestCardPeriods.map((period) => period.creditAvailable));
  const creditUsed = creditLimit !== undefined && creditAvailable !== undefined ? Math.max(0, creditLimit - creditAvailable) : undefined;
  const creditUtilizationRate = creditUsed !== undefined && creditLimit ? creditUsed / creditLimit : undefined;
  const ordinarySpend = Math.max(0, consolidatedRealSpend - travelSpend);
  const currentPeriodKey = periods[0]?.key;
  const currentPeriods = currentPeriodKey ? periods.filter((period) => period.key === currentPeriodKey) : [];
  const currentStatementIds = new Set(currentPeriods.map((period) => period.statementId));
  const manualRefunds = sum(transactions.filter((transaction) => transaction.statementId === undefined && inferTransactionKind(transaction) === "refund").map((transaction) => absolute(transaction.amount)));
  const currentMonthSpend = currentPeriods.length
    ? Math.max(0, sum(currentPeriods.map((period) => period.newCharges)) + manualSpend - sum(currentPeriods.map((period) => period.refunds)) - manualRefunds)
    : manualSpend;
  const currentMonthTransactions = currentPeriods.length
    ? transactions.filter((transaction) => transaction.statementId === undefined || currentStatementIds.has(transaction.statementId))
    : transactions;
  const currentMonthIncome = sum(currentMonthTransactions.filter((transaction) => isRealIncomeTransaction(transaction, statements)).map((transaction) => absolute(transaction.amount)));
  const periodGroups = new Map<string, PeriodMetrics[]>();
  periods.forEach((period) => periodGroups.set(period.key, [...(periodGroups.get(period.key) ?? []), period]));
  const periodKeys = Array.from(periodGroups.keys());
  const spendTransactions = transactions.filter(isSpendTransaction);
  const periodByStatement = new Map(periods.map((period) => [period.statementId, period.key]));

  function transactionsForPeriod(key: string) {
    return transactions.filter((transaction) => transaction.statementId
      ? periodByStatement.get(transaction.statementId) === key
      : key === currentPeriodKey);
  }

  const analyticsBase = periodKeys.map((key) => {
    const group = periodGroups.get(key) ?? [];
    const periodTransactions = transactionsForPeriod(key);
    const linkedSpend = periodTransactions.filter(isSpendTransaction);
    const manualForPeriod = key === currentPeriodKey ? manualSpend : 0;
    const refundsForPeriod = sum(group.map((period) => period.refunds)) + (key === currentPeriodKey ? manualRefunds : 0);
    const spend = Math.max(0, sum(group.map((period) => period.newCharges)) + manualForPeriod - refundsForPeriod);
    const income = sum(periodTransactions.filter((transaction) => isRealIncomeTransaction(transaction, statements)).map((transaction) => absolute(transaction.amount)));
    const extraordinarySpend = Math.min(spend, sum(linkedSpend.filter(isExtraordinaryTransaction).map((transaction) => absolute(transaction.amount))));
    const travelSpendForPeriod = Math.min(spend, sum(linkedSpend.filter(isTravelTransaction).map((transaction) => absolute(transaction.amount))));
    const bankPeriods = latestBySource(group.filter((period) => period.kind === "bank"));
    const cardPeriodsForKey = latestBySource(group.filter((period) => period.kind === "card"));
    const cash = sumKnown(bankPeriods.map((period) => period.cashBalance));
    const debt = sumKnown(cardPeriodsForKey.map((period) => period.debtBalance));
    return {
      key,
      label: group[0]?.label ?? key,
      spend,
      ordinarySpend: Math.max(0, spend - extraordinarySpend),
      extraordinarySpend,
      travelSpend: travelSpendForPeriod,
      paymentTotal: sum(group.map((period) => period.realPayments)),
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
    const key = normalize(name);
    const previous = categoryMap.get(key);
    categoryMap.set(key, { name: previous?.name ?? name, total: (previous?.total ?? 0) + absolute(transaction.amount) });
  });
  const categoryDistribution = Array.from(categoryMap.values())
    .sort((left, right) => right.total - left.total)
    .map((item) => ({ ...item, share: currentSpendTotal ? item.total / currentSpendTotal : 0 } satisfies CategorySpend));

  const merchantMap = new Map<string, { name: string; total: number; count: number }>();
  currentSpendTransactions.forEach((transaction) => {
    const name = merchantLabel(transaction.description);
    const key = normalize(name);
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
    const key = normalize(transaction.category.trim() || "Sin categoría");
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
  const reviewItems = transactions.filter((transaction) => transaction.category === "Sin categoría" || (transaction.confidence ?? 1) < 0.75);
  const reviewThreshold = Math.max(1000, (analyticsPeriods[0]?.spend ?? currentMonthSpend) * 0.05);
  const dataQuality: DataQualityMetrics = {
    classifiedPercent: transactions.length ? ((transactions.length - reviewItems.length) / transactions.length) * 100 : 100,
    classifiedCount: transactions.length - reviewItems.length,
    totalCount: transactions.length,
    reviewCount: reviewItems.length,
    relevantReviewCount: reviewItems.filter((transaction) => absolute(transaction.amount) >= reviewThreshold).length,
  };
  const currentPatrimony = currentPeriodKey ? periodPatrimony(periodGroups.get(currentPeriodKey) ?? []) : undefined;
  const previousPatrimony = periodKeys[1] ? periodPatrimony(periodGroups.get(periodKeys[1]) ?? []) : undefined;
  const liquidPatrimonyChangePercent = currentPatrimony !== undefined && previousPatrimony !== undefined && previousPatrimony !== 0
    ? (currentPatrimony - previousPatrimony) / Math.abs(previousPatrimony)
    : null;
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
    latestMsiInstallmentsCount: lastDefined(cardPeriods, (period) => period.msiInstallmentsCount),
    latestPaymentForNoInterest: latestCardPaymentForNoInterest,
    latestMinimumPayment: latestCardMinimumPayment,
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
    primaryCause,
    projection,
    executiveAlerts,
    creditLimit,
    creditAvailable,
    creditUsed,
    creditUtilizationRate,
  };
}
