/* global Response */

import test from "node:test";
import assert from "node:assert/strict";
import { verifyReaderDeployment } from "../scripts/verify-reader-deployment.mjs";

test("verifica health y preflight sin enviar un PDF real", async () => {
  const calls = [];
  const result = await verifyReaderDeployment({
    endpoint: "https://reader.example/api/statement-reader",
    token: "temporary-reader-token",
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      if (String(url).endsWith("/health")) return new Response(JSON.stringify({ status: "ok", configured: true }), { status: 200 });
      return new Response(JSON.stringify({ status: "ready", model: "muse-spark-1.2-contributor-free", contract: "statement-extraction.v1" }), { status: 200 });
    },
  });
  assert.deepEqual(result.preflight, { status: "ready", model: "muse-spark-1.2-contributor-free", contract: "statement-extraction.v1" });
  assert.equal(calls.length, 2);
  assert.equal(calls[0].url, "https://reader.example/health");
  assert.equal(calls[1].url, "https://reader.example/api/statement-reader/preflight");
  assert.equal(calls[1].init.body, "{}");
  assert.equal(calls[1].init.headers.authorization, "Bearer temporary-reader-token");
});

test("bloquea un servicio cuya configuración o contrato no está listo", async () => {
  await assert.rejects(
    verifyReaderDeployment({
      endpoint: "https://reader.example/api/statement-reader",
      token: "temporary-reader-token",
      fetchImpl: async () => new Response(JSON.stringify({ status: "ok", configured: false }), { status: 200 }),
    }),
    /configured=true/,
  );
  await assert.rejects(
    verifyReaderDeployment({
      endpoint: "https://reader.example/api/statement-reader",
      token: "temporary-reader-token",
      fetchImpl: async (url) => String(url).endsWith("/health")
        ? new Response(JSON.stringify({ status: "ok", configured: true }), { status: 200 })
        : new Response(JSON.stringify({ status: "ready", model: "vision-model" }), { status: 200 }),
    }),
    /contrato JSON/,
  );
});

test("no permite verificar un endpoint HTTP público ni omitir el token", async () => {
  await assert.rejects(
    verifyReaderDeployment({ endpoint: "http://reader.example/api/statement-reader", token: "token" }),
    /HTTPS/,
  );
  await assert.rejects(
    verifyReaderDeployment({ endpoint: "https://reader.example/api/statement-reader" }),
    /Falta STATEMENT_READER_TOKEN/,
  );
});

