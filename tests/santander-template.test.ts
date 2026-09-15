import test from "node:test";
import assert from "node:assert/strict";
import { parseDeterministicStatement } from "../src/issuerParsers/index.ts";
import { matchSantanderCheckingTemplate, santanderCheckingTemplateV1, statementTemplateValidationError } from "../src/issuerParsers/templates.ts";
import type { DocumentLayout, DocumentLayoutLine } from "../src/issuerParsers/types.ts";

const words = (page: number, y: number, values: Array<[number, string]>, scale = 1): DocumentLayoutLine => ({
  page,
  words: values.map(([x, text], readingOrder) => ({
    x: x * scale,
    y,
    width: Math.max(0.025, text.length * 0.007) * scale,
    height: 0.018,
    text,
    confidence: 0.99,
    readingOrder,
  })),
});

function fixture(options: { title?: boolean; header?: boolean; shift?: number; withdrawal?: string; balance?: string; scale?: number; cropY?: number } = {}) {
  const shift = options.shift ?? 0;
  const scale = options.scale ?? 1;
  const y = options.cropY ?? 0.72;
  const x = (value: number) => value + shift;
  const lines: DocumentLayoutLine[] = [
    words(1, 0.94, [[x(0.08), "Banco Santander México, S.A."], [x(0.43), "Grupo Financiero Santander México"]], scale),
  ];
  if (options.title !== false) {
    lines.push(words(1, 0.86, [[x(0.10), "Detalle de movimientos cuenta de cheques"]], scale));
  }
  if (options.header !== false) {
    lines.push(words(1, y + 0.08, [[x(0.06), "FECHA"], [x(0.14), "FOLIO"], [x(0.20), "DESCRIPCION"], [x(0.63), "DEPOSITO"], [x(0.75), "RETIRO"], [x(0.88), "SALDO"]], scale));
  }
  lines.push(
    words(1, y, [[x(0.06), "01-JUL-2026"], [x(0.14), "000001"], [x(0.20), "NOMINA ACME"], [x(0.63), "100.00"], [x(0.88), "1,100.00"]], scale),
    words(1, y - 0.06, [[x(0.06), "02-JUL-2026"], [x(0.14), "000002"], [x(0.20), "COMPRA TIENDA"], [x(0.75), options.withdrawal ?? "40.00"], [x(0.88), options.balance ?? "1,060.00"]], scale),
    words(1, y - 0.12, [[x(0.20), "TOTAL"], [x(0.63), "100.00"], [x(0.75), "40.00"]], scale),
  );
  const layout: DocumentLayout = { pages: [{ page: 1, lines }] };
  let text = [
    "Banco Santander México, S.A. Institución de Banca Múltiple",
    "Grupo Financiero Santander México",
    "Saldo inicial 1,000.00",
    "+ Depósitos 100.00",
    "- Retiros 40.00",
    "= Saldo final 1,060.00",
  ].join("\n");
  if (options.title !== false) text += "\nDetalle de movimientos cuenta de cheques";
  return { text, layout };
}

test("Santander v1 persists the match and uses only calibrated movement columns", () => {
  const input = fixture();
  const parsed = parseDeterministicStatement({ source: "Santander", fileName: "santander-2026.pdf", mode: "ocr", ...input });
  assert.equal(parsed.templateMatch?.templateId, "santander-checking");
  assert.equal(parsed.templateMatch?.templateVersion, "1");
  assert.equal(parsed.templateMatch?.status, "matched");
  assert.equal(parsed.reconciliation.status, "valid");
  assert.deepEqual(parsed.transactions.map((row) => row.amount), [100, -40]);
  assert.equal(parsed.transactions[1]?.extractionEvidence?.selectedColumn, "RETIRO");
  assert.equal(parsed.transactions[1]?.extractionEvidence?.templateAlignmentScore >= 0.9, true);
  assert.equal(parsed.transactions[1]?.extractionEvidence?.bounds?.y !== undefined, true);
});

test("normalized template tolerates scale and vertical crop without using pixels", () => {
  for (const input of [fixture({ scale: 0.98 }), fixture({ cropY: 0.44 })]) {
    const match = matchSantanderCheckingTemplate(input.layout, input.text);
    assert.equal(match.status, "matched");
    assert.ok(match.alignmentScore >= 0.9);
  }
});

test("Santander v1 reuses the calibrated schema when only the decorative title is unreadable", () => {
  const input = fixture({ title: false });
  const parsed = parseDeterministicStatement({ source: "Santander", fileName: "same-layout.pdf", mode: "ocr", ...input });
  assert.equal(parsed.templateMatch?.status, "matched");
  assert.equal(parsed.templateMatch?.reason, "santander.template-matched-with-verified-header-and-rows");
  assert.equal(parsed.reconciliation.status, "valid");
  assert.deepEqual(parsed.transactions.map((row) => row.amount), [100, -40]);
});

test("title-less Santander header without two dated movement rows remains in review", () => {
  const input = fixture({ title: false });
  input.layout.pages[0]!.lines = input.layout.pages[0]!.lines.slice(0, 3);
  const match = matchSantanderCheckingTemplate(input.layout, input.text);
  assert.equal(match.status, "review");
  assert.equal(match.reason, "santander.template-title-and-row-signal-missing");
});

test("the canonical Santander template has bounded normalized geometry and strict validation", () => {
  assert.equal(statementTemplateValidationError(santanderCheckingTemplateV1), undefined);
  const malformed = structuredClone(santanderCheckingTemplateV1);
  malformed.columns.find((column) => column.key === "RETIRO")!.referenceBounds.x = 0.99;
  assert.match(statementTemplateValidationError(malformed), /bounds-out-of-range/);
});

test("Santander without an essential header remains in review", () => {
  const input = fixture({ header: false });
  const parsed = parseDeterministicStatement({ source: "Santander", fileName: "unknown.pdf", mode: "ocr", ...input });
  assert.equal(parsed.templateMatch?.status, "review");
  assert.equal(parsed.templateMatch?.reason, "santander.template-required-columns-missing");
  assert.equal(parsed.reconciliation.status, "invalid");
  assert.equal(parsed.transactions.length, 0);
});

test("Santander columns shifted beyond the template alignment range remain in review", () => {
  const input = fixture({ shift: 0.16 });
  const match = matchSantanderCheckingTemplate(input.layout, input.text);
  assert.equal(match.status, "review");
  assert.equal(match.reason, "santander.template-geometry-misaligned");
});

test("a lost decimal or added digit cannot be repaired by a total", () => {
  const missingDecimal = parseDeterministicStatement({ source: "Santander", fileName: "decimal.pdf", mode: "ocr", ...fixture({ withdrawal: "4000" }) });
  assert.equal(missingDecimal.reconciliation.status, "invalid");
  assert.equal(missingDecimal.transactions.length < 2, true);
  const addedDigit = parseDeterministicStatement({ source: "Santander", fileName: "digit.pdf", mode: "ocr", ...fixture({ withdrawal: "400.00", balance: "1,060.00" }) });
  assert.equal(addedDigit.reconciliation.status, "invalid");
  assert.equal(addedDigit.transactions.length, 2);
});

test("an unknown Santander document is not classified as a valid v1 statement", () => {
  const layout: DocumentLayout = { pages: [{ page: 1, lines: [words(1, 0.9, [[0.1, "Banco Santander México, S.A."], [0.3, "TARJETA EMPRESARIAL"]])] }] };
  const match = matchSantanderCheckingTemplate(layout, "Banco Santander México, S.A. Estado de tarjeta empresarial");
  assert.equal(match.status, "review");
  assert.equal(match.reason, "santander.template-required-columns-missing");
});
