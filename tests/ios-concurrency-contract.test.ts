import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const rootTabPath = new URL("../apps/ios/Cauce/RootTabView.swift", import.meta.url);
const sectionsPath = new URL("../apps/ios/Cauce/Sections.swift", import.meta.url);
const modelsPath = new URL("../apps/ios/Cauce/Models.swift", import.meta.url);
const aiClassificationPath = new URL("../apps/ios/Cauce/AIClassification.swift", import.meta.url);
const nativeCorpusPath = new URL("../apps/ios/Tests/NativeCorpusContractTests.swift", import.meta.url);
const nativeCorpusRunnerPath = new URL("../apps/ios/scripts/run-native-corpus.sh", import.meta.url);

test("la interfaz iOS usa importación y reconstrucción asíncronas", async () => {
  const [rootTab, sections, models] = await Promise.all([
    readFile(rootTabPath, "utf8"),
    readFile(sectionsPath, "utf8"),
    readFile(modelsPath, "utf8"),
  ]);

  assert.match(rootTab, /try await store\.importPDFAsync\(/);
  assert.match(rootTab, /await store\.rebuildCanonicalLedgerIfNeededAsync\s*\{/);
  assert.doesNotMatch(rootTab, /try store\.importPDF\(/);
  assert.doesNotMatch(rootTab, /store\.rebuildCanonicalLedgerIfNeeded\s*\{/);

  assert.match(sections, /try await store\.importPDFAsync\(/);
  assert.doesNotMatch(sections, /try store\.importPDF\(/);

  assert.match(models, /func importPDFAsync\(/);
  assert.match(models, /Task\.detached\(priority: \.userInitiated\)/);
  assert.match(models, /func importPDFAsync[\s\S]*?try Task\.checkCancellation\(\)[\s\S]*?try Task\.checkCancellation\(\)/);
  assert.match(models, /func rebuildCanonicalLedgerIfNeededAsync\(/);
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
  assert.match(source, /forcedForeignCurrency \|\| Self\.hasForeignCurrency\(in: normalizedFullText\)[\s\S]*?\? nil/);
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
