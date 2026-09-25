import test from "node:test";
import assert from "node:assert/strict";
import { buildPrivateReferenceDraft } from "../scripts/build-private-reference-draft.mjs";

function fixtures() {
  const fingerprint = "a".repeat(64);
  return {
    independent: {
      readerVersion: "independent-test",
      results: [{
        sourceFingerprint: fingerprint,
        source: "BBVA",
        accountKey: "bbva:1234",
        period: "2026-01",
        readerVersion: "independent-test",
        mode: "pdf-text",
        extractedRows: [{ date: "2026-01-02", page: 1, signedAmount: "-10", description: "candidate", kind: "purchase" }],
      }],
    },
    native: {
      readerVersion: "native-test",
      files: [{
        sourceFileName: "private.pdf",
        sourceFingerprint: fingerprint,
        source: "BBVA",
        accountKey: "bbva:1234",
        period: "2026-01",
        candidateRows: [{ date: "2026-01-02", page: 1, signedAmount: "-10", title: "native" }],
      }],
    },
  };
}

test("separa el borrador candidato del golden visual", () => {
  const result = buildPrivateReferenceDraft(fixtures().independent, fixtures().native);
  assert.equal(result.referenceMethod, "independent-reader-candidate");
  assert.equal(result.visualReviewRequired, true);
  assert.equal(result.files[0].rows[0].kindCandidate, "purchase");
  assert.equal("rowExpectations" in result.files[0], false);
});

test("rechaza una referencia que no cubre exactamente el export nativo", () => {
  const { independent, native } = fixtures();
  native.files[0].candidateRows.push({ date: "2026-01-03", page: 1, signedAmount: "-2", title: "native" });
  assert.throws(() => buildPrivateReferenceDraft(independent, native), /row-count/);
});
