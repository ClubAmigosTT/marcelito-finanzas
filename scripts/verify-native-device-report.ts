import { readFile } from "node:fs/promises";

type DeviceFile = {
  file?: unknown;
  sourceFingerprint?: unknown;
  source?: unknown;
  accountKey?: unknown;
  kind?: unknown;
  mode?: unknown;
  sourceStatus?: unknown;
  sourceConfidence?: unknown;
  status?: unknown;
  requiresReview?: unknown;
  rows?: unknown;
  ocrConfidence?: unknown;
  weakestOCRPage?: unknown;
  ocrColumnsCalibrated?: unknown;
  reconciliationValid?: unknown;
  duplicate?: unknown;
  errorCode?: unknown;
};

type DeviceReport = {
  schemaVersion?: unknown;
  generatedAt?: unknown;
  readerVersion?: unknown;
  files?: unknown;
  accepted?: unknown;
  blocked?: unknown;
  expectedValid?: unknown;
  expectedPending?: unknown;
  goldenAutoAccepted?: unknown;
  goldenFalseAccepted?: unknown;
  automaticAcceptancePrecision?: unknown;
  unresolvedOCR?: unknown;
  certified?: unknown;
  financialDataRedacted?: unknown;
  generatedBy?: unknown;
};

function option(name: string) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function numberValue(value: unknown) {
  if (typeof value === "number") return value;
  if (typeof value === "string" && value.trim()) return Number(value);
  return Number.NaN;
}

function isBoolean(value: unknown) {
  return typeof value === "boolean";
}

function isHexFingerprint(value: unknown) {
  return typeof value === "string" && /^[a-f0-9]{64}$/i.test(value.trim());
}

function isMaskedAccount(value: unknown) {
  return typeof value === "string" && /^[a-z0-9]+:\d{4}$/i.test(value.trim());
}

export function verifyNativeDeviceReport(report: DeviceReport, expectedReaderVersion: string, minimumFiles: number) {
  const errors: string[] = [];
  if (report.schemaVersion !== 1) errors.push("schemaVersion debe ser 1");
  if (!["ios-vision-device", "ios-hybrid-device"].includes(String(report.generatedBy))) errors.push("generatedBy no corresponde al certificador de iOS");
  if (report.financialDataRedacted !== true) errors.push("el informe no confirma que los datos financieros estén redactados");
  if (report.readerVersion !== expectedReaderVersion) {
    errors.push(`readerVersion ${String(report.readerVersion ?? "vacía")} no coincide con ${expectedReaderVersion}`);
  }

  const files = Array.isArray(report.files) ? report.files : [];
  const accepted = numberValue(report.accepted);
  const blocked = numberValue(report.blocked);
  const precision = numberValue(report.automaticAcceptancePrecision);
  const unresolvedOCR = numberValue(report.unresolvedOCR);
  if (!Array.isArray(report.files)) errors.push("files debe ser una lista");
  if (files.length < minimumFiles) errors.push(`el informe contiene ${files.length} archivo(s); se requieren al menos ${minimumFiles}`);
  if (!Number.isInteger(accepted) || accepted < 0) errors.push("accepted no es un entero válido");
  if (!Number.isInteger(blocked) || blocked < 0) errors.push("blocked no es un entero válido");
  if (Number.isInteger(accepted) && Number.isInteger(blocked) && accepted + blocked !== files.length) {
    errors.push("accepted + blocked no coincide con files");
  }
  if (!Number.isFinite(precision) || precision < 0.97 || precision > 1) errors.push("precisión automática menor a 97%");
  if (unresolvedOCR !== 0) errors.push(`quedan ${Number.isFinite(unresolvedOCR) ? unresolvedOCR : "desconocido"} OCR pendientes`);
  if (report.expectedValid !== files.length) errors.push("expectedValid no coincide con el número de archivos");
  if (report.expectedPending !== 0) errors.push("expectedPending debe ser 0");
  if (report.goldenAutoAccepted !== accepted) errors.push("goldenAutoAccepted no coincide con accepted");
  if (report.goldenFalseAccepted !== 0) errors.push("goldenFalseAccepted debe ser 0");
  if (report.certified !== true) errors.push("el dispositivo no marcó certified=true");

  const seenFiles = new Set<string>();
  const seenFingerprints = new Set<string>();
  files.forEach((raw, index) => {
    const row = raw && typeof raw === "object" ? raw as DeviceFile : {};
    const label = typeof row.file === "string" && row.file.trim() ? row.file.trim() : `fila ${index + 1}`;
    if (seenFiles.has(label)) errors.push(`${label}: archivo duplicado`);
    seenFiles.add(label);
    if (!isHexFingerprint(row.sourceFingerprint)) errors.push(`${label}: sourceFingerprint inválido`);
    else {
      const fingerprint = String(row.sourceFingerprint).toLowerCase();
      if (seenFingerprints.has(fingerprint)) errors.push(`${label}: huella PDF duplicada`);
      seenFingerprints.add(fingerprint);
    }
    if (typeof row.source !== "string" || !row.source.trim() || row.source === "Desconocido") errors.push(`${label}: emisor no identificado`);
    if (!isMaskedAccount(row.accountKey)) errors.push(`${label}: accountKey no está en formato emisor:últimos4`);
    if (!(["bank", "card", "unknown"] as unknown[]).includes(row.kind)) errors.push(`${label}: kind inválido`);
    if (!(["pdf-text", "vision-ocr", "multimodal-ai"] as unknown[]).includes(row.mode)) errors.push(`${label}: mode inválido`);
    if (row.sourceStatus !== "verified") errors.push(`${label}: sourceStatus no es verified`);
    const sourceConfidence = numberValue(row.sourceConfidence);
    if (!Number.isFinite(sourceConfidence) || sourceConfidence < 0 || sourceConfidence > 1) errors.push(`${label}: sourceConfidence inválida`);
    if (!(["valid", "pending", "invalid"] as unknown[]).includes(row.status)) errors.push(`${label}: status inválido`);
    if (!isBoolean(row.requiresReview)) errors.push(`${label}: requiresReview no es booleano`);
    if (row.reconciliationValid !== true) errors.push(`${label}: conciliación no válida`);
    if (row.duplicate === true) errors.push(`${label}: PDF duplicado`);
    const rows = numberValue(row.rows);
    if (!Number.isInteger(rows) || rows < 0) errors.push(`${label}: rows inválido`);
    if (row.mode === "vision-ocr" || row.mode === "multimodal-ai") {
      const confidence = numberValue(row.ocrConfidence);
      const weakest = numberValue(row.weakestOCRPage);
      if (!Number.isFinite(confidence) || confidence < 0.88) errors.push(`${label}: confianza OCR media menor a 88%`);
      if (!Number.isFinite(weakest) || weakest < 0.78) errors.push(`${label}: página OCR menor a 78%`);
      if (row.mode === "vision-ocr" && row.source === "Santander" && row.ocrColumnsCalibrated !== true) errors.push(`${label}: columnas Santander sin calibrar`);
    }
    if (row.status !== "valid" || row.requiresReview !== false || row.reconciliationValid !== true) {
      errors.push(`${label}: el archivo no quedó aceptado por el lector`);
    }
  });

  return { ok: errors.length === 0, errors };
}

async function main() {
  const reportPath = option("--report");
  const expectedReaderVersion = option("--reader-version");
  const minimumFiles = Number(option("--minimum-files") ?? 10);
  if (!reportPath || !expectedReaderVersion || !Number.isInteger(minimumFiles) || minimumFiles < 1) {
    console.error("Uso: npm run pdf:native:verify-device -- --report artifacts/native-corpus-certification.json --reader-version ios-reader-... --minimum-files 10");
    process.exitCode = 2;
    return;
  }
  let report: DeviceReport;
  try {
    report = JSON.parse(await readFile(reportPath, "utf8")) as DeviceReport;
  } catch {
    console.error("No se pudo leer el informe de certificación del dispositivo.");
    process.exitCode = 1;
    return;
  }
  const result = verifyNativeDeviceReport(report, expectedReaderVersion, minimumFiles);
  console.log(JSON.stringify({ verified: result.ok, readerVersion: report.readerVersion, files: Array.isArray(report.files) ? report.files.length : 0, errors: result.errors }, null, 2));
  if (!result.ok) process.exitCode = 1;
}

const invokedPath = process.argv[1]?.replaceAll("\\", "/");
if (invokedPath && import.meta.url.endsWith(invokedPath)) {
  await main();
}
