import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { execFile as execFileCallback } from "node:child_process";
import { promisify } from "node:util";
import { dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import * as pdfjs from "pdfjs-dist/legacy/build/pdf.mjs";
import { detectAccountKey, detectSourceEvidence, extractTransactions, gateOcrReconciliation, parseImportedTransactions, parseStatementSummary, PDF_READER_VERSION, rebuildPdfText, reconcileStatementImport, shouldUseOCR } from "../src/pdfImport.ts";
import type { StatementKind, StatementSource } from "../src/types.ts";

const execFile = promisify(execFileCallback);

type ExpectedFile = {
  file: string;
  sourceFingerprint?: string;
  /** Issuer-scoped masked identity; the full account number is never stored. */
  accountKey?: string;
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
  const loadingTask = pdfjs.getDocument({ data, disableWorker: true });
  const document = await loadingTask.promise;
  try {
    const pages: string[] = [];
    for (let pageNumber = 1; pageNumber <= document.numPages; pageNumber += 1) {
      const page = await document.getPage(pageNumber);
      const content = await page.getTextContent();
      pages.push(`__PDF_PAGE_${pageNumber}__\n${rebuildPdfText(content.items)}`);
      page.cleanup();
    }
    return { text: pages.join("\n"), sourceFingerprint, numPages: document.numPages };
  } finally {
    // PDF.js 6 exposes lifecycle teardown on the loading task rather than on
    // the resolved PDFDocumentProxy. Keeping this aligned with the app avoids
    // reporting every real attachment as a parser failure.
    await loadingTask.destroy();
  }
}

async function ocrTextFromPdf(file: string, numPages: number, dpi: number, pdftoppmPath: string) {
  const temporaryDirectory = await mkdtemp(join(tmpdir(), "marcelito-pdf-ocr-"));
  const outputPrefix = join(temporaryDirectory, "page");
  try {
    await execFile(pdftoppmPath, [
      "-f", "1",
      "-l", String(numPages),
      "-r", String(dpi),
      "-png",
      file,
      outputPrefix,
    ], { maxBuffer: 1024 * 1024 });
    const imageFiles = (await readdir(temporaryDirectory))
      .filter((name) => name.toLowerCase().endsWith(".png"))
      .sort((left, right) => {
        const leftNumber = Number(left.match(/(\d+)\.png$/i)?.[1] ?? 0);
        const rightNumber = Number(right.match(/(\d+)\.png$/i)?.[1] ?? 0);
        return leftNumber - rightNumber;
      });
    if (imageFiles.length !== numPages) {
      throw new Error(`pdftoppm generó ${imageFiles.length} páginas de ${numPages}`);
    }
    const { createWorker } = await import("tesseract.js");
    const worker = await createWorker("spa");
    const pages: string[] = [];
    const pageConfidences: number[] = [];
    try {
      for (let index = 0; index < imageFiles.length; index += 1) {
        const image = await readFile(join(temporaryDirectory, imageFiles[index]));
        const result = await worker.recognize(image);
        pages.push(`__PDF_PAGE_${index + 1}__\n${result.data.text}`);
        pageConfidences.push(Math.max(0, Math.min(1, Number(result.data.confidence) / 100)));
      }
    } finally {
      await worker.terminate();
    }
    const confidence = pageConfidences.length
      ? pageConfidences.reduce((total, value) => total + value, 0) / pageConfidences.length
      : 0;
    return { text: pages.join("\n"), confidence, pageConfidences };
  } finally {
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
}

async function evaluate(file: string, options: { ocr: boolean; dpi: number; pdftoppmPath: string }) {
  const extracted = await textFromPdf(file);
  let text = extracted.text;
  const fileName = file.split(/[\\/]/).at(-1) ?? file;
  // Keep corpus diagnostics on the exact same text/OCR decision as the app;
  // otherwise a hidden administrative layer could be certified as text here
  // while the product correctly falls back to visual OCR (or vice versa).
  const requiresOCR = shouldUseOCR(text);
  let mode: "ocr-required" | "pdf-text" | "ocr" = requiresOCR ? "ocr-required" : "pdf-text";
  let ocrConfidence: number | undefined;
  let ocrPageConfidences: number[] | undefined;
  if (requiresOCR && options.ocr) {
    const ocr = await ocrTextFromPdf(file, extracted.numPages, options.dpi, options.pdftoppmPath);
    text = ocr.text;
    mode = "ocr";
    ocrConfidence = ocr.confidence;
    ocrPageConfidences = ocr.pageConfidences;
  }
  const sourceDetection = detectSourceEvidence(text, fileName);
  const accountKey = detectAccountKey(text, sourceDetection.source);
  const kind = kindFor(sourceDetection.source);
  const transactions = kind === "unknown" ? [] : mode === "ocr"
    ? parseImportedTransactions(text, sourceDetection.source, fileName, kind, "ocr", ocrPageConfidences)
    : extractTransactions(text, sourceDetection.source, fileName, kind);
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
  const baseReconciliation = kind === "unknown"
    ? { status: "pending" as const, tolerance: 0.05, extractedMovementCount: 0, reason: "Emisor no identificado" }
    : reconcileStatementImport(kind, summary, transactions);
  const reconciliation = mode === "ocr"
    ? gateOcrReconciliation(baseReconciliation, "ocr", ocrConfidence, ocrPageConfidences)
    : baseReconciliation;
  const qualityGateApplied = baseReconciliation.status !== reconciliation.status;
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
    ocrConfidence,
    ocrPageConfidences,
    qualityGate: {
      applied: qualityGateApplied,
      statusBefore: baseReconciliation.status,
      statusAfter: reconciliation.status,
    },
    source: sourceDetection.source,
    accountKey,
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
const useOCR = process.argv.includes("--ocr");
const ocrDpiRaw = argument("--ocr-dpi");
const ocrDpi = ocrDpiRaw === undefined ? 220 : Number(ocrDpiRaw);
const pdftoppmPath = argument("--pdftoppm") ?? process.env.MARCELITO_PDFTOPPM ?? "pdftoppm";
const requireManifest = process.argv.includes("--require-manifest");
const targetPrecisionRaw = argument("--target-precision");
const targetPrecision = targetPrecisionRaw === undefined ? 0.99 : Number(targetPrecisionRaw);
if (!directory) {
  console.error("Uso: npm run pdf:corpus -- --dir <carpeta> [--manifest <archivo.json>] [--out <reporte.json>] [--require-manifest] [--target-precision 0.99] [--ocr --ocr-dpi 220 --pdftoppm <ruta>]");
  process.exitCode = 2;
} else if (requireManifest && !manifestPath) {
  console.error("La certificación requiere --manifest con expectativas doradas para cada PDF.");
  process.exitCode = 2;
} else if (!Number.isFinite(targetPrecision) || targetPrecision < 0 || targetPrecision > 1) {
  console.error("--target-precision debe ser un número entre 0 y 1.");
  process.exitCode = 2;
} else if (useOCR && (!Number.isFinite(ocrDpi) || ocrDpi < 72 || ocrDpi > 300)) {
  console.error("--ocr-dpi debe ser un número entre 72 y 300.");
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
  let diagnosticOcrAccepted = 0;
  const expectedFiles = manifest.files ?? [];
  const expectedNames = expectedFiles.map((item) => item.file);
  const manifestSchemaFailures: string[] = [];
  if (requireManifest) {
    expectedFiles.forEach((entry, index) => {
      const label = entry.file?.trim() || `entrada ${index + 1}`;
      if (!entry.file?.trim()) manifestSchemaFailures.push(`${label}: falta file`);
      if (!entry.sourceFingerprint || !/^[a-f0-9]{64}$/i.test(entry.sourceFingerprint.trim())) {
        manifestSchemaFailures.push(`${label}: falta sourceFingerprint SHA-256`);
      }
      if (!entry.accountKey || !/^[a-z0-9]+:\d{4}$/i.test(entry.accountKey.trim())) {
        manifestSchemaFailures.push(`${label}: falta accountKey emisor:últimos4`);
      }
      if (!entry.source || entry.source === "Desconocido") {
        manifestSchemaFailures.push(`${label}: falta source identificado`);
      }
      if (!entry.kind || !["bank", "card", "unknown"].includes(entry.kind)) {
        manifestSchemaFailures.push(`${label}: falta kind válido`);
      }
      if (!entry.status || !["valid", "pending", "invalid"].includes(entry.status)) {
        manifestSchemaFailures.push(`${label}: falta status valid/pending/invalid`);
      }
      if (entry.status === "valid" && (!Number.isInteger(entry.rows) || (entry.rows ?? -1) < 0)) {
        manifestSchemaFailures.push(`${label}: un golden valid necesita rows entero no negativo`);
      }
    });
    if (manifestSchemaFailures.length) failures += manifestSchemaFailures.length;
  }
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
      result = await evaluate(resolve(root, name), { ocr: useOCR, dpi: ocrDpi, pdftoppmPath });
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
        accountKey: undefined,
        sourceStatus: "unknown",
        sourceConfidence: 0,
        sourceEvidence: [],
        ignoredBodyMentions: [],
        kind: "unknown",
        rows: 0,
        statementControls: {},
        qualityGate: {
          applied: false,
          statusBefore: "pending",
          statusAfter: "pending",
        },
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
    // A scan without OCR has no reliable header, so defer this assertion to
    // the native/diagnostic OCR run. Text-layer documents are checked here.
    if (expected?.accountKey && (result.mode !== "ocr-required" || useOCR)
      && expected.accountKey !== result.accountKey) {
      mismatches.push(`cuenta esperada ${expected.accountKey}, obtenida ${result.accountKey ?? "ausente"}`);
    }
    if (expected?.sourceFingerprint && expected.sourceFingerprint !== result.sourceFingerprint) mismatches.push("huella SHA-256 del archivo no coincide");
    const expectedOCRPromotion = useOCR && expected?.status === "pending";
    if (expected?.status && !expectedOCRPromotion && expected.status !== result.reconciliation.status) mismatches.push(`estado esperado ${expected.status}, obtenido ${result.reconciliation.status}`);
    if (expected?.rows !== undefined && !expectedOCRPromotion && expected.rows !== result.rows) mismatches.push(`filas esperadas ${expected.rows}, obtenidas ${result.rows}`);
    if (expectedOCRPromotion && result.mode !== "ocr") mismatches.push("el modo OCR no se ejecutó");
    if (expectedOCRPromotion && result.reconciliation.status === "invalid") mismatches.push("OCR produjo una conciliación inválida");
    if (expectedOCRPromotion && result.mode === "ocr" && result.rows === 0) mismatches.push("OCR no produjo movimientos");
    for (const [key, value] of Object.entries(expected?.summary ?? {})) {
      const actual = result.reconciliation[key as keyof typeof result.reconciliation]
        ?? result.statementControls[key as keyof typeof result.statementControls];
      if (!closeEnough(actual, value, tolerance)) mismatches.push(`${key}: esperado ${value}, obtenido ${String(actual)}`);
    }
    const checked = expected ? mismatches.length === 0 : undefined;
    if (mismatches.length) failures += 1;
    const qualityAccepted = result.reconciliation.status === "valid"
      && result.sourceStatus === "verified"
      && result.suspiciousRows === 0
      && result.missingEvidenceRows === 0;
    // Local Tesseract is a diagnostic aid, not the production acceptance
    // path. Keep its successful promotions visible, but do not call them
    // automatic acceptances or count them as false positives against the
    // 99% metric reserved for text extraction/Vision-native output.
    const autoAccepted = qualityAccepted && result.mode !== "ocr";
    if (expected && result.mode === "ocr" && qualityAccepted) diagnosticOcrAccepted += 1;
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
  const expectedValidFiles = expectedFiles.filter((expected) => expected.status === "valid").length;
  const goldenCoverage = expectedValidFiles > 0
    ? Number((goldenAutoAccepted / expectedValidFiles).toFixed(4))
    : 0;
  const goldenCoverageFailure = Boolean(requireManifest && (
    expectedValidFiles === 0 || goldenCoverage < 1
  ));
  if (goldenCoverageFailure) failures += 1;
  const precisionFailure = Boolean(requireManifest && (automaticAcceptancePrecision === null || automaticAcceptancePrecision < targetPrecision));
  if (precisionFailure) failures += 1;
  const nativeOCRPending = results.filter((result) => result.mode === "ocr-required").length;
  const nativeVisionRequired = useOCR
    ? results.filter((result) => result.mode === "ocr").length
    : nativeOCRPending;
  // Precision answers “of the rows we accepted, how many were correct?”;
  // certification also requires every manifest file to have been evaluated
  // by the appropriate reader. A text-only run must never look certified
  // while scanned PDFs are waiting for Vision on macOS/iOS.
  const acceptanceRate = results.length
    ? Number((accepted / results.length).toFixed(4))
    : 0;
  const certified = Boolean(
    requireManifest
      && !useOCR
      && failures === 0
      && nativeOCRPending === 0
      && expectedFiles.length === results.length
      && automaticAcceptancePrecision !== null
      && automaticAcceptancePrecision >= targetPrecision,
  );
  const certificationBlockers = [
    ...(!requireManifest ? ["falta --require-manifest"] : []),
    ...(useOCR ? ["--ocr es diagnóstico local y no sustituye Vision nativa"] : []),
    ...(nativeVisionRequired > 0 ? [`${nativeVisionRequired} PDF(s) requieren certificación Vision nativa`] : []),
    ...(manifestReaderVersionMismatch ? ["la versión del manifiesto no coincide con el lector"] : []),
    ...(parseErrors > 0 ? [`${parseErrors} PDF(s) no se pudieron leer`] : []),
    ...(precisionFailure ? ["la precisión automática está por debajo del objetivo"] : []),
    ...(goldenCoverageFailure ? [`la cobertura de goldens válidos es ${goldenCoverage}; se requiere 1.0`] : []),
    ...(failures > 0 && !parseErrors && !manifestReaderVersionMismatch && !precisionFailure ? ["hay discrepancias con el manifiesto"] : []),
  ];
  const output = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    directory: root,
    files: results.length,
    accepted,
    blocked: results.length - accepted,
    manifestChecked: Boolean(manifestPath),
    readerVersion: PDF_READER_VERSION,
    ocrEnabled: useOCR,
    ocrDpi: useOCR ? ocrDpi : undefined,
    manifestReaderVersion: manifest.readerVersion,
    manifestReaderVersionMismatch,
    manifestFailures: failures,
    manifestSchemaFailures,
    manifestMissingFiles: missingManifestFiles,
    manifestDuplicateFiles: duplicateManifestFiles,
    manifestUnlistedFiles: unlistedCorpusFiles,
    parseErrors,
    targetPrecision,
    precisionFailure,
    certified,
    acceptanceRate,
    nativeOCRPending,
    nativeVisionRequired,
    certificationBlockers,
    goldenExpectedFiles: expectedFiles.length,
    goldenExpectedValidFiles: expectedValidFiles,
    goldenAutoAccepted,
    goldenFalseAccepted,
    goldenCoverage,
    goldenCoverageFailure,
    diagnosticOcrAccepted,
    automaticAcceptancePrecision,
    results,
  };
  const serialized = JSON.stringify(output, null, 2);
  console.log(serialized);
  if (outputPath) {
    const resolvedOutputPath = resolve(outputPath);
    // The documented commands commonly write to an `artifacts/` directory
    // that is intentionally not tracked. Create it on the first run so a
    // clean checkout produces the same report instead of failing after the
    // expensive PDF/OCR pass.
    await mkdir(dirname(resolvedOutputPath), { recursive: true });
    await writeFile(resolvedOutputPath, `${serialized}\n`, "utf8");
  }
  if (failures > 0) process.exitCode = 1;
}
