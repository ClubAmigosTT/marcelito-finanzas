import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

// Builds a private, redacted worklist from the strict reader comparison. The
// queue identifies only document/row ordinals and mismatch categories; it is
// deliberately insufficient to reconstruct a statement.

const mismatchKeys = ["date", "amount", "kind", "title", "page", "missingPage"];

function option(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function rowOrdinals(document) {
  const ordinals = new Set();
  for (const key of mismatchKeys) {
    for (const value of document?.mismatchRows?.[key] ?? []) {
      if (Number.isInteger(value) && value > 0) ordinals.add(value);
    }
  }
  return [...ordinals].sort((left, right) => left - right);
}

export function buildPrivateReviewQueue(comparison) {
  if (comparison?.schemaVersion !== 2) throw new Error("comparison-schema");
  if (comparison?.referenceMethod !== "independent-reader-comparison") {
    throw new Error("comparison-method");
  }
  if (comparison?.validation?.ok !== true) throw new Error("comparison-invalid");
  const documents = Array.isArray(comparison.documents) ? comparison.documents : [];
  if (!documents.length) throw new Error("comparison-empty");

  const queuedDocuments = documents.map((document) => {
    const rows = rowOrdinals(document);
    const mismatchCounts = Object.fromEntries(
      mismatchKeys.map((key) => [key, Number.isInteger(document?.mismatches?.[key])
        ? document.mismatches[key] : 0]),
    );
    return {
      document: document.document,
      source: document.source,
      nativeMode: document.nativeMode,
      independentMode: document.independentMode,
      nativeRows: document.nativeRows,
      independentRows: document.independentRows,
      coreOutcome: document.coreOutcome,
      outcome: document.outcome,
      semanticReview: document.semanticReview === true,
      mismatchCounts,
      rowOrdinals: rows,
    };
  });

  const queued = queuedDocuments.filter((document) => document.outcome !== "match");
  const queuedRows = new Set(
    queued.flatMap((document) => document.rowOrdinals.map((row) => `${document.document}:${row}`)),
  ).size;
  return {
    schemaVersion: 1,
    referenceMethod: "private-visual-review-queue",
    comparisonSchemaVersion: comparison.schemaVersion,
    nativeReaderVersion: comparison.nativeReaderVersion ?? "",
    independentReaderVersion: comparison.independentReaderVersion ?? "",
    summary: {
      files: documents.length,
      queuedFiles: queued.length,
      queuedRows,
      strictExactFiles: documents.length - queued.length,
      coreExactFiles: Number(comparison.summary?.coreExactFiles ?? 0),
    },
    documents: queuedDocuments,
  };
}

async function main() {
  const input = option("--comparison");
  const output = option("--out");
  if (!input || !output) {
    console.error("Uso: node scripts/build-private-review-queue.mjs --comparison /ruta/comparison.json --out /ruta/review-queue.json");
    process.exitCode = 2;
    return;
  }
  try {
    const comparison = JSON.parse(await readFile(input, "utf8"));
    const queue = buildPrivateReviewQueue(comparison);
    await writeFile(output, `${JSON.stringify(queue, null, 2)}\n`, { flag: "w" });
    console.log(JSON.stringify({
      schemaVersion: queue.schemaVersion,
      queuedFiles: queue.summary.queuedFiles,
      queuedRows: queue.summary.queuedRows,
      output: resolve(output),
    }));
  } catch {
    console.error("No se pudo construir la cola privada. No se imprimieron datos financieros.");
    process.exitCode = 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main();
}
