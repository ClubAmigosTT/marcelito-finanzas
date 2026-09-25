import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

// This comparator is intentionally a redacted diagnostic. It compares a
// private native export with the independent web-reader output, but never
// writes descriptions, amounts, or dates to its result.

function cents(value) {
  if (typeof value === "number") {
    return Number.isFinite(value) ? Math.round(value * 100) : null;
  }
  if (typeof value !== "string") return null;
  const text = value.trim().replace(/,/g, ".");
  if (!/^-?\d+(?:\.\d{1,2})?$/.test(text)) return null;
  const negative = text.startsWith("-");
  const [whole, fraction = ""] = text.replace(/^-/, "").split(".");
  const result = BigInt(whole) * 100n + BigInt(fraction.padEnd(2, "0"));
  return Number(negative ? -result : result);
}

function normalizeText(value) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/\p{M}/gu, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

function titleMatches(nativeTitle, independentTitle) {
  const left = normalizeText(nativeTitle);
  const right = normalizeText(independentTitle);
  if (!left || !right) return false;
  return left.includes(right) || right.includes(left);
}

function isCardPaymentKind(value) {
  return value === "cardPayment" || value === "Pago de tarjeta";
}

function canonicalKind(value) {
  const normalized = String(value ?? "").trim().toLowerCase();
  if (["cardpayment", "pago de tarjeta"].includes(normalized)) return "cardPayment";
  if (["purchase", "compra"].includes(normalized)) return "purchase";
  if (["refund", "devolución", "devolucion"].includes(normalized)) return "refund";
  if (["income", "ingreso"].includes(normalized)) return "income";
  if (["banktransfer", "transferencia", "traspaso propio", "traspaso"].includes(normalized)) return "bankTransfer";
  if (["credit", "crédito contable", "credito contable"].includes(normalized)) return "credit";
  if (["fee", "comisión", "comision"].includes(normalized)) return "fee";
  if (["interest", "interés", "interes"].includes(normalized)) return "interest";
  if (["other", "otro"].includes(normalized)) return "other";
  if (["debt", "deuda"].includes(normalized)) return "debt";
  if (["msi"].includes(normalized)) return "msi";
  return normalized;
}

function hasMaskedAccountKey(value) {
  return /^[a-z0-9]+:\d{4}$/i.test(String(value ?? ""));
}

function comparableAmountPair(nativeRow, independentRow) {
  const nativeAmount = cents(nativeRow?.signedAmount);
  const independentAmount = cents(independentRow?.signedAmount);
  if (nativeAmount === null || independentAmount === null) return null;
  const cardPayment = isCardPaymentKind(nativeRow?.kind) || isCardPaymentKind(independentRow?.kind);
  return cardPayment
    ? [Math.abs(nativeAmount), Math.abs(independentAmount)]
    : [nativeAmount, independentAmount];
}

export function compareIndependentRowReaders(nativeReport, independentReport) {
  const nativeFiles = Array.isArray(nativeReport?.files) ? nativeReport.files : [];
  const independentFiles = Array.isArray(independentReport?.results) ? independentReport.results : [];
  const validationErrors = [];
  if (!String(nativeReport?.readerVersion ?? "").trim()) validationErrors.push("falta readerVersion nativo");
  if (!String(independentReport?.readerVersion ?? "").trim()) validationErrors.push("falta readerVersion independiente");
  if (!nativeFiles.length) validationErrors.push("el export nativo no contiene archivos");
  if (!independentFiles.length) validationErrors.push("la referencia independiente no contiene archivos");
  if (nativeFiles.length !== independentFiles.length) validationErrors.push("los conjuntos de archivos tienen tamaños distintos");
  const nativeFingerprints = nativeFiles.map((file) => file?.sourceFingerprint).filter(Boolean);
  const independentFingerprints = independentFiles.map((file) => file?.sourceFingerprint).filter(Boolean);
  if (nativeFiles.some((file) => !/^[a-f0-9]{64}$/i.test(String(file?.sourceFingerprint ?? "")))) {
    validationErrors.push("el export nativo contiene una huella inválida");
  }
  if (independentFiles.some((file) => !/^[a-f0-9]{64}$/i.test(String(file?.sourceFingerprint ?? "")))) {
    validationErrors.push("la referencia independiente contiene una huella inválida");
  }
  if (new Set(nativeFingerprints).size !== nativeFingerprints.length) validationErrors.push("el export nativo contiene huellas repetidas");
  if (new Set(independentFingerprints).size !== independentFingerprints.length) validationErrors.push("la referencia independiente contiene huellas repetidas");
  if (nativeFiles.some((file) => !hasMaskedAccountKey(file?.accountKey))) {
    validationErrors.push("el export nativo contiene una identidad de cuenta ausente o sin máscara");
  }
  if (independentFiles.some((file) => !hasMaskedAccountKey(file?.accountKey))) {
    validationErrors.push("la referencia independiente contiene una identidad de cuenta ausente o sin máscara");
  }
  const independentByFingerprint = new Map(
    independentFiles
      .filter((file) => typeof file?.sourceFingerprint === "string")
      .map((file) => [file.sourceFingerprint, file]),
  );
  const independentByName = new Map(
    independentFiles
      .filter((file) => typeof file?.file === "string")
      .map((file) => [file.file, file]),
  );

  const documents = nativeFiles.map((nativeFile, index) => {
    const independent = independentByFingerprint.get(nativeFile?.sourceFingerprint)
      ?? independentByName.get(nativeFile?.sourceFileName);
    const nativeRows = Array.isArray(nativeFile?.candidateRows) ? nativeFile.candidateRows : [];
    const independentRows = Array.isArray(independent?.extractedRows) ? independent.extractedRows : [];
    const comparedRows = Math.min(nativeRows.length, independentRows.length);
    const matched = Boolean(independent);
    const mismatches = {
      rowCount: nativeRows.length === independentRows.length ? 0 : 1,
      emptyRows: matched && (nativeRows.length === 0 || independentRows.length === 0) ? 1 : 0,
      date: 0,
      amount: 0,
      kind: 0,
      title: 0,
      page: 0,
      missingPage: 0,
    };
    const identityMatches = matched
      && hasMaskedAccountKey(nativeFile?.accountKey)
      && hasMaskedAccountKey(independent?.accountKey)
      && nativeFile.accountKey === independent.accountKey;
    const sourceMatches = matched
      && typeof nativeFile?.source === "string"
      && typeof independent?.source === "string"
      && nativeFile.source.length > 0
      && nativeFile.source === independent.source;
    if (matched && !identityMatches) validationErrors.push(`identidad de cuenta distinta o ausente en documento ${index + 1}`);
    const mismatchRows = { date: [], amount: [], kind: [], title: [], page: [] };
    let exactRows = 0;
    let coreExactRows = 0;
    for (let rowIndex = 0; rowIndex < comparedRows; rowIndex += 1) {
      const nativeRow = nativeRows[rowIndex] ?? {};
      const independentRow = independentRows[rowIndex] ?? {};
      let exact = true;
      let coreExact = true;
      if (nativeRow.date !== independentRow.date) {
        mismatches.date += 1;
        mismatchRows.date.push(rowIndex + 1);
        exact = false;
        coreExact = false;
      }
      const amountPair = comparableAmountPair(nativeRow, independentRow);
      if (amountPair === null || amountPair[0] !== amountPair[1]) {
        mismatches.amount += 1;
        mismatchRows.amount.push(rowIndex + 1);
        exact = false;
        coreExact = false;
      }
      if (canonicalKind(nativeRow?.kind) !== canonicalKind(independentRow?.kind)) {
        mismatches.kind += 1;
        mismatchRows.kind.push(rowIndex + 1);
        // A taxonomy difference is still a financial-meaning difference. Keep
        // it separate from date/amount/text diagnostics, but do not certify
        // the file until a reviewer resolves it.
        exact = false;
      }
      if (!titleMatches(nativeRow.title, independentRow.description)) {
        mismatches.title += 1;
        mismatchRows.title.push(rowIndex + 1);
        exact = false;
        coreExact = false;
      }
      if (nativeRow.page == null || independentRow.page == null) {
        mismatches.missingPage += 1;
        mismatchRows.page.push(rowIndex + 1);
        exact = false;
        coreExact = false;
      } else if (nativeRow.page !== independentRow.page) {
        mismatches.page += 1;
        mismatchRows.page.push(rowIndex + 1);
        exact = false;
        coreExact = false;
      }
      if (coreExact) coreExactRows += 1;
      if (exact) exactRows += 1;
    }
    if (!matched) validationErrors.push(`falta referencia para documento ${index + 1}`);
    if (matched && !sourceMatches) validationErrors.push(`emisor ausente o distinto en documento ${index + 1}`);
    if (matched && nativeFile?.status !== "valid") validationErrors.push(`estado nativo no válido en documento ${index + 1}`);
    if (matched && independent?.reconciliation?.status !== "valid") validationErrors.push(`estado independiente no válido en documento ${index + 1}`);
    if (matched && (nativeRows.length === 0 || independentRows.length === 0)) {
      validationErrors.push(`filas vacías en documento ${index + 1}`);
    }
    const readMismatchTotal = Object.values(mismatches).reduce((sum, value) => sum + value, 0);
    const coreReadMismatchTotal = Object.entries(mismatches)
      .filter(([key]) => key !== "kind")
      .reduce((sum, [, value]) => sum + value, 0);
    const commonValid = matched
      && identityMatches
      && sourceMatches
      && nativeFile?.status === "valid"
      && independent?.reconciliation?.status === "valid"
      && nativeRows.length > 0
      && independentRows.length > 0;
    return {
      document: index + 1,
      source: nativeFile?.source ?? "Desconocido",
      nativeMode: nativeFile?.mode ?? "unknown",
      independentMode: independent?.mode ?? "missing",
      nativeStatus: nativeFile?.status ?? "missing",
      independentStatus: independent?.reconciliation?.status ?? "missing",
      matched,
      nativeRows: nativeRows.length,
      independentRows: independentRows.length,
      comparedRows,
      exactRows,
      coreExactRows,
      mismatches,
      mismatchRows,
      semanticReview: mismatches.kind > 0,
      coreOutcome: commonValid && coreReadMismatchTotal === 0 ? "match" : "review",
      outcome: commonValid && readMismatchTotal === 0 ? "match" : "review",
    };
  });

  const summary = documents.reduce((result, document) => {
    result.files += 1;
    if (document.matched) result.matchedFiles += 1;
    if (document.outcome === "match") result.exactFiles += 1;
    else result.filesNeedingReview += 1;
    if (document.coreOutcome === "match") result.coreExactFiles += 1;
    else result.coreFilesNeedingReview += 1;
    result.nativeRows += document.nativeRows;
    result.independentRows += document.independentRows;
    result.comparedRows += document.comparedRows;
    result.exactRows += document.exactRows;
    result.coreExactRows += document.coreExactRows;
    for (const key of Object.keys(result.mismatches)) result.mismatches[key] += document.mismatches[key];
    return result;
  }, {
    files: 0,
    matchedFiles: 0,
    exactFiles: 0,
    filesNeedingReview: 0,
    coreExactFiles: 0,
    coreFilesNeedingReview: 0,
    nativeRows: 0,
    independentRows: 0,
    comparedRows: 0,
    exactRows: 0,
    coreExactRows: 0,
    mismatches: { rowCount: 0, emptyRows: 0, date: 0, amount: 0, kind: 0, title: 0, page: 0, missingPage: 0 },
  });

  return {
    // Version 2 makes the strict outcome explicit: classification mismatches
    // now keep a document in review, while coreOutcome remains diagnostic.
    schemaVersion: 2,
    referenceMethod: "independent-reader-comparison",
    validation: { ok: validationErrors.length === 0, errors: validationErrors },
    nativeReaderVersion: nativeReport?.readerVersion ?? "",
    independentReaderVersion: independentReport?.readerVersion ?? "",
    summary,
    documents,
  };
}

function argument(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

async function main() {
  const nativePath = argument("--native");
  const independentPath = argument("--independent");
  const outputPath = argument("--out");
  if (!nativePath || !independentPath) {
    console.error("Uso: node scripts/compare-independent-row-readers.mjs --native <json> --independent <json> [--out <json>]");
    process.exitCode = 2;
    return;
  }
  const comparison = compareIndependentRowReaders(
    JSON.parse(await readFile(nativePath, "utf8")),
    JSON.parse(await readFile(independentPath, "utf8")),
  );
  const serialized = `${JSON.stringify(comparison, null, 2)}\n`;
  if (outputPath) await writeFile(outputPath, serialized, "utf8");
  console.log(serialized);
  if (!comparison.validation.ok) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
