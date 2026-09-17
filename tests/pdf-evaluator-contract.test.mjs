/* global URL */

import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

test("el evaluador del corpus destruye el loading task compatible con PDF.js 6", async () => {
  const source = await readFile(new URL("../scripts/evaluate-pdf-corpus.ts", import.meta.url), "utf8");
  assert.match(source, /const loadingTask = pdfjs\.getDocument/);
  assert.match(source, /await loadingTask\.destroy\(\)/);
  assert.doesNotMatch(source, /document\.destroy\(\)/);
});

test("el evaluador trata Rappi como tarjeta y compara sus controles de cargos/pagos", async () => {
  const source = await readFile(new URL("../scripts/evaluate-pdf-corpus.ts", import.meta.url), "utf8");
  assert.match(source, /source === "Amex" \|\| source === "Rappi"/);
  assert.match(source, /\["Santander", "BBVA", "Amex", "Rappi"\]/);
  assert.match(source, /chargeTotal: "extractedChargeTotal"/);
  assert.match(source, /paymentTotal: "extractedPaymentTotal"/);
});

test("la inspección PDF aplica la compuerta OCR antes de exponer una conciliación válida", async () => {
  const source = await readFile(new URL("../src/pdfImport.ts", import.meta.url), "utf8");
  assert.match(source, /const baseReconciliation = deterministic\?\.reconciliation/);
  assert.match(source, /const reconciliation = gateOcrReconciliation\(/);
  assert.match(source, /ocrResult\?\.pageConfidences/);
});

test("el evaluador privado usa la misma compuerta de confianza OCR que la importación", async () => {
  const source = await readFile(new URL("../scripts/evaluate-pdf-corpus.ts", import.meta.url), "utf8");
  assert.match(source, /gateOcrReconciliation/);
  assert.match(source, /mode === "ocr" \? "ocr" : "text"/);
  assert.match(source, /ocrConfidence,\s*ocrPageConfidences/);
});

test("Rappi prueba primero si su capa de texto concilia antes de activar OCR", async () => {
  const evaluator = await readFile(new URL("../scripts/evaluate-pdf-corpus.ts", import.meta.url), "utf8");
  const importer = await readFile(new URL("../src/pdfImport.ts", import.meta.url), "utf8");
  assert.match(evaluator, /const selectableRappiReconciles = rappiTextLayerReconciles\(text, fileName, layout\)/);
  assert.match(evaluator, /const requiresOCR = !selectableRappiReconciles && shouldUseOCR\(text\)/);
  assert.match(importer, /const mode = selectableRappiReconciles \|\| !shouldUseOCR\(extractedText\) \? "text" : "ocr"/);
});

test("la calidad Rappi mide categorías solo en gastos y conserva cobertura de identidad", async () => {
  const source = await readFile(new URL("../scripts/evaluate-pdf-corpus.ts", import.meta.url), "utf8");
  assert.match(source, /if \(row\.flow !== "expense"\) return false/);
  assert.match(source, /merchantReviewRows/);
  assert.match(source, /rawDescriptionRows/);
  assert.match(source, /normalizedMerchantRows/);
  assert.match(source, /displayMerchantRows/);
});

test("la revisión web muestra evidencia original en filas Rappi por enriquecer", async () => {
  const source = await readFile(new URL("../src/App.tsx", import.meta.url), "utf8");
  assert.match(source, /function enrichmentLabel\(transaction: Transaction\)/);
  assert.match(source, /Texto original:/);
  assert.match(source, /item\.rawDescription/);
  assert.match(source, /confianza \$\{Math\.round\(confidence \* 100\)\}%/);
});
