import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { URL } from "node:url";

const sections = readFileSync(new URL("../apps/ios/Cauce/Sections.swift", import.meta.url), "utf8");
const reader = readFileSync(new URL("../apps/ios/Cauce/BankScreenshotImport.swift", import.meta.url), "utf8");
const models = readFileSync(new URL("../apps/ios/Cauce/Models.swift", import.meta.url), "utf8");

test("native Accounts screen exposes a visible multi-image screenshot import", () => {
  assert.match(sections, /Text\("Subir capturas"\)/);
  assert.match(sections, /photosPicker\(/);
  assert.match(sections, /maxSelectionCount:\s*20/);
  assert.match(sections, /BankScreenshotReader\.inspect/);
});

test("native Accounts keeps official statements and diagnostics visible", () => {
  assert.match(sections, /Text\("Subir estado bancario"\)/);
  assert.match(sections, /allowedContentTypes:\s*\[\.pdf\]/);
  assert.match(sections, /Label\("Diagnóstico", systemImage: "stethoscope"\)/);
  assert.match(sections, /Label\("Movimientos", systemImage: "slider\.horizontal\.3"\)/);
});

test("processed captures distinguish OCR completion from reconciliation", () => {
  assert.match(sections, /Text\("Capturas procesadas"\)/);
  assert.match(sections, /En métricas/);
  assert.match(sections, /provisional/);
  assert.match(sections, /Conciliada con estado oficial/);
  assert.match(sections, /pendientes en el banco/);
});

test("native screenshot observations feed a reversible provisional live ledger", () => {
  assert.match(models, /var screenshotCaptures:\s*\[BankScreenshotCapture\]/);
  assert.match(reader, /var canonicalScreenshotMovements/);
  assert.match(models, /func synchronizeProvisionalScreenshotLedger\(\)/);
  assert.match(models, /row\.duplicateOf == nil && row\.matchedOfficialMovementID == nil/);
  assert.match(models, /extractionEvidence:\s*row\.evidence/);
  assert.match(models, /persist\(markingChange: true\)/);
  assert.match(reader, /reconcileBankScreenshotsAgainstOfficialLedger/);
  assert.match(reader, /synchronizeProvisionalScreenshotLedger\(\)/);
});

test("native reader includes issuer-specific parsing and duplicate protection", () => {
  assert.match(reader, /case bbva = "BBVA"/);
  assert.match(reader, /case santander = "Santander"/);
  assert.match(reader, /case amex = "Amex"/);
  assert.match(reader, /existingFingerprints/);
  assert.match(reader, /duplicateOf/);
  assert.match(reader, /matchedOfficialMovementID/);
});

test("each suspected duplicate requires an explicit same-or-keep-both decision", () => {
  assert.match(reader, /struct BankScreenshotDuplicateConflict/);
  assert.match(reader, /Text\("Posibles repetidos"\)/);
  assert.match(reader, /Interruptor apagado: es el mismo movimiento/);
  assert.match(reader, /Encendido: conservar ambos cargos/);
  assert.match(reader, /resolveScreenshotDuplicates\(captureID:/);
  assert.match(reader, /duplicateOf = nil/);
});

test("provisional screenshot rows are visible and identified across the product", () => {
  assert.match(models, /var dashboardIsProvisional: Bool \{ eligibleMovements.contains/);
  assert.doesNotMatch(models, /if isProvisionalScreenshotMovement\(movement\) \{ return true \}/);
  assert.match(sections, /return "Captura provisional"/);
  assert.match(sections, /Ya está incluido en las métricas/);
  assert.match(reader, /Reflejados ahora/);
});
