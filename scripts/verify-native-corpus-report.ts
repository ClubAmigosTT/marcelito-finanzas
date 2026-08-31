import { readFile } from "node:fs/promises";

type NativeCorpusSummary = {
  readerVersion?: string;
  files?: string | number;
  accepted?: string | number;
  blocked?: string | number;
  expectedValid?: string | number;
  expectedPending?: string | number;
  goldenAutoAccepted?: string | number;
  goldenFalseAccepted?: string | number;
  automaticAcceptancePrecision?: string | number;
  unresolvedOCR?: string | number;
  certified?: string | boolean;
};

type Verification = {
  ok: boolean;
  errors: string[];
  summary: NativeCorpusSummary;
};

type NativeCorpusReportRow = {
  file?: string;
  accountKey?: string;
  expectedAccountKey?: string;
};

type ReportVerification = {
  ok: boolean;
  errors: string[];
  rows: NativeCorpusReportRow[];
};

function numberField(summary: NativeCorpusSummary, key: keyof NativeCorpusSummary) {
  const value = Number(summary[key]);
  return Number.isFinite(value) ? value : undefined;
}

function countField(summary: NativeCorpusSummary, key: keyof NativeCorpusSummary) {
  const value = numberField(summary, key);
  return value !== undefined && Number.isInteger(value) && value >= 0 ? value : undefined;
}

function booleanField(value: NativeCorpusSummary["certified"]) {
  return value === true || ["true", "1", "yes"].includes(String(value ?? "").toLowerCase());
}

/**
 * Verifies the machine-readable native Vision result before a human copies
 * its certification into the distribution gate. This intentionally accepts
 * only the summary emitted by NativeCorpusContractTests, never a hand-written
 * boolean or a partial log.
 */
export function verifyNativeCorpusSummary(summary: NativeCorpusSummary, expectedReaderVersion?: string): Verification {
  const errors: string[] = [];
  const files = countField(summary, "files");
  const accepted = countField(summary, "accepted");
  const blocked = countField(summary, "blocked");
  const expectedValid = countField(summary, "expectedValid");
  const expectedPending = countField(summary, "expectedPending");
  const goldenAutoAccepted = countField(summary, "goldenAutoAccepted");
  const goldenFalseAccepted = countField(summary, "goldenFalseAccepted");
  const precision = numberField(summary, "automaticAcceptancePrecision");
  const unresolvedOCR = countField(summary, "unresolvedOCR");

  if (!summary.readerVersion) errors.push("el informe no incluye readerVersion");
  if (expectedReaderVersion && summary.readerVersion !== expectedReaderVersion) {
    errors.push(`readerVersion ${summary.readerVersion ?? "vacía"} no coincide con ${expectedReaderVersion}`);
  }
  if (files === undefined || accepted === undefined || blocked === undefined || files !== accepted + blocked) {
    errors.push("files no coincide con accepted + blocked");
  }
  if (expectedValid === undefined || expectedPending === undefined) errors.push("faltan expectedValid/expectedPending");
  if (goldenAutoAccepted === undefined || goldenFalseAccepted === undefined) errors.push("faltan contadores golden");
  if (goldenFalseAccepted !== undefined && goldenFalseAccepted !== 0) errors.push(`hay ${goldenFalseAccepted} aceptación(es) falsa(s)`);
  if (expectedPending !== undefined && expectedPending !== 0) errors.push(`quedan ${expectedPending} golden(s) pendientes`);
  if (expectedValid !== undefined && goldenAutoAccepted !== undefined && goldenAutoAccepted !== expectedValid) {
    errors.push(`goldenAutoAccepted ${goldenAutoAccepted} no coincide con expectedValid ${expectedValid}`);
  }
  if (precision === undefined || precision < 0 || precision > 1 || precision < 0.99) {
    errors.push(`precisión automática ${precision ?? "ausente"} fuera del objetivo 0.99`);
  }
  if (unresolvedOCR === undefined || unresolvedOCR !== 0) errors.push(`quedan ${unresolvedOCR ?? "desconocido"} OCR sin resolver`);
  if (!booleanField(summary.certified)) errors.push("el runner no marcó certified=true");

  return { ok: errors.length === 0, errors, summary };
}

/**
 * Verifies the per-file portion emitted by NativeCorpusContractTests. The
 * summary is intentionally insufficient on its own: a forged or truncated
 * summary could otherwise claim certification without proving every PDF's
 * account identity. Only issuer-scoped last-four keys are allowed.
 */
export function verifyNativeCorpusReport(report: unknown, expectedFiles?: number): ReportVerification {
  const errors: string[] = [];
  const rawRows = Array.isArray(report) ? report : [];
  const rows = rawRows.filter((row): row is NativeCorpusReportRow => Boolean(row) && typeof row === "object");
  if (!Array.isArray(report)) errors.push("NATIVE_CORPUS_REPORT no contiene una lista");
  if (Array.isArray(report) && rows.length !== rawRows.length) {
    errors.push("NATIVE_CORPUS_REPORT contiene filas inválidas");
  }
  if (expectedFiles !== undefined && rows.length !== expectedFiles) {
    errors.push(`el reporte contiene ${rows.length} fila(s), esperado ${expectedFiles}`);
  }
  const files = rows.map((row) => typeof row.file === "string" ? row.file.trim() : "");
  if (files.some((file) => !file)) errors.push("el reporte contiene una fila sin nombre de archivo");
  if (new Set(files).size !== files.length) errors.push("el reporte contiene archivos duplicados");
  rows.forEach((row, index) => {
    const label = files[index] || `fila ${index + 1}`;
    const actual = typeof row.accountKey === "string" ? row.accountKey.trim() : "";
    const expected = typeof row.expectedAccountKey === "string" ? row.expectedAccountKey.trim() : "";
    if (!actual || !/^[a-z0-9]+:\d{4}$/i.test(actual)) {
      errors.push(`${label}: accountKey no está en formato emisor:últimos4`);
    }
    if (expected && actual !== expected) {
      errors.push(`${label}: accountKey ${actual || "ausente"} no coincide con ${expected}`);
    }
  });
  return { ok: errors.length === 0, errors, rows };
}

function option(name: string) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

async function main() {
  const logPath = option("--log") ?? process.argv[2];
  const expectedReaderVersion = option("--reader-version");
  const requireCertified = process.argv.includes("--require-certified");
  if (!logPath) {
    console.error("Uso: npm run pdf:native:verify -- --log /ruta/xcodebuild.log --reader-version ios-reader-...");
    process.exitCode = 2;
    return;
  }

  const raw = await readFile(logPath, "utf8");
  const matches = [...raw.matchAll(/^NATIVE_CORPUS_SUMMARY\s+(\{.*\})\s*$/gm)];
  if (!matches.length) {
    console.error("No se encontró NATIVE_CORPUS_SUMMARY en el log; no se puede certificar.");
    process.exitCode = 1;
    return;
  }
  let summary: NativeCorpusSummary;
  try {
    summary = JSON.parse(matches.at(-1)?.[1] ?? "") as NativeCorpusSummary;
  } catch {
    console.error("NATIVE_CORPUS_SUMMARY no contiene JSON válido.");
    process.exitCode = 1;
    return;
  }

  const result = verifyNativeCorpusSummary(summary, expectedReaderVersion);
  const reportMatches = [...raw.matchAll(/^NATIVE_CORPUS_REPORT\s+(\[.*\])\s*$/gm)];
  let reportResult: ReportVerification | undefined;
  if (reportMatches.length) {
    try {
      const report = JSON.parse(reportMatches.at(-1)?.[1] ?? "") as unknown;
      reportResult = verifyNativeCorpusReport(report, numberField(summary, "files"));
    } catch {
      reportResult = { ok: false, errors: ["NATIVE_CORPUS_REPORT no contiene JSON válido"], rows: [] };
    }
  } else {
    reportResult = { ok: false, errors: ["No se encontró NATIVE_CORPUS_REPORT en el log"], rows: [] };
  }
  const errors = [...result.errors, ...reportResult.errors];
  const verified = result.ok && reportResult.ok;
  console.log(JSON.stringify({ ...summary, verified, errors }, null, 2));
  if (requireCertified && !verified) process.exitCode = 1;
}

const invokedPath = process.argv[1]?.replaceAll("\\", "/");
if (invokedPath && import.meta.url.endsWith(invokedPath)) {
  await main();
}
