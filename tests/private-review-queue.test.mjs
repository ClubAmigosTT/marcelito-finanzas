import test from "node:test";
import assert from "node:assert/strict";
import { buildPrivateReviewQueue } from "../scripts/build-private-review-queue.mjs";

function comparison() {
  return {
    schemaVersion: 2,
    referenceMethod: "independent-reader-comparison",
    validation: { ok: true, errors: [] },
    nativeReaderVersion: "native-test",
    independentReaderVersion: "independent-test",
    summary: { coreExactFiles: 1 },
    documents: [{
      document: 1,
      source: "BBVA",
      nativeMode: "pdf-text",
      independentMode: "pdf-text",
      nativeRows: 2,
      independentRows: 2,
      coreOutcome: "review",
      outcome: "review",
      semanticReview: true,
      mismatches: { date: 0, amount: 1, kind: 1, title: 0, page: 0, missingPage: 0 },
      mismatchRows: { date: [], amount: [2], kind: [2], title: [], page: [], missingPage: [] },
    }],
  };
}

test("crea una cola privada por ordinales sin copiar campos financieros", () => {
  const result = buildPrivateReviewQueue(comparison());
  assert.equal(result.summary.queuedFiles, 1);
  assert.equal(result.summary.queuedRows, 1);
  assert.deepEqual(result.documents[0].rowOrdinals, [2]);
  assert.equal(result.documents[0].mismatchCounts.amount, 1);
  assert.doesNotMatch(JSON.stringify(result), /2026-|10\.00|comercio|description|signedAmount/);
});

test("rechaza comparaciones anteriores o no validadas", () => {
  assert.throws(() => buildPrivateReviewQueue({ ...comparison(), schemaVersion: 1 }), /comparison-schema/);
  assert.throws(() => buildPrivateReviewQueue({ ...comparison(), validation: { ok: false } }), /comparison-invalid/);
});
