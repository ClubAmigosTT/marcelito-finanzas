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

export type SourceDetectionStatus = "verified" | "review" | "unknown";

/**
 * How a transaction was read from its source document.
 *
 * `multimodal` is intentionally separate from the local PDF text/OCR paths:
 * it identifies a schema-constrained external reader, which still has to
 * pass the same validation and reconciliation gates before reaching the
 * canonical ledger.
 */
export type ExtractionMethod = "pdf-text" | "ocr" | "multimodal" | "manual";

export type ExtractionProvider = "local" | "multimodal";

/** Normalized coordinates of the source row (0–1 for OCR, document units for text PDFs). */
export type ExtractionBounds = {
  x: number;
  y: number;
  width: number;
  height: number;
};

/** Provenance retained for each parsed row so an accepted amount is auditable. */
export type TransactionExtractionEvidence = {
  method: ExtractionMethod;
  page?: number;
  confidence: number;
  /** Short source fragment used to reconstruct the row; never the full PDF. */
  sourceText?: string;
  /** Bounding box when the extraction method provides visual coordinates. */
  bounds?: ExtractionBounds;
};

/** Evidence used to identify the issuer without trusting transaction text. */
export type SourceDetection = {
  source: StatementSource;
  confidence: number;
  status: SourceDetectionStatus;
  evidence: string[];
  ignoredBodyMentions: string[];
};

export type StatementStatus = "ready" | "review";

/** Resultado de contrastar las filas extraídas contra los totales del estado. */
export type StatementReconciliationStatus = "valid" | "invalid" | "pending";

export type StatementReconciliation = {
  status: StatementReconciliationStatus;
  tolerance: number;
  extractedDepositTotal?: number;
  extractedWithdrawalTotal?: number;
  extractedChargeTotal?: number;
  extractedDomesticChargeTotal?: number;
  extractedForeignChargeTotal?: number;
  /** Créditos del estado (por ejemplo, “monto a diferir”) descontados del gasto neto. */
  extractedCreditTotal?: number;
  extractedPaymentTotal?: number;
  /** Difference in the card identity: credit limit - available - debt. */
  creditIdentityDifference?: number;
  extractedMovementCount?: number;
  /** Expected row count when the issuer declares deposit/withdrawal counts. */
  expectedMovementCount?: number;
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
  /** Marks rows reconstructed from an issuer's foreign-currency section. */
  foreignCurrency?: boolean;
  confidence?: number;
  extractionEvidence?: TransactionExtractionEvidence;
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
  /** Subtotals that issuers print for domestic/foreign transaction sections. */
  domesticTransactionTotal?: number;
  /** Some Amex statements print the domestic subtotal as a credit (CR). */
  domesticTransactionTotalIsCredit?: boolean;
  foreignTransactionTotal?: number;
  /** Totales declarados en estados de cuenta bancarios. */
  depositTotal?: number;
  withdrawalTotal?: number;
  depositCount?: number;
  withdrawalCount?: number;
};

export type ImportResult = {
  source: StatementSource;
  /** Stable masked account identity (issuer + last four digits), when the PDF header provides it. */
  accountKey?: string;
  sourceDetection?: SourceDetection;
  kind: StatementKind;
  period: string;
  fileName: string;
  /** SHA-256 of the original PDF when the browser crypto API is available. */
  sourceFingerprint?: string;
  /** Original PDF metadata retained for reproducible audit, not for parsing. */
  fileSizeBytes?: number;
  pageCount?: number;
  /** Exact reader revision that produced this extraction. */
  readerVersion?: string;
  /** Proveedor de extracción (local o lector multimodal seguro). */
  extractionProvider?: ExtractionProvider;
  /** Modelo remoto utilizado, si aplica; nunca contiene credenciales. */
  extractionModel?: string;
  /** Versión del contrato/prompt para reproducir la extracción. */
  extractionPromptVersion?: string;
  /** The parser either used the PDF text layer or rendered pages through OCR. */
  mode: "text" | "ocr";
  transactions: Transaction[];
  summary?: StatementSummary;
  reconciliation?: StatementReconciliation;
  /** Average OCR confidence (0–1) when the PDF had no usable text layer. */
  ocrConfidence?: number;
  /** Per-page OCR confidence, retained for diagnostics and review UX. */
  ocrPageConfidences?: number[];
  /**
   * Transient text/OCR stream kept only while the import dialog is open. It is
   * intentionally not part of ImportCommit/Statement so raw PDF text is not
   * persisted; it lets a reviewer re-read rows after correcting issuer/kind.
   */
  extractedText?: string;
};

export type Statement = {
  id: string;
  source: StatementSource;
  /** Stable masked account identity; never stores the full account number. */
  accountKey?: string;
  period: string;
  fileName: string;
  /** Stable identity of the exact source PDF used for this statement. */
  sourceFingerprint?: string;
  /** Original PDF metadata used to reproduce an import decision. */
  fileSizeBytes?: number;
  pageCount?: number;
  /** Exact reader revision that produced this statement. */
  readerVersion?: string;
  /** Proveedor de extracción (local o lector multimodal seguro). */
  extractionProvider?: ExtractionProvider;
  /** Modelo remoto utilizado, si aplica; nunca contiene credenciales. */
  extractionModel?: string;
  /** Versión del contrato/prompt para reproducir la extracción. */
  extractionPromptVersion?: string;
  importedAt: string;
  mode: ImportResult["mode"];
  transactionCount: number;
  status: StatementStatus;
  kind?: StatementKind;
  summary?: StatementSummary;
  /** Undefined is accepted only for legacy/programmatic data; the app migrates it to pending. */
  reconciliationStatus?: StatementReconciliationStatus;
  reconciliation?: StatementReconciliation;
  sourceDetection?: SourceDetection;
  /** Explicit human confirmation for a known issuer when automatic evidence is provisional. */
  issuerConfirmedByUser?: boolean;
  ocrConfidence?: number;
  /** Per-page OCR confidence retained for audit and reproducible review. */
  ocrPageConfidences?: number[];
};

export type ImportCommit = {
  source: StatementSource;
  accountKey?: string;
  kind: StatementKind;
  period: string;
  fileName: string;
  sourceFingerprint?: string;
  fileSizeBytes?: number;
  pageCount?: number;
  readerVersion?: string;
  extractionProvider?: ExtractionProvider;
  extractionModel?: string;
  extractionPromptVersion?: string;
  mode: ImportResult["mode"];
  transactions: Transaction[];
  summary?: StatementSummary;
  reconciliation?: StatementReconciliation;
  sourceDetection?: SourceDetection;
  ocrConfidence?: number;
  ocrPageConfidences?: number[];
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
  /** PDF-derived rows removed during startup migration because their reader
   * revision or reconciliation evidence was stale. */
  quarantinedMovementCount?: number;
  /** SHA-256 identities of the source PDFs included in this audit. */
  sourceFingerprints?: string[];
  /** Reader revisions represented by the canonical ledger. */
  readerVersions?: string[];
  message?: string;
};
