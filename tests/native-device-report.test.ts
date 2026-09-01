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
