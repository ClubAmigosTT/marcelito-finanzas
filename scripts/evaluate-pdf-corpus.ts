import { readdir, readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { resolve } from "node:path";
import * as pdfjs from "pdfjs-dist/legacy/build/pdf.mjs";
import { detectSourceEvidence, extractTransactions, parseStatementSummary, PDF_READER_VERSION, rebuildPdfText, reconcileStatementImport, shouldUseOCR } from "../src/pdfImport.ts";
import type { StatementKind, StatementSource } from "../src/types.ts";

type ExpectedFile = {
  file: string;
  sourceFingerprint?: string;
  source?: StatementSource;
  kind?: StatementKind;
  status?: "valid" | "invalid" | "pending";
  rows?: number;
  summary?: Record<string, number>;
};

type CorpusManifest = {
  tolerance?: number;
  /** The manifest is tied to the exact extraction rules it certifies. */
  readerVersion?: string;
  files?: ExpectedFile[];
};

function argument(name: string) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function kindFor(source: StatementSource): StatementKind {
  return source === "Amex" ? "card" : source === "Desconocido" ? "unknown" : "bank";
}

function closeEnough(actual: unknown, expected: unknown, tolerance: number) {
  if (typeof actual !== "number" || typeof expected !== "number") return actual === expected;
  return Math.abs(actual - expected) <= tolerance;
}

async function textFromPdf(file: string) {
  const data = new Uint8Array(await readFile(file));
  const sourceFingerprint = createHash("sha256").update(data).digest("hex");
  const document = await pdfjs.getDocument({ data, disableWorker: true }).promise;
  try {
    const pages: string[] = [];
    for (let pageNumber = 1; pageNumber <= document.numPages; pageNumber += 1) {
      const page = await document.getPage(pageNumber);
      const content = await page.getTextContent();
      pages.push(`__PDF_PAGE_${pageNumber}__\n${rebuildPdfText(content.items)}`);
      page.cleanup();
    }
    return { text: pages.join("\n"), sourceFingerprint };
  } finally {
    await document.destroy();
  }
}

async function evaluate(file: string) {
  const extracted = await textFromPdf(file);
  const text = extracted.text;
  const fileName = file.split(/[\\/]/).at(-1) ?? file;
  // Keep corpus diagnostics on the exact same text/OCR decision as the app;
  // otherwise a hidden administrative layer could be certified as text here
  // while the product correctly falls back to visual OCR (or vice versa).
  const mode = shouldUseOCR(text) ? "ocr-required" : "pdf-text";
  const sourceDetection = detectSourceEvidence(text, fileName);
  const kind = kindFor(sourceDetection.source);
  const transactions = kind === "unknown" ? [] : extractTransactions(text, sourceDetection.source, fileName, kind);
  const summary = kind === "unknown" ? undefined : parseStatementSummary(text, kind);
  const creditUsed = summary?.creditLimit !== undefined && summary.creditAvailable !== undefined
    ? Math.max(0, summary.creditLimit - summary.creditAvailable)
    : summary?.debtBalance;
  const statementControls = summary ? {
    previousBalance: summary.previousBalance,
    cashBalance: summary.cashBalance,
    depositTotal: summary.depositTotal,
    withdrawalTotal: summary.withdrawalTotal,
    depositCount: summary.depositCount,
    withdrawalCount: summary.withdrawalCount,
    statementBalance: summary.statementBalance,
    creditLimit: summary.creditLimit,
    creditAvailable: summary.creditAvailable,
    debtBalance: creditUsed,
    paymentForNoInterest: summary.paymentForNoInterest,
    minimumPlusMsi: summary.minimumPlusMsi,
    msiPending: summary.msiPending,
  } : {};
  const reconciliation = kind === "unknown"
    ? { status: "pending" as const, tolerance: 0.05, extractedMovementCount: 0, reason: "Emisor no identificado" }
    : reconcileStatementImport(kind, summary, transactions);
  const suspiciousRows = transactions.filter((row) => !Number.isFinite(row.amount) || Math.abs(row.amount) >= 100_000_000 || row.date === "Sin fecha");
  // A valid total is not enough to certify an extracted row. Every accepted
  // movement must remain traceable to the source page and a bounded fragment
  // of the input text so a reviewer can reproduce the amount and description.
  const missingEvidenceRows = transactions.filter((row) => {
    const evidence = row.extractionEvidence;
    return !evidence
      || !Number.isFinite(evidence.confidence)
      || !evidence.method
      || !Number.isInteger(evidence.page)
      || (evidence.page ?? 0) < 1
      || !evidence.sourceText?.trim();
  });
  const evidenceCoverage = transactions.length > 0
    ? Number(((transactions.length - missingEvidenceRows.length) / transactions.length).toFixed(4))
    : 1;
  return {
    file: fileName,
    readerVersion: PDF_READER_VERSION,
    sourceFingerprint: extracted.sourceFingerprint,
    mode,
    source: sourceDetection.source,
    sourceStatus: sourceDetection.status,
    sourceConfidence: Number(sourceDetection.confidence.toFixed(4)),
    sourceEvidence: sourceDetection.evidence,
    ignoredBodyMentions: sourceDetection.ignoredBodyMentions,
    kind,
    rows: transactions.length,
    // Keep the issuer's balance controls separate from row reconciliation so
    // OCR runs can compare Santander scans even before their movement table is
    // accepted. Undefined fields are omitted from JSON automatically.
    statementControls,
    suspiciousRows: suspiciousRows.length,
    missingEvidenceRows: missingEvidenceRows.length,
    evidenceCoverage,
    reconciliation: {
      status: reconciliation.status,
      reason: reconciliation.reason,
      extractedMovementCount: reconciliation.extractedMovementCount,
      expectedMovementCount: reconciliation.expectedMovementCount,
      rowCoverage: reconciliation.expectedMovementCount && reconciliation.expectedMovementCount > 0
        ? Number((reconciliation.extractedMovementCount / reconciliation.expectedMovementCount).toFixed(4))
        : undefined,
      extractedDepositTotal: reconciliation.extractedDepositTotal,
      extractedWithdrawalTotal: reconciliation.extractedWithdrawalTotal,
      extractedChargeTotal: reconciliation.extractedChargeTotal,
      extractedPaymentTotal: reconciliation.extractedPaymentTotal,
    },
  };
}

const directory = argument("--dir");
const manifestPath = argument("--manifest");
const outputPath = argument("--out");
const requireManifest = process.argv.includes("--require-manifest");
const targetPrecisionRaw = argument("--target-precision");
const targetPrecision = targetPrecisionRaw === undefined ? 0.99 : Number(targetPrecisionRaw);
if (!directory) {
  console.error("Uso: npm run pdf:corpus -- --dir <carpeta> [--manifest <archivo.json>] [--out <reporte.json>] [--require-manifest] [--target-precision 0.99]");
  process.exitCode = 2;
} else if (requireManifest && !manifestPath) {
  console.error("La certificación requiere --manifest con expectativas doradas para cada PDF.");
  process.exitCode = 2;
} else if (!Number.isFinite(targetPrecision) || targetPrecision < 0 || targetPrecision > 1) {
  console.error("--target-precision debe ser un número entre 0 y 1.");
  process.exitCode = 2;
} else {
  const root = resolve(directory);
  const manifest: CorpusManifest = manifestPath ? JSON.parse(await readFile(resolve(manifestPath), "utf8")) : {};
  const tolerance = manifest.tolerance ?? 0.05;
  const names = (await readdir(root)).filter((name) => name.toLowerCase().endsWith(".pdf")).sort();
  const results = [];
  let failures = 0;
  let parseErrors = 0;
  let goldenAutoAccepted = 0;
  let goldenFalseAccepted = 0;
  const expectedFiles = manifest.files ?? [];
  const expectedNames = expectedFiles.map((item) => item.file);
  const duplicateManifestFiles = [...new Set(expectedNames.filter((name, index) => expectedNames.indexOf(name) !== index))].sort();
  const missingManifestFiles = expectedNames.filter((name) => !names.includes(name)).sort();
  const unlistedCorpusFiles = manifestPath ? names.filter((name) => !expectedNames.includes(name)).sort() : [];
  if (duplicateManifestFiles.length) failures += duplicateManifestFiles.length;
  if (missingManifestFiles.length) failures += missingManifestFiles.length;
  if (requireManifest && unlistedCorpusFiles.length) failures += unlistedCorpusFiles.length;
  const manifestReaderVersionMismatch = Boolean(
    requireManifest && manifest.readerVersion !== PDF_READER_VERSION,
  );
  if (manifestReaderVersionMismatch) failures += 1;

  for (const name of names) {
    let result: Awaited<ReturnType<typeof evaluate>>;
    try {
      result = await evaluate(resolve(root, name));
    } catch (error) {
      // A damaged/encrypted PDF must not abort the whole corpus run. Keep a
      // deterministic per-file failure so every file is accounted for and a
      // certification can never pass by silently skipping an unreadable PDF.
      parseErrors += 1;
      failures += 1;
      result = {
        file: name,
        readerVersion: PDF_READER_VERSION,
        sourceFingerprint: undefined,
        mode: "parse-error",
        source: "Desconocido",
        sourceStatus: "unknown",
        sourceConfidence: 0,
        sourceEvidence: [],
        ignoredBodyMentions: [],
        kind: "unknown",
        rows: 0,
        statementControls: {},
        suspiciousRows: 0,
        missingEvidenceRows: 0,
        evidenceCoverage: 0,
        parseError: error instanceof Error ? error.message : String(error),
        reconciliation: {
          status: "pending",
          reason: "No se pudo abrir o extraer el PDF",
          extractedMovementCount: 0,
        },
      };
    }
    const expected = manifest.files?.find((item) => item.file === name);
    const mismatches: string[] = [];
    if (expected?.source && expected.source !== result.source) mismatches.push(`emisor esperado ${expected.source}, obtenido ${result.source}`);
    // A golden marked valid must prove the issuer, not merely match the
    // filename/source string. Filename-only detections remain review-only and
    // must never look checked or certified in the corpus report.
    if (expected?.status === "valid" && result.sourceStatus !== "verified") {
      mismatches.push(`emisor no verificado (estado ${result.sourceStatus})`);
    }
    if (expected?.kind && expected.kind !== result.kind) mismatches.push(`tipo esperado ${expected.kind}, obtenido ${result.kind}`);
    if (expected?.sourceFingerprint && expected.sourceFingerprint !== result.sourceFingerprint) mismatches.push("huella SHA-256 del archivo no coincide");
    if (expected?.status && expected.status !== result.reconciliation.status) mismatches.push(`estado esperado ${expected.status}, obtenido ${result.reconciliation.status}`);
    if (expected?.rows !== undefined && expected.rows !== result.rows) mismatches.push(`filas esperadas ${expected.rows}, obtenidas ${result.rows}`);
    for (const [key, value] of Object.entries(expected?.summary ?? {})) {
      const actual = result.reconciliation[key as keyof typeof result.reconciliation]
        ?? result.statementControls[key as keyof typeof result.statementControls];
      if (!closeEnough(actual, value, tolerance)) mismatches.push(`${key}: esperado ${value}, obtenido ${String(actual)}`);
    }
    const checked = expected ? mismatches.length === 0 : undefined;
    if (mismatches.length) failures += 1;
    const autoAccepted = result.reconciliation.status === "valid"
      && result.sourceStatus === "verified"
      && result.suspiciousRows === 0
      && result.missingEvidenceRows === 0;
    if (expected && autoAccepted) {
      if (expected.status === "valid" && mismatches.length === 0) goldenAutoAccepted += 1;
      else goldenFalseAccepted += 1;
    }
    results.push({ ...result, ...(expected ? { expected: { checked, mismatches } } : {}) });
  }

  const accepted = results.filter((result) => result.reconciliation.status === "valid"
    && result.sourceStatus === "verified"
    && result.suspiciousRows === 0
    && result.missingEvidenceRows === 0).length;
  const automaticAcceptancePrecision = goldenAutoAccepted + goldenFalseAccepted > 0
    ? Number((goldenAutoAccepted / (goldenAutoAccepted + goldenFalseAccepted)).toFixed(4))
    : null;
  const precisionFailure = Boolean(requireManifest && (automaticAcceptancePrecision === null || automaticAcceptancePrecision < targetPrecision));
  if (precisionFailure) failures += 1;
  const nativeOCRPending = results.filter((result) => result.mode === "ocr-required").length;
  // Precision answers “of the rows we accepted, how many were correct?”;
  // certification also requires every manifest file to have been evaluated
  // by the appropriate reader. A text-only run must never look certified
  // while scanned PDFs are waiting for Vision on macOS/iOS.
  const acceptanceRate = results.length
    ? Number((accepted / results.length).toFixed(4))
    : 0;
  const certified = Boolean(
    requireManifest
      && failures === 0
      && nativeOCRPending === 0
      && expectedFiles.length === results.length
      && automaticAcceptancePrecision !== null
      && automaticAcceptancePrecision >= targetPrecision,
  );
  const output = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    directory: root,
    files: results.length,
    accepted,
    blocked: results.length - accepted,
    manifestChecked: Boolean(manifestPath),
    readerVersion: PDF_READER_VERSION,
    manifestReaderVersion: manifest.readerVersion,
    manifestReaderVersionMismatch,
    manifestFailures: failures,
    manifestMissingFiles: missingManifestFiles,
    manifestDuplicateFiles: duplicateManifestFiles,
    manifestUnlistedFiles: unlistedCorpusFiles,
    parseErrors,
    targetPrecision,
    precisionFailure,
    certified,
    acceptanceRate,
    nativeOCRPending,
    goldenExpectedFiles: expectedFiles.length,
    goldenAutoAccepted,
    goldenFalseAccepted,
    automaticAcceptancePrecision,
    results,
  };
  const serialized = JSON.stringify(output, null, 2);
  console.log(serialized);
  if (outputPath) {
    await writeFile(resolve(outputPath), `${serialized}\n`, "utf8");
  }
  if (failures > 0) process.exitCode = 1;
}
