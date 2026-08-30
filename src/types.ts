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

export type TransactionValidationStatus = "valid" | "review" | "invalid";
export type ReconciliationType = "internalTransfer" | "cardPayment";

// Known brands keep stable labels, while the open string branch lets a file
// from any other bank retain the name detected from its document or filename.
export type StatementSource = "Amex" | "Santander" | "BBVA" | "Desconocido" | (string & {});

export type StatementStatus = "ready" | "review";

/** Resultado de contrastar las filas extraídas contra los totales del estado. */
export type StatementReconciliationStatus = "valid" | "invalid" | "pending";

export type StatementReconciliation = {
  status: StatementReconciliationStatus;
  tolerance: number;
  extractedDepositTotal?: number;
  extractedWithdrawalTotal?: number;
  extractedChargeTotal?: number;
  extractedPaymentTotal?: number;
  extractedMovementCount?: number;
  reason?: string;
};

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
  /** Canonical merchant/concept used for reconciliation and grouping. */
  normalizedDescription?: string;
  /** Stable identity across overlapping statements and repeated imports. */
  deduplicationKey?: string;
  validationStatus?: TransactionValidationStatus;
  /** Links both sides of a transfer or a bank-to-card payment. */
  reconciliationId?: string;
  reconciledAs?: ReconciliationType;
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
  /** Minimum payment plus active MSI installments, when the issuer prints it. */
  minimumPlusMsi?: number;
  paymentForNoInterest?: number;
  paymentDueDate?: string;
  cashBalance?: number;
  msiOriginalDeferred?: number;
  msiPending?: number;
  revolvingBalance?: number;
  msiInstallments?: number;
  msiMonthlyLoad?: number;
  /** Totales declarados en estados de cuenta bancarios. */
  depositTotal?: number;
  withdrawalTotal?: number;
  depositCount?: number;
  withdrawalCount?: number;
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
  reconciliation?: StatementReconciliation;
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
  /** Undefined is accepted only for legacy/programmatic data; the app migrates it to pending. */
  reconciliationStatus?: StatementReconciliationStatus;
  reconciliation?: StatementReconciliation;
};

export type ImportCommit = {
  source: StatementSource;
  kind: StatementKind;
  period: string;
  fileName: string;
  mode: ImportResult["mode"];
  transactions: Transaction[];
  summary?: StatementSummary;
  reconciliation?: StatementReconciliation;
  /** User corrections learned from this review, keyed by normalized merchant. */
  categoryRules?: Record<string, string>;
};

export type AuditRunStatus = "passed" | "warning" | "blocked";

/** Persisted evidence for the last deterministic client-side audit. */
export type AuditRunRecord = {
  id: string;
  ranAt: string;
  trigger: "startup" | "foreground" | "import" | "edit";
  status: AuditRunStatus;
  ledgerFingerprint: string;
  statementCount: number;
  reconciledStatementCount: number;
  canonicalMovementCount: number;
  issueCount: number;
  message?: string;
};
