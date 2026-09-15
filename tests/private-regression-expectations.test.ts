import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

type PrivateExpectation = {
  id: string;
  issuer: string;
  statementKind: "card" | "bank" | "unknown";
  expectedMovementCount: number;
  reconciliationExpected: "valid" | "pending" | "invalid";
  extractionMethod: "text" | "ocr";
  requiresColumnCalibration: boolean;
  maxRejectedRows: number;
  maxUncategorizedMovements: number;
};

test("las expectativas privadas son anonimizadas y cubren los casos obligatorios", async () => {
  const fixture = JSON.parse(await readFile(
    join(process.cwd(), "tests", "fixtures", "private-regression-expectations.json"),
    "utf8",
  )) as { schemaVersion: number; purpose: string; documents: PrivateExpectation[] };

  assert.equal(fixture.schemaVersion, 1);
  assert.match(fixture.purpose, /no contiene PDFs/i);
  assert.ok(Array.isArray(fixture.documents));
  assert.equal(new Set(fixture.documents.map((entry) => entry.id)).size, fixture.documents.length);
  assert.ok(fixture.documents.length >= 9);

  const issuers = new Set(fixture.documents.map((entry) => entry.issuer));
  for (const issuer of ["Amex", "BBVA", "Santander", "Rappi", "Desconocido"]) assert.ok(issuers.has(issuer), `falta ${issuer}`);
  assert.equal(fixture.documents.filter((entry) => entry.issuer === "Rappi").length, 3);
  assert.ok(fixture.documents.filter((entry) => entry.issuer === "Santander").length >= 3);

  for (const entry of fixture.documents) {
    assert.match(entry.id, /^[a-z0-9-]+$/);
    assert.ok(Number.isInteger(entry.expectedMovementCount) && entry.expectedMovementCount >= 0);
    assert.ok(Number.isInteger(entry.maxRejectedRows) && entry.maxRejectedRows >= 0);
    assert.ok(Number.isInteger(entry.maxUncategorizedMovements) && entry.maxUncategorizedMovements >= 0);
    assert.ok(["card", "bank", "unknown"].includes(entry.statementKind));
    assert.ok(["valid", "pending", "invalid"].includes(entry.reconciliationExpected));
    assert.ok(["text", "ocr"].includes(entry.extractionMethod));
    assert.equal(typeof entry.requiresColumnCalibration, "boolean");
    assert.equal(entry.id.includes(".pdf"), false);
    assert.equal(JSON.stringify(entry).toLowerCase().includes("fingerprint"), false);
    assert.equal(entry.requiresColumnCalibration, entry.issuer === "Santander" || entry.issuer === "Rappi" || entry.issuer === "Desconocido");
  }

  const amex = fixture.documents.find((entry) => entry.issuer === "Amex");
  const bbva = fixture.documents.find((entry) => entry.issuer === "BBVA");
  assert.equal(amex?.extractionMethod, "text");
  assert.equal(amex?.reconciliationExpected, "valid");
  assert.equal(bbva?.extractionMethod, "text");
  assert.equal(bbva?.reconciliationExpected, "valid");
  assert.ok(fixture.documents.filter((entry) => entry.issuer === "Santander").every((entry) => entry.extractionMethod === "ocr" && entry.reconciliationExpected === "valid"));
  assert.ok(fixture.documents.filter((entry) => entry.issuer === "Rappi").every((entry) => entry.extractionMethod === "ocr" && entry.reconciliationExpected === "valid"));

  const unreadable = fixture.documents.find((entry) => entry.issuer === "Desconocido");
  assert.equal(unreadable?.statementKind, "unknown");
  assert.equal(unreadable?.reconciliationExpected, "pending");
  assert.equal(unreadable?.expectedMovementCount, 0);
});
