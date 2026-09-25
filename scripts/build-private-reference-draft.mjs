import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

// Produces a private candidate reference for a human reviewer. It is not the
// row-golden schema on purpose: candidate fields cannot be passed directly to
// the strict native verifier as visual-independent evidence.

function option(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function requiredString(value, label) {
  if (typeof value !== "string" || !value.trim()) throw new Error(`${label}-missing`);
  return value.trim();
}

export function buildPrivateReferenceDraft(independentReport, nativeReport) {
  if (!Array.isArray(independentReport?.results) || !independentReport.results.length) {
    throw new Error("independent-results-empty");
  }
  if (!Array.isArray(nativeReport?.files) || !nativeReport.files.length) {
    throw new Error("native-files-empty");
  }
  const byFingerprint = new Map(
    independentReport.results.map((result) => [result.sourceFingerprint, result]),
  );
  const files = nativeReport.files.map((nativeFile, index) => {
    const fingerprint = requiredString(nativeFile.sourceFingerprint, `document-${index + 1}-fingerprint`);
    const independent = byFingerprint.get(fingerprint);
    if (!independent) throw new Error(`document-${index + 1}-reference-missing`);
    if (nativeFile.source !== independent.source) throw new Error(`document-${index + 1}-source-mismatch`);
    if (nativeFile.accountKey !== independent.accountKey) throw new Error(`document-${index + 1}-account-mismatch`);
    const rows = Array.isArray(independent.extractedRows) ? independent.extractedRows : [];
    if (!rows.length || rows.length !== nativeFile.candidateRows?.length) {
      throw new Error(`document-${index + 1}-row-count`);
    }
    return {
      document: index + 1,
      file: requiredString(nativeFile.sourceFileName ?? nativeFile.file, `document-${index + 1}-file`),
      sourceFingerprint: fingerprint,
      source: nativeFile.source,
      accountKey: nativeFile.accountKey,
      period: nativeFile.period ?? independent.period ?? "",
      sourceReader: independent.readerVersion ?? "",
      sourceMode: independent.mode ?? "",
      rows: rows.map((row, rowIndex) => ({
        ordinal: rowIndex + 1,
        dateCandidate: row.date ?? "",
        pageCandidate: row.page ?? null,
        signedAmountCandidate: row.signedAmount ?? "",
        titleCandidate: row.description ?? "",
        kindCandidate: row.kind ?? "",
      })),
    };
  });
  return {
    schemaVersion: 1,
    referenceMethod: "independent-reader-candidate",
    visualReviewRequired: true,
    nativeReaderVersion: nativeReport.readerVersion ?? "",
    independentReaderVersion: independentReport.readerVersion ?? "",
    files,
  };
}

async function main() {
  const independentPath = option("--independent");
  const nativePath = option("--native");
  const output = option("--out");
  if (!independentPath || !nativePath || !output) {
    console.error("Uso: node scripts/build-private-reference-draft.mjs --independent /ruta/independent.json --native /ruta/native.json --out /ruta/draft.json");
    process.exitCode = 2;
    return;
  }
  try {
    const [independent, native] = await Promise.all([
      readFile(independentPath, "utf8").then(JSON.parse),
      readFile(nativePath, "utf8").then(JSON.parse),
    ]);
    const draft = buildPrivateReferenceDraft(independent, native);
    await writeFile(output, `${JSON.stringify(draft, null, 2)}\n`, { flag: "w" });
    console.log(JSON.stringify({
      schemaVersion: draft.schemaVersion,
      referenceMethod: draft.referenceMethod,
      files: draft.files.length,
      output: resolve(output),
    }));
  } catch {
    console.error("No se pudo construir el borrador privado. No se imprimieron datos financieros.");
    process.exitCode = 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main();
}
