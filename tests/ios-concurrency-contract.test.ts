import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const rootTabPath = new URL("../apps/ios/Cauce/RootTabView.swift", import.meta.url);
const sectionsPath = new URL("../apps/ios/Cauce/Sections.swift", import.meta.url);
const modelsPath = new URL("../apps/ios/Cauce/Models.swift", import.meta.url);

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
