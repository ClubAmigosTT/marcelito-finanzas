import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { URL } from "node:url";

const modelsPath = new URL("../apps/ios/Cauce/Models.swift", import.meta.url);
const sectionsPath = new URL("../apps/ios/Cauce/Sections.swift", import.meta.url);
const aiPath = new URL("../apps/ios/Cauce/AIClassification.swift", import.meta.url);
const settingsPath = new URL("../apps/ios/Cauce/Settings.swift", import.meta.url);

test("el lector nativo separa diagnóstico de libro operativo", async () => {
  const source = await readFile(modelsPath, "utf8");
  assert.match(source, /var rowDiagnostics: \[OCRRowDiagnostic\]\? = nil/);
  assert.match(source, /static let readerVersion = "ios-reader-deterministic-2026\.09\.07\.5"/);
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

test("el importador nativo no tiene fallback genérico ni desbloqueo manual", async () => {
  const source = await readFile(modelsPath, "utf8");
  const settings = await readFile(settingsPath, "utf8");
  const extractStart = source.indexOf("private static func extractPDF(");
  const extractEnd = source.indexOf("private func applyPDFExtraction(", extractStart);
  const extraction = source.slice(extractStart, extractEnd);
  const reconcileStart = source.indexOf("private func reconcileStatement(");
  const reconcileEnd = source.indexOf("private static func textLayerReconciles(", reconcileStart);
  const reconciliation = source.slice(reconcileStart, reconcileEnd);

  assert.ok(extractStart >= 0 && extractEnd > extractStart && reconcileStart >= 0 && reconcileEnd > reconcileStart);
  assert.doesNotMatch(extraction, /parseGenericOCR\(/);
  assert.doesNotMatch(extraction, /tras agotar/);
  assert.match(reconciliation, /let tolerance = Decimal\.zero/);
  assert.match(source, /var dashboardIsBlocked: Bool \{ ledgerQuality\.isBlocking \}/);
  assert.match(source, /El desbloqueo manual fue eliminado/);
  assert.doesNotMatch(settings, /Desbloquear resultados provisionales/);
});
