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
  assert.match(source, /static let readerVersion = "ios-reader-recovery-2026\.09\.25\.14"/);
  assert.match(source, /let canonicalFresh = Self\.shouldPersistCanonicalRowsForTesting/);
  assert.match(source, /let ocrQualityNeedsReview = usedOCR/);
  assert.doesNotMatch(source, /let ocrQualityNeedsReview = false/);
  assert.match(source, /\|\| ocrQualityNeedsReview/);
  assert.doesNotMatch(source, /if \(isCurrentReader\(statement\), statement\.reconciliation\?\.status == \.valid\)/);
  assert.match(source, /movements\.insert\(contentsOf: canonicalFresh\.reversed\(\), at: 0\)/);
  assert.match(source, /rowDiagnostics: extraction\.rowDiagnostics/);
  assert.match(source, /columnas CARGOS\/ABONOS\/SALDO calibradas por encabezado distribuido/);
  assert.match(source, /fila colapsada/);
  assert.match(source, /SelectablePDFLayout\.rappiText\(from: document\)/);
  assert.match(source, /var selectedRappiCandidates: \[Movement\] = \[\]/);
  assert.doesNotMatch(source, /var selectedRappiCandidates = ocrCandidates/);
  assert.match(source, /rappi-unsafe-candidate-stream-rejected/);
  assert.match(source, /rappiOCRSpatiallyDeduplicatedCandidates/);
  assert.match(source, /bbva\.foreign-auxiliary/);
  assert.match(await readFile(new URL("../apps/ios/Cauce/SelectablePDFLayout.swift", import.meta.url), "utf8"), /static func rappiText\(from document: PDFDocument\)/);
  assert.match(await readFile(new URL("../apps/ios/Cauce/SelectablePDFLayout.swift", import.meta.url), "utf8"), /let dateMatches = dateRegex\.matches/);
  assert.match(await readFile(new URL("../apps/ios/Cauce/SelectablePDFLayout.swift", import.meta.url), "utf8"), /let amountMatch = amountRegex\.firstMatch/);
  assert.match(await readFile(new URL("../apps/ios/Cauce/SelectablePDFLayout.swift", import.meta.url), "utf8"), /__RAPPI_ROW_BOUNDS__/);
  assert.match(source, /let blockedCount = statements\.reduce/);
  assert.match(source, /blockedMovementCount: blockedCount/);
  assert.match(source, /enrichmentMovementCount: reviewCount/);
});

test("el dashboard separa estados conciliados, filas bloqueadas y enriquecimiento", async () => {
  const [rootTab, diagnostics, models] = await Promise.all([
    readFile(new URL("../apps/ios/Cauce/RootTabView.swift", import.meta.url), "utf8"),
    readFile(new URL("../apps/ios/Cauce/Diagnostics.swift", import.meta.url), "utf8"),
    readFile(modelsPath, "utf8"),
  ]);
  assert.match(rootTab, /Conciliación financiera:/);
  assert.match(rootTab, /Movimientos bloqueados por fila:/);
  assert.match(rootTab, /por enriquecer:/);
  assert.match(diagnostics, /audit\.blockedRows/);
  assert.match(diagnostics, /Por enriquecer/);
  assert.match(models, /let blockedRows: Int/);
  assert.match(models, /reconciledStatementCount/);
  assert.match(models, /quarantinedCandidateCount/);
  assert.match(models, /quarantinedMovementCount/);
  assert.match(diagnostics, /Candidatos fuera de KPI/);
});

test("diagnóstico puede auditar todo el libro sin volver a subir PDFs", async () => {
  const [diagnostics, models] = await Promise.all([
    readFile(new URL("../apps/ios/Cauce/Diagnostics.swift", import.meta.url), "utf8"),
    readFile(modelsPath, "utf8"),
  ]);
  assert.match(diagnostics, /Analizar todos los estados guardados/);
  assert.match(diagnostics, /diagnostics\.manual/);
  assert.match(diagnostics, /No vuelve a subir archivos ni a ejecutar OCR/);
  assert.match(diagnostics, /Copiar diagnóstico completo/);
  assert.match(models, /struct LedgerDiagnosticReport/);
  assert.match(models, /func diagnosticReport\(\) -> LedgerDiagnosticReport/);
  assert.match(models, /movementBlockingReasons\(movement\)/);
  assert.match(models, /where !row\.accepted/);
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

test("el matcher nativo compara transferencias propias con puntaje y vínculo auditable", async () => {
  const [models, sections, settings] = await Promise.all([
    readFile(modelsPath, "utf8"),
    readFile(sectionsPath, "utf8"),
    readFile(settingsPath, "utf8"),
  ]);

  assert.match(models, /defaultTransferOwnerAliases/);
  assert.match(models, /globallyBestTransferCandidates/);
  assert.match(models, /evidence\.score >= 90/);
  assert.match(models, /matchedMovementId = inflow\.id/);
  assert.match(models, /falta contraparte/);
  assert.match(models, /ownEvidence && evidence.score >= 90/);
  assert.match(settings, /Transferencias entre mis cuentas/);
  assert.match(settings, /Guardar y volver a comparar/);
  assert.match(sections, /Section\("Conciliación entre cuentas"\)/);
  assert.match(sections, /LabeledContent\("Puntaje de evidencia"/);
});
