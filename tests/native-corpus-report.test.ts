import test from "node:test";
import assert from "node:assert/strict";
import { verifyNativeCorpusReport, verifyNativeCorpusSummary } from "../scripts/verify-native-corpus-report.ts";

test("el resumen nativo certificado pasa con la revisión esperada", () => {
  const result = verifyNativeCorpusSummary({
    readerVersion: "ios-reader-test",
    files: "8",
    accepted: "8",
    blocked: "0",
    expectedValid: "8",
    expectedPending: "0",
    goldenAutoAccepted: "8",
    goldenFalseAccepted: "0",
    automaticAcceptancePrecision: "1.0000",
    unresolvedOCR: "0",
    certified: "true",
  }, "ios-reader-test");
  assert.equal(result.ok, true);
  assert.deepEqual(result.errors, []);
});

test("el resumen nativo pendiente o desactualizado no pasa la certificación", () => {
  const result = verifyNativeCorpusSummary({
    readerVersion: "ios-reader-old",
    files: 8,
    accepted: 5,
    blocked: 3,
    expectedValid: 4,
    expectedPending: 4,
    goldenAutoAccepted: 4,
    goldenFalseAccepted: 1,
    automaticAcceptancePrecision: 0.8,
    unresolvedOCR: 2,
    certified: false,
  }, "ios-reader-current");
  assert.equal(result.ok, false);
  assert.ok(result.errors.some((error) => error.includes("readerVersion")));
  assert.ok(result.errors.some((error) => error.includes("golden(s) pendientes")));
  assert.ok(result.errors.some((error) => error.includes("aceptación(es) falsa(s)")));
  assert.ok(result.errors.some((error) => error.includes("objetivo 0.99")));
});

test("el resumen no se acepta si los conteos estructurales no cuadran", () => {
  const result = verifyNativeCorpusSummary({
    readerVersion: "ios-reader-test",
    files: 8,
    accepted: 8,
    blocked: 2,
    expectedValid: 8,
    expectedPending: 0,
    goldenAutoAccepted: 8,
    goldenFalseAccepted: 0,
    automaticAcceptancePrecision: 1,
    unresolvedOCR: 0,
    certified: true,
  }, "ios-reader-test");
  assert.equal(result.ok, false);
  assert.ok(result.errors.some((error) => error.includes("accepted + blocked")));
});

test("el resumen nativo rechaza contadores fraccionarios o negativos", () => {
  const result = verifyNativeCorpusSummary({
    readerVersion: "ios-reader-test",
    files: -1,
    accepted: 0.5,
    blocked: 1,
    expectedValid: 8,
    expectedPending: 0,
    goldenAutoAccepted: 8,
    goldenFalseAccepted: 0,
    automaticAcceptancePrecision: 1.2,
    unresolvedOCR: -1,
    certified: true,
  }, "ios-reader-test");
  assert.equal(result.ok, false);
  assert.ok(result.errors.some((error) => error.includes("files no coincide")));
  assert.ok(result.errors.some((error) => error.includes("OCR sin resolver")));
  assert.ok(result.errors.some((error) => error.includes("objetivo 0.99")));
});

test("el reporte nativo exige una identidad enmascarada por PDF", () => {
  const result = verifyNativeCorpusReport([
    { file: "bbva.pdf", accountKey: "bbva:4922", expectedAccountKey: "bbva:4922" },
    { file: "amex.pdf", accountKey: "amex:1003", expectedAccountKey: "amex:1003" },
  ], 2);
  assert.equal(result.ok, true);
});

test("el reporte nativo rechaza números completos o archivos repetidos", () => {
  const result = verifyNativeCorpusReport([
    { file: "bbva.pdf", accountKey: "bbva:1575694922", expectedAccountKey: "bbva:4922" },
    { file: "bbva.pdf", accountKey: "bbva:4922", expectedAccountKey: "bbva:4922" },
  ], 2);
  assert.equal(result.ok, false);
  assert.ok(result.errors.some((error) => error.includes("formato emisor:últimos4")));
  assert.ok(result.errors.some((error) => error.includes("archivos duplicados")));
});

test("el reporte nativo rechaza filas inválidas o sin nombre de PDF", () => {
  const result = verifyNativeCorpusReport([
    null,
    { accountKey: "bbva:4922", expectedAccountKey: "bbva:4922" },
  ], 2);
  assert.equal(result.ok, false);
  assert.ok(result.errors.some((error) => error.includes("filas inválidas")));
  assert.ok(result.errors.some((error) => error.includes("sin nombre de archivo")));
});
