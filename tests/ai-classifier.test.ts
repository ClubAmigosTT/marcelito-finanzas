import assert from "node:assert/strict";
import test from "node:test";
import {
  applyTransactionClassifications,
  buildClassificationInputs,
  classifierEndpoint,
  requestTransactionClassification,
  requestTransactionClassifierPreflight,
  TransactionClassifierError,
  validateTransactionClassification,
} from "../src/aiClassifier.ts";
import type { Transaction } from "../src/types.ts";

const expense = (overrides: Partial<Transaction> = {}): Transaction => ({
  id: overrides.id ?? "expense-1",
  date: overrides.date ?? "2026-08-05",
  description: overrides.description ?? "SUPERMERCADO LOCAL",
  account: overrides.account ?? "BBVA:0941",
  category: overrides.category ?? "Sin categoría",
  amount: overrides.amount ?? -245.90,
  flow: overrides.flow ?? "expense",
  kind: overrides.kind ?? "purchase",
  ...overrides,
});

test("Zen recibe únicamente gastos y nunca filas contables especiales", () => {
  const rows = buildClassificationInputs([
    expense({ id: "purchase" }),
    expense({ id: "payment", description: "PAGO AMEX", kind: "cardPayment", flow: "debt", amount: -1000 }),
    expense({ id: "transfer", description: "SPEI A CUENTA PROPIA", kind: "bankTransfer", flow: "transfer", amount: -500 }),
    expense({ id: "refund", description: "DEVOLUCION", kind: "refund", flow: "income", amount: 50 }),
  ]);
  assert.equal(rows.length, 1);
  assert.deepEqual(rows[0], {
    index: 0,
    date: "2026-08-05",
    description: "SUPERMERCADO LOCAL",
    amount_cents: 24590,
    category: "Sin categoría",
    flow: "expense",
    kind: "purchase",
    travel: false,
  });
});

test("la respuesta de Zen solo puede enriquecer, no mutar identidad contable", async () => {
  let body: Record<string, unknown> | undefined;
  const source = [expense({ id: "a" }), expense({ id: "b", description: "HOTEL CENTRO", amount: -1200 })];
  const response = await requestTransactionClassification(source, {
    endpoint: "https://reader.example/api/statement-reader",
    enabled: true,
    authorization: "Bearer temporary",
    fetchImpl: async (_url, init) => {
      body = JSON.parse(String(init?.body)) as Record<string, unknown>;
      return new Response(JSON.stringify({
        model: "mimo-v2.5-free",
        provider: "zen",
        version: "transaction-classifier-2026.09.03.1",
        classifications: [
          { index: 0, merchant: "Supermercado local", category: "Alimentos", recurring: false, extraordinary: false, travel: false, confidence: 0.96, reason: "Concepto de supermercado", requires_review: false },
          { index: 1, merchant: "Hotel centro", category: "Viajes", recurring: false, extraordinary: true, travel: true, confidence: 0.94, reason: "Alojamiento", requires_review: false },
        ],
      }), { status: 200 });
    },
  });
  const payloadRows = body?.rows as Array<Record<string, unknown>>;
  assert.equal(response.classifications.length, 2);
  assert.equal(body && "pdfBase64" in body, false);
  assert.equal(payloadRows[0]?.account, undefined);
  assert.equal(payloadRows[0]?.amount_cents, 24590);

  const enriched = applyTransactionClassifications(source, response);
  assert.equal(enriched[0].amount, source[0].amount);
  assert.equal(enriched[0].flow, source[0].flow);
  assert.equal(enriched[0].kind, source[0].kind);
  assert.equal(enriched[0].category, "Alimentos");
  assert.equal(enriched[1].travelRelated, true);
  assert.equal(enriched[1].classificationProvider, "zen");
});

test("el cliente rechaza una respuesta que suplanta al proveedor o la versión", async () => {
  await assert.rejects(
    requestTransactionClassification([expense()], {
      endpoint: "https://reader.example/api/transaction-classifier",
      enabled: true,
      fetchImpl: async () => new Response(JSON.stringify({
        provider: "otro-proveedor",
        version: "transaction-classifier-legacy",
        classifications: [{ index: 0, merchant: "Comercio", category: "Alimentos", recurring: false, extraordinary: false, travel: false, confidence: 0.9, reason: "Concepto", requires_review: false }],
      }), { status: 200 }),
    }),
    (error: unknown) => error instanceof TransactionClassifierError && error.code === "invalid_payload",
  );
});

test("el contrato rechaza una clasificación incompleta o con campos contables", () => {
  const expected = buildClassificationInputs([expense()]);
  assert.throws(
    () => validateTransactionClassification({ classifications: [] }, expected),
    (error: unknown) => error instanceof TransactionClassifierError && error.code === "invalid_payload",
  );
  assert.throws(
    () => validateTransactionClassification({ classifications: [{
      index: 0,
      merchant: "Comercio",
      category: "Alimentos",
      recurring: false,
      extraordinary: false,
      travel: false,
      confidence: 0.9,
      reason: "Texto suficiente",
      requires_review: false,
      amount: 999999,
    }] }, expected),
    (error: unknown) => error instanceof TransactionClassifierError && error.code === "invalid_payload",
  );
});

test("el preflight del clasificador no usa el endpoint de lectura de PDFs", async () => {
  let calledUrl = "";
  const result = await requestTransactionClassifierPreflight({
    endpoint: "https://reader.example/api/statement-reader",
    enabled: true,
    fetchImpl: async (url) => {
      calledUrl = String(url);
      return new Response(JSON.stringify({ status: "ready", model: "mimo-v2.5-free", contract: "transaction-classification.v1" }), { status: 200 });
    },
  });
  assert.equal(result.contract, "transaction-classification.v1");
  assert.match(calledUrl, /\/api\/transaction-classifier\/preflight$/);
});

test("el cliente acepta una URL directa del clasificador sin duplicar la ruta", () => {
  assert.equal(
    classifierEndpoint("https://reader.example/api/transaction-classifier"),
    "https://reader.example/api/transaction-classifier",
  );
  assert.equal(
    classifierEndpoint("https://reader.example/api/transaction-classifier/preflight"),
    "https://reader.example/api/transaction-classifier",
  );
});
