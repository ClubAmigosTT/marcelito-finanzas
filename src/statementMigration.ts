import { PDF_READER_VERSION } from "./pdfImport.ts";
import type { Statement } from "./types.ts";

const MIGRATION_TOLERANCE = 0.05;

/**
 * Makes persisted statements safe across parser revisions.
 *
 * A statement produced by an older reader cannot be trusted retroactively:
 * its rows may contain exactly the extraction error the new reader fixed.
 * Keep the document visible for audit, but quarantine it until the source PDF
 * is imported again with the current reader contract.
 */
export function prepareStoredStatements(
  statements: Statement[],
  readerVersion = PDF_READER_VERSION,
) {
  return statements.map((statement) => {
    const hasReconciliation = Boolean(statement.reconciliationStatus && statement.reconciliation);
    const isCurrentReader = statement.readerVersion === readerVersion;
    if (hasReconciliation && isCurrentReader) return statement;

    const reason = !statement.readerVersion
      ? "Estado importado antes de la conciliación automática; vuelve a importarlo para usarlo en los KPI."
      : !isCurrentReader
        ? `Estado generado con el lector ${statement.readerVersion}; vuelve a importar el PDF con ${readerVersion}.`
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
