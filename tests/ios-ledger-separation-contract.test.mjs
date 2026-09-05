import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const modelsPath = new URL("../apps/ios/Cauce/Models.swift", import.meta.url);
const sectionsPath = new URL("../apps/ios/Cauce/Sections.swift", import.meta.url);
const aiPath = new URL("../apps/ios/Cauce/AIClassification.swift", import.meta.url);

test("el lector nativo separa diagnóstico de libro operativo", async () => {
  const source = await readFile(modelsPath, "utf8");
  assert.match(source, /var rowDiagnostics: \[OCRRowDiagnostic\]\? = nil/);
  assert.match(source, /static let readerVersion = "ios-reader-2026\.09\.05\.35"/);
  assert.match(source, /let canonicalFresh = Self\.shouldPersistCanonicalRowsForTesting/);
  assert.match(source, /movements\.insert\(contentsOf: canonicalFresh\.reversed\(\), at: 0\)/);
  assert.match(source, /rowDiagnostics: extraction\.rowDiagnostics/);
  assert.match(source, /columnas CARGOS\/ABONOS\/SALDO calibradas por encabezado distribuido/);
  assert.match(source, /fila colapsada/);
});

test("Zen solo recibe gastos canónicos y falla cerrado", async () => {
  const sections = await readFile(sectionsPath, "utf8");
  const ai = await readFile(aiPath, "utf8");
  assert.match(sections, /store\.canonicalMovements\.filter/);
  assert.match(ai, /movements\.allSatisfy/);
  assert.match(ai, /case \.cardPayment\?, \.bankTransfer\?, \.refund\?, \.credit\?/);
});
