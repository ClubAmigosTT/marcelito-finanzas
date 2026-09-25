import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { verifyNativeCorpusReport, verifyNativeCorpusSummary } from "./verify-native-corpus-report.ts";
import { verifyNativeDeviceReport } from "./verify-native-device-report.ts";

type RawSummary = Record<string, unknown> & { readerVersion?: unknown };
type RawRow = Record<string, unknown>;

function option(name: string) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function numberValue(value: unknown) {
  if (typeof value === "number") return value;
  if (typeof value === "string" && value.trim()) return Number(value.trim().replace(/^(-?\d+),(\d+)$/, "$1.$2"));
  return Number.NaN;
}

function integerValue(value: unknown, label: string) {
  const parsed = numberValue(value);
  if (!Number.isInteger(parsed) || parsed < 0) throw new Error(`${label} no es un entero no negativo`);
  return parsed;
}

function booleanValue(value: unknown) {
  return value === true || ["true", "1", "yes"].includes(String(value ?? "").trim().toLowerCase());
}

function lastJSON<T>(raw: string, prefix: string, suffix: string) {
  const matches = [...raw.matchAll(new RegExp(`^${prefix}\\s+(${suffix})\\s*$`, "gm"))];
  if (!matches.length) throw new Error(`No se encontró ${prefix} en el log`);
  return JSON.parse(matches.at(-1)?.[1] ?? "") as T;
}

/**
 * Converts the private XCTest log into the small, redacted artifact consumed
 * by the TestFlight gate. The log may contain private expected/extracted
 * amounts; this output copies only hashes, masked account keys, counts and
 * quality booleans, so the artifact is safe to review in the repository.
 */
function redactedDeviceRow(row: RawRow, index: number) {
  // Do not carry a private filename into the public artifact. The native
  // runner keeps the original name in its local log for debugging; the
  // distribution report only needs a stable ordinal plus the SHA-256.
  const label = `document-${String(index + 1).padStart(2, "0")}.pdf`;
  const output: Record<string, unknown> = {
    file: label,
    sourceFingerprint: String(row.sourceFingerprint ?? ""),
    source: String(row.source ?? ""),
    accountKey: String(row.accountKey ?? ""),
    kind: String(row.kind ?? ""),
    mode: String(row.mode ?? ""),
    sourceStatus: String(row.sourceStatus ?? ""),
    sourceConfidence: numberValue(row.sourceConfidence),
    status: String(row.status ?? ""),
    requiresReview: booleanValue(row.requiresReview),
    rows: integerValue(row.rows, `${String(row.file ?? "fila")}: rows`),
    reconciliationValid: String(row.status ?? "") === "valid" && !booleanValue(row.requiresReview),
    duplicate: false,
    goldenRowAuditPassed: booleanValue(row.goldenRowAuditPassed),
    goldenRowAuditMismatches: integerValue(row.goldenRowAuditMismatches, `${String(row.file ?? "fila")}: goldenRowAuditMismatches`),
    independentOCRProof: booleanValue(row.independentOCRProof),
  };
  if (row.ocrConfidence !== undefined && String(row.ocrConfidence).trim() !== "") {
    output.ocrConfidence = numberValue(row.ocrConfidence);
  }
  if (row.weakestOCRPage !== undefined && String(row.weakestOCRPage).trim() !== "") {
    output.weakestOCRPage = numberValue(row.weakestOCRPage);
  }
  if (row.ocrColumnsCalibrated !== undefined && String(row.ocrColumnsCalibrated).trim() !== "") {
    output.ocrColumnsCalibrated = booleanValue(row.ocrColumnsCalibrated);
  }
  return output;
}

async function main() {
  const logPath = option("--log");
  const outputPath = option("--output");
  const expectedReaderVersion = option("--reader-version");
  const scope = option("--scope") ?? "general";
  const expectedFilesRaw = option("--expected-files");
  const expectedFiles = expectedFilesRaw === undefined ? undefined : Number(expectedFilesRaw);
  if (!logPath || !outputPath || !["general", "rappi-focused"].includes(scope)
      || (expectedFiles !== undefined && (!Number.isInteger(expectedFiles) || expectedFiles < 1))) {
    console.error("Uso: npm run pdf:native:report -- --log /ruta/xcodebuild.log --output docs/native-corpus-certification.json --reader-version ios-reader-... --expected-files 22 [--scope general]");
    process.exitCode = 2;
    return;
  }

  let raw: string;
  try {
    raw = await readFile(logPath, "utf8");
  } catch {
    console.error("No se pudo leer el log privado del corpus.");
    process.exitCode = 1;
    return;
  }

  let summary: RawSummary;
  let report: unknown;
  try {
    summary = lastJSON<RawSummary>(raw, "NATIVE_CORPUS_SUMMARY", "\\{.*\\}");
    report = lastJSON<unknown>(raw, "NATIVE_CORPUS_REPORT", "\\[.*\\]");
  } catch (error) {
    console.error(String(error instanceof Error ? error.message : error));
    process.exitCode = 1;
    return;
  }

  const readerVersion = expectedReaderVersion ?? String(summary.readerVersion ?? "");
  const summaryResult = verifyNativeCorpusSummary(summary, readerVersion);
  const reportResult = verifyNativeCorpusReport(report, integerValue(summary.files, "summary.files"));
  const sourceRows = reportResult.rows as RawRow[];
  const errors = [...summaryResult.errors, ...reportResult.errors];
  if (expectedFiles !== undefined && sourceRows.length !== expectedFiles) {
    errors.push(`el log contiene ${sourceRows.length} archivo(s); se requieren exactamente ${expectedFiles}`);
  }
  if (!summaryResult.ok || !reportResult.ok || errors.length > 0) {
    console.error(JSON.stringify({ verified: false, errors }, null, 2));
    process.exitCode = 1;
    return;
  }

  let files: Record<string, unknown>[];
  try {
    files = sourceRows.map((row, index) => redactedDeviceRow(row, index));
  } catch (error) {
    console.error(String(error instanceof Error ? error.message : error));
    process.exitCode = 1;
    return;
  }
  const ocrRows = files.filter((row) => ["vision-ocr", "multimodal-ai"].includes(String(row.mode)));
  const deviceReport: Record<string, unknown> = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    readerVersion,
    files,
    accepted: integerValue(summary.accepted, "summary.accepted"),
    blocked: integerValue(summary.blocked, "summary.blocked"),
    expectedValid: integerValue(summary.expectedValid, "summary.expectedValid"),
    expectedPending: integerValue(summary.expectedPending, "summary.expectedPending"),
    goldenAutoAccepted: integerValue(summary.goldenAutoAccepted, "summary.goldenAutoAccepted"),
    goldenFalseAccepted: integerValue(summary.goldenFalseAccepted, "summary.goldenFalseAccepted"),
    automaticAcceptancePrecision: numberValue(summary.automaticAcceptancePrecision),
    unresolvedOCR: integerValue(summary.unresolvedOCR, "summary.unresolvedOCR"),
    goldenRowAuditsPassed: integerValue(summary.goldenRowAuditsPassed, "summary.goldenRowAuditsPassed"),
    goldenRowAuditsExpected: integerValue(summary.goldenRowAuditsExpected, "summary.goldenRowAuditsExpected"),
    goldenRowAuditMismatches: integerValue(summary.goldenRowAuditMismatches, "summary.goldenRowAuditMismatches"),
    independentProofFiles: ocrRows.filter((row) => booleanValue(row.independentOCRProof)).length,
    independentProofExpected: ocrRows.length,
    rowGoldensComplete: booleanValue(summary.rowGoldensComplete),
    certified: booleanValue(summary.certified),
    certificationScope: scope,
    financialDataRedacted: true,
    generatedBy: ocrRows.some((row) => row.mode === "multimodal-ai") ? "ios-hybrid-device" : "ios-vision-device",
  };
  const deviceResult = verifyNativeDeviceReport(
    deviceReport,
    readerVersion,
    scope === "rappi-focused" ? 6 : (expectedFiles ?? files.length),
    {
      expectedFiles: expectedFiles ?? files.length,
      requireRowAudit: true,
      requireIndependentProof: true,
    },
  );
  if (!deviceResult.ok) {
    console.error(JSON.stringify({ verified: false, errors: deviceResult.errors }, null, 2));
    process.exitCode = 1;
    return;
  }

  const absoluteOutput = resolve(outputPath);
  await writeFile(absoluteOutput, `${JSON.stringify(deviceReport, null, 2)}\n`, "utf8");
  console.log(JSON.stringify({ verified: true, output: absoluteOutput, files: files.length, readerVersion }, null, 2));
}

const invokedPath = process.argv[1];
const invokedUrl = invokedPath ? pathToFileURL(resolve(invokedPath)).href : undefined;
if (invokedUrl && import.meta.url === invokedUrl) {
  await main();
}
