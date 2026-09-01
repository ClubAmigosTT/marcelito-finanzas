import test from "node:test";
import assert from "node:assert/strict";
import {
  MultimodalReaderError,
  extractionToImportResult,
  requestMultimodalExtraction,
  requestMultimodalReaderPreflight,
  validateMultimodalExtraction,
} from "../src/multimodalReader.ts";
import type { MultimodalStatementSummary } from "../src/multimodalReader.ts";

const summary = (overrides: Partial<MultimodalStatementSummary> = {}): MultimodalStatementSummary => ({
  previous_balance_cents: null,
  statement_balance_cents: null,
  debt_balance_cents: null,
  new_transactions_cents: null,
  payments_cents: null,
  credits_cents: null,
  payments_credits_cents: null,
  new_charges_cents: null,
  interest_cents: null,
  fees_cents: null,
  credit_limit_cents: null,
  credit_available_cents: null,
  minimum_payment_cents: null,
  minimum_plus_msi_cents: null,
  payment_for_no_interest_cents: null,
  cash_balance_cents: null,
  msi_original_deferred_cents: null,
  msi_pending_cents: null,
  revolving_balance_cents: null,
  msi_installments: null,
  msi_monthly_load_cents: null,
  domestic_transaction_total_cents: null,
  domestic_transaction_total_is_credit: null,
  foreign_transaction_total_cents: null,
  deposit_total_cents: null,
  withdrawal_total_cents: null,
  deposit_count: null,
  withdrawal_count: null,
  ...overrides,
});

const bankExtraction = (overrides: Record<string, unknown> = {}) => ({
  source: "BBVA",
  kind: "bank",
  account_last4: "0941",
  period_start: "2026-08-01",
  period_end: "2026-08-31",
  cutoff_date: "2026-08-31",
  page_count: 2,
  summary: summary({
    previous_balance_cents: 100_000,
    cash_balance_cents: 130_000,
    deposit_total_cents: 100_000,
    withdrawal_total_cents: 70_000,
    deposit_count: 1,
    withdrawal_count: 1,
  }),
  rows: [
    { date: "2026-08-05", description: "NOMINA ACME", amount_cents: 100_000, direction: "in", kind: "income", foreign_currency: false, page: 1, evidence: "05/AGO NOMINA ACME 1,000.00", confidence: 0.99 },
    { date: "2026-08-06", description: "SUPERMERCADO LOCAL", amount_cents: 70_000, direction: "out", kind: "purchase", foreign_currency: false, page: 1, evidence: "06/AGO SUPERMERCADO LOCAL 700.00", confidence: 0.99 },
  ],
  ...overrides,
});

test("valida contrato multimodal y rechaza encabezados como movimientos", () => {
  const valid = validateMultimodalExtraction(bankExtraction());
  assert.equal(valid.rows.length, 2);
  assert.throws(
    () => validateMultimodalExtraction(bankExtraction({ rows: [{ ...valid.rows[0], description: "TOTAL IMPORTE CARGOS" }] })),
    (error: unknown) => error instanceof MultimodalReaderError && error.code === "invalid_payload",
  );
});

test("rechaza evidencia que no se puede vincular con el comercio", () => {
  assert.throws(
    () => validateMultimodalExtraction(bankExtraction({
      rows: [{ ...bankExtraction().rows[0], evidence: "31/AGO SALDO FINAL 1,000.00" }],
    })),
    (error: unknown) => error instanceof MultimodalReaderError && error.code === "invalid_payload",
  );
});

test("convierte centavos, conserva evidencia y reconcilia antes de entregar el resultado", () => {
  const result = extractionToImportResult({ ...bankExtraction(), source: "BBVA MEXICO, S.A., INSTITUCION DE BANCA MULTIPLE" }, { name: "BBVA agosto.pdf", size: 1200 });
  assert.equal(result.source, "BBVA");
  assert.equal(result.accountKey, "BBVA:0941");
  assert.equal(result.extractionProvider, "multimodal");
  assert.equal(result.transactions[0].amount, 1000);
  assert.equal(result.transactions[1].amount, -700);
  assert.equal(result.transactions[0].extractionEvidence?.method, "multimodal");
  assert.equal(result.reconciliation?.status, "valid");
});

test("rechaza un emisor que en realidad es texto administrativo", () => {
  assert.throws(
    () => validateMultimodalExtraction({ ...bankExtraction(), source: "Ciudad de México" }),
    (error: unknown) => error instanceof MultimodalReaderError && error.code === "invalid_payload",
  );
});

test("la extracción de tarjeta conserva deuda y separa un pago de tarjeta del gasto", () => {
  const result = extractionToImportResult({
    source: "Amex",
    kind: "card",
    account_last4: "1234",
    period_start: "2026-07-28",
    period_end: "2026-08-27",
    cutoff_date: "2026-08-27",
    page_count: 4,
    summary: summary({
      debt_balance_cents: 5_036_721,
      statement_balance_cents: 5_036_721,
      credit_limit_cents: 15_000_000,
      credit_available_cents: 9_963_279,
      payment_for_no_interest_cents: 3_996_615,
      minimum_plus_msi_cents: 1_957_969,
      domestic_transaction_total_cents: 1_200_000,
      foreign_transaction_total_cents: 0,
    }),
    rows: [
      { date: "2026-08-02", description: "HOTEL EJEMPLO", amount_cents: 1_200_000, direction: "out", kind: "purchase", foreign_currency: false, page: 2, evidence: "02/AGO HOTEL EJEMPLO 12,000.00", confidence: 0.98 },
      { date: "2026-08-10", description: "PAGO RECIBIDO", amount_cents: 3_000_000, direction: "in", kind: "cardPayment", foreign_currency: false, page: 1, evidence: "10/AGO PAGO RECIBIDO 30,000.00", confidence: 0.99 },
    ],
  }, { name: "Amex agosto.pdf", size: 900 });
  assert.equal(result.summary?.debtBalance, 50_367.21);
  assert.equal(result.summary?.paymentForNoInterest, 39_966.15);
  assert.equal(result.transactions[0].flow, "expense");
  assert.equal(result.transactions[1].flow, "debt");
  assert.equal(result.reconciliation?.status, "valid");
});

test("no envía el PDF sin opt-in y acepta únicamente respuestas JSON válidas del proxy", async () => {
  const file = {
    name: "BBVA agosto.pdf",
    size: 3,
    arrayBuffer: async () => new Uint8Array([1, 2, 3]).buffer,
  } as unknown as File;
  await assert.rejects(
    requestMultimodalExtraction(file, { endpoint: "https://reader.invalid", enabled: false }),
    (error: unknown) => error instanceof MultimodalReaderError && error.code === "not_configured",
  );

  let requestBody = "";
  const response = await requestMultimodalExtraction(file, {
    endpoint: "https://reader.example/api/statement-reader",
    enabled: true,
    fetchImpl: async (_input, init) => {
      requestBody = String(init?.body ?? "");
      return new Response(JSON.stringify({ extraction: bankExtraction(), model: "vision-statement-v1", sourceFingerprint: "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81" }), { status: 200, headers: { "content-type": "application/json" } });
    },
  });
  assert.equal(response.extraction.rows.length, 2);
  assert.equal(response.model, "vision-statement-v1");
  assert.equal(response.sourceFingerprint, "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81");
  assert.match(requestBody, /pdfBase64/);
  assert.doesNotMatch(requestBody, /api[_-]?key/i);
});

test("rechaza una extracción cuyo hash no corresponde al PDF enviado", async () => {
  const file = {
    name: "estado.pdf",
    size: 3,
    arrayBuffer: async () => new Uint8Array([1, 2, 3]).buffer,
  } as unknown as File;
  await assert.rejects(
    requestMultimodalExtraction(file, {
      endpoint: "https://reader.example/api/statement-reader",
      enabled: true,
      fetchImpl: async () => new Response(JSON.stringify({ extraction: bankExtraction(), sourceFingerprint: "f".repeat(64) }), { status: 200 }),
    }),
    (error: unknown) => error instanceof MultimodalReaderError && error.code === "invalid_payload",
  );
});

test("no envía el PDF a un endpoint HTTP público", async () => {
  const file = {
    name: "estado.pdf",
    size: 3,
    arrayBuffer: async () => new Uint8Array([1, 2, 3]).buffer,
  } as unknown as File;
  await assert.rejects(
    requestMultimodalExtraction(file, { endpoint: "http://reader.example/api/statement-reader", enabled: true }),
    (error: unknown) => error instanceof MultimodalReaderError && error.code === "not_configured",
  );
});

test("el preflight comprueba el contrato sin leer un archivo del usuario", async () => {
  let requestBody = "";
  const result = await requestMultimodalReaderPreflight({
    endpoint: "https://reader.example/api/statement-reader",
    enabled: true,
    authorization: "Bearer reader-token",
    fetchImpl: async (_input, init) => {
      requestBody = String(init?.body ?? "");
      return new Response(JSON.stringify({ status: "ready", model: "vision-statement-v1", contract: "statement-extraction.v1" }), { status: 200 });
    },
  });
  assert.deepEqual(result, { status: "ready", model: "vision-statement-v1", contract: "statement-extraction.v1" });
  assert.equal(requestBody, "{}");
});

test("el preflight no acepta un proveedor que omite el contrato", async () => {
  await assert.rejects(
    requestMultimodalReaderPreflight({
      endpoint: "https://reader.example/api/statement-reader",
      enabled: true,
      fetchImpl: async () => new Response(JSON.stringify({ status: "ready", model: "vision-statement-v1" }), { status: 200 }),
    }),
    (error: unknown) => error instanceof MultimodalReaderError && error.code === "invalid_payload",
  );
});
