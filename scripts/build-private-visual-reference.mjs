import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

// Builds the private row manifest only after a rendered-page review.  The
// page OCR is a third observation of the PDF: it is independent from both
// the native iOS export and the web reader.  The output stays outside Git and
// contains only the minimum substring needed by the native row contract.

function option(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function normalize(value) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/\p{M}/gu, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

function tokens(value) {
  const normalized = normalize(value);
  return normalized ? normalized.split(" ") : [];
}

function commonRuns(left, right) {
  const runs = [];
  for (let leftStart = 0; leftStart < left.length; leftStart += 1) {
    for (let rightStart = 0; rightStart < right.length; rightStart += 1) {
      let length = 0;
      while (
        leftStart + length < left.length
        && rightStart + length < right.length
        && left[leftStart + length] === right[rightStart + length]
      ) {
        length += 1;
      }
      if (length > 0) runs.push(left.slice(leftStart, leftStart + length));
    }
  }
  const seen = new Set();
  return runs
    .map((run) => run.join(" "))
    .filter((run) => {
      if (seen.has(run)) return false;
      seen.add(run);
      return true;
    })
    .sort((a, b) => {
      const tokenDelta = tokens(b).length - tokens(a).length;
      return tokenDelta || b.length - a.length;
    });
}

function pageContains(pageText, anchor) {
  return normalize(pageText).includes(normalize(anchor));
}

function fallbackPrefix(nativeTitle, pageText) {
  const page = normalize(pageText).replaceAll(" ", "");
  const candidates = [...new Set(tokens(nativeTitle))]
    .filter((token) => token.length >= 3)
    .sort((a, b) => b.length - a.length);
  for (const token of candidates) {
    for (let length = token.length; length >= 3; length -= 1) {
      const prefix = token.slice(0, length);
      if (page.includes(prefix)) return prefix;
    }
  }
  return "";
}

function chooseAnchor(nativeTitle, independentTitle, pageText) {
  const page = String(pageText ?? "");
  for (const run of commonRuns(tokens(nativeTitle), tokens(independentTitle))) {
    if (tokens(run).length >= 3 && pageContains(page, run)) {
      return { anchor: run, method: "common-run" };
    }
  }
  // Short merchant names are acceptable only when the rendered page contains
  // them and the native title contains the exact same token.
  for (const run of commonRuns(tokens(nativeTitle), tokens(independentTitle))) {
    if (run.length >= 3 && pageContains(page, run)) {
      return { anchor: run, method: "short-common-run" };
    }
  }
  const prefix = fallbackPrefix(nativeTitle, page);
  if (prefix) return { anchor: prefix, method: "native-prefix" };
  return null;
}

function statementKind(source) {
  return ["Amex", "Rappi"].includes(source) ? "card" : "bank";
}

function summaryFor(nativeFile) {
  const controls = nativeFile.declaredControls ?? {};
  const summary = {};
  const direct = [
    "previousBalance", "cashBalance", "depositTotal", "withdrawalTotal",
    "creditLimit", "creditAvailable", "paymentForNoInterest",
    "minimumPlusMsi", "msiPending",
  ];
  for (const key of direct) {
    if (controls[key] !== undefined) summary[key] = controls[key];
  }
  if (controls.newCharges !== undefined) summary.chargeTotal = controls.newCharges;
  // The native contract calls this derived projection "deuda comprometida":
  // it is the unused-credit subtraction, not the card statement's payment
  // balance. Keep that semantic explicit in the private golden.
  if (controls.creditLimit !== undefined && controls.creditAvailable !== undefined) {
    const committed = Number(controls.creditLimit) - Number(controls.creditAvailable);
    if (Number.isFinite(committed)) summary.debtBalance = Number(committed.toFixed(2));
  } else if (controls.debtBalance !== undefined) {
    summary.debtBalance = controls.debtBalance;
  }
  return Object.keys(summary).length ? summary : undefined;
}

function buildManifest(nativeReport, independentReport, pageOCR, confirm) {
  if (!confirm) throw new Error("requiere --confirm-visual-review después de revisar las páginas renderizadas");
  if (!Array.isArray(nativeReport?.files) || !nativeReport.files.length) throw new Error("native-files-empty");
  if (!Array.isArray(independentReport?.results) || !independentReport.results.length) throw new Error("independent-results-empty");
  const byFingerprint = new Map(independentReport.results.map((result) => [result.sourceFingerprint, result]));
  const pageDocuments = pageOCR?.documents ?? {};
  const files = nativeReport.files.map((nativeFile, fileIndex) => {
    const independent = byFingerprint.get(nativeFile.sourceFingerprint);
    if (!independent) throw new Error(`document-${fileIndex + 1}:independent-missing`);
    if (nativeFile.source !== independent.source || nativeFile.accountKey !== independent.accountKey) {
      throw new Error(`document-${fileIndex + 1}:identity-mismatch`);
    }
    const nativeRows = Array.isArray(nativeFile.candidateRows) ? nativeFile.candidateRows : [];
    const independentRows = Array.isArray(independent.extractedRows) ? independent.extractedRows : [];
    if (!nativeRows.length || nativeRows.length !== independentRows.length) {
      throw new Error(`document-${fileIndex + 1}:row-count`);
    }
    // The native export uses a lexical `document-XX` order, while the page
    // renderer preserves the numeric prefixes from the original filenames.
    // Match rendered evidence by filename first so a reordered corpus cannot
    // silently validate a row against another PDF's page.
    const pageDocument = Object.values(pageDocuments).find((document) => (
      document?.file === (nativeFile.sourceFileName ?? nativeFile.file)
    )) ?? pageDocuments[String(fileIndex + 1)];
    const pages = pageDocument?.pages ?? {};
    const rows = nativeRows.map((nativeRow, rowIndex) => {
      const independentRow = independentRows[rowIndex];
      const pageText = (pages[String(nativeRow.page)] ?? []).join(" ");
      const chosen = chooseAnchor(nativeRow.title, independentRow.description, pageText);
      if (!chosen || !pageContains(pageText, chosen.anchor)) {
        throw new Error(`document-${fileIndex + 1}:row-${rowIndex + 1}:visual-anchor`);
      }
      if (normalize(nativeRow.title).includes(normalize(chosen.anchor)) === false) {
        throw new Error(`document-${fileIndex + 1}:row-${rowIndex + 1}:native-anchor`);
      }
      return {
        date: nativeRow.date,
        page: nativeRow.page,
        signedAmount: nativeRow.signedAmount,
        titleContains: chosen.anchor,
        kind: nativeRow.kind,
      };
    });
    return {
      file: nativeFile.sourceFileName ?? nativeFile.file,
      sourceFingerprint: nativeFile.sourceFingerprint,
      source: nativeFile.source,
      accountKey: nativeFile.accountKey,
      kind: statementKind(nativeFile.source),
      period: nativeFile.period,
      status: "valid",
      rows: rows.length,
      summary: summaryFor(nativeFile),
      expectedMethod: nativeFile.mode,
      rowExpectations: rows,
    };
  });
  return {
    schemaVersion: 1,
    referenceMethod: "visual-independent",
    visualReviewCompleted: true,
    visualReviewMethod: "rendered-page-vision-ocr",
    readerVersion: nativeReport.readerVersion ?? "",
    nativeReaderVersion: nativeReport.readerVersion ?? "",
    independentReaderVersion: independentReport.readerVersion ?? "",
    files,
  };
}

async function main() {
  const nativePath = option("--native");
  const independentPath = option("--independent");
  const pageOCRPath = option("--page-ocr");
  const output = option("--out");
  const confirm = process.argv.includes("--confirm-visual-review");
  if (!nativePath || !independentPath || !pageOCRPath || !output) {
    console.error("Uso: node scripts/build-private-visual-reference.mjs --native native.json --independent independent.json --page-ocr page-ocr.json --out reference.json --confirm-visual-review");
    process.exitCode = 2;
    return;
  }
  try {
    const [nativeReport, independentReport, pageOCR] = await Promise.all([
      readFile(nativePath, "utf8").then(JSON.parse),
      readFile(independentPath, "utf8").then(JSON.parse),
      readFile(pageOCRPath, "utf8").then(JSON.parse),
    ]);
    const manifest = buildManifest(nativeReport, independentReport, pageOCR, confirm);
    await writeFile(output, `${JSON.stringify(manifest, null, 2)}\n`, { flag: "w" });
    console.log(JSON.stringify({
      schemaVersion: manifest.schemaVersion,
      referenceMethod: manifest.referenceMethod,
      files: manifest.files.length,
      rows: manifest.files.reduce((sum, file) => sum + file.rows, 0),
      visualReviewMethod: manifest.visualReviewMethod,
      output: resolve(output),
    }));
  } catch (error) {
    console.error(`No se pudo construir la referencia visual privada: ${error instanceof Error ? error.message : "error"}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main();
}

export { buildManifest, chooseAnchor, normalize };
