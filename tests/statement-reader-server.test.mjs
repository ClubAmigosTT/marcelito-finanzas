/* global fetch, Response */

import test from "node:test";
import assert from "node:assert/strict";
import { createStatementReaderServer } from "../server/statement-reader.mjs";

const emptySummary = () => ({
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
});

const extraction = {
  source: "BBVA",
  kind: "bank",
  account_last4: "0941",
  period_start: "2026-08-01",
  period_end: "2026-08-31",
  cutoff_date: "2026-08-31",
  page_count: 1,
  summary: emptySummary(),
  rows: [],
};

test("el proxy exige token y nunca devuelve el PDF", async () => {
  let providerBody;
  const server = createStatementReaderServer({
    env: {
      OPENAI_API_KEY: "server-secret",
      OPENAI_STATEMENT_MODEL: "vision-model",
      STATEMENT_READER_TOKEN: "reader-token",
      STATEMENT_READER_ALLOWED_ORIGIN: "https://app.example",
    },
    fetchImpl: async (_url, init) => {
      providerBody = JSON.parse(init.body);
      return new Response(JSON.stringify({ output_text: JSON.stringify(extraction) }), { status: 200 });
    },
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  const base = `http://127.0.0.1:${address.port}`;
  try {
    const health = await fetch(`${base}/health`);
    assert.deepEqual(await health.json(), { status: "ok", configured: true });

    const unauthorized = await fetch(`${base}/api/statement-reader`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ fileName: "estado.pdf", pdfBase64: "JVBERi0xLjQ=" }),
    });
    assert.equal(unauthorized.status, 401);

    const response = await fetch(`${base}/api/statement-reader`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: "Bearer reader-token",
        origin: "https://app.example",
      },
      body: JSON.stringify({ fileName: "estado.pdf", pdfBase64: "JVBERi0xLjQ=" }),
    });
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.equal(body.extraction.source, "BBVA");
    assert.equal(body.sourceFingerprint.length, 64);
    assert.equal(providerBody.store, false);
    assert.equal(providerBody.input[0].content[0].type, "input_file");
    assert.match(providerBody.input[0].content[0].file_data, /^data:application\/pdf;base64,/);
    assert.ok(!JSON.stringify(body).includes("JVBERi0xLjQ="));
  } finally {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
});

test("el proxy descarta respuestas del proveedor que contienen filas administrativas", async () => {
  const server = createStatementReaderServer({
    env: {
      OPENAI_API_KEY: "server-secret",
      OPENAI_STATEMENT_MODEL: "vision-model",
      STATEMENT_READER_TOKEN: "reader-token",
    },
    fetchImpl: async () => new Response(JSON.stringify({
      output_text: JSON.stringify({
        ...extraction,
        rows: [{
          date: "2026-08-05",
          description: "TOTAL IMPORTE CARGOS",
          amount_cents: 100,
          direction: "out",
          kind: "purchase",
          foreign_currency: false,
          page: 1,
          evidence: "TOTAL IMPORTE CARGOS 1.00",
          confidence: 1,
        }],
      }),
    }), { status: 200 }),
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  try {
    const response = await fetch(`http://127.0.0.1:${address.port}/api/statement-reader`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer reader-token" },
      body: JSON.stringify({ fileName: "estado.pdf", pdfBase64: "JVBERi0xLjQ=" }),
    });
    assert.equal(response.status, 422);
  } finally {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
});

test("el proxy rechaza una respuesta que no cumple todos los campos del contrato", async () => {
  const incomplete = JSON.parse(JSON.stringify(extraction));
  delete incomplete.summary.fees_cents;
  const server = createStatementReaderServer({
    env: {
      OPENAI_API_KEY: "server-secret",
      OPENAI_STATEMENT_MODEL: "vision-model",
      STATEMENT_READER_TOKEN: "reader-token",
    },
    fetchImpl: async () => new Response(JSON.stringify({ output_text: JSON.stringify(incomplete) }), { status: 200 }),
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  try {
    const response = await fetch(`http://127.0.0.1:${address.port}/api/statement-reader`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer reader-token" },
      body: JSON.stringify({ fileName: "estado.pdf", pdfBase64: "JVBERi0xLjQ=" }),
    });
    assert.equal(response.status, 422);
  } finally {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
});

test("el proxy rechaza bytes que no son un PDF", async () => {
  const server = createStatementReaderServer({
    env: {
      OPENAI_API_KEY: "server-secret",
      OPENAI_STATEMENT_MODEL: "vision-model",
      STATEMENT_READER_TOKEN: "reader-token",
    },
    fetchImpl: async () => {
      throw new Error("no debe llamar al proveedor");
    },
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  try {
    const response = await fetch(`http://127.0.0.1:${address.port}/api/statement-reader`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer reader-token" },
      body: JSON.stringify({ fileName: "estado.pdf", pdfBase64: "AAECAwQ=" }),
    });
    assert.equal(response.status, 400);
  } finally {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
});

test("el proxy limita solicitudes autenticadas por origen", async () => {
  const server = createStatementReaderServer({
    env: {
      OPENAI_API_KEY: "server-secret",
      OPENAI_STATEMENT_MODEL: "vision-model",
      STATEMENT_READER_TOKEN: "reader-token",
      STATEMENT_READER_MAX_REQUESTS_PER_MINUTE: "1",
    },
    fetchImpl: async () => new Response(JSON.stringify({ output_text: JSON.stringify(extraction) }), { status: 200 }),
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  const request = () => fetch(`http://127.0.0.1:${address.port}/api/statement-reader`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer reader-token" },
    body: JSON.stringify({ fileName: "estado.pdf", pdfBase64: "JVBERi0xLjQ=" }),
  });
  try {
    assert.equal((await request()).status, 200);
    assert.equal((await request()).status, 429);
  } finally {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
});

test("el proxy permite configurar un endpoint compatible sin exponer la clave", async () => {
  let providerUrl = "";
  let providerAuthorization = "";
  const server = createStatementReaderServer({
    env: {
      STATEMENT_READER_API_KEY: "provider-secret",
      STATEMENT_READER_MODEL: "vision-model",
      STATEMENT_READER_PROVIDER_URL: "https://zen.example/v1/responses",
      STATEMENT_READER_TOKEN: "reader-token",
    },
    fetchImpl: async (url, init) => {
      providerUrl = String(url);
      providerAuthorization = init.headers.authorization;
      return new Response(JSON.stringify({ output_text: JSON.stringify(extraction) }), { status: 200 });
    },
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  try {
    const response = await fetch(`http://127.0.0.1:${address.port}/api/statement-reader`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer reader-token" },
      body: JSON.stringify({ fileName: "estado.pdf", pdfBase64: "JVBERi0xLjQ=" }),
    });
    assert.equal(response.status, 200);
    assert.equal(providerUrl, "https://zen.example/v1/responses");
    assert.equal(providerAuthorization, "Bearer provider-secret");
    assert.ok(!JSON.stringify(await response.json()).includes("provider-secret"));
  } finally {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
});

test("el preflight prueba PDF y JSON sin enviar un estado del usuario", async () => {
  let providerBody;
  const server = createStatementReaderServer({
    env: {
      STATEMENT_READER_API_KEY: "provider-secret",
      STATEMENT_READER_MODEL: "vision-model",
      STATEMENT_READER_TOKEN: "reader-token",
    },
    fetchImpl: async (_url, init) => {
      providerBody = JSON.parse(init.body);
      return new Response(JSON.stringify({ output_text: JSON.stringify({
        ...extraction,
        source: "unknown",
        kind: "unknown",
        account_last4: null,
        period_start: null,
        period_end: null,
        cutoff_date: null,
        summary: emptySummary(),
        rows: [],
      }) }), { status: 200 });
    },
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  try {
    const response = await fetch(`http://127.0.0.1:${address.port}/api/statement-reader/preflight`, {
      method: "POST",
      headers: { authorization: "Bearer reader-token" },
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {
      status: "ready",
      model: "vision-model",
      contract: "statement-extraction.v1",
    });
    const encoded = providerBody.input[0].content[0].file_data;
    assert.match(encoded, /^data:application\/pdf;base64,/);
    assert.match(providerBody.input[0].content[1].text, /prueba técnica/);
    assert.ok(!JSON.stringify(providerBody).includes("provider-secret"));
  } finally {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
});
