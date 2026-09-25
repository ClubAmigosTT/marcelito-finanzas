import assert from "node:assert/strict";
import test from "node:test";
import { verifyNativeDeviceReport } from "../scripts/verify-native-device-report.ts";

function row(index: number, overrides: Record<string, unknown> = {}) {
  return {
    file: `document-${String(index).padStart(2, "0")}.pdf`,
    sourceFingerprint: String(index).padStart(64, "0"),
    source: "BBVA",
    accountKey: "bbva:3001",
    kind: "bank",
    mode: "pdf-text",
    sourceStatus: "verified",
    sourceConfidence: 0.99,
    status: "valid",
    requiresReview: false,
    rows: 11,
    reconciliationValid: true,
    duplicate: false,
    goldenRowAuditPassed: true,
    goldenRowAuditMismatches: 0,
    independentOCRProof: true,
    ...overrides,
  };
}

function report(rows: Array<Record<string, unknown>>) {
  return {
    schemaVersion: 1,
    generatedBy: "ios-vision-device",
    financialDataRedacted: true,
    readerVersion: "ios-reader-2026.08.31.14",
    files: rows,
    accepted: rows.length,
    blocked: 0,
    expectedValid: rows.length,
    expectedPending: 0,
    goldenAutoAccepted: rows.length,
    goldenFalseAccepted: 0,
    automaticAcceptancePrecision: 1,
    unresolvedOCR: 0,
    goldenRowAuditsPassed: rows.length,
    goldenRowAuditsExpected: rows.length,
    goldenRowAuditMismatches: 0,
    independentProofFiles: rows.filter((row) => ["vision-ocr", "multimodal-ai"].includes(String(row.mode))).length,
    independentProofExpected: rows.filter((row) => ["vision-ocr", "multimodal-ai"].includes(String(row.mode))).length,
    rowGoldensComplete: true,
    certified: true,
  };
}

test("el informe del dispositivo certificado pasa con 10 PDFs únicos", () => {
  const result = verifyNativeDeviceReport(
    report(Array.from({ length: 10 }, (_, index) => row(index + 1))),
    "ios-reader-2026.08.31.14",
    10,
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.errors, []);
});

test("el perfil rappi-focused pasa con seis estados Rappi OCR", () => {
  const rows = Array.from({ length: 6 }, (_, index) => row(index + 1, {
    source: "Rappi",
    accountKey: "rappi:9040",
    kind: "card",
    mode: "vision-ocr",
    ocrConfidence: 0.94,
    weakestOCRPage: 0.84,
  }));
  const result = verifyNativeDeviceReport(
    { ...report(rows), certificationScope: "rappi-focused" },
    "ios-reader-2026.08.31.14",
    10,
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.errors, []);
});

test("el perfil rappi-focused también acepta texto nativo conciliado", () => {
  const rows = Array.from({ length: 6 }, (_, index) => row(index + 1, {
    source: "Rappi",
    accountKey: "rappi:9040",
    kind: "card",
    mode: index === 0 ? "pdf-text" : "vision-ocr",
    ...(index === 0 ? {} : { ocrConfidence: 0.94, weakestOCRPage: 0.84 }),
  }));
  const result = verifyNativeDeviceReport(
    { ...report(rows), certificationScope: "rappi-focused" },
    "ios-reader-2026.08.31.14",
    10,
  );
  assert.equal(result.ok, true);
  assert.deepEqual(result.errors, []);
});

test("el perfil rappi-focused rechaza un conjunto Rappi incompleto o no local", () => {
  const rows = Array.from({ length: 6 }, (_, index) => row(index + 1, {
    source: "Rappi",
    accountKey: "rappi:9040",
    kind: "card",
    mode: "vision-ocr",
    ocrConfidence: 0.94,
    weakestOCRPage: 0.84,
  }));
  rows[5] = row(6, {
    source: "Rappi",
    accountKey: "rappi:9040",
    kind: "card",
    mode: "multimodal-ai",
  });
  const result = verifyNativeDeviceReport(
    { ...report(rows), certificationScope: "rappi-focused" },
    "ios-reader-2026.08.31.14",
    10,
  );
  assert.equal(result.ok, false);
  assert.ok(result.errors.some((error) => error.includes("solo permite archivos Rappi")));
});

test("el informe del dispositivo bloquea duplicados y estados pendientes", () => {
  const rows = Array.from({ length: 9 }, (_, index) => row(index + 1));
  rows.push(row(10, {
    file: "document-01.pdf",
    sourceFingerprint: rows[0].sourceFingerprint,
    status: "pending",
    requiresReview: true,
    reconciliationValid: false,
    duplicate: true,
  }));
  const result = verifyNativeDeviceReport(
    { ...report(rows), accepted: 9, blocked: 1, certified: false, unresolvedOCR: 1 },
    "ios-reader-2026.08.31.14",
    10,
  );
  assert.equal(result.ok, false);
  assert.ok(result.errors.some((error) => error.includes("PDF duplicada")));
  assert.ok(result.errors.some((error) => error.includes("no quedó aceptado")));
});

test("el informe híbrido acepta una lectura multimodal conciliada", () => {
  const rows = Array.from({ length: 10 }, (_, index) => row(index + 1));
  rows[0] = row(1, {
    mode: "multimodal-ai",
    ocrConfidence: 0.94,
    weakestOCRPage: 0.84,
  });
  const result = verifyNativeDeviceReport(
    { ...report(rows), generatedBy: "ios-hybrid-device" },
    "ios-reader-2026.08.31.14",
    10,
  );
  assert.equal(result.ok, true);
});

test("la prueba independiente permite OCR bruto bajo en tarjetas", () => {
  const rows = Array.from({ length: 10 }, (_, index) => row(index + 1));
  rows[0] = row(1, {
    source: "Rappi",
    accountKey: "rappi:9040",
    kind: "card",
    mode: "vision-ocr",
    ocrConfidence: 0.56,
    weakestOCRPage: 0.5,
    independentOCRProof: true,
  });
  const result = verifyNativeDeviceReport(
    report(rows),
    "ios-reader-2026.08.31.14",
    10,
    { expectedFiles: 10, requireRowAudit: true, requireIndependentProof: true },
  );
  assert.equal(result.ok, true, result.errors.join("; "));
});

test("la compuerta estricta exige auditoría exacta e independencia OCR", () => {
  const rows = Array.from({ length: 10 }, (_, index) => row(index + 1));
  rows[0] = row(1, {
    mode: "vision-ocr",
    ocrConfidence: 0.94,
    weakestOCRPage: 0.84,
    ocrColumnsCalibrated: true,
  });
  const result = verifyNativeDeviceReport(
    report(rows),
    "ios-reader-2026.08.31.14",
    10,
    { expectedFiles: 10, requireRowAudit: true, requireIndependentProof: true },
  );
  assert.equal(result.ok, true, result.errors.join("; "));

  const incomplete = verifyNativeDeviceReport(
    {
      ...report(rows),
      rowGoldensComplete: false,
      goldenRowAuditsPassed: 9,
      goldenRowAuditMismatches: 1,
      independentProofFiles: 0,
    },
    "ios-reader-2026.08.31.14",
    10,
    { expectedFiles: 10, requireRowAudit: true, requireIndependentProof: true },
  );
  assert.equal(incomplete.ok, false);
  assert.ok(incomplete.errors.some((error) => error.includes("goldens completos")));
  assert.ok(incomplete.errors.some((error) => error.includes("discrepancias")));
  assert.ok(incomplete.errors.some((error) => error.includes("prueba independiente")));
});

test("el informe estricto rechaza archivos privados, estados sin filas y emisores desconocidos", () => {
  const rows = Array.from({ length: 10 }, (_, index) => row(index + 1));
  rows[0] = row(1, {
    file: "Estado-de-cuenta-agosto-2026.pdf",
    kind: "unknown",
    rows: 0,
  });
  const result = verifyNativeDeviceReport(
    report(rows),
    "ios-reader-2026.08.31.14",
    10,
    { expectedFiles: 10, requireRowAudit: true, requireIndependentProof: true },
  );
  assert.equal(result.ok, false);
  assert.ok(result.errors.some((error) => error.includes("nombre de archivo no está redactado")));
  assert.ok(result.errors.some((error) => error.includes("kind=unknown")));
  assert.ok(result.errors.some((error) => error.includes("al menos una fila")));
});
