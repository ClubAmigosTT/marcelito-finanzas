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

test("native screenshot observations remain outside the canonical movement ledger", () => {
  assert.match(models, /var screenshotCaptures:\s*\[BankScreenshotCapture\]/);
  assert.match(reader, /var canonicalScreenshotMovements/);
  assert.doesNotMatch(reader, /movements\.insert/);
  assert.match(reader, /reconcileBankScreenshotsAgainstOfficialLedger/);
});

test("native reader includes issuer-specific parsing and duplicate protection", () => {
  assert.match(reader, /case bbva = "BBVA"/);
  assert.match(reader, /case santander = "Santander"/);
  assert.match(reader, /case amex = "Amex"/);
  assert.match(reader, /existingFingerprints/);
  assert.match(reader, /duplicateOf/);
  assert.match(reader, /matchedOfficialMovementID/);
});
