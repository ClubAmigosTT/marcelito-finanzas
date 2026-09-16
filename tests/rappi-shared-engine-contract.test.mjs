import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const bundlePath = path.join(repositoryRoot, "apps", "ios", "Cauce", "Resources", "rappi-engine.js");
const bridgePath = path.join(repositoryRoot, "apps", "ios", "Cauce", "RappiSharedEngine.swift");
const modelsPath = path.join(repositoryRoot, "apps", "ios", "Cauce", "Models.swift");
const projectSpecPath = path.join(repositoryRoot, "apps", "ios", "project.yml");

function loadEngine() {
  const sandbox = { console: globalThis.console };
  vm.runInNewContext(readFileSync(bundlePath, "utf8"), sandbox, { filename: bundlePath });
  return sandbox.MarcelitoRappiEngine;
}

test("el bundle local de iOS expone el mismo contrato determinista de Rappi", () => {
  const engine = loadEngine();
  assert.equal(engine?.version, "rappi-shared-engine-2026.09.16.1");
  assert.equal(typeof engine?.parse, "function");

  const parsed = engine.parse({
    fileName: "rappi-shared-contract.pdf",
    mode: "text",
    text: [
      "Tarjeta de crédito RappiCard",
      "Número de cuenta 00000000000000000000",
      "Adeudo del periodo anterior = $0.00",
      "Cargos regulares (no a meses) + $100.00",
      "Cargos compras a meses (capital) + $0.00",
      "Pagos y abonos - $40.00",
      "Saldo deudor total $60.00",
      "CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)",
      "__PDF_PAGE_3__",
      "2026-08-01 2026-08-01 MERPAGO*CAFETERIA; RFC: ABC010203AB1 +$50.00",
      "2026-08-02 2026-08-02 COMERCIO DOS +$50.00",
      "2026-08-03 2026-08-03 PAGO POR SPEI -$40.00",
      "Total de cargos +$100.00",
      "Total de abonos -$40.00",
    ].join("\n"),
  });

  assert.equal(parsed.parserId, "rappicard-operations-v1");
  assert.equal(parsed.transactions.length, 3);
  assert.deepEqual(Array.from(parsed.transactions, (row) => row.amount), [-50, -50, -40]);
  assert.equal(parsed.transactions[0].rawDescription, "MERPAGO*CAFETERIA; RFC: ABC010203AB1");
  assert.equal(parsed.transactions[0].normalizedMerchant, "cafeteria");
  assert.equal(parsed.transactions[0].displayMerchant, "Cafeteria");
  assert.equal(parsed.reconciliation.status, "valid");
});

test("el contrato compartido conserva geometría, confianza y metadatos OCR por fila", () => {
  const engine = loadEngine();
  const parsed = engine.parse({
    fileName: "rappi-ocr-contract.pdf",
    mode: "ocr",
    pageConfidences: [1, 0.82, 0.77],
    text: [
      "Tarjeta de crédito RappiCard",
      "Adeudo del periodo anterior = $0.00",
      "Cargos regulares (no a meses) + $50.00",
      "Cargos compras a meses (capital) + $0.00",
      "Pagos y abonos - $40.00",
      "Saldo deudor total $10.00",
      "CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)",
      "__PDF_PAGE_3__",
      "__RAPPI_ROW_BOUNDS__ 3 0.120000 0.420000 0.760000 0.032000 0.820000",
      "2026-08-01 2026-08-01 MERPAGO*CAFETERIA; RFC: ABC010203AB1 +$50.00",
      "__RAPPI_ROW_BOUNDS__ 3 0.120000 0.380000 0.760000 0.032000 0.770000",
      "__RAPPI_ROW_META__ signo OCR corregido por etiqueta inequívoca de abono Rappi",
      "2026-08-02 2026-08-02 PAGO POR SPEI +$40.00",
      "Total de cargos +$50.00",
      "Total de abonos -$40.00",
    ].join("\n"),
  });

  assert.equal(parsed.reconciliation.status, "valid");
  assert.deepEqual(Array.from(parsed.transactions, (row) => row.amount), [-50, -40]);
  assert.deepEqual(Array.from(parsed.transactions, (row) => row.extractionEvidence?.page), [3, 3]);
  assert.deepEqual(Array.from(parsed.transactions, (row) => row.extractionEvidence?.confidence), [0.82, 0.77]);
  assert.equal(parsed.transactions[0].extractionEvidence?.sameVisualRow, true);
  const bounds = parsed.transactions[0].extractionEvidence?.bounds;
  assert.equal(bounds?.x, 0.12);
  assert.equal(bounds?.y, 0.42);
  assert.equal(bounds?.width, 0.76);
  assert.equal(bounds?.height, 0.032);
  assert.match(parsed.transactions[1].extractionEvidence?.selectionReason ?? "", /signo OCR corregido/);
});

test("iOS empaqueta y usa el puente compartido para ambos extractores Rappi", () => {
  const bridge = readFileSync(bridgePath, "utf8");
  const models = readFileSync(modelsPath, "utf8");
  const projectSpec = readFileSync(projectSpecPath, "utf8");
  assert.match(bridge, /import JavaScriptCore/);
  assert.match(bridge, /rappi-engine/);
  assert.match(bridge, /source\.selectionReason/);
  assert.match(models, /evidenceMethod == "pdf-text" \|\| evidenceMethod == "vision-ocr"/);
  assert.match(projectSpec, /Cauce\/Resources\/rappi-engine\.js/);
});
