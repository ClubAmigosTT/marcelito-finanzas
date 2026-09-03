/* global fetch, Response */

import test from "node:test";
import assert from "node:assert/strict";
import { createStatementReaderServer } from "../server/statement-reader.mjs";

const rows = [{
  index: 0,
  date: "2026-08-05",
  description: "SUPERMERCADO LOCAL",
  amount_cents: 24590,
  category: "Sin categoría",
  flow: "expense",
  kind: "purchase",
  travel: false,
}];

const classification = {
  classifications: [{
    index: 0,
    merchant: "Supermercado local",
    category: "Alimentos",
    recurring: false,
    extraordinary: false,
    travel: false,
    confidence: 0.96,
    reason: "Concepto de supermercado",
    requires_review: false,
  }],
};

const classifierRequestVersion = {
  classifierVersion: "transaction-classifier-2026.09.03.1",
  promptVersion: "expense-classification-v1",
};

async function withServer(fetchImpl, callback) {
  const server = createStatementReaderServer({
    env: {
      OPENAI_API_KEY: "server-secret",
      OPENAI_STATEMENT_MODEL: "mimo-v2.5-free",
      STATEMENT_READER_PROVIDER_URL: "https://api.openai.com/v1/chat/completions",
      STATEMENT_READER_TOKEN: "reader-token",
    },
    fetchImpl,
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  try {
    await callback(`http://127.0.0.1:${address.port}`);
  } finally {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
}

test("el endpoint de Zen clasifica filas sin aceptar PDFs ni cuentas", async () => {
  let providerBody;
  await withServer(async (_url, init) => {
    providerBody = JSON.parse(init.body);
    return new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify(classification) } }] }), { status: 200 });
  }, async (base) => {
    const response = await fetch(`${base}/api/transaction-classifier`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer reader-token" },
      body: JSON.stringify({ rows, ...classifierRequestVersion, pdfBase64: "must-not-be-used" }),
    });
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.equal(body.classifications[0].category, "Alimentos");
    const serialized = JSON.stringify(providerBody);
    assert.equal(serialized.includes("pdfBase64"), false);
    assert.equal(/"account"\s*:/.test(serialized), false);
    assert.equal(providerBody.messages[0].content[0].type, "text");
  });
});

test("el endpoint bloquea categorías o índices inválidos del proveedor", async () => {
  await withServer(async () => new Response(JSON.stringify({ output_text: JSON.stringify({ classifications: [{ ...classification.classifications[0], index: 0, category: "Deuda inventada" }] }) }), { status: 200 }), async (base) => {
    const response = await fetch(`${base}/api/transaction-classifier`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer reader-token" },
      body: JSON.stringify({ rows, ...classifierRequestVersion }),
    });
    assert.equal(response.status, 422);
  });
});

test("el endpoint nunca entrega transferencias o pagos de tarjeta a Zen", async () => {
  await withServer(async () => new Response(JSON.stringify({ output_text: JSON.stringify(classification) }), { status: 200 }), async (base) => {
    for (const kind of ["bankTransfer", "cardPayment", "refund", "credit"]) {
      const response = await fetch(`${base}/api/transaction-classifier`, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: "Bearer reader-token" },
        body: JSON.stringify({ rows: [{ ...rows[0], kind }] }),
      });
      assert.equal(response.status, 422, `kind=${kind}`);
    }
  });
});

test("el endpoint rechaza un contrato de clasificador desactualizado", async () => {
  await withServer(async () => new Response(JSON.stringify({ output_text: JSON.stringify(classification) }), { status: 200 }), async (base) => {
    const response = await fetch(`${base}/api/transaction-classifier`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer reader-token" },
      body: JSON.stringify({ rows, classifierVersion: "transaction-classifier-legacy", promptVersion: "expense-classification-legacy" }),
    });
    assert.equal(response.status, 422);
  });
});

test("el preflight del clasificador usa la misma allowlist gratuita", async () => {
  await withServer(async () => new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify(classification) } }] }), { status: 200 }), async (base) => {
    const response = await fetch(`${base}/api/transaction-classifier/preflight`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer reader-token" },
      body: "{}",
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { status: "ready", model: "mimo-v2.5-free", contract: "transaction-classification.v1" });
  });
});
