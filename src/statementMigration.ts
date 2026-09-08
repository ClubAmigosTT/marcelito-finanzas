import { inferLocalCategory, PDF_READER_VERSION, reconcileStatementImport } from "./pdfImport.ts";
import { defaultStatementKind, hasSufficientOcrQuality, hasVerifiedSourceEvidence } from "./finance.ts";
import { hasTraceableEvidence } from "./reconciliation.ts";
import { categoryFromRules, type CategoryRules } from "./categoryRules.ts";
import type { Statement, Transaction } from "./types.ts";

const MIGRATION_TOLERANCE = 0;

function isSupportedReaderVersion(version: string | undefined, currentReaderVersion: string) {
  if (version === currentReaderVersion) return true;
  // 2026.09.06.10 tightened one OCR balance-repair branch without changing
  // the statement contract. The immediately preceding local reader already
  // produced the same issuer evidence, row provenance and issuer-total
  // controls, so those persisted rows can be revalidated in place. Remote /
  // multimodal revisions and older local contracts remain quarantined.
  return currentReaderVersion === "web-reader-2026.09.06.10"
    && version === "web-reader-2026.09.01.9";
}

const pendingCategories = new Set([
  "Sin categoría", "Por revisar", "Otros / Por revisar", "Otros gastos",
  "Alimentos", "Comidas", "Servicios", "Compras", "Finanzas",
  "Educación", "Hogar", "Mascotas",
]);

function enrichStoredTransaction(
  transaction: Transaction,
  learnedRules: CategoryRules = {},
  manualOverrides: CategoryRules = {},
): Transaction {
  // Valid categories are intentionally stable. Only rows in the old/review
  // buckets are eligible for the taxonomy migration.
  if (!pendingCategories.has(transaction.category)) return transaction;
  if (transaction.flow === "income") return { ...transaction, category: "Ingresos" };
  if (["cardPayment", "bankTransfer", "credit", "refund"].includes(transaction.kind ?? "")) {
    return { ...transaction, category: "Transferencia", classificationProvider: "rules", classificationConfidence: 1, classificationReason: "Movimiento contable identificado por conciliación" };
  }
  if (transaction.flow !== "expense") return transaction;
  // A manually entered uncategorized row is an explicit user review item.
  // Only migrate PDF-derived rows whose extraction will still be checked by
  // statement reconciliation and page-level provenance below.
  if (!transaction.statementId) return transaction;
  const explicit = categoryFromRules(transaction.description, manualOverrides)
    ?? categoryFromRules(transaction.description, learnedRules);
  const inferred = explicit
    ? { ...inferLocalCategory(transaction.description, transaction.flow, transaction.kind), category: explicit, confidence: 1, reason: "Regla local aprendida o corrección explícita del usuario." }
    : inferLocalCategory(transaction.description, transaction.flow, transaction.kind);
  return {
    ...transaction,
    category: inferred.category,
    // Reader .9 used 0.62 solely as the sentinel for "Sin categoría". Once
    // the same row has a deterministic bucket and its statement revalidates,
    // retaining that sentinel would recreate the misleading 93% review rate.
    confidence: Math.max(transaction.confidence ?? 0, 0.92),
    classificationProvider: "rules",
    classificationTags: inferred.tags,
    merchantNormalized: inferred.merchant,
    classificationConfidence: inferred.confidence,
    classificationReason: inferred.reason,
    travelRelated: transaction.travelRelated || inferred.travel,
    extraordinary: transaction.extraordinary || inferred.extraordinary,
  };
}

/**
 * Makes persisted statements safe across parser revisions.
 *
 * Reader revisions are quarantined by default because they may contain the
 * extraction error a later contract fixed. A deliberately allowlisted,
 * contract-compatible revision can proceed to row-level revalidation in
 * `prepareStoredLedger`; all other documents remain visible for audit only.
 */
export function prepareStoredStatements(
  statements: Statement[],
  readerVersion = PDF_READER_VERSION,
) {
  return statements.map((statement) => {
    const hasReconciliation = Boolean(statement.reconciliationStatus && statement.reconciliation);
    const isCurrentReader = isSupportedReaderVersion(statement.readerVersion, readerVersion);
    // A statement that is already ready must also carry verified issuer
    // evidence.  Earlier reader versions could mark a file ready from a
    // filename-only guess (or leave the field absent entirely); allowing that
    // row into the canonical ledger would let a BBVA PDF masquerade as a
    // Santander account even when its totals happen to reconcile.
    const sourceNeedsReview = statement.status === "ready"
      && !hasVerifiedSourceEvidence(statement);
    const kindNeedsReview = statement.kind === "unknown";
    const ocrNeedsReview = !hasSufficientOcrQuality(statement);
    if (hasReconciliation && isCurrentReader && !sourceNeedsReview && !kindNeedsReview && !ocrNeedsReview) return statement;

    const reason = !statement.readerVersion
      ? "Estado importado antes de la conciliación automática; vuelve a importarlo para usarlo en los KPI."
      : !isCurrentReader
        ? `Estado generado con el lector ${statement.readerVersion}; vuelve a importar el PDF con ${readerVersion}.`
        : sourceNeedsReview
          ? "Estado sin evidencia institucional verificada del emisor; vuelve a importarlo para confirmar el banco antes de usarlo en los KPI."
          : kindNeedsReview
            ? "No se pudo identificar si el estado es bancario o de tarjeta; confirma el tipo antes de usarlo en los KPI."
          : ocrNeedsReview
            ? "Estado OCR con confianza insuficiente; revisa las páginas y vuelve a importarlo antes de usarlo en los KPI."
            : "Estado sin evidencia de conciliación completa; vuelve a importarlo para usarlo en los KPI.";

    return {
      ...statement,
      status: "review" as const,
      reconciliationStatus: "pending" as const,
      reconciliation: {
        status: "pending" as const,
        tolerance: MIGRATION_TOLERANCE,
        reason,
      },
    };
  });
}

/**
 * Rebuild the persisted web ledger boundary after a reader update.
 *
 * Persisted rows are user data and must never disappear during a reader
 * upgrade. A narrowly compatible revision is revalidated from its issuer
 * evidence, row provenance and declared controls. Unsupported or genuinely
 * invalid statements keep their rows visible for audit, while the canonical
 * KPI boundary excludes them until the source is reviewed again.
 */
export function prepareStoredLedger(
  statements: Statement[],
  transactions: Transaction[],
  readerVersion = PDF_READER_VERSION,
  learnedRules: CategoryRules = {},
  manualOverrides: CategoryRules = {},
) {
  // Never discard a user's imported ledger during a reader migration. Rows
  // from a genuinely unsupported statement remain visible to the audit layer
  // but are excluded from KPI by the single eligibility boundary in finance.
  const preparedTransactions = transactions.map((transaction) => enrichStoredTransaction(transaction, learnedRules, manualOverrides));
  const initiallyPrepared = prepareStoredStatements(statements, readerVersion);
  const preparedStatements = initiallyPrepared.map((prepared, index) => {
    const original = statements[index];
    if (!original || !isSupportedReaderVersion(original.readerVersion, readerVersion)) return prepared;
    if (!hasVerifiedSourceEvidence(original)) return prepared;
    if (original.kind === "unknown" || !hasSufficientOcrQuality(original)) return prepared;
    const linked = preparedTransactions.filter((transaction) => transaction.statementId === original.id);
    if (linked.some((transaction) => !hasTraceableEvidence(transaction))) return prepared;
    const reconciliation = reconcileStatementImport(original.kind ?? defaultStatementKind(original.source), original.summary, linked);
    if (reconciliation.status !== "valid") return prepared;
    return {
      ...original,
      status: "ready" as const,
      reconciliationStatus: "valid" as const,
      reconciliation,
      transactionCount: linked.length,
    };
  });
  const quarantinedStatementIds = new Set(
    preparedStatements
      .filter((statement) => {
        return !isSupportedReaderVersion(statement.readerVersion, readerVersion)
          || statement.reconciliationStatus !== "valid"
          || statement.reconciliation?.status !== "valid"
          || statement.status !== "ready"
          || !hasVerifiedSourceEvidence(statement)
          || statement.kind === "unknown"
          || !hasSufficientOcrQuality(statement);
      })
      .map((statement) => statement.id),
  );
  return {
    statements: preparedStatements,
    transactions: preparedTransactions,
    quarantinedStatementIds: [...quarantinedStatementIds],
    quarantinedMovementCount: preparedTransactions.filter((transaction) => Boolean(transaction.statementId && quarantinedStatementIds.has(transaction.statementId))).length,
  };
}
