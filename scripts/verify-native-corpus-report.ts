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

function numberField(summary: NativeCorpusSummary, key: keyof NativeCorpusSummary) {
  const value = Number(summary[key]);
  return Number.isFinite(value) ? value : undefined;
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
  const files = numberField(summary, "files");
  const accepted = numberField(summary, "accepted");
  const blocked = numberField(summary, "blocked");
  const expectedValid = numberField(summary, "expectedValid");
  const expectedPending = numberField(summary, "expectedPending");
  const goldenAutoAccepted = numberField(summary, "goldenAutoAccepted");
  const goldenFalseAccepted = numberField(summary, "goldenFalseAccepted");
  const precision = numberField(summary, "automaticAcceptancePrecision");
  const unresolvedOCR = numberField(summary, "unresolvedOCR");

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
  if (precision === undefined || precision < 0.99) errors.push(`precisión automática ${precision ?? "ausente"} < 0.99`);
  if (unresolvedOCR === undefined || unresolvedOCR !== 0) errors.push(`quedan ${unresolvedOCR ?? "desconocido"} OCR sin resolver`);
  if (!booleanField(summary.certified)) errors.push("el runner no marcó certified=true");

  return { ok: errors.length === 0, errors, summary };
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
  console.log(JSON.stringify({ ...summary, verified: result.ok, errors: result.errors }, null, 2));
  if (requireCertified && !result.ok) process.exitCode = 1;
}

const invokedPath = process.argv[1]?.replaceAll("\\", "/");
if (invokedPath && import.meta.url.endsWith(invokedPath)) {
  await main();
}
