import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const rootTabPath = new URL("../apps/ios/Cauce/RootTabView.swift", import.meta.url);
const sectionsPath = new URL("../apps/ios/Cauce/Sections.swift", import.meta.url);
const modelsPath = new URL("../apps/ios/Cauce/Models.swift", import.meta.url);
const appPath = new URL("../apps/ios/Cauce/CauceApp.swift", import.meta.url);
const aiClassificationPath = new URL("../apps/ios/Cauce/AIClassification.swift", import.meta.url);
const certificationViewPath = new URL("../apps/ios/Cauce/NativeCorpusCertification.swift", import.meta.url);
const nativeCorpusPath = new URL("../apps/ios/Tests/NativeCorpusContractTests.swift", import.meta.url);
const nativeCorpusRunnerPath = new URL("../apps/ios/scripts/run-native-corpus.sh", import.meta.url);

test("la interfaz iOS usa importación y reconstrucción asíncronas", async () => {
  const [rootTab, sections, models, app] = await Promise.all([
    readFile(rootTabPath, "utf8"),
    readFile(sectionsPath, "utf8"),
    readFile(modelsPath, "utf8"),
    readFile(appPath, "utf8"),
  ]);

  assert.match(rootTab, /try await store\.importPDFAsync\(/);
  assert.match(rootTab, /await store\.rebuildCanonicalLedgerIfNeededAsync\s*\{/);
  assert.doesNotMatch(rootTab, /try store\.importPDF\(/);
  assert.doesNotMatch(rootTab, /store\.rebuildCanonicalLedgerIfNeeded\s*\{/);
  // Opening Resumen must hydrate the persisted envelope only. A full PDF
  // rebuild is an explicit action, never a view-appearance side effect.
  assert.doesNotMatch(rootTab, /\.task\s*\{\s*await rebuildPendingLedgerIfNeeded\(\)/);
  assert.match(rootTab, /PendingLedgerRefreshCard/);

  assert.match(sections, /try await store\.importPDFAsync\(/);
  assert.doesNotMatch(sections, /try store\.importPDF\(/);

  assert.match(models, /func importPDFAsync\(/);
  assert.match(models, /Task\.detached\(priority: \.userInitiated\)/);
  assert.match(models, /func importPDFAsync[\s\S]*?try Task\.checkCancellation\(\)[\s\S]*?try Task\.checkCancellation\(\)/);
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
  assert.match(app, /phase == \.active, !financeStore\.hasCanonicalRebuildPending/);
  assert.match(models, /normalizeAfterImport: Bool = true/);
  assert.match(models, /normalizeAfterImport: false/);
});

test("la auditoría de foreground no se repite para el mismo libro", async () => {
  const [app, models] = await Promise.all([
    readFile(new URL("../apps/ios/Cauce/CauceApp.swift", import.meta.url), "utf8"),
    readFile(modelsPath, "utf8"),
  ]);
  assert.match(app, /runAutomaticAuditIfNeeded\(trigger: "foreground"\)/);
  assert.match(models, /func runAutomaticAuditIfNeeded\(trigger: String = "foreground"\)/);
  assert.match(models, /lastAuditRun\.ledgerVersion == ledgerVersion/);
  assert.match(models, /lastAuditRun\.readerVersion == Self\.readerVersion/);
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
  assert.match(source, /if baseConfidence < 0\.88/);
  assert.match(source, /var selectedImage = cgImage/);
});

test("una capa de texto no conciliada fuerza una recuperación visual", async () => {
  const source = await readFile(modelsPath, "utf8");
  // A malformed or administrative text layer can contain enough dates and
  // numbers to look structured while still producing wrong rows. Vision must
  // be attempted unless the text-only parse has already reconciled with the
  // issuer controls; if Vision returns no observations, the original text is
  // retained so the normal reconciliation error remains visible.
  assert.match(source, /let shouldAttemptOCR = allowOCR && !textLayerReconciles/);
  assert.match(source, /let ocrText = Self\.ocrText\(from: ocrObservations\)/);
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
  assert.match(nativeCorpus, /runExpectations\.count >= 10/);
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
  assert.match(source, /let textLayerReconciles = Self\.textLayerReconciles\(/);
  assert.match(source, /let isAmexLayout = source\.localizedCaseInsensitiveContains\("Amex"\)[\s\S]*?Self\.rebuildAmexSelectableLines/);
  assert.match(source, /let shouldAttemptOCR = allowOCR && !textLayerReconciles/);
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
  assert.match(source, /static let maxBatchSize = 32/);
  assert.match(source, /classifyBatch\(/);
  assert.match(source, /requested\.contains\(movementID\)/);
  assert.match(source, /seen\.insert\(movementID\)\.inserted/);
  assert.match(source, /maxTokens: 2000/);
});

test("iOS usa Zen solo para enriquecer gastos después de la lectura local", async () => {
  const [models, settings, certification] = await Promise.all([
    readFile(modelsPath, "utf8"),
    readFile(aiClassificationPath, "utf8"),
    readFile(certificationViewPath, "utf8"),
  ]);
  assert.doesNotMatch(settings, /Toggle\("Usar IA cuando Vision no concilie"/);
  assert.match(settings, /Nunca recibe PDFs ni saldos/);
  assert.match(models, /stage\?\("Lectura local lista; conciliando contra los totales/);
  assert.doesNotMatch(models, /ZenStatementReader/);
  assert.doesNotMatch(certification, /allowMultimodalFallback/);
  assert.match(certification, /OpenCode Zen no recibe PDFs/);
  assert.match(models, /Legacy compatibility markers/);
  assert.match(certification, /multimodalFallbackAttempted/);
  assert.match(certification, /static let targetPrecision = 0\.97/);
  assert.match(certification, /cada archivo aceptado debe conciliar al 100%/);
});

test("el clasificador iOS no envía cuentas ni documentos", async () => {
  const source = await readFile(aiClassificationPath, "utf8");
  assert.doesNotMatch(source, /"cuenta"\s*:/);
  assert.match(source, /No recibes ni debes solicitar PDFs/);
  assert.match(source, /guard parsed\.count == movements\.count/);
});
