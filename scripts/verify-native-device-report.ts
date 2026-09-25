import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

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
  goldenRowAuditPassed?: unknown;
  goldenRowAuditMismatches?: unknown;
  independentOCRProof?: unknown;
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
  goldenRowAuditsPassed?: unknown;
  goldenRowAuditsExpected?: unknown;
  goldenRowAuditMismatches?: unknown;
  independentProofFiles?: unknown;
  independentProofExpected?: unknown;
  rowGoldensComplete?: unknown;
  certified?: unknown;
  certificationScope?: unknown;
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

type VerifyOptions = {
  expectedFiles?: number;
  requireRowAudit?: boolean;
  requireIndependentProof?: boolean;
};

function booleanToken(value: unknown) {
  return value === true || ["true", "1", "yes"].includes(String(value ?? "").trim().toLowerCase());
}

export function verifyNativeDeviceReport(
  report: DeviceReport,
  expectedReaderVersion: string,
  minimumFiles: number,
  options: VerifyOptions = {},
) {
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
  const certificationScope = String(report.certificationScope ?? "general");
  const focusedRappi = certificationScope === "rappi-focused";
  const effectiveMinimumFiles = focusedRappi ? 6 : minimumFiles;
  if (!["general", "rappi-focused"].includes(certificationScope)) {
    errors.push(`certificationScope inválido: ${certificationScope}`);
  }
  if (!Array.isArray(report.files)) errors.push("files debe ser una lista");
  if (files.length < effectiveMinimumFiles) errors.push(`el informe contiene ${files.length} archivo(s); se requieren al menos ${effectiveMinimumFiles} para ${certificationScope}`);
  if (options.expectedFiles !== undefined && files.length !== options.expectedFiles) {
    errors.push(`el informe contiene ${files.length} archivo(s); se requieren exactamente ${options.expectedFiles}`);
  }
  if (focusedRappi && files.some((raw) => {
    const row = raw && typeof raw === "object" ? raw as DeviceFile : {};
    return row.source !== "Rappi" || row.kind !== "card" || !["pdf-text", "vision-ocr"].includes(String(row.mode));
  })) {
    errors.push("el perfil rappi-focused solo permite archivos Rappi de tarjeta procesados con texto nativo u OCR visual");
  }
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
  if (options.requireRowAudit) {
    const passed = numberValue(report.goldenRowAuditsPassed);
    const expected = numberValue(report.goldenRowAuditsExpected);
    const mismatches = numberValue(report.goldenRowAuditMismatches);
    if (report.rowGoldensComplete !== true) errors.push("el informe no confirma goldens completos por fila");
    if (!Number.isInteger(passed) || !Number.isInteger(expected) || !Number.isInteger(mismatches)) {
      errors.push("faltan contadores de auditoría exacta por fila");
    } else {
      if (expected !== files.length) errors.push("goldenRowAuditsExpected no coincide con files");
      if (passed !== expected) errors.push("no todos los archivos tienen auditoría exacta aprobada");
      if (mismatches !== 0) errors.push(`hay ${mismatches} discrepancias de filas`);
    }
  }
  if (options.requireIndependentProof) {
    const proofFiles = numberValue(report.independentProofFiles);
    const proofExpected = numberValue(report.independentProofExpected);
    if (!Number.isInteger(proofFiles) || !Number.isInteger(proofExpected) || proofFiles !== proofExpected) {
      errors.push("la prueba independiente de OCR está incompleta");
    }
  }
  if (report.certified !== true) errors.push("el dispositivo no marcó certified=true");

  const seenFiles = new Set<string>();
  const seenFingerprints = new Set<string>();
  files.forEach((raw, index) => {
    const row = raw && typeof raw === "object" ? raw as DeviceFile : {};
    const label = typeof row.file === "string" && row.file.trim() ? row.file.trim() : `fila ${index + 1}`;
    if (!/^document-\d{2,}\.pdf$/i.test(label)) errors.push(`${label}: nombre de archivo no está redactado`);
    const expectedLabel = `document-${String(index + 1).padStart(2, "0")}.pdf`;
    if (label.toLowerCase() !== expectedLabel) errors.push(`${label}: ordinal de archivo redactado inesperado (se esperaba ${expectedLabel})`);
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
    if (row.status === "valid" && row.kind === "unknown") errors.push(`${label}: un estado válido no puede conservar kind=unknown`);
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
    else if (row.status === "valid" && rows < 1) errors.push(`${label}: un estado válido debe contener al menos una fila`);
    if (row.mode === "vision-ocr" || row.mode === "multimodal-ai") {
      const confidence = numberValue(row.ocrConfidence);
      const weakest = numberValue(row.weakestOCRPage);
      const independentProof = booleanToken(row.independentOCRProof);
      // Raw Vision scores can be conservative for difficult statements. The
      // native reader permits that case only when exact independent row proof
      // and reconciliation succeeded. Without that proof, these thresholds
      // remain hard blockers for the release artifact.
      if (!independentProof && (!Number.isFinite(confidence) || confidence < 0.88)) {
        errors.push(`${label}: confianza OCR media menor a 88%`);
      }
      if (!independentProof && (!Number.isFinite(weakest) || weakest < 0.78)) {
        errors.push(`${label}: página OCR menor a 78%`);
      }
      // Column calibration is a bank-statement invariant. Card layouts such
      // as Rappi do not expose bank columns and therefore intentionally omit
      // this field. Santander still requires explicit calibration.
      if (row.mode === "vision-ocr" && row.source === "Santander" && row.ocrColumnsCalibrated !== true) {
        errors.push(`${label}: columnas Santander sin calibrar`);
      }
    }
    if (options.requireRowAudit && row.status === "valid") {
      if (!booleanToken(row.goldenRowAuditPassed)) errors.push(`${label}: auditoría exacta por fila no aprobada`);
      const mismatches = numberValue(row.goldenRowAuditMismatches);
      if (!Number.isInteger(mismatches) || mismatches !== 0) errors.push(`${label}: discrepancias en auditoría exacta por fila`);
    }
    if (options.requireIndependentProof && row.status === "valid"
        && (row.mode === "vision-ocr" || row.mode === "multimodal-ai")
        && !booleanToken(row.independentOCRProof)) {
      errors.push(`${label}: falta prueba independiente de OCR`);
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
  const expectedFilesRaw = option("--expected-files");
  const expectedFiles = expectedFilesRaw === undefined ? undefined : Number(expectedFilesRaw);
  const requireRowAudit = process.argv.includes("--require-row-audit");
  const requireIndependentProof = process.argv.includes("--require-independent-proof");
  if (!reportPath || !expectedReaderVersion || !Number.isInteger(minimumFiles) || minimumFiles < 1
      || (expectedFiles !== undefined && (!Number.isInteger(expectedFiles) || expectedFiles < 1))) {
    console.error("Uso: npm run pdf:native:verify-device -- --report artifacts/native-corpus-certification.json --reader-version ios-reader-... --minimum-files 10 [--expected-files 22 --require-row-audit --require-independent-proof]");
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
  const result = verifyNativeDeviceReport(report, expectedReaderVersion, minimumFiles, {
    expectedFiles,
    requireRowAudit,
    requireIndependentProof,
  });
  console.log(JSON.stringify({ verified: result.ok, readerVersion: report.readerVersion, files: Array.isArray(report.files) ? report.files.length : 0, errors: result.errors }, null, 2));
  if (!result.ok) process.exitCode = 1;
}

const invokedPath = process.argv[1];
const invokedUrl = invokedPath ? pathToFileURL(resolve(invokedPath)).href : undefined;
if (invokedUrl && import.meta.url === invokedUrl) {
  await main();
}
