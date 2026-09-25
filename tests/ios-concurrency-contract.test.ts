import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const rootTabPath = new URL("../apps/ios/Cauce/RootTabView.swift", import.meta.url);
const sectionsPath = new URL("../apps/ios/Cauce/Sections.swift", import.meta.url);
const modelsPath = new URL("../apps/ios/Cauce/Models.swift", import.meta.url);
const pdfDiagnosticPath = new URL("../apps/ios/Cauce/PDFExtractionDiagnostic.swift", import.meta.url);
const pdfCachePath = new URL("../apps/ios/Cauce/PDFReadingCache.swift", import.meta.url);
const appPath = new URL("../apps/ios/Cauce/CauceApp.swift", import.meta.url);
const aiClassificationPath = new URL("../apps/ios/Cauce/AIClassification.swift", import.meta.url);
const diagnosticsViewPath = new URL("../apps/ios/Cauce/Diagnostics.swift", import.meta.url);
const certificationViewPath = new URL("../apps/ios/Cauce/NativeCorpusCertification.swift", import.meta.url);
const nativeCorpusPath = new URL("../apps/ios/Tests/NativeCorpusContractTests.swift", import.meta.url);
const nativeCorpusRunnerPath = new URL("../apps/ios/scripts/run-native-corpus.sh", import.meta.url);

test("la interfaz iOS usa importación y reconstrucción asíncronas", async () => {
  const [rootTab, sections, models, app, pdfCache] = await Promise.all([
    readFile(rootTabPath, "utf8"),
    readFile(sectionsPath, "utf8"),
    readFile(modelsPath, "utf8"),
    readFile(appPath, "utf8"),
    readFile(pdfCachePath, "utf8"),
  ]);

  assert.match(rootTab, /try await store\.importPDFAsync\(/);
  assert.match(rootTab, /await store\.rebuildCanonicalLedgerIfNeededAsync\s*\{/);
  assert.doesNotMatch(rootTab, /try store\.importPDF\(/);
  assert.doesNotMatch(rootTab, /store\.rebuildCanonicalLedgerIfNeeded\s*\{/);
  // Opening Resumen must never start PDFKit/Vision over the full archive.
  // A pending migration stays explicit and uses the asynchronous single-flight
  // path only after the user taps the visible refresh action.
  assert.doesNotMatch(rootTab, /\.task\(id: store\.hasCanonicalRebuildPending\)/);
  assert.match(rootTab, /Button\("Actualizar estados ahora", action: refreshAction\)/);
  assert.match(rootTab, /await rebuildPendingLedgerIfNeeded\(\)/);
  assert.match(rootTab, /PendingLedgerRefreshCard/);
  assert.match(rootTab, /TabView\(selection: \$selectedTab\)/);
  assert.match(rootTab, /private struct DeferredTab<Content: View>/);
  assert.match(rootTab, /await Task\.yield\(\)/);

  assert.match(sections, /try await store\.importPDFAsync\(/);
  assert.doesNotMatch(sections, /try store\.importPDF\(/);

  assert.match(models, /func importPDFAsync\(/);
  assert.match(pdfCache, /actor PDFExtractionCoordinator/);
  assert.match(models, /PDFExtractionCoordinator\.shared\.perform/);
  const importBlock = models.match(/func importPDFAsync\([\s\S]*?func inspectPDFAsync/)?.[0];
  assert.ok(importBlock, "la importación debe tener un límite de extracción identificable");
  assert.doesNotMatch(importBlock, /Task\.detached/);
  assert.match(importBlock, /try Task\.checkCancellation\(\)/);
  assert.match(models, /for pageIndex in 0\.\.<document\.pageCount \{\s*if Task\.isCancelled \{ break \}/);
  assert.match(models, /ciContext\.clearCaches\(\)/);
  assert.match(models, /func inspectPDFAsync[\s\S]*?PDFExtractionCoordinator\.shared\.perform/);
  assert.match(models, /PDFExtractionCoordinator\.shared\.perform \{\s*var seenFingerprints = Set<String>\(\)[\s\S]{0,400}for url in storedURLs \{\s*try Task\.checkCancellation\(\)/);
  assert.doesNotMatch(models, /let candidates = await Task\.detached\(priority: \.utility\)/);
  assert.match(models, /func rebuildCanonicalLedgerIfNeededAsync\(/);
  assert.match(models, /private var activeRebuildTask: Task<CanonicalRebuildResult, Never>\? = nil/);
  assert.match(models, /private func performCanonicalRebuildIfNeededAsync\(/);
  assert.match(models, /FinanceStore\(reconciliationOnly: true\)/);
  assert.match(models, /One atomic in-memory commit followed by one envelope write/);
  assert.match(models, /normalizedLedgerReaderVersionKey/);

  // A reader migration must not perform normalization or serialize the
  // complete envelope synchronously from FinanceStore.init(). The old build
  // did exactly that and starved SwiftUI before the first frame appeared.
  const migrationBlock = models.match(
    /let normalizedReaderVersion[\s\S]*?refreshCanonicalRebuildStatus\(\)/
  )?.[0];
  assert.ok(migrationBlock, "la migración de lector debe dejar una señal explícita");
  assert.doesNotMatch(migrationBlock, /normalizeStoredLedger\(\)/);
  assert.doesNotMatch(migrationBlock, /\bpersist\(/);
  assert.match(migrationBlock, /defaults\.set\(false, forKey: canonicalRebuildKey\)/);
  assert.match(models, /guard !canonicalRebuildPending else \{ return false \}/);
  assert.match(app, /phase == \.active/);
  assert.doesNotMatch(app, /phase == \.active[\s\S]*?runAutomaticAuditIfNeeded/);
  assert.match(models, /normalizeAfterImport: Bool = true/);
  assert.match(models, /normalizeAfterImport: false/);
});

test("volver al frente no ejecuta una auditoría síncrona ni congela las pestañas", async () => {
  const [app, models] = await Promise.all([
    readFile(new URL("../apps/ios/Cauce/CauceApp.swift", import.meta.url), "utf8"),
    readFile(modelsPath, "utf8"),
  ]);
  assert.doesNotMatch(app, /runAutomaticAuditIfNeeded\(trigger: "foreground"\)/);
  assert.match(app, /synchronous reconciliation\/serialization pass/);
  assert.match(models, /func runAutomaticAuditIfNeeded\(trigger: String = "foreground"\)/);
  assert.match(models, /lastAuditRun\.ledgerVersion == ledgerVersion/);
  assert.match(models, /lastAuditRun\.readerVersion == Self\.readerVersion/);
  assert.match(models, /DerivedProjectionCache/);
  assert.match(models, /@ObservationIgnored private var ledgerQualityCache/);
});

test("toda lectura nativa de PDF comparte el límite cancelable de memoria", async () => {
  const [models, diagnostic] = await Promise.all([
    readFile(modelsPath, "utf8"),
    readFile(pdfDiagnosticPath, "utf8"),
  ]);
  assert.match(diagnostic, /PDFExtractionCoordinator\.shared\.perform/);
  assert.doesNotMatch(diagnostic, /Task\.detached/);
  assert.match(models, /@MainActor func repairBBVAPeriods[\s\S]*?PDFExtractionCoordinator\.shared\.perform/);
  const ocrBlock = models.match(/private static func ocrObservations\([\s\S]*?private static func ocrText\(/)?.[0];
  assert.ok(ocrBlock, "la pasada OCR debe quedar delimitada para revisar su uso de memoria");
  assert.match(ocrBlock, /autoreleasepool \{/);
  assert.match(ocrBlock, /ciContext\.clearCaches\(\)/);
  assert.match(ocrBlock, /if Task\.isCancelled \{ break \}/);
});

test("la auditoría iOS separa revisión canónica de cuarentena", async () => {
  const [models, diagnostics, rootTab] = await Promise.all([
    readFile(modelsPath, "utf8"),
    readFile(new URL("../apps/ios/Cauce/Diagnostics.swift", import.meta.url), "utf8"),
    readFile(rootTabPath, "utf8"),
  ]);
  assert.match(models, /let reviewRows = canonical\.filter/);
  assert.match(models, /quarantinedMovementCount: quarantined\.count/);
  assert.match(models, /reviewTotal: review\.reduce/);
  assert.match(diagnostics, /Movimientos por enriquecer/);
  assert.match(diagnostics, /Movimientos bloqueados/);
  assert.match(diagnostics, /audit\.quarantinedRows/);
  assert.match(rootTab, /Por enriquecer en el libro/);
});

test("Vision tiene fallback de idiomas cuando el dispositivo no expone etiquetas regionales", async () => {
  const source = await readFile(modelsPath, "utf8");
  assert.match(source, /run\(languages: \["es-MX", "en-US"\]\)/);
  assert.match(source, /run\(languages: \["es", "en"\]\)/);
  assert.match(source, /run\(languages: nil\)/);
  // A fallback de Vision no puede convertirse en una aceptación silenciosa:
  // las filas siguen pasando por fecha, dirección, evidencia y conciliación.
  assert.match(source, /valid date, direction and issuer reconciliation/);
});

test("Vision escala el render por página sin desbordar memoria", async () => {
  const source = await readFile(modelsPath, "utf8");
  assert.match(source, /func renderSize\(for page: PDFPage, longEdge: CGFloat\)/);
  assert.match(source, /let maxPixels: CGFloat = 5_000_000/);
  assert.match(source, /render\(page, longEdge: 2_400\)/);
  assert.match(source, /render\(page, longEdge: 3_200\)/);
  assert.match(source, /useSantanderFinancialOCRRetry = issuerHint\?\.localizedCaseInsensitiveCompare\("Santander"\)/);
  assert.match(source, /baseConfidence < 0\.88\s*\|\|\s*\(useSantanderFinancialOCRRetry && \(baseFinancialConfidence \?\? 1\) < 0\.88\)/);
  assert.match(source, /meanConfidence\(selectedObservations\) < 0\.88\s*\|\|\s*\(useSantanderFinancialOCRRetry/);
  assert.match(source, /preferOCRPass\(\s*detailObservations,\s*over: selectedObservations,\s*includeFinancialConfidence: useSantanderFinancialOCRRetry/);
  assert.match(source, /preferOCRPass\(\s*contrastObservations,\s*over: selectedObservations,\s*includeFinancialConfidence: useSantanderFinancialOCRRetry/);
  assert.match(source, /var selectedImage = cgImage/);
});

test("Rappi repite OCR con foco numérico cuando la fuente pierde dígitos", async () => {
  const source = await readFile(modelsPath, "utf8");
  assert.match(source, /prioritizeNumericEvidence: selectableSource == "Rappi"/);
  assert.match(source, /numericFocus: Bool = false/);
  assert.match(source, /request\.usesLanguageCorrection = false/);
  assert.match(source, /request\.minimumTextHeight = 0\.004/);
  assert.match(source, /let numericPasses = \[/);
  assert.match(source, /run\(languages: nil\)/);
  assert.match(source, /numericPasses\.max/);
  assert.match(source, /func numericComponentEvidenceCount\(_ pageObservations: \[OCRObservation\]\)/);
  assert.match(source, /if leftScore\.components != rightScore\.components/);
  assert.match(source, /let tokenObservations = numericTokens\(from: recovery\)/);
  assert.match(source, /for token in tokenObservations/);
  assert.match(source, /let recoveryImages = \[numericImage, enhancedImage\(from: numericImage\)\]/);
  assert.match(source, /let shouldRecoverNumeric = pageIndex == 0\s*\|\| prioritizeNumericEvidence\s*\|\| currentNumericCount < 6\s*\|\| currentDateCount < 4/);
  assert.match(source, /func numericComponents\(from pageObservations: \[OCRObservation\]\)/);
  assert.match(source, /pageIndex == 0 \? numericComponents\(from: recovery\) : \[\]/);
  assert.match(source, /isNumericPart \|\| isMonth \|\| isConnector \|\| isCurrencyOrSign/);
  assert.match(source, /currentNumericCount < 6/);
  assert.match(source, /let currentNumericCount = numericEvidenceCount\(selectedObservations\)/);
  assert.match(source, /let currentDateCount = selectedObservations\.reduce/);
  assert.match(source, /func rappiCoverNumericObservation\(from image: CGImage, page: Int\)/);
  assert.match(source, /let rawCrop = CGRect\(/);
  assert.match(source, /var coverImage = selectedImage/);
  assert.match(source, /coverImage = numericImage/);
  assert.match(source, /selectedImage = contrastImage/);
  assert.match(source, /rappiCoverNumericObservation\(from: coverImage, page: pageIndex\)/);
});

test("Rappi recupera periodos cuando Vision pierde separadores o el conector", async () => {
  const source = await readFile(modelsPath, "utf8");
  assert.match(source, /sourceHint: String\? = nil/);
  assert.match(source, /let detectedSource = sourceHint \?\? sourceDetection\(from: text, fileName: fileName\)\.source/);
  assert.match(source, /let broadDatePattern =/);
  assert.match(source, /func formattedCycle\(_ first: Date, _ second: Date\)/);
  assert.match(source, /let cutoffPattern =/);
  assert.match(source, /let daysPatterns =/);
  assert.match(source, /return Int\(String\(cover\[daysRange\]\)\)/);
  assert.match(source, /let movementMarker = \[/);
  assert.match(source, /if let periodRange = cover\.range\(of: "periodo"\)/);
  assert.match(source, /bestCycle\(in: String\(tail\.prefix\(260\)\)\)/);
});

test("Rappi relee la portada aunque la tabla seleccionable ya concilie", async () => {
  const source = await readFile(modelsPath, "utf8");
  assert.match(source, /let coverPeriodOCRText: String = \{/);
  assert.match(source, /pageIndexes: Set\(\[0\]\)/);
  assert.match(source, /period metadata and never changes the selected movement rows/i);
  assert.match(source, /guard primary == "Periodo no identificado" else \{ return "" \}/);
  assert.match(source, /recognizedText: usedOCR \? text : ""/);
});

test("Rappi conserva OCR completo cuando la detección por bandas es parcial", async () => {
  const source = await readFile(modelsPath, "utf8");
  // Encontrar algunas bandas no demuestra cobertura completa. La ruta visual
  // debe conservar también la pasada de página y deduplicar por coordenada,
  // de modo que una fila omitida pueda recuperarse sin sumar duplicados.
  assert.match(source, /selectedObservations\.append\(contentsOf: visualRows\)/);
  assert.match(source, /rappiOCRMovementLineRecords\(from: observations\)/);
  assert.match(source, /abs\(\$0\.y - candidate\.y\) <= 0\.018/);
  assert.match(source, /normalized\(\$0\.amount\) == normalized\(candidate\.amount\)/);
  assert.doesNotMatch(source, /if !visualRows\.isEmpty \{[\s\S]{0,260}observations\.append\(contentsOf: visualRows\)\s*return/);
});

test("Rappi combina bandas de regla y anclas de fecha sin duplicarlas", async () => {
  const source = await readFile(modelsPath, "utf8");
  assert.match(source, /private static func mergedRappiRowRegions\(/);
  assert.match(source, /let retriedDateRegions = rappiDateAnchoredRowRegions\(in: image\)/);
  assert.match(source, /return mergedRappiRowRegions\(ruleRegions: ruleRegions, dateRegions: dateRegions\)/);
  assert.match(source, /overlapRatio >= 0\.35/);
  assert.match(source, /fullPageObservations: \[OCRObservation\] = \[\]/);
  assert.match(source, /observedDateRegions\.count >= ruleRegions\.count/);
  assert.match(source, /retryDateAnchorsWhenUnobserved: Bool = true/);
  assert.match(source, /rappiTableRowRegions\(in: image, retryDateAnchorsWhenUnobserved: false\)/);
});

test("Rappi guarda página y región visual de cada fila OCR", async () => {
  const source = await readFile(modelsPath, "utf8");
  assert.match(source, /private static let rappiRowBoundsPrefix = "__RAPPI_ROW_BOUNDS__"/);
  assert.match(source, /MovementExtractionBounds\(x: x, y: y, width: width, height: height\)/);
  assert.match(source, /sourceText: pending, bounds: evidenceBounds/);
  assert.match(source, /rowBounds: evidence\?\.bounds/);
  assert.match(source, /sameVisualRow: evidenceBounds != nil \? true : nil/);
});

test("Rappi conserva evidencia cuando el comercio no es confiable", async () => {
  const source = await readFile(modelsPath, "utf8");
  assert.match(source, /var sourceFallback: String\?/);
  assert.match(source, /return sourceFallback \?\? ""/);
  assert.match(source, /repaired\.category = "Por revisar"/);
  assert.match(source, /repaired\.displayMerchant = String\(source\.prefix\(120\)\)/);
  assert.doesNotMatch(source, /repaired\.title = "Movimiento Rappi sin concepto/);
});

test("la inspección nativa aplica los mismos bloqueos OCR que la importación", async () => {
  const source = await readFile(modelsPath, "utf8");
  assert.match(source, /private static func ocrQualityNeedsReview\(\s*_ extraction: PDFImportExtraction,\s*reconciliation: StatementReconciliationRecord\s*\)/);
  assert.match(source, /let ocrQualityNeedsReview = (?:usedOCR|extraction\.usedOCR) && Self\.ocrQualityNeedsReview\(\s*extraction,\s*reconciliation: gatedReconciliation\s*\)/);
  assert.match(source, /let independentProof = hasIndependentOCRProofForTesting\(/);
  assert.match(source, /extraction\.ocrFallbackNeedsReview\s*&&\s*!independentProof/);
  assert.match(source, /extraction\.ocrConfidenceNeedsReview\s*&&\s*!independentProof/);
  assert.match(source, /extraction\.ocrColumnCalibrationNeedsReview/);
  assert.match(source, /extraction\.rowDiagnostics\.contains \{ !\$0\.accepted \}/);
  assert.match(source, /let merchant = rappiMerchantIdentity\(titleBody, rawDescription: titleBody\)/);
  assert.match(source, /sourceText: pending, bounds: evidenceBounds/);
});

test("Rappi deja diagnóstico rechazado para filas OCR visuales no seleccionadas", async () => {
  const source = await readFile(modelsPath, "utf8");
  assert.match(source, /private static func rappiOCRRowDiagnostics\(/);
  assert.match(source, /rappi\.visual-row-not-reconstructed/);
  assert.match(source, /rappi\.visual-row-unselected/);
  assert.match(source, /rappi\.visual-stream-unreconciled/);
  assert.match(source, /Fila candidata Rappi en revisión/);
  assert.match(source, /Fila visual fuera de corriente/);
  assert.match(source, /Corriente OCR Rappi sin conciliar/);
  assert.match(source, /La señal agregada de página es/);
  assert.match(source, /let rappiPageWarningOnly = source\.caseInsensitiveCompare\("Rappi"\) == \.orderedSame/);
  assert.match(source, /selectedRappiOCRObservations = ocrObservations/);
  assert.match(source, /rowDiagnostics = Self\.rappiOCRRowDiagnostics\(/);
});

test("el visor PDF enfoca la región OCR con la convención de Vision", async () => {
  const source = await readFile(sectionsPath, "utf8");
  assert.match(source, /both use a bottom-left origin/);
  assert.match(source, /y: bounds\.minY \+ CGFloat\(initialBounds\.y \+ initialBounds\.height \/ 2\) \* bounds\.height/);
  assert.doesNotMatch(source, /y: bounds\.maxY - CGFloat\(initialBounds\.y/);
  assert.match(source, /Text\("Ajustar a ancho"\)/);
  assert.ok(source.includes('Text("Página \\(currentPage) de'));
});

test("Rappi no cruza controles entre candidatos y sus propios resúmenes", async () => {
  const source = await readFile(modelsPath, "utf8");
  assert.match(source, /candidateSets: \[\s*\(pageWiseCandidates, pageWiseSummary\)/);
  assert.match(source, /for \(candidates, summary\) in candidateSets/);
  assert.doesNotMatch(source, /candidateSets: \[\s*pageWiseCandidates/);
});

test("una capa de texto no conciliada fuerza una recuperación visual", async () => {
  const source = await readFile(modelsPath, "utf8");
  // A malformed or administrative text layer can contain enough dates and
  // numbers to look structured while still producing wrong rows. Vision must
  // be attempted unless the text-only parse has already reconciled with the
  // issuer controls; if Vision returns no observations, the original text is
  // retained so the normal reconciliation error remains visible.
  assert.match(source, /let shouldAttemptOCR = allowOCR && !textLayerReconciles/);
  assert.match(source, /let ocrText = selectableSource\.localizedCaseInsensitiveCompare\("Rappi"\)/);
  assert.match(source, /Self\.rappiOCRText\(from: ocrObservations\)/);
  assert.match(source, /let usedOCR = shouldAttemptOCR && !ocrObservations\.isEmpty/);
  assert.match(source, /let text = usedOCR \? ocrText : extractedText/);
});

test("la lectura directa conserva la página de cada fila", async () => {
  const source = await readFile(modelsPath, "utf8");
  // PDFKit flattens page strings by default. The sentinel must be inserted
  // before parsing so direct PDF-text rows satisfy the same evidence contract
  // as Vision rows and remain inspectable in the audit screen.
  assert.ok(source.includes(String.raw`return "__PDF_PAGE_\(index + 1)__\n\(pageText)"`));
  assert.match(source, /let pageMarkerRegex = try\? NSRegularExpression\(pattern: #"\^__pdf_page_\(\\d\+\)__\$"#/);
});

test("el corpus nativo admite manifiesto privado fuera del repositorio", async () => {
  const [nativeCorpus, runner] = await Promise.all([
    readFile(nativeCorpusPath, "utf8"),
    readFile(nativeCorpusRunnerPath, "utf8"),
  ]);

  assert.match(nativeCorpus, /MARCELITO_PDF_CORPUS_MANIFEST/);
  assert.match(nativeCorpus, /readerVersion/);
  assert.match(nativeCorpus, /runExpectations/);
  assert.match(nativeCorpus, /!runExpectations\.isEmpty/);
  assert.match(runner, /MARCELITO_PDF_CORPUS_MANIFEST/);
  assert.match(runner, /export MARCELITO_PDF_CORPUS_MANIFEST=/);
  assert.match(runner, /No se encontró el manifiesto privado/);
});

test("Amex Vision selecciona el importe MXN por columna y respeta sus secciones", async () => {
  const source = await readFile(modelsPath, "utf8");
  // The local amount is right aligned; source-currency and TC tokens can
  // appear later in OCR text and must not be selected by string order.
  assert.match(source, /let nonRateAmounts = orderedAmounts\.filter \{ !isExchangeRateCandidate\(\$0\) \}/);
  assert.match(source, /let localCurrencyCandidates = nonRateAmounts\.filter \{ \$0\.x >= 0\.72 \}/);
  assert.match(source, /let exchangeRateAnchor:/);
  assert.match(source, /forcedForeignCurrency: amexSection == 2/);
  assert.match(source, /amexSection = 3/);
  assert.match(source, /foreignCurrency: forcedForeignCurrency \|\| hasForeignCurrency/);
  assert.match(source, /let isForeignRow = forcedForeignCurrency \|\| Self\.hasForeignCurrency\(in: normalizedFullText\)/);
});

test("Amex conserva PDFKit cuando su capa de texto ya concilia", async () => {
  const source = await readFile(modelsPath, "utf8");
  // OCR is a recovery path only. A reconciled Amex text layer must win so
  // PDFKit's native domestic/foreign/payment/MSI section boundaries are not
  // lost in a second, noisier Vision pass.
  assert.match(source, /var textLayerReconciles = Self\.textLayerReconciles\(/);
  assert.match(source, /let isAmexLayout = source\.localizedCaseInsensitiveContains\("Amex"\)[\s\S]*?Self\.rebuildAmexSelectableLines/);
  assert.match(source, /let shouldAttemptOCR = allowOCR && !textLayerReconciles/);
});

test("Amex conserva PDFKit y cae a Vision cuando la capa de texto falla", async () => {
  const source = await readFile(modelsPath, "utf8");
  assert.match(source, /private static func parseAmexText\(_ text: String, fileName: String, diagnosticSink:/);
  assert.match(source, /let shouldAttemptOCR = allowOCR && !textLayerReconciles/);
  assert.match(source, /let ocrObservations = shouldAttemptOCR\s*\?/);
  assert.match(source, /else if usedOCR, source\.localizedCaseInsensitiveContains\("Amex"\)/);
  assert.match(source, /let initial = Self\.parseAmexOCRResult\(ocrObservations, fileName: fileName\)/);
  assert.match(source, /parsedCandidates = Self\.parseAmexText\(text, fileName: fileName, diagnosticSink:/);
});

test("RappiCard usa tabla dedicada y concilia abonos además de cargos", async () => {
  const source = await readFile(modelsPath, "utf8");
  assert.match(source, /if header.contains\("rappicard"\) && header.contains\("tarjeta de credito"\) \{ return "Rappi" \}/);
  assert.match(source, /parsedCandidates = Self\.parseRappiText\(text(?:,\s*fileName: fileName)?\)/);
  assert.match(source, /compare\("pagos y abonos", extracted: payments \+ credits/);
  assert.match(source, /opening \+ charges - payments - credits/);
  assert.match(source, /result\.msiMonthlyLoad == 0, result\.msiPending == 0/);
  assert.match(source, /let rappiPages = selectableSource == "Rappi" \? Self\.rappiOCRPageIndexes/);
  assert.match(source, /else if usedOCR, source == "Rappi"/);
  assert.match(source, /evidenceMethod: "vision-ocr"/);
});

test("Santander usa rectángulo y columnas fijas de la tabla", async () => {
  const source = await readFile(modelsPath, "utf8");
  assert.match(source, /private static func parseSantanderTable\(/);
  assert.match(source, /let requiredLabels = \["fecha", "folio", "descripcion", "deposito", "retiro", "saldo"\]/);
  assert.match(source, /santander\.table-title-not-found/);
  assert.match(source, /santander\.column-header-not-found/);
  assert.match(source, /lineWindows\(on: page\)/);
  assert.match(source, /if normalized\.contains\("saldo final del periodo anterior"\) \{ return false \}/);
  assert.match(source, /calibrationReason: "geometría fija de la tabla Carta Santander"/);
  assert.match(source, /movementMinX: tableX\(0\.610\)/);
  assert.match(source, /depositMaxX: tableX\(0\.742\)/);
  assert.match(source, /balanceMinX: tableX\(0\.874\)/);
  assert.match(source, /requireFixedMovementColumn: true/);
  assert.match(source, /return previousPrintedBalance \+ movement.amount == balance/);
  assert.match(source, /previousPrintedBalance = physical.balance/);
  assert.equal((source.match(/let gatedReconciliation = Self.santanderRowGate\(/g) ?? []).length, 2);
  assert.match(source, /santanderCropPixelRect\(region, width: image.width, height: image.height\)/);
  assert.match(source, /(?:let|var) santanderResult = Self\.parseSantanderTable\(\s*ocrObservations/);
});

test("Santander conserva cajas nativas de fecha e importe", async () => {
  const source = await readFile(modelsPath, "utf8");
  assert.match(source, /let dateBoxes: \[OCRTextBox\]/);
  assert.match(source, /let amountBoxes: \[OCRTextBox\]/);
  assert.match(source, /candidate\.boundingBox\(for: stringRange\)/);
  assert.match(source, /observation\.dateBoxes\.first/);
  assert.match(source, /if !observation\.amountBoxes\.isEmpty/);
});

test("Santander no inventa conteos a partir de días del periodo", async () => {
  const source = await readFile(modelsPath, "utf8");
  assert.match(source, /if source\.localizedCaseInsensitiveCompare\("BBVA"\) == \.orderedSame \{\s*summary\.depositCount/);
  assert.doesNotMatch(source, /if source\.localizedCaseInsensitiveCompare\("Santander"\).*summary\.depositCount/s);
});

test("BBVA exige calibración y dirección explícita por columna", async () => {
  const source = await readFile(modelsPath, "utf8");
  assert.match(source, /private static func parseBBVAOCRRow\([\s\S]*?guard columns\.calibratedFromHeader else \{ return nil \}/);
  assert.match(source, /selectedColumn = "CARGOS"/);
  assert.match(source, /selectedColumn = "ABONOS"/);
  assert.match(source, /CARGOS determina salida; ABONOS y SALDO se excluyen/);
  assert.match(source, /ABONOS determina entrada; CARGOS y SALDO se excluyen/);
  assert.doesNotMatch(source, /selectedColumn = "MOVIMIENTO \(respaldo\)"/);
});

test("Santander protege filas OCR con geometría colapsada", async () => {
  const source = await readFile(modelsPath, "utf8");
  // Vision can return a row in one box or in several unusually wide boxes.
  // Both shapes must use the penultimate/final amount pair so the running
  // balance can never be promoted to a transaction.
  assert.match(source, /let isWholeRowObservation = orderedAmountCandidates\.count >= 2/);
  assert.match(source, /let isCollapsedRowGeometry = orderedAmountCandidates\.count >= 2/);
  assert.match(source, /let useWholeRowPair = isWholeRowObservation \|\| isCollapsedRowGeometry/);
  assert.match(source, /let wholeRowMovement = useWholeRowPair \? orderedAmountCandidates\.dropLast\(\)\.last/);
  assert.match(source, /let wholeRowBalance = useWholeRowPair \? orderedAmountCandidates\.last/);
});

test("el clasificador iOS solo ofrece modelos gratuitos vigentes de Zen", async () => {
  const source = await readFile(aiClassificationPath, "utf8");
  const freeModels = [
    "mimo-v2.5-free",
    "ling-3.0-flash-fin-free",
    "nemotron-3-ultra-free",
    "nemotron-3.5-lightning-free",
    "big-pickle",
  ];
  for (const model of freeModels) assert.match(source, new RegExp(`id: "${model.replaceAll(".", "\\.")}"`));
  assert.doesNotMatch(source, /deepseek-v4-flash-free|north-mini-code-free/);
});

test("el clasificador iOS interpola categorías y movimientos reales en el prompt", async () => {
  const source = await readFile(aiClassificationPath, "utf8");
  assert.match(source, /usando solo estas categor[ií]as: \\\(categories\)/i);
  assert.match(source, /pendientes:\\n\\\(inputJSON\)/);
  assert.doesNotMatch(source, /usando solo estas categor[ií]as: \(categories\)/i);
  assert.doesNotMatch(source, /pendientes:\\n\(inputJSON\)/);
});

test("el clasificador iOS divide lotes y filtra respuestas fuera de alcance", async () => {
  const source = await readFile(aiClassificationPath, "utf8");
  assert.match(source, /static let maxBatchSize = 5/);
  assert.match(source, /classifyBatch\(/);
  assert.match(source, /requested\.contains\(movementID\)/);
  assert.match(source, /seen\.insert\(movementID\)\.inserted/);
  assert.match(source, /let usesDeterministicOptions = provider == \.nvidia \|\| provider == \.gemini/);
  assert.match(source, /maxTokens: usesDeterministicOptions \? 4096 : nil/);
  assert.match(source, /let firstPass = batchResult\.classifications\.isEmpty/);
  assert.match(source, /provider-format-stopped/);
});

test("iOS usa el proveedor seleccionado solo para enriquecer gastos después de la lectura local", async () => {
  const [models, settings, certification] = await Promise.all([
    readFile(modelsPath, "utf8"),
    readFile(aiClassificationPath, "utf8"),
    readFile(certificationViewPath, "utf8"),
  ]);
  assert.doesNotMatch(settings, /Toggle\("Usar IA cuando Vision no concilie"/);
  assert.match(settings, /Nunca recibe PDFs, cuentas ni saldos/);
  assert.match(models, /localExtractionStage\(for: localExtraction\.recoveryAttempts\)/);
  assert.match(models, /conciliando contra los totales/);
  assert.doesNotMatch(models, /ZenStatementReader/);
  assert.doesNotMatch(certification, /allowMultimodalFallback/);
  assert.match(certification, /El proveedor de IA seleccionado no recibe PDFs/);
  assert.match(models, /Legacy compatibility markers/);
  assert.match(certification, /multimodalFallbackAttempted/);
  assert.match(certification, /static let targetPrecision = 0\.97/);
  assert.match(certification, /conciliar cada archivo al 100%/);
});

test("el diagnóstico del dispositivo no se presenta como certificación de publicación", async () => {
  const [diagnostics, certification] = await Promise.all([
    readFile(diagnosticsViewPath, "utf8"),
    readFile(certificationViewPath, "utf8"),
  ]);
  assert.match(diagnostics, /Section\("Diagnóstico del lector"\)/);
  assert.match(diagnostics, /Diagnosticar estados con Vision/);
  assert.match(diagnostics, /runner privado con auditoría fila por fila/);
  assert.match(certification, /navigationTitle\("Diagnóstico del lector"\)/);
  assert.match(certification, /Este informe mide el lector local y no contiene las referencias golden privadas/);
  assert.doesNotMatch(certification, /guárdalo como docs\/native-corpus-certification\.json/);
});

test("iOS permite elegir Gemini, Zen o NVIDIA sin incluir claves en el código", async () => {
  const [settings, sections] = await Promise.all([
    readFile(aiClassificationPath, "utf8"),
    readFile(sectionsPath, "utf8"),
  ]);
  assert.match(settings, /case openCodeZen/);
  assert.match(settings, /case nvidia/);
  assert.match(settings, /case gemini/);
  assert.match(settings, /https:\/\/generativelanguage\.googleapis\.com\/v1beta\/openai\/chat\/completions/);
  assert.match(settings, /https:\/\/opencode\.ai\/zen\/v1\/chat\/completions/);
  assert.match(settings, /https:\/\/integrate\.api\.nvidia\.com\/v1\/chat\/completions/);
  assert.match(settings, /deepseek-ai\/deepseek-v4-flash-0731/);
  assert.match(settings, /moonshotai\/kimi-k3/);
  assert.match(settings, /Picker\("Servicio de IA", selection: \$selectedProvider\)/);
  assert.match(settings, /kSecAttrAccount as String: "\\\(provider\.rawValue\)-api-key"/);
  assert.match(settings, /chatTemplateKwargs: provider == \.nvidia && model == nvidiaDefaultModel \? ChatTemplateKwargs\(thinking: false\) : nil/);
  assert.match(settings, /type: "json_schema"/);
  assert.match(settings, /return ResponseFormat\(type: "json_object", jsonSchema: nil\)/);
  assert.match(settings, /reasoningEffort: provider == \.nvidia && model == "moonshotai\/kimi-k3" \? "low" : nil/);
  assert.match(settings, /retryableStatusCodes = Set\(\[408, 425, 429, 500, 502, 503, 504, 529\]\)/);
  assert.match(sections, /provider: provider/);
  assert.doesNotMatch(settings, /nvapi-/);
  assert.doesNotMatch(settings, /AQ\.Ab8RN6/);
});

test("el clasificador iOS no envía cuentas ni documentos", async () => {
  const source = await readFile(aiClassificationPath, "utf8");
  assert.doesNotMatch(source, /"cuenta"\s*:/);
  assert.match(source, /No recibes ni debes solicitar PDFs/);
  assert.match(source, /for payload in payloads/);
  assert.match(source, /"rows-missing"/);
  assert.doesNotMatch(source, /guard parsed\.count == movements\.count/);
});
