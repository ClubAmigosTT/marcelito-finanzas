import test from "node:test";
import assert from "node:assert/strict";
import { buildManifest } from "../scripts/build-private-visual-reference.mjs";

function fixtures() {
  const fingerprint = "a".repeat(64);
  const native = {
    readerVersion: "ios-test",
    files: [{
      sourceFileName: "statement.pdf",
      sourceFingerprint: fingerprint,
      source: "Rappi",
      accountKey: "rappi:1234",
      mode: "pdf-text",
      status: "valid",
      declaredControls: { creditLimit: 1000, creditAvailable: 990, debtBalance: 10 },
      candidateRows: [{
        date: "2026-01-02",
        page: 1,
        signedAmount: "-10.00",
        title: "7eleven la salle",
        kind: "Compra",
      }],
    }],
  };
  const independent = {
    readerVersion: "web-test",
    results: [{
      sourceFingerprint: fingerprint,
      source: "Rappi",
      accountKey: "rappi:1234",
      extractedRows: [{
        date: "2026-01-02",
        page: 1,
        signedAmount: "-10.00",
        description: "7 ELEVEN LA SALLE; RFC: SEM980701STA",
        kind: "Compra",
      }],
    }],
  };
  const pageOCR = { documents: { "1": { pages: { "1": ["7 ELEVEN LA SALLE; RFC: SEM980701STA"] } } } };
  return { native, independent, pageOCR };
}

test("visual reference requires explicit review confirmation", () => {
  const { native, independent, pageOCR } = fixtures();
  assert.throws(() => buildManifest(native, independent, pageOCR, false), /confirm-visual-review/);
  const result = buildManifest(native, independent, pageOCR, true);
  assert.equal(result.referenceMethod, "visual-independent");
  assert.equal(result.visualReviewCompleted, true);
  assert.equal(result.files[0].rowExpectations[0].titleContains, "la salle");
  assert.equal(result.files[0].rowExpectations[0].kind, "Compra");
  assert.equal(result.files[0].summary.debtBalance, 10);
});

test("visual reference fails when the rendered page has no anchor", () => {
  const { native, independent } = fixtures();
  assert.throws(
    () => buildManifest(native, independent, { documents: { "1": { pages: { "1": ["unrelated text"] } } } }, true),
    /visual-anchor/,
  );
});

test("visual reference maps rendered pages by filename when corpus orders differ", () => {
  const { native, independent, pageOCR } = fixtures();
  native.files[0].sourceFileName = "10-statement.pdf";
  pageOCR.documents = {
    "1": { file: "1-other.pdf", pages: { "1": ["unrelated text"] } },
    "2": { file: "10-statement.pdf", pages: { "1": ["7 ELEVEN LA SALLE; RFC: SEM980701STA"] } },
  };
  const result = buildManifest(native, independent, pageOCR, true);
  assert.equal(result.files[0].rowExpectations[0].titleContains, "la salle");
});
