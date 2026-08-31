import { readdir, readFile } from "node:fs/promises";
import { resolve } from "node:path";
import * as pdfjs from "pdfjs-dist/legacy/build/pdf.mjs";
import { detectSourceEvidence, extractTransactions, parseStatementSummary, rebuildPdfText, reconcileStatementImport } from "../src/pdfImport.ts";
import type { StatementKind, StatementSource } from "../src/types.ts";

type ExpectedFile = {
  file: string;
  source?: StatementSource;
  kind?: StatementKind;
  status?: "valid" | "invalid" | "pending";
  rows?: number;
  summary?: Record<string, number>;
};

type CorpusManifest = {
  tolerance?: number;
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
  const document = await pdfjs.getDocument({ data, disableWorker: true }).promise;
  try {
    const pages: string[] = [];
    for (let pageNumber = 1; pageNumber <= document.numPages; pageNumber += 1) {
      const page = await document.getPage(pageNumber);
      const content = await page.getTextContent();
      pages.push(rebuildPdfText(content.items));
      page.cleanup();
    }
    return pages.join("\n");
  } finally {
    await document.destroy();
  }
}

async function evaluate(file: string) {
  const text = await textFromPdf(file);
  const fileName = file.split(/[\\/]/).at(-1) ?? file;
  const mode = text.replace(/\s/g, "").length > 500 ? "pdf-text" : "ocr-required";
  const sourceDetection = detectSourceEvidence(text, fileName);
  const kind = kindFor(sourceDetection.source);
  const transactions = kind === "unknown" ? [] : extractTransactions(text, sourceDetection.source, fileName, kind);
  const summary = kind === "unknown" ? {} : parseStatementSummary(text, kind);
  const reconciliation = kind === "unknown"
    ? { status: "pending" as const, tolerance: 0.05, extractedMovementCount: 0, reason: "Emisor no identificado" }
    : reconcileStatementImport(kind, summary, transactions);
  const suspiciousRows = transactions.filter((row) => !Number.isFinite(row.amount) || Math.abs(row.amount) >= 100_000_000 || row.date === "Sin fecha");
  return {
    file: fileName,
    mode,
    source: sourceDetection.source,
    sourceStatus: sourceDetection.status,
    sourceConfidence: Number(sourceDetection.confidence.toFixed(4)),
    kind,
    rows: transactions.length,
    suspiciousRows: suspiciousRows.length,
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
if (!directory) {
  console.error("Uso: npm run pdf:corpus -- --dir <carpeta> [--manifest <archivo.json>]");
  process.exitCode = 2;
} else {
  const root = resolve(directory);
  const manifestPath = argument("--manifest");
  const manifest: CorpusManifest = manifestPath ? JSON.parse(await readFile(resolve(manifestPath), "utf8")) : {};
  const tolerance = manifest.tolerance ?? 0.05;
  const names = (await readdir(root)).filter((name) => name.toLowerCase().endsWith(".pdf")).sort();
  const results = [];
  let failures = 0;
  let goldenAutoAccepted = 0;
  let goldenFalseAccepted = 0;
  const expectedFiles = manifest.files ?? [];
  const expectedNames = expectedFiles.map((item) => item.file);
  const duplicateManifestFiles = [...new Set(expectedNames.filter((name, index) => expectedNames.indexOf(name) !== index))].sort();
  const missingManifestFiles = expectedNames.filter((name) => !names.includes(name)).sort();
  if (duplicateManifestFiles.length) failures += duplicateManifestFiles.length;
  if (missingManifestFiles.length) failures += missingManifestFiles.length;

  for (const name of names) {
    const result = await evaluate(resolve(root, name));
    const expected = manifest.files?.find((item) => item.file === name);
    const mismatches: string[] = [];
    if (expected?.source && expected.source !== result.source) mismatches.push(`emisor esperado ${expected.source}, obtenido ${result.source}`);
    if (expected?.kind && expected.kind !== result.kind) mismatches.push(`tipo esperado ${expected.kind}, obtenido ${result.kind}`);
    if (expected?.status && expected.status !== result.reconciliation.status) mismatches.push(`estado esperado ${expected.status}, obtenido ${result.reconciliation.status}`);
    if (expected?.rows !== undefined && expected.rows !== result.rows) mismatches.push(`filas esperadas ${expected.rows}, obtenidas ${result.rows}`);
    for (const [key, value] of Object.entries(expected?.summary ?? {})) {
      const actual = result.reconciliation[key as keyof typeof result.reconciliation];
      if (!closeEnough(actual, value, tolerance)) mismatches.push(`${key}: esperado ${value}, obtenido ${String(actual)}`);
    }
    const checked = expected ? mismatches.length === 0 : undefined;
    if (mismatches.length) failures += 1;
    const autoAccepted = result.reconciliation.status === "valid"
      && result.sourceStatus === "verified"
      && result.suspiciousRows === 0;
    if (expected && autoAccepted) {
      if (expected.status === "valid" && mismatches.length === 0) goldenAutoAccepted += 1;
      else goldenFalseAccepted += 1;
    }
    results.push({ ...result, ...(expected ? { expected: { checked, mismatches } } : {}) });
  }

  const accepted = results.filter((result) => result.reconciliation.status === "valid" && result.sourceStatus === "verified" && result.suspiciousRows === 0).length;
  const output = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    directory: root,
    files: results.length,
    accepted,
    blocked: results.length - accepted,
    manifestChecked: Boolean(manifestPath),
    manifestFailures: failures,
    manifestMissingFiles: missingManifestFiles,
    manifestDuplicateFiles: duplicateManifestFiles,
    goldenExpectedFiles: expectedFiles.length,
    goldenAutoAccepted,
    goldenFalseAccepted,
    automaticAcceptancePrecision: goldenAutoAccepted + goldenFalseAccepted > 0
      ? Number((goldenAutoAccepted / (goldenAutoAccepted + goldenFalseAccepted)).toFixed(4))
      : null,
    results,
  };
  console.log(JSON.stringify(output, null, 2));
  if (failures > 0) process.exitCode = 1;
}
