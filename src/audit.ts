import { buildDeduplicationKey, type PipelineResult } from "./reconciliation.ts";
import { PDF_READER_VERSION } from "./pdfImport.ts";
import type { AuditRunRecord, AuditRunStatus, Statement, Transaction } from "./types.ts";

/**
 * Stable, non-secret fingerprint of the canonical ledger. It is intentionally
 * not a cryptographic hash: its purpose is to detect a changed generation and
 * correlate an audit run, never to identify a user or a PDF.
 */
export function canonicalLedgerFingerprint(transactions: Transaction[]) {
  const rows = transactions
    .map((transaction) => [
      transaction.id,
      transaction.statementId ?? "manual",
      transaction.deduplicationKey ?? buildDeduplicationKey(transaction),
      transaction.kind ?? "other",
      transaction.amount.toFixed(2),
    ].join("|"))
    .sort();
  let hash = 2_166_136_261;
  for (const character of rows.join("\n")) {
    hash ^= character.charCodeAt(0);
    hash = Math.imul(hash, 16_777_619);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}

export function createAuditRun(
  pipeline: PipelineResult,
  statements: Statement[],
  transactions: Transaction[],
  trigger: AuditRunRecord["trigger"],
  migration?: { quarantinedMovementCount?: number },
): AuditRunRecord {
  // A conciliación válida todavía requiere confirmación cuando el usuario
  // debe revisar filas OCR, categorías o una detección ambigua. Esos estados
  // tampoco pueden aparecer como "Verificado" en la autoauditoría.
  const pendingStatements = statements.filter((statement) =>
    statement.reconciliationStatus !== "valid" || statement.status === "review"
  ).length;
  const issueCount = pendingStatements
    + pipeline.audit.invalidCount
    + pipeline.audit.duplicateCount
    + pipeline.audit.relevantReviewCount
    + pipeline.audit.missingEvidenceCount;
  const status: AuditRunStatus = pipeline.audit.criticalIssues.length || pendingStatements > 0
    ? "blocked"
    : pipeline.audit.reviewCount > 0
      ? "warning"
      : "passed";
  return {
    id: `audit-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`,
    ranAt: new Date().toISOString(),
    trigger,
    status,
    ledgerFingerprint: canonicalLedgerFingerprint(transactions),
    statementCount: statements.length,
    reconciledStatementCount: statements.length - pendingStatements,
    canonicalMovementCount: transactions.length,
    issueCount,
    ...(migration?.quarantinedMovementCount
      ? { quarantinedMovementCount: migration.quarantinedMovementCount }
      : {}),
    sourceFingerprints: statements
      .map((statement) => statement.sourceFingerprint)
      .filter((fingerprint): fingerprint is string => Boolean(fingerprint))
      .filter((fingerprint, index, all) => all.indexOf(fingerprint) === index)
      .sort(),
    readerVersions: [...new Set([
      PDF_READER_VERSION,
      ...statements.map((statement) => statement.readerVersion).filter((version): version is string => Boolean(version)),
    ])].sort(),
    message: pipeline.audit.criticalIssues[0] ?? (pendingStatements ? `${pendingStatements} estado(s) pendientes de conciliación o revisión.` : undefined),
  };
}
