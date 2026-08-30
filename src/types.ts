export type Section = "Resumen" | "Gastos" | "Cuentas" | "Patrimonio";

export type FinancialGoalKind = "patrimony" | "debt" | "maxSpend" | "savings";

export type FinancialGoal = {
  id: string;
  kind: FinancialGoalKind;
  target: number;
};

export type FlowType = "income" | "transfer" | "expense" | "debt";

export type TransactionKind =
  | "purchase"
  | "cardPayment"
  | "bankTransfer"
  | "income"
  | "credit"
  | "refund"
  | "msi"
  | "interest"
  | "fee"
  | "other";

// Known brands keep stable labels, while the open string branch lets a file
// from any other bank retain the name detected from its document or filename.
export type StatementSource = "Amex" | "Santander" | "BBVA" | "Desconocido" | (string & {});

export type StatementStatus = "ready" | "review";

export type Transaction = {
  id: string;
  date: string;
  description: string;
  account: string;
  category: string;
  amount: number;
  flow: FlowType;
  kind?: TransactionKind;
  travelRelated?: boolean;
  confidence?: number;
  statementId?: string;
};

export type StatementKind = "card" | "bank" | "unknown";

/** Totals copied from the statement summary and corrected by the user when needed. */
export type StatementSummary = {
  previousBalance?: number;
  statementBalance?: number;
  debtBalance?: number;
  newTransactions?: number;
  payments?: number;
  credits?: number;
  paymentsCredits?: number;
  newCharges?: number;
  interest?: number;
  fees?: number;
  creditLimit?: number;
  creditAvailable?: number;
  minimumPayment?: number;
  paymentForNoInterest?: number;
  paymentDueDate?: string;
  cashBalance?: number;
  msiOriginalDeferred?: number;
  msiInstallments?: number;
  msiMonthlyLoad?: number;
};

export type ImportResult = {
  source: StatementSource;
  kind: StatementKind;
  period: string;
  fileName: string;
  /** The parser either used the PDF text layer or rendered pages through OCR. */
  mode: "text" | "ocr";
  transactions: Transaction[];
  summary?: StatementSummary;
};

export type Statement = {
  id: string;
  source: StatementSource;
  period: string;
  fileName: string;
  importedAt: string;
  mode: ImportResult["mode"];
  transactionCount: number;
  status: StatementStatus;
  kind?: StatementKind;
  summary?: StatementSummary;
};

export type ImportCommit = {
  source: StatementSource;
  kind: StatementKind;
  period: string;
  fileName: string;
  mode: ImportResult["mode"];
  transactions: Transaction[];
  summary?: StatementSummary;
  /** User corrections learned from this review, keyed by normalized merchant. */
  categoryRules?: Record<string, string>;
};
