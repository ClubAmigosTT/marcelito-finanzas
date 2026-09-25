import test from "node:test";
import assert from "node:assert/strict";
import { compareIndependentRowReaders } from "../scripts/compare-independent-row-readers.mjs";

const native = (rows) => ({
  readerVersion: "ios-reader-test",
  files: [{
    sourceFileName: "private.pdf",
    sourceFingerprint: "a".repeat(64),
    source: "BBVA",
    accountKey: "bbva:1234",
    mode: "pdf-text",
    status: "valid",
    candidateRows: rows,
  }],
});

const independent = (rows) => ({
  readerVersion: "web-reader-test",
  results: [{
    file: "private.pdf",
    sourceFingerprint: "a".repeat(64),
    source: "BBVA",
    accountKey: "bbva:1234",
    mode: "pdf-text",
    reconciliation: { status: "valid" },
    extractedRows: rows,
  }],
});

test("compara filas por fecha, importe, concepto y página sin exportar valores", () => {
  const result = compareIndependentRowReaders(
    native([{ date: "2026-01-02", page: 2, signedAmount: "-10.50", title: "Comercio Central" }]),
    independent([{ date: "2026-01-02", page: 2, signedAmount: -10.5, description: "Comercio Central" }]),
  );
  assert.equal(result.summary.exactFiles, 1);
  assert.equal(result.summary.exactRows, 1);
  assert.equal(result.documents[0].outcome, "match");
  assert.equal(result.schemaVersion, 2);
  assert.doesNotMatch(JSON.stringify(result), /Comercio|10\.50|2026-01-02/);
});

test("compara un pago Rappi con el signo canónico del libro nativo", () => {
  const result = compareIndependentRowReaders(
    native([{ date: "2026-01-02", page: 2, signedAmount: "40", kind: "cardPayment", title: "Pago por SPEI" }]),
    independent([{ date: "2026-01-02", page: 2, signedAmount: -40, kind: "cardPayment", description: "Pago por SPEI" }]),
  );
  assert.equal(result.summary.exactFiles, 1);
  assert.equal(result.summary.exactRows, 1);
});

test("normaliza también el valor localizado del tipo de pago nativo", () => {
  const result = compareIndependentRowReaders(
    native([{ date: "2026-01-02", page: 2, signedAmount: "-40", kind: "Pago de tarjeta", title: "Pago" }]),
    independent([{ date: "2026-01-02", page: 2, signedAmount: 40, kind: "cardPayment", description: "Pago" }]),
  );
  assert.equal(result.summary.exactFiles, 1);
  assert.equal(result.summary.exactRows, 1);
});

test("normaliza tipos equivalentes de traspaso y crédito", () => {
  const result = compareIndependentRowReaders(
    native([{ date: "2026-01-02", page: 2, signedAmount: "40", kind: "Traspaso propio", title: "Traspaso" }]),
    independent([{ date: "2026-01-02", page: 2, signedAmount: 40, kind: "bankTransfer", description: "Traspaso" }]),
  );
  assert.equal(result.summary.mismatches.kind, 0);
  assert.equal(result.documents[0].outcome, "match");
});

test("separa diferencia semántica de pago de tarjeta y diferencia monetaria", () => {
  const result = compareIndependentRowReaders(
    native([{ date: "2026-01-02", page: 2, signedAmount: "40", kind: "cardPayment", title: "Pago" }]),
    independent([{ date: "2026-01-02", page: 2, signedAmount: -40, kind: "purchase", description: "Pago" }]),
  );
  assert.equal(result.summary.mismatches.amount, 0);
  assert.equal(result.summary.mismatches.kind, 1);
  assert.equal(result.documents[0].outcome, "review");
  assert.equal(result.documents[0].coreOutcome, "match");
  assert.equal(result.summary.exactFiles, 0);
  assert.equal(result.summary.coreExactFiles, 1);
  assert.equal(result.documents[0].semanticReview, true);
});

test("deja en revisión una fila que difiere o pierde evidencia de página", () => {
  const result = compareIndependentRowReaders(
    native([
      { date: "2026-01-02", page: 2, signedAmount: "-10.50", title: "Comercio Central" },
      { date: "2026-01-03", page: 2, signedAmount: "-5.00", title: "Otra fila" },
    ]),
    independent([{ date: "2026-01-02", signedAmount: -11, description: "Distinto" }]),
  );
  assert.equal(result.summary.exactFiles, 0);
  assert.equal(result.documents[0].outcome, "review");
  assert.equal(result.documents[0].mismatches.rowCount, 1);
  assert.equal(result.documents[0].mismatches.amount, 1);
  assert.equal(result.documents[0].mismatches.title, 1);
  assert.equal(result.documents[0].mismatches.missingPage, 1);
  assert.deepEqual(result.documents[0].mismatchRows.amount, [1]);
  assert.deepEqual(result.documents[0].mismatchRows.title, [1]);
});

test("rechaza una comparación estructuralmente incompleta aunque ambos lados estén vacíos", () => {
  const result = compareIndependentRowReaders(
    native([]),
    independent([]),
  );
  assert.equal(result.validation.ok, false);
  assert.equal(result.summary.exactFiles, 0);
  assert.equal(result.documents[0].outcome, "review");
  assert.equal(result.documents[0].mismatches.emptyRows, 1);
});

test("rechaza la comparación si falta la identidad enmascarada de la cuenta", () => {
  const nativeReport = native([
    { date: "2026-01-02", page: 2, signedAmount: "-10.50", title: "Comercio Central" },
  ]);
  delete nativeReport.files[0].accountKey;
  const result = compareIndependentRowReaders(
    nativeReport,
    independent([{ date: "2026-01-02", page: 2, signedAmount: -10.5, description: "Comercio Central" }]),
  );
  assert.equal(result.validation.ok, false);
  assert.equal(result.documents[0].outcome, "review");
});
