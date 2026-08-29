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
  msiOriginalDeferred?: number;
  msiInstallmentsCount?: number;
  msiMonthlyLoad?: number;
  cashBalance?: number;
  debtBalance?: number;
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

export function isSpendTransaction(transaction: Transaction) {
  const kind = inferTransactionKind(transaction);
  return transaction.flow === "expense" && !["cardPayment", "bankTransfer", "refund"].includes(kind);
}

function isTravelTransaction(transaction: Transaction) {
  if (transaction.travelRelated) return true;
  const text = normalize(`${transaction.description} ${transaction.category}`);
  return /viaje|hotel|hospedaje|aerolinea|vuelo|avion|transporte|uber|taxi|metro|renta de auto|destino|equipaje/.test(text);
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
    difference: newTransactions - realPayments,
    accumulatedBalance: newTransactions - realPayments,
    paidPercent: newTransactions ? realPayments / newTransactions : null,
    pendingPercent: newTransactions ? Math.max(0, newTransactions - realPayments) / newTransactions : null,
    travelSpend,
    ordinarySpend,
    creditLimit,
    creditAvailable,
    creditUsed,
    creditUtilizationRate,
    paymentForNoInterest,
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
  const accumulatedBalance = totalNewTransactions - totalRealPayments;
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
  const realIncome = sum(transactions.filter((transaction) => transaction.flow === "income" && !["credit", "refund"].includes(inferTransactionKind(transaction))).map((transaction) => absolute(transaction.amount)));
  const netFlow = realIncome - consolidatedRealSpend;
  const latestBankPeriods = latestBySource(periods.filter((period) => period.kind === "bank"));
  const latestCardPeriods = latestBySource(cardPeriods);
  const cashAvailable = sumKnown(latestBankPeriods.map((period) => period.cashBalance));
  const debtTotal = sumKnown(latestCardPeriods.map((period) => period.debtBalance));
  const liquidPatrimony = cashAvailable !== undefined && debtTotal !== undefined ? cashAvailable - debtTotal : undefined;
  const creditLimit = sumKnown(latestCardPeriods.map((period) => period.creditLimit));
  const creditAvailable = sumKnown(latestCardPeriods.map((period) => period.creditAvailable));
  const creditUsed = creditLimit !== undefined && creditAvailable !== undefined ? Math.max(0, creditLimit - creditAvailable) : undefined;
  const creditUtilizationRate = creditUsed !== undefined && creditLimit ? creditUsed / creditLimit : undefined;
  const ordinarySpend = Math.max(0, consolidatedRealSpend - travelSpend);

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
    paidPercent: totalNewTransactions ? totalRealPayments / totalNewTransactions : null,
    pendingPercent: totalNewTransactions ? Math.max(0, accumulatedBalance) / totalNewTransactions : null,
    travelSpend,
    travelPercent: consolidatedRealSpend ? travelSpend / consolidatedRealSpend : null,
    ordinarySpend,
    ordinaryAverageMonthly: periodCount ? ordinarySpend / periodCount : 0,
    latestMsiMonthlyLoad: lastDefined(cardPeriods, (period) => period.msiMonthlyLoad),
    latestMsiOriginalDeferred: lastDefined(cardPeriods, (period) => period.msiOriginalDeferred),
    latestMsiInstallmentsCount: lastDefined(cardPeriods, (period) => period.msiInstallmentsCount),
    latestPaymentForNoInterest: lastDefined(cardPeriods, (period) => period.paymentForNoInterest),
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
    creditLimit,
    creditAvailable,
    creditUsed,
    creditUtilizationRate,
  };
}
