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
  assert.equal(engine?.version, "rappi-shared-engine-2026.09.23.1");
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

test("el motor compartido normaliza fechas OCR localizadas antes de cruzar con Swift", () => {
  const engine = loadEngine();
  const parsed = engine.parse({
    fileName: "rappi-localized-dates.pdf",
    mode: "text",
    text: [
      "Tarjeta de crédito RappiCard",
      "Adeudo del periodo anterior = $0.00",
      "Cargos regulares (no a meses) + $100.00",
      "Cargos compras a meses (capital) + $0.00",
      "Pagos y abonos - $50.00",
      "Saldo deudor total $60.00",
      "CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)",
      "01/08/2026 02/08/2026 COMERCIO UNO +$50.00",
      "01/08/2026 02/08/2026 COMERCIO DOS +$50.00",
      "02-AGO-2026 02-AGO-2026 PAGO POR SPEI -$40.00",
      "03/08/2026 03/08/2026 BONIFICACIÓN CON CASHBACK -$10.00",
      "Total de cargos +$100.00",
      "Total de abonos -$50.00",
    ].join("\n"),
  });

  assert.equal(parsed.reconciliation.status, "valid");
  assert.deepEqual(Array.from(parsed.transactions, (row) => row.date), [
    "2026-08-01",
    "2026-08-01",
    "2026-08-02",
    "2026-08-03",
  ]);
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

test("Rappi descarta encabezados y fragmentos de comercio sin perder filas completas", () => {
  const engine = loadEngine();
  const parsed = engine.parse({
    fileName: "rappi-overlapping-row-headings.pdf",
    mode: "ocr",
    text: [
      "Tarjeta de crédito RappiCard",
      "Adeudo del periodo anterior = $10.00",
      "Cargos regulares (no a meses) + $30.00",
      "Pagos y abonos - $5.00",
      "Saldo deudor total $35.00",
      "CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)",
      "__PDF_PAGE_3__",
      "2026-08-01 2026-08-01 RESTAURANTE EJEMPLO +$10.00",
      "2026-08-02 2026-08-02 DESGLOSE DE MOVIMIENTOS +$99.00",
      "2026-08-02 2026-08-02 CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES +$88.00",
      "2026-08-03 2026-08-03 POR -$7.00",
      "2026-08-03 2026-08-03 COMERCIO DOS +$20.00",
      "2026-08-04 2026-08-04 PAGO POR SPEI -$5.00",
      "Total de cargos +$30.00",
      "Total de abonos -$5.00",
    ].join("\n"),
  });

  const descriptions = Array.from(parsed.transactions, (row) => row.description.toLowerCase());
  assert.equal(parsed.reconciliation.status, "valid");
  assert.equal(parsed.transactions.length, 3);
  assert.equal(parsed.rejectedRowCount, 3);
  assert.equal(descriptions.some((value) => value.includes("desglose de movimientos")), false);
  assert.equal(descriptions.some((value) => value.includes("cargos, abonos y compras regulares")), false);
  assert.equal(descriptions.some((value) => value === "por"), false);
  assert.equal(parsed.transactions.filter((row) => row.kind === "cardPayment").length, 1);
});

test("el bundle nativo conserva candidatos Rappi legibles pero no valida una corriente incompleta", () => {
  const engine = loadEngine();
  const parsed = engine.parse({
    fileName: "rappi-reporte-febrero.pdf",
    mode: "ocr",
    text: [
      "Tarjeta de crédito RappiCard",
      "Cargos regulares (no a meses) + $22,526.21",
      "Cargos compras a meses (capital) + $0.00",
      "Pagos y abonos - $19,161.36",
      "Saldo deudor total $13,470.03",
      "CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)",
      "__PDF_PAGE_3__",
      "2026-02-22 2026-02-23 REST REINA DE LOS MARE +$566.50",
      "2026-02-23 2026-02-24 DESGLOSE DE MOVIMIENTOS +$1,022.25",
      "2026-02-24 2026-02-26 CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES +$90.00",
      "2026-02-24 2026-02-24 POR -$400.00",
      "2026-02-21 2026-02-24 EXTRA K ADOLFO PRIETO +$77.00",
      "2026-02-21 2026-02-21 LIB ROSARIO CASTELLANO +$72.25",
      "2026-02-21 2026-02-24 MERPAGO*GAJREST +$511.50",
      "2026-02-21 2026-02-21 CHILI S INSURGENTES +$458.70",
      "2026-02-26 2026-02-22 OP BRUESAL II +$490.00",
      "2026-02-21 2026-02-27 MERPAGO*CLUBCITOMX +$150.00",
    ].join("\n"),
  });

  assert.equal(parsed.transactions.length, 7);
  assert.equal(parsed.rejectedRowCount, 3);
  assert.equal(parsed.reconciliation.status, "invalid");
  assert.equal(parsed.reconciliation.extractedChargeTotal, 2_325.95);
  assert.equal(parsed.reconciliation.extractedPaymentTotal, 0);
});

test("iOS empaqueta y usa el puente compartido para ambos extractores Rappi", () => {
  const bridge = readFileSync(bridgePath, "utf8");
  const models = readFileSync(modelsPath, "utf8");
  const projectSpec = readFileSync(projectSpecPath, "utf8");
  assert.match(bridge, /import JavaScriptCore/);
  assert.match(bridge, /rappi-engine/);
  assert.match(bridge, /source\.selectionReason/);
  assert.match(bridge, /result\.reconciliation\?\.status == "valid"/);
  assert.match(models, /evidenceMethod == "pdf-text" \|\| evidenceMethod == "vision-ocr"/);
  assert.match(projectSpec, /Cauce\/Resources\/rappi-engine\.js/);
});
